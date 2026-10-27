#import "MLChipLocatorController.h"

#import "MLChipLocatorPanel.h"
#import "MLConfigStore.h"
#import "MLIconCache.h"
#import "MLRunningAppsMonitor.h"
#import "MLStrings.h"
#import "MLTaskbarController.h"
#import "MLTaskbarController+Categories.h"
#import "MLTaskbarView.h"
#import "MLWindowActivationMRU.h"

enum {
    MLChipLocatorDefaultVisibleRows = 10,
};

@interface MLChipLocatorCandidate : NSObject
@property (nonatomic, strong) MLTaskbarItem *item;
@property (nonatomic, strong) NSNumber *screenID;
@property (nonatomic, copy) NSString *screenName;
@property (nonatomic, assign) NSInteger sectionOrder; /* 0 = focus screen */
@property (nonatomic, assign) NSInteger frozenIndex;  /* stable order while panel open */
@property (nonatomic, assign) CGFloat matchScore;
@property (nonatomic, copy) NSString *appName;
@end

@implementation MLChipLocatorCandidate
@end

@interface MLChipLocatorController () <MLChipLocatorPanelDelegate>
@property (nonatomic, strong) MLChipLocatorPanel *panel;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, strong) NSNumber *focusScreenID;
@property (nonatomic, copy) NSArray<MLChipLocatorCandidate *> *allCandidates;
@property (nonatomic, copy) NSArray<MLChipLocatorCandidate *> *filteredCandidates;
@property (nonatomic, assign) NSInteger highlightIndex;
@property (nonatomic, assign) BOOL showingAll;
@property (nonatomic, strong) id resignObserver;
@property (nonatomic, strong) id outsideClickMonitor;
/** Ignore resign-key close while raiseOnly steals then returns focus. */
@property (nonatomic, assign) BOOL suppressResignClose;
@property (nonatomic, assign) NSInteger raiseShieldGeneration;
@property (nonatomic, assign) NSInteger previewDebounceGeneration;
/** After open, list order is frozen (no MRU reshuffle on preview). */
@property (nonatomic, assign) BOOL listOrderFrozen;
@end

@implementation MLChipLocatorController

#pragma mark - Fuzzy

/** Higher is better. 0 = no match. */
static CGFloat MLChipLocatorFuzzyScore(NSString *haystack, NSString *needle) {
    if (needle.length == 0) {
        return 1.0;
    }
    if (haystack.length == 0) {
        return 0.0;
    }
    NSString *h = haystack.localizedLowercaseString;
    NSString *n = needle.localizedLowercaseString;
    if ([h isEqualToString:n]) {
        return 1000.0;
    }
    if ([h hasPrefix:n]) {
        return 800.0 + (CGFloat)n.length;
    }
    NSRange sub = [h rangeOfString:n];
    if (sub.location != NSNotFound) {
        return 600.0 - (CGFloat)sub.location * 0.5 + (CGFloat)n.length;
    }
    /* Subsequence: a…b…c */
    NSUInteger hi = 0;
    NSUInteger gaps = 0;
    NSUInteger last = NSNotFound;
    for (NSUInteger ni = 0; ni < n.length; ni++) {
        unichar nc = [n characterAtIndex:ni];
        BOOL found = NO;
        while (hi < h.length) {
            unichar hc = [h characterAtIndex:hi];
            hi++;
            if (hc == nc) {
                found = YES;
                if (last != NSNotFound) {
                    gaps += (hi - 1) - last - 1;
                }
                last = hi - 1;
                break;
            }
        }
        if (!found) {
            return 0.0;
        }
    }
    return 300.0 - (CGFloat)gaps * 2.0 + (CGFloat)n.length;
}

static CGFloat MLChipLocatorBestScore(MLChipLocatorCandidate *c, NSString *query) {
    if (query.length == 0) {
        return 1.0;
    }
    CGFloat titleScore = MLChipLocatorFuzzyScore(c.item.title, query);
    CGFloat appScore = MLChipLocatorFuzzyScore(c.appName, query);
    CGFloat pathScore = 0;
    if (c.item.path.length > 0) {
        pathScore = MLChipLocatorFuzzyScore(c.item.path.lastPathComponent.stringByDeletingPathExtension,
                                            query) *
                    0.5;
    }
    CGFloat best = MAX(titleScore, MAX(appScore, pathScore));
    if (titleScore > 0 && titleScore >= appScore) {
        best += 5.0;
    }
    return best;
}

#pragma mark - Lifecycle

- (void)dealloc {
    [self uninstallObservers];
}

- (BOOL)isVisible {
    return self.visible;
}

- (void)toggle {
    if (self.visible) {
        [self hide];
    } else {
        [self show];
    }
}

- (void)show {
    if (!self.taskbar) {
        return;
    }
    if (self.visible) {
        [self reclaimPanelKeyFocus];
        return;
    }

    if ([self.delegate respondsToSelector:@selector(chipLocatorControllerWillShow:)]) {
        [self.delegate chipLocatorControllerWillShow:self];
    }

    NSScreen *screen = [MLConfigStore screenUnderMouse];
    self.focusScreenID = [[self class] screenIDForScreenPublic:screen];

    self.showingAll = NO;
    self.highlightIndex = 0;
    self.suppressResignClose = YES;
    self.listOrderFrozen = NO;

    if (!self.panel) {
        self.panel = [[MLChipLocatorPanel alloc] initPanel];
        self.panel.locatorDelegate = self;
    }
    self.panel.iconCache = self.taskbar.iconCache;
    self.panel.showingAll = NO;
    self.panel.query = @"";

    /* Build list once at open — order freezes after this. */
    [self rebuildCandidates];
    [self freezeCandidateOrder];
    [self applyFilterRaisingFirst:NO];

    [self.panel layoutForScreen:screen];
    self.panel.alphaValue = 0.01;
    self.visible = YES;

    [NSApp activateIgnoringOtherApps:YES];
    [self.panel makeKeyAndOrderFront:nil];
    [self.panel focusSearchField];

    BOOL reduce = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (reduce) {
        self.panel.alphaValue = 1.0;
    } else {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.14;
            self.panel.animator.alphaValue = 1.0;
        }];
    }

    [self installObservers];

    /* After the panel is key, soft-preview row 0 without stealing focus. */
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self.visible) {
            return;
        }
        self.suppressResignClose = NO;
        if (self.highlightIndex >= 0) {
            [self previewHighlighted];
        }
    });
}

- (void)hide {
    if (!self.visible) {
        return;
    }
    [self uninstallObservers];
    self.visible = NO;
    self.listOrderFrozen = NO;
    self.suppressResignClose = NO;
    MLChipLocatorPanel *panel = self.panel;
    BOOL reduce = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    void (^finish)(void) = ^{
        [panel orderOut:nil];
        panel.alphaValue = 1.0;
    };
    if (reduce || !panel) {
        finish();
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.12;
        panel.animator.alphaValue = 0.0;
    } completionHandler:finish];
}

- (void)reclaimPanelKeyFocus {
    if (!self.visible || !self.panel) {
        return;
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.panel focusSearchField];
}

#pragma mark - Candidates

+ (NSNumber *)screenIDForScreenPublic:(NSScreen *)screen {
    if (!screen) {
        return @0;
    }
    id num = screen.deviceDescription[@"NSScreenNumber"];
    if ([num isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)num;
    }
    return @(screen.hash);
}

- (NSString *)localizedNameForScreenID:(NSNumber *)sid {
    for (NSScreen *s in NSScreen.screens) {
        NSNumber *idNum = [[self class] screenIDForScreenPublic:s];
        if ([idNum isEqualToNumber:sid]) {
            if (s.localizedName.length > 0) {
                return s.localizedName;
            }
            break;
        }
    }
    return [NSString stringWithFormat:@"Display %@", sid ?: @0];
}

- (void)rebuildCandidates {
    NSDictionary<NSNumber *, NSArray<MLTaskbarItem *> *> *byScreen =
        [self.taskbar chipLocatorItemsByScreenID];
    MLWindowActivationMRU *mru = self.taskbar.activationMRU;

    NSMutableArray<NSNumber *> *screenOrder = [NSMutableArray array];
    if (self.focusScreenID) {
        [screenOrder addObject:self.focusScreenID];
    }
    NSMutableArray<NSNumber *> *others = [NSMutableArray array];
    for (NSNumber *sid in byScreen.allKeys) {
        if (self.focusScreenID && [sid isEqualToNumber:self.focusScreenID]) {
            continue;
        }
        [others addObject:sid];
    }
    [others sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSInteger ra = [mru rankForScreenID:a];
        NSInteger rb = [mru rankForScreenID:b];
        if (ra != rb) {
            return ra < rb ? NSOrderedAscending : NSOrderedDescending;
        }
        /* Main screen before others; then stable by screenID. */
        NSNumber *mainID = [[self class] screenIDForScreenPublic:NSScreen.mainScreen];
        BOOL aMain = mainID && [a isEqualToNumber:mainID];
        BOOL bMain = mainID && [b isEqualToNumber:mainID];
        if (aMain != bMain) {
            return aMain ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a compare:b];
    }];
    [screenOrder addObjectsFromArray:others];

    NSMutableArray<MLChipLocatorCandidate *> *all = [NSMutableArray array];
    NSInteger section = 0;
    for (NSNumber *sid in screenOrder) {
        NSArray<MLTaskbarItem *> *items = byScreen[sid];
        if (items.count == 0) {
            section++;
            continue;
        }
        NSString *name = [self localizedNameForScreenID:sid];
        NSMutableArray<MLChipLocatorCandidate *> *sectionCands = [NSMutableArray array];
        for (MLTaskbarItem *it in items) {
            MLChipLocatorCandidate *c = [[MLChipLocatorCandidate alloc] init];
            c.item = it;
            c.screenID = sid;
            c.screenName = name;
            c.sectionOrder = section;
            c.appName = [self.taskbar displayNameForPath:it.path] ?: @"";
            [sectionCands addObject:c];
        }
        [sectionCands sortUsingComparator:^NSComparisonResult(MLChipLocatorCandidate *a,
                                                              MLChipLocatorCandidate *b) {
            return [self compareCandidate:a to:b query:@""];
        }];
        [all addObjectsFromArray:sectionCands];
        section++;
    }
    self.allCandidates = all;
}

- (void)freezeCandidateOrder {
    NSInteger i = 0;
    for (MLChipLocatorCandidate *c in self.allCandidates) {
        c.frozenIndex = i++;
    }
    self.listOrderFrozen = YES;
}

- (NSComparisonResult)compareCandidate:(MLChipLocatorCandidate *)a
                                    to:(MLChipLocatorCandidate *)b
                                 query:(NSString *)query {
    if (query.length > 0) {
        if (a.matchScore != b.matchScore) {
            return a.matchScore > b.matchScore ? NSOrderedAscending : NSOrderedDescending;
        }
        /* Keep open-time relative order among equal scores. */
        if (self.listOrderFrozen && a.frozenIndex != b.frozenIndex) {
            return a.frozenIndex < b.frozenIndex ? NSOrderedAscending : NSOrderedDescending;
        }
    }
    if (self.listOrderFrozen) {
        if (a.frozenIndex != b.frozenIndex) {
            return a.frozenIndex < b.frozenIndex ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }
    MLWindowActivationMRU *mru = self.taskbar.activationMRU;
    NSInteger ra;
    NSInteger rb;
    if (a.item.windowID != 0) {
        ra = [mru rankForWindowID:a.item.windowID];
    } else {
        ra = [mru rankForPath:a.item.path];
    }
    if (b.item.windowID != 0) {
        rb = [mru rankForWindowID:b.item.windowID];
    } else {
        rb = [mru rankForPath:b.item.path];
    }
    if (ra != rb) {
        return ra < rb ? NSOrderedAscending : NSOrderedDescending;
    }
    if (a.item.seenOrder != b.item.seenOrder) {
        if (a.item.seenOrder == 0) {
            return NSOrderedDescending;
        }
        if (b.item.seenOrder == 0) {
            return NSOrderedAscending;
        }
        return a.item.seenOrder < b.item.seenOrder ? NSOrderedAscending : NSOrderedDescending;
    }
    return [(a.item.title ?: @"") compare:(b.item.title ?: @"")];
}

/** While open: refresh titles / drop closed windows without reshuffling order. */
- (void)refreshFrozenCandidatesInPlace {
    NSDictionary<NSNumber *, NSArray<MLTaskbarItem *> *> *byScreen =
        [self.taskbar chipLocatorItemsByScreenID];
    NSMutableDictionary<NSString *, MLTaskbarItem *> *live = [NSMutableDictionary dictionary];
    for (NSNumber *sid in byScreen) {
        for (MLTaskbarItem *it in byScreen[sid]) {
            NSString *key = nil;
            if (it.windowID != 0) {
                key = [NSString stringWithFormat:@"w:%u", (unsigned)it.windowID];
            } else if (it.path.length > 0) {
                key = [NSString stringWithFormat:@"p:%ld:%@", (long)it.kind, it.path];
            }
            if (key) {
                live[key] = it;
            }
        }
    }
    NSMutableArray<MLChipLocatorCandidate *> *kept = [NSMutableArray array];
    for (MLChipLocatorCandidate *c in self.allCandidates) {
        NSString *key = nil;
        if (c.item.windowID != 0) {
            key = [NSString stringWithFormat:@"w:%u", (unsigned)c.item.windowID];
        } else if (c.item.path.length > 0) {
            key = [NSString stringWithFormat:@"p:%ld:%@", (long)c.item.kind, c.item.path];
        }
        MLTaskbarItem *fresh = key ? live[key] : nil;
        if (!fresh) {
            continue; /* window closed — drop, keep relative order of survivors */
        }
        c.item = fresh;
        c.appName = [self.taskbar displayNameForPath:fresh.path] ?: c.appName;
        [kept addObject:c];
    }
    self.allCandidates = kept;
}

- (void)applyFilterRaisingFirst:(BOOL)raiseFirst {
    NSString *query = self.panel.query ?: @"";
    NSMutableArray<MLChipLocatorCandidate *> *filtered = [NSMutableArray array];

    /* Keep section grouping (decision A). */
    NSInteger maxSection = -1;
    for (MLChipLocatorCandidate *c in self.allCandidates) {
        if (c.sectionOrder > maxSection) {
            maxSection = c.sectionOrder;
        }
    }
    for (NSInteger sec = 0; sec <= maxSection; sec++) {
        NSMutableArray<MLChipLocatorCandidate *> *bucket = [NSMutableArray array];
        for (MLChipLocatorCandidate *c in self.allCandidates) {
            if (c.sectionOrder != sec) {
                continue;
            }
            CGFloat score = MLChipLocatorBestScore(c, query);
            if (query.length > 0 && score <= 0) {
                continue;
            }
            c.matchScore = score;
            [bucket addObject:c];
        }
        [bucket sortUsingComparator:^NSComparisonResult(MLChipLocatorCandidate *a,
                                                        MLChipLocatorCandidate *b) {
            return [self compareCandidate:a to:b query:query];
        }];
        [filtered addObjectsFromArray:bucket];
    }
    self.filteredCandidates = filtered;
    if (self.highlightIndex >= (NSInteger)filtered.count) {
        self.highlightIndex = filtered.count > 0 ? 0 : -1;
    }
    if (self.highlightIndex < 0 && filtered.count > 0) {
        self.highlightIndex = 0;
    }
    [self rebuildPanelRows];
    if (raiseFirst && self.highlightIndex >= 0) {
        [self schedulePreviewHighlighted];
    }
}

- (NSString *)subtitleForCandidate:(MLChipLocatorCandidate *)c {
    MLTaskbarItem *it = c.item;
    if (it.kind == MLTaskbarItemRunningWindow) {
        return c.appName.length > 0 ? c.appName : @"";
    }
    if (it.kind == MLTaskbarItemRunningNoWindow) {
        return [MLStrings t:@"locator.subtitle_running"];
    }
    if (it.kind == MLTaskbarItemPinnedOnly) {
        return [MLStrings t:@"locator.subtitle_pinned"];
    }
    return c.appName ?: @"";
}

- (void)rebuildPanelRows {
    NSArray<MLChipLocatorCandidate *> *filtered = self.filteredCandidates ?: @[];
    NSMutableArray<MLChipLocatorRow *> *rows = [NSMutableArray array];

    if (filtered.count == 0) {
        MLChipLocatorRow *empty = [[MLChipLocatorRow alloc] init];
        empty.isEmptyPlaceholder = YES;
        empty.candidateIndex = -1;
        NSString *q = self.panel.query ?: @"";
        empty.title = q.length > 0 ? [MLStrings t:@"locator.no_match"]
                                   : [MLStrings t:@"locator.empty"];
        [rows addObject:empty];
        self.panel.highlightedCandidateIndex = -1;
        self.panel.rows = rows;
        [self.panel updateEmptyMessage:nil];
        [self.panel reloadListKeepingHighlight:NO];
        return;
    }

    NSUInteger limit = self.showingAll ? filtered.count
                                       : MIN(filtered.count, (NSUInteger)MLChipLocatorDefaultVisibleRows);
    NSInteger lastSection = -1;
    NSInteger visibleCand = 0;
    NSUInteger emitted = 0;
    BOOL multiScreen = NO;
    NSNumber *firstSID = filtered.firstObject.screenID;
    for (MLChipLocatorCandidate *c in filtered) {
        if (firstSID && c.screenID && ![c.screenID isEqualToNumber:firstSID]) {
            multiScreen = YES;
            break;
        }
        if (!firstSID && c.screenID) {
            firstSID = c.screenID;
        }
    }
    /* Also multi if more than one screen in NSScreen.screens and we have focus section label. */
    if (NSScreen.screens.count > 1) {
        multiScreen = YES;
    }

    for (NSUInteger i = 0; i < filtered.count && emitted < limit; i++) {
        MLChipLocatorCandidate *c = filtered[i];
        if (multiScreen && c.sectionOrder != lastSection) {
            MLChipLocatorRow *hdr = [[MLChipLocatorRow alloc] init];
            hdr.isSectionHeader = YES;
            hdr.candidateIndex = -1;
            BOOL isFocus = self.focusScreenID && [c.screenID isEqualToNumber:self.focusScreenID];
            NSString *fmt = isFocus ? [MLStrings t:@"locator.section_this_display"]
                                    : [MLStrings t:@"locator.section_display"];
            hdr.headerTitle = [NSString stringWithFormat:fmt, c.screenName ?: @""];
            [rows addObject:hdr];
            lastSection = c.sectionOrder;
        }
        MLChipLocatorRow *row = [[MLChipLocatorRow alloc] init];
        row.candidateIndex = (NSInteger)i;
        row.title = c.item.title.length > 0 ? c.item.title : c.appName;
        row.subtitle = [self subtitleForCandidate:c];
        row.iconPath = c.item.path;
        [rows addObject:row];
        emitted++;
        if ((NSInteger)i == self.highlightIndex) {
            visibleCand = (NSInteger)i;
        }
    }

    if (!self.showingAll && filtered.count > (NSUInteger)MLChipLocatorDefaultVisibleRows) {
        MLChipLocatorRow *footer = [[MLChipLocatorRow alloc] init];
        footer.isShowAllFooter = YES;
        footer.candidateIndex = -1;
        footer.remainingHiddenCount =
            filtered.count - (NSUInteger)MLChipLocatorDefaultVisibleRows;
        [rows addObject:footer];
    } else if (self.showingAll && filtered.count > (NSUInteger)MLChipLocatorDefaultVisibleRows) {
        MLChipLocatorRow *footer = [[MLChipLocatorRow alloc] init];
        footer.isShowAllFooter = YES;
        footer.candidateIndex = -1;
        [rows addObject:footer];
    }

    if (self.highlightIndex >= (NSInteger)limit) {
        self.highlightIndex = limit > 0 ? (NSInteger)limit - 1 : -1;
    }
    self.panel.highlightedCandidateIndex = self.highlightIndex;
    self.panel.showingAll = self.showingAll;
    self.panel.rows = rows;
    [self.panel updateEmptyMessage:nil];
    [self.panel reloadListKeepingHighlight:YES];
    (void)visibleCand;
}

#pragma mark - Raise

/** Live preview — no app activate, panel keeps typing focus. */
- (void)previewHighlighted {
    if (self.highlightIndex < 0 ||
        self.highlightIndex >= (NSInteger)self.filteredCandidates.count) {
        return;
    }
    MLChipLocatorCandidate *c = self.filteredCandidates[(NSUInteger)self.highlightIndex];
    [self.taskbar previewRaiseItem:c.item];
}

- (void)schedulePreviewHighlighted {
    self.previewDebounceGeneration += 1;
    NSInteger gen = self.previewDebounceGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (!self || !self.visible || gen != self.previewDebounceGeneration) {
                           return;
                       }
                       [self previewHighlighted];
                   });
}

- (void)confirmHighlighted {
    if (self.highlightIndex < 0 ||
        self.highlightIndex >= (NSInteger)self.filteredCandidates.count) {
        [self hide];
        return;
    }
    MLChipLocatorCandidate *c = self.filteredCandidates[(NSUInteger)self.highlightIndex];
    /* Final confirm may activate the app; close panel first so resign doesn't fight us. */
    self.suppressResignClose = YES;
    [self hide];
    [self.taskbar raiseOnlyItem:c.item];
}

#pragma mark - Panel delegate

- (void)chipLocatorPanelQueryDidChange:(MLChipLocatorPanel *)panel {
    (void)panel;
    self.highlightIndex = 0;
    [self applyFilterRaisingFirst:YES];
}

- (void)chipLocatorPanel:(MLChipLocatorPanel *)panel didMoveHighlightBy:(NSInteger)delta {
    (void)panel;
    NSInteger count = (NSInteger)self.filteredCandidates.count;
    if (count == 0) {
        return;
    }
    NSUInteger limit = self.showingAll ? (NSUInteger)count
                                       : MIN((NSUInteger)count, (NSUInteger)MLChipLocatorDefaultVisibleRows);
    if (limit == 0) {
        return;
    }
    NSInteger next = self.highlightIndex + delta;
    if (next < 0) {
        next = (NSInteger)limit - 1;
    } else if (next >= (NSInteger)limit) {
        next = 0;
    }
    self.highlightIndex = next;
    self.panel.highlightedCandidateIndex = next;
    [self.panel reloadListKeepingHighlight:YES];
    [self previewHighlighted];
}

- (void)chipLocatorPanelDidConfirm:(MLChipLocatorPanel *)panel {
    (void)panel;
    [self confirmHighlighted];
}

- (void)chipLocatorPanelDidCancel:(MLChipLocatorPanel *)panel {
    NSString *q = panel.query ?: @"";
    if (q.length > 0) {
        panel.query = @"";
        self.highlightIndex = 0;
        [self applyFilterRaisingFirst:YES];
        return;
    }
    [self hide];
}

- (void)chipLocatorPanelDidClickShowAll:(MLChipLocatorPanel *)panel {
    (void)panel;
    self.showingAll = !self.showingAll;
    self.panel.showingAll = self.showingAll;
    [self rebuildPanelRows];
}

- (void)chipLocatorPanel:(MLChipLocatorPanel *)panel didClickRow:(NSInteger)row {
    (void)panel;
    if (row < 0 || row >= (NSInteger)self.filteredCandidates.count) {
        return;
    }
    self.highlightIndex = row;
    [self confirmHighlighted];
}

- (void)chipLocatorPanel:(MLChipLocatorPanel *)panel didHoverCandidateIndex:(NSInteger)index {
    (void)panel;
    if (index < 0 || index >= (NSInteger)self.filteredCandidates.count) {
        return;
    }
    if (self.highlightIndex == index) {
        return;
    }
    self.highlightIndex = index;
    self.panel.highlightedCandidateIndex = index;
    [self schedulePreviewHighlighted];
}

#pragma mark - Observers

- (void)installObservers {
    [self uninstallObservers];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(runningAppsDidChange:)
                                                 name:MLRunningAppsDidChangeNotification
                                               object:self.taskbar.monitor];
    __weak typeof(self) weakSelf = self;
    self.resignObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification
                                                          object:self.panel
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
                                                          __strong typeof(weakSelf) self = weakSelf;
                                                          if (!self || !self.visible || self.suppressResignClose) {
                                                              return;
                                                          }
                                                          /* Lost key focus (click other app / desktop) → close. */
                                                          [self hide];
                                                      }];
    /* Clicks outside our windows while we stay key (rare) or after raise races. */
    self.outsideClickMonitor =
        [NSEvent addGlobalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown)
                                               handler:^(NSEvent *event) {
                                                   __strong typeof(weakSelf) self = weakSelf;
                                                   if (!self || !self.visible || self.suppressResignClose) {
                                                       return;
                                                   }
                                                   NSPoint screenPt = [NSEvent mouseLocation];
                                                   if (!NSPointInRect(screenPt, self.panel.frame)) {
                                                       dispatch_async(dispatch_get_main_queue(), ^{
                                                           if (self.visible && !self.suppressResignClose) {
                                                               [self hide];
                                                           }
                                                       });
                                                   }
                                                   (void)event;
                                               }];
}

- (void)uninstallObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:MLRunningAppsDidChangeNotification
                                                  object:nil];
    if (self.resignObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.resignObserver];
        self.resignObserver = nil;
    }
    if (self.outsideClickMonitor) {
        [NSEvent removeMonitor:self.outsideClickMonitor];
        self.outsideClickMonitor = nil;
    }
}

- (void)runningAppsDidChange:(NSNotification *)note {
    (void)note;
    if (!self.visible) {
        return;
    }
    NSInteger prevHighlight = self.highlightIndex;
    CGWindowID prevWID = 0;
    NSString *prevPath = nil;
    if (prevHighlight >= 0 && prevHighlight < (NSInteger)self.filteredCandidates.count) {
        MLTaskbarItem *it = self.filteredCandidates[(NSUInteger)prevHighlight].item;
        prevWID = it.windowID;
        prevPath = it.path;
    }
    /* Never reshuffle by MRU while open — only refresh / prune in place. */
    if (self.listOrderFrozen) {
        [self refreshFrozenCandidatesInPlace];
    } else {
        [self rebuildCandidates];
        [self freezeCandidateOrder];
    }
    [self applyFilterRaisingFirst:NO];

    /* Try to keep highlight on same identity (same list slot preference). */
    NSInteger found = -1;
    for (NSInteger i = 0; i < (NSInteger)self.filteredCandidates.count; i++) {
        MLTaskbarItem *it = self.filteredCandidates[(NSUInteger)i].item;
        if (prevWID != 0 && it.windowID == prevWID) {
            found = i;
            break;
        }
        if (prevWID == 0 && prevPath.length > 0 && it.windowID == 0 &&
            [it.path isEqualToString:prevPath]) {
            found = i;
            break;
        }
    }
    if (found >= 0) {
        self.highlightIndex = found;
    } else if (prevHighlight >= 0 && prevHighlight < (NSInteger)self.filteredCandidates.count) {
        self.highlightIndex = prevHighlight;
    } else if (self.filteredCandidates.count > 0) {
        self.highlightIndex = MIN(prevHighlight, (NSInteger)self.filteredCandidates.count - 1);
        if (self.highlightIndex < 0) {
            self.highlightIndex = 0;
        }
    } else {
        self.highlightIndex = -1;
    }
    self.panel.highlightedCandidateIndex = self.highlightIndex;
    [self rebuildPanelRows];
}

@end
