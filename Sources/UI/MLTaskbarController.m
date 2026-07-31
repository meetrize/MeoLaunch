#import "MLTaskbarController.h"

#import "MLCGSAlpha.h"
#import "MLMinimizeInterceptor.h"
#import "MLRunningAppsMonitor.h"
#import "MLScreenGeometry.h"
#import "MLTaskbarIconCache.h"
#import "MLTaskbarPinStore.h"
#import "MLTaskbarView.h"
#import "MLWindowSoftState.h"
#import "MLWorkAreaEnforcer.h"

#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

enum { MLTaskbarBarHeight = 40 };

@interface MLTaskbarScreenBar : NSObject
@property (nonatomic, strong) NSNumber *screenID;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) MLTaskbarView *barView;
@end

@implementation MLTaskbarScreenBar
@end

@interface MLTaskbarController () <MLTaskbarViewDelegate>
@property (nonatomic, strong) MLTaskbarPinStore *pinStore;
@property (nonatomic, strong) MLRunningAppsMonitor *monitor;
@property (nonatomic, strong) MLTaskbarIconCache *iconCache;
@property (nonatomic, strong) NSMutableArray<MLTaskbarScreenBar *> *bars;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *displayNameCache;
@property (nonatomic, strong) MLMinimizeInterceptor *minimizeInterceptor;
@property (nonatomic, strong) MLWorkAreaEnforcer *workAreaEnforcer;
@property (nonatomic, strong) NSSet<NSNumber *> *fullscreenScreenIDs;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL hiddenForOverlay;
@property (nonatomic, assign) BOOL fullscreenCheckPending;
@property (nonatomic, assign) NSUInteger startupVisibilityGeneration;
@end

@implementation MLTaskbarController

- (instancetype)initWithPinStore:(MLTaskbarPinStore *)pins
                         monitor:(MLRunningAppsMonitor *)monitor
                       iconCache:(MLTaskbarIconCache *)icons {
    self = [super init];
    if (self) {
        _pinStore = pins;
        _monitor = monitor;
        _iconCache = icons;
        _enabled = YES;
        _bars = [NSMutableArray array];
        _displayNameCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

+ (NSNumber *)screenIDForScreen:(NSScreen *)screen {
    if (!screen) {
        return @0;
    }
    id num = screen.deviceDescription[@"NSScreenNumber"];
    if ([num isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)num;
    }
    return @(screen.hash);
}

- (NSString *)displayNameForPath:(NSString *)path {
    if (path.length == 0) {
        return @"";
    }
    NSString *cached = self.displayNameCache[path];
    if (cached) {
        return cached;
    }
    NSString *name = nil;
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (bundle) {
        name = bundle.localizedInfoDictionary[@"CFBundleDisplayName"];
        if (name.length == 0) {
            name = bundle.infoDictionary[@"CFBundleDisplayName"];
        }
        if (name.length == 0) {
            name = bundle.localizedInfoDictionary[@"CFBundleName"];
        }
        if (name.length == 0) {
            name = bundle.infoDictionary[@"CFBundleName"];
        }
    }
    if (name.length == 0) {
        name = path.lastPathComponent.stringByDeletingPathExtension;
    }
    if (self.displayNameCache.count >= 32) {
        [self.displayNameCache removeAllObjects];
    }
    self.displayNameCache[path] = name ?: @"";
    return name ?: @"";
}

- (pid_t)pidForPath:(NSString *)path snapshot:(MLRunningAppsSnapshot *)snap {
    if (path.length == 0 || !snap) {
        return 0;
    }
    NSString *std = path.stringByStandardizingPath;
    for (NSNumber *pidNum in snap.pidToPath) {
        NSString *p = snap.pidToPath[pidNum];
        if ([p isEqualToString:path] ||
            (std.length > 0 && [p.stringByStandardizingPath isEqualToString:std])) {
            return (pid_t)pidNum.intValue;
        }
    }
    return 0;
}

- (BOOL)pinSet:(NSSet<NSString *> *)pinSet containsPath:(NSString *)path {
    if (path.length == 0 || pinSet.count == 0) {
        return NO;
    }
    if ([pinSet containsObject:path]) {
        return YES;
    }
    NSString *std = path.stringByStandardizingPath;
    if (std.length > 0 && [pinSet containsObject:std]) {
        return YES;
    }
    for (NSString *pin in pinSet) {
        if ([pin.stringByStandardizingPath isEqualToString:std]) {
            return YES;
        }
    }
    return NO;
}

- (MLTaskbarItem *)itemWithPath:(NSString *)path
                            pid:(pid_t)pid
                       windowID:(CGWindowID)windowID
                          title:(NSString *)title
                           kind:(MLTaskbarItemKind)kind
                         pinned:(BOOL)pinned
                      minimized:(BOOL)minimized
                         active:(BOOL)active
                      seenOrder:(NSUInteger)seenOrder {
    MLTaskbarItem *item = [[MLTaskbarItem alloc] init];
    item.path = path;
    item.pid = pid;
    item.windowID = windowID;
    item.title = title;
    item.kind = kind;
    item.pinned = pinned;
    item.minimized = minimized;
    item.active = active;
    item.seenOrder = seenOrder;
    return item;
}

/** Frontmost layer-0 window of the frontmost regular app (CG front-to-back order). */
- (CGWindowID)frontmostTrackedWindowID {
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    if (!front || front.isTerminated || front.processIdentifier <= 0) {
        return 0;
    }
    if (front.activationPolicy != NSApplicationActivationPolicyRegular) {
        return 0;
    }
    NSString *selfBid = [NSBundle mainBundle].bundleIdentifier;
    if (selfBid.length > 0 && [front.bundleIdentifier isEqualToString:selfBid]) {
        return 0;
    }
    pid_t pid = front.processIdentifier;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                     kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    if (!list) {
        return 0;
    }
    CGWindowID best = 0;
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        CFNumberRef pidRef = info ? CFDictionaryGetValue(info, kCGWindowOwnerPID) : NULL;
        pid_t wpid = 0;
        if (pidRef) {
            CFNumberGetValue(pidRef, kCFNumberIntType, &wpid);
        }
        if (wpid != pid) {
            continue;
        }
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        int layer = 0;
        if (layerRef) {
            CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        }
        if (layer != 0) {
            continue;
        }
        CGRect bounds = CGRectZero;
        CFDictionaryRef bd = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!bd || !CGRectMakeWithDictionaryRepresentation(bd, &bounds)) {
            continue;
        }
        if (bounds.size.width < 100.0 || bounds.size.height < 80.0) {
            continue;
        }
        CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
        if (winRef) {
            CFNumberGetValue(winRef, kCFNumberIntType, &best);
        }
        break; /* first match is frontmost */
    }
    CFRelease(list);
    return best;
}

/** Prefer the screen with the largest intersection; ties break to containing center.
 * Soft-state reinject stores Cocoa bounds; CG polls store Quartz — try Cocoa first, then Quartz→Cocoa. */
- (NSScreen *)screenForWindowBounds:(CGRect)bounds {
    if (CGRectIsEmpty(bounds)) {
        return nil;
    }
    NSScreen *viaCocoa = [MLScreenGeometry screenForCocoaRect:NSRectFromCGRect(bounds)];
    NSRect asCocoaFromQuartz = [MLScreenGeometry cocoaRectFromQuartzBounds:bounds];
    NSScreen *viaQuartz = [MLScreenGeometry screenForCocoaRect:asCocoaFromQuartz];
    /* Prefer the interpretation that intersects a screen with larger area. */
    CGFloat a1 = 0, a2 = 0;
    if (viaCocoa) {
        CGRect inter = CGRectIntersection(bounds, NSRectToCGRect(viaCocoa.frame));
        a1 = CGRectIsNull(inter) ? 0 : inter.size.width * inter.size.height;
    }
    if (viaQuartz) {
        CGRect inter = CGRectIntersection(NSRectToCGRect(asCocoaFromQuartz), NSRectToCGRect(viaQuartz.frame));
        a2 = CGRectIsNull(inter) ? 0 : inter.size.width * inter.size.height;
    }
    if (a2 > a1) {
        return viaQuartz;
    }
    return viaCocoa ?: viaQuartz;
}

- (NSArray<MLTaskbarWindowInfo *> *)windowsOnScreen:(NSScreen *)screen
                                          fromSnap:(MLRunningAppsSnapshot *)snap
                                              cap:(NSUInteger)cap {
    NSMutableArray<MLTaskbarWindowInfo *> *out = [NSMutableArray array];
    if (!screen || !snap) {
        return out;
    }
    NSNumber *wantID = [[self class] screenIDForScreen:screen];
    for (MLTaskbarWindowInfo *w in snap.windows ?: @[]) {
        NSScreen *owner = [self screenForWindowBounds:w.bounds];
        if (!owner && w.minimized) {
            /*
             * Avoid dumping onto mainScreen: prefer any non-empty bounds center,
             * else skip (better missing chip than wrong-screen chip).
             */
            if (!CGRectIsEmpty(w.bounds)) {
                CGPoint c = CGPointMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds));
                for (NSScreen *s in NSScreen.screens) {
                    if (NSPointInRect(NSMakePoint(c.x, c.y), s.frame)) {
                        owner = s;
                        break;
                    }
                }
            }
        }
        if (!owner) {
            continue;
        }
        if (![[[self class] screenIDForScreen:owner] isEqualToNumber:wantID]) {
            continue;
        }
        [out addObject:w];
        if (cap > 0 && out.count >= cap) {
            break;
        }
    }
    return out;
}

- (void)rebuildItemsForBar:(MLTaskbarScreenBar *)bar screen:(NSScreen *)screen {
    if (!bar.barView || !screen) {
        return;
    }

    /* Inherit prior chip order so minimize/restore never reshuffles. */
    NSMutableDictionary<NSNumber *, NSNumber *> *priorOrderByWid = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *priorOrderByPathTitle = [NSMutableDictionary dictionary];
    NSUInteger priorIdx = 1;
    for (MLTaskbarItem *prev in bar.barView.items ?: @[]) {
        if (prev.kind != MLTaskbarItemRunningWindow) {
            continue;
        }
        NSUInteger ord = prev.seenOrder > 0 ? prev.seenOrder : priorIdx;
        if (prev.windowID != 0) {
            priorOrderByWid[@(prev.windowID)] = @(ord);
        }
        NSString *pt = [NSString stringWithFormat:@"%@|%@", prev.path ?: @"", prev.title ?: @""];
        if (!priorOrderByPathTitle[pt]) {
            priorOrderByPathTitle[pt] = @(ord);
        }
        priorIdx++;
    }

    MLRunningAppsSnapshot *snap = self.monitor.snapshot;
    NSArray<NSString *> *pins = self.pinStore.pinnedPaths;
    NSSet<NSString *> *pinSet = [NSSet setWithArray:pins];

    NSUInteger cap = self.monitor.maxWindowEntries > 0 ? self.monitor.maxWindowEntries
                                                       : (NSUInteger)MLTaskbarMaxWindowEntries;
    NSArray<MLTaskbarWindowInfo *> *screenWindows = [self windowsOnScreen:screen fromSnap:snap cap:cap];

    /* Dedupe again at UI layer (same windowID / path+title). */
    NSMutableArray<MLTaskbarWindowInfo *> *uniqueWindows = [NSMutableArray array];
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (MLTaskbarWindowInfo *w in screenWindows) {
        NSString *key = w.windowID != 0
                            ? [NSString stringWithFormat:@"id:%u", (unsigned)w.windowID]
                            : [NSString stringWithFormat:@"p:%d|%@|%@", (int)w.pid, w.path ?: @"", w.title ?: @""];
        if ([keys containsObject:key]) {
            continue;
        }
        /* Collapse path+title duplicates even when one has windowID and one does not */
        BOOL pathTitleDup = NO;
        for (MLTaskbarWindowInfo *existing in uniqueWindows) {
            if (![existing.path isEqualToString:w.path]) {
                continue;
            }
            BOOL sameID = (existing.windowID != 0 && existing.windowID == w.windowID);
            BOOL idZeroClone = (existing.windowID != 0 && w.windowID == 0) ||
                               (w.windowID != 0 && existing.windowID == 0);
            BOOL titlesBothNonEmpty = existing.title.length > 0 && w.title.length > 0;
            BOOL titleMatch = titlesBothNonEmpty &&
                              ([existing.title isEqualToString:w.title] ||
                               [existing.title hasPrefix:w.title] ||
                               [w.title hasPrefix:existing.title]);
            BOOL bothEmptyTitle = existing.title.length == 0 && w.title.length == 0;
            if (!(sameID || (idZeroClone && (titleMatch || bothEmptyTitle)) || titleMatch)) {
                continue;
            }
            pathTitleDup = YES;
            if (existing.minimized && !w.minimized) {
                NSUInteger idx = [uniqueWindows indexOfObject:existing];
                if (idx != NSNotFound) {
                    w.seenOrder = existing.seenOrder > 0 ? existing.seenOrder : w.seenOrder;
                    if (w.windowID == 0 && existing.windowID != 0) {
                        w.windowID = existing.windowID;
                    }
                    uniqueWindows[idx] = w;
                }
            } else if (!existing.minimized && w.minimized) {
                /* keep visible entry; inherit order already */
                if (existing.seenOrder == 0 && w.seenOrder > 0) {
                    existing.seenOrder = w.seenOrder;
                }
            } else if (existing.seenOrder == 0 && w.seenOrder > 0) {
                existing.seenOrder = w.seenOrder;
            } else if (w.seenOrder > 0 && existing.seenOrder > 0) {
                existing.seenOrder = MIN(existing.seenOrder, w.seenOrder);
            }
            break;
        }
        if (pathTitleDup) {
            continue;
        }
        [keys addObject:key];
        [uniqueWindows addObject:w];
    }

    NSMutableArray<MLTaskbarItem *> *windowItems = [NSMutableArray array];
    CGWindowID frontWid = [self frontmostTrackedWindowID];
    for (MLTaskbarWindowInfo *w in uniqueWindows) {
        NSString *display = [self displayNameForPath:w.path];
        NSString *title = w.title.length > 0 ? w.title : display;
        BOOL pinned = [self pinSet:pinSet containsPath:w.path];
        NSUInteger ord = w.seenOrder;
        if (ord == 0 && w.windowID != 0) {
            ord = priorOrderByWid[@(w.windowID)].unsignedIntegerValue;
        }
        if (ord == 0) {
            NSString *pt = [NSString stringWithFormat:@"%@|%@", w.path ?: @"", title ?: @""];
            ord = priorOrderByPathTitle[pt].unsignedIntegerValue;
        }
        BOOL active = !w.minimized && w.windowID != 0 && frontWid != 0 && w.windowID == frontWid;
        [windowItems addObject:[self itemWithPath:w.path
                                              pid:w.pid
                                         windowID:w.windowID
                                            title:title
                                             kind:MLTaskbarItemRunningWindow
                                           pinned:pinned
                                        minimized:w.minimized
                                           active:active
                                        seenOrder:ord]];
    }

    [windowItems sortUsingComparator:^NSComparisonResult(MLTaskbarItem *a, MLTaskbarItem *b) {
        if (a.seenOrder != b.seenOrder) {
            if (a.seenOrder == 0) {
                return NSOrderedDescending;
            }
            if (b.seenOrder == 0) {
                return NSOrderedAscending;
            }
            return a.seenOrder < b.seenOrder ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.title ?: @"" compare:b.title ?: @""];
    }];

    NSMutableArray<MLTaskbarItem *> *items = [NSMutableArray array];

    /*
     * Pinned launchers with no window chip on this screen stay at the leading
     * edge (pin order). Do NOT gate on runningSet: Electron apps (Cursor, etc.)
     * often keep a process alive after the last window closes — hiding the pin
     * then makes the icon vanish. Show the bare icon whenever this screen has
     * no window for that path; click will activate or open a new window.
     */
    NSMutableSet<NSString *> *pathsWithWindows = [NSMutableSet set];
    for (MLTaskbarWindowInfo *w in uniqueWindows) {
        if (w.path.length > 0) {
            [pathsWithWindows addObject:w.path];
            NSString *std = w.path.stringByStandardizingPath;
            if (std.length > 0) {
                [pathsWithWindows addObject:std];
            }
        }
    }
    for (NSString *path in pins) {
        if (path.length == 0) {
            continue;
        }
        NSString *std = path.stringByStandardizingPath;
        if ([pathsWithWindows containsObject:path] ||
            (std.length > 0 && [pathsWithWindows containsObject:std])) {
            continue;
        }
        pid_t pinPid = [self pidForPath:path snapshot:snap];
        [items addObject:[self itemWithPath:path
                                        pid:pinPid
                                   windowID:0
                                      title:[self displayNameForPath:path]
                                       kind:MLTaskbarItemPinnedOnly
                                     pinned:YES
                                  minimized:NO
                                     active:NO
                                  seenOrder:0]];
    }
    [items addObjectsFromArray:windowItems];

    items = [self fitItems:items toWidth:NSWidth(bar.barView.bounds) spacing:bar.barView.spacing
                    minWidth:bar.barView.itemMinWidth];
    bar.barView.items = items;
}

- (void)rebuildItems {
    if (!self.started) {
        return;
    }
    NSDictionary<NSNumber *, NSScreen *> *screensByID = [self screensByID];
    for (MLTaskbarScreenBar *bar in self.bars) {
        NSScreen *screen = screensByID[bar.screenID];
        if (screen) {
            [self rebuildItemsForBar:bar screen:screen];
        }
    }
}

- (NSMutableArray<MLTaskbarItem *> *)fitItems:(NSMutableArray<MLTaskbarItem *> *)items
                                      toWidth:(CGFloat)width
                                      spacing:(CGFloat)spacing
                                     minWidth:(CGFloat)minW {
    if (width < 32.0 || items.count == 0) {
        return items;
    }
    /* Pinned-only slots are bare icons (~iconSize+4); window chips use minW. */
    CGFloat pinnedW = 36.0;
    CGFloat avail = width - 6.0;
    while (items.count > 0) {
        CGFloat need = 0;
        NSUInteger n = items.count;
        for (NSUInteger i = 0; i < n; i++) {
            MLTaskbarItem *it = items[i];
            CGFloat w = (it.kind == MLTaskbarItemPinnedOnly) ? pinnedW : minW;
            need += w;
            if (i + 1 < n) {
                need += spacing;
            }
        }
        if (need <= avail) {
            break;
        }
        NSInteger drop = -1;
        for (NSInteger i = (NSInteger)items.count - 1; i >= 0; i--) {
            if (!items[(NSUInteger)i].pinned) {
                drop = i;
                break;
            }
        }
        if (drop < 0) {
            break;
        }
        [items removeObjectAtIndex:(NSUInteger)drop];
    }
    return items;
}

- (NSDictionary<NSNumber *, NSScreen *> *)screensByID {
    NSMutableDictionary<NSNumber *, NSScreen *> *map = [NSMutableDictionary dictionary];
    for (NSScreen *screen in NSScreen.screens) {
        map[[[self class] screenIDForScreen:screen]] = screen;
    }
    return map;
}

- (MLTaskbarScreenBar *)makeBarForScreen:(NSScreen *)screen {
    NSRect visible = screen.visibleFrame;
    CGFloat height = (CGFloat)MLTaskbarBarHeight;
    NSRect frame = NSMakeRect(NSMinX(visible), NSMinY(visible), NSWidth(visible), height);

    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.opaque = NO;
    w.backgroundColor = [NSColor clearColor];
    w.hasShadow = NO;
    w.level = NSFloatingWindowLevel;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                           NSWindowCollectionBehaviorStationary |
                           NSWindowCollectionBehaviorIgnoresCycle;
    w.ignoresMouseEvents = NO;
    w.acceptsMouseMovedEvents = NO;
    w.releasedWhenClosed = NO;

    MLTaskbarView *view = [[MLTaskbarView alloc] initWithFrame:w.contentView.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.delegate = self;
    view.iconCache = self.iconCache;
    view.barHeight = height;
    [w.contentView addSubview:view];

    MLTaskbarScreenBar *bar = [[MLTaskbarScreenBar alloc] init];
    bar.screenID = [[self class] screenIDForScreen:screen];
    bar.window = w;
    bar.barView = view;
    return bar;
}

- (void)syncBarsToScreens {
    NSDictionary<NSNumber *, NSScreen *> *screensByID = [self screensByID];
    NSMutableSet<NSNumber *> *wanted = [NSMutableSet setWithArray:screensByID.allKeys];

    NSMutableArray<MLTaskbarScreenBar *> *keep = [NSMutableArray array];
    for (MLTaskbarScreenBar *bar in self.bars) {
        NSScreen *screen = screensByID[bar.screenID];
        if (screen) {
            [keep addObject:bar];
            [wanted removeObject:bar.screenID];
            NSRect visible = screen.visibleFrame;
            CGFloat height = bar.barView.barHeight > 0 ? bar.barView.barHeight : (CGFloat)MLTaskbarBarHeight;
            NSRect frame = NSMakeRect(NSMinX(visible), NSMinY(visible), NSWidth(visible), height);
            [bar.window setFrame:frame display:YES];
        } else {
            [bar.window orderOut:nil];
            bar.window = nil;
            bar.barView = nil;
        }
    }
    self.bars = keep;

    for (NSNumber *sid in wanted) {
        NSScreen *screen = screensByID[sid];
        if (!screen) {
            continue;
        }
        MLTaskbarScreenBar *bar = [self makeBarForScreen:screen];
        [self.bars addObject:bar];
        /* Fail-open: show immediately, then hide only if detection confirms fullscreen. */
        if (!self.hiddenForOverlay) {
            [bar.window orderFrontRegardless];
        }
    }

    [self rebuildItems];
    [self refreshFullscreenVisibility];
    [self.workAreaEnforcer enforceNow];
}

- (void)start {
    if (self.started) {
        return;
    }
    if (!self.enabled) {
        return;
    }
    self.started = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(softStateDidChange:)
                                                 name:MLWindowSoftStateDidChangeNotification
                                               object:self.monitor.softState];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pinsDidChange:)
                                                 name:MLTaskbarPinsDidChangeNotification
                                               object:self.pinStore];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(runningDidChange:)
                                                 name:MLRunningAppsDidChangeNotification
                                               object:self.monitor];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenParamsChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
    NSNotificationCenter *wsnc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [wsnc addObserver:self
             selector:@selector(frontAppDidChange:)
                 name:NSWorkspaceDidActivateApplicationNotification
               object:nil];
    [wsnc addObserver:self
             selector:@selector(activeSpaceDidChange:)
                 name:NSWorkspaceActiveSpaceDidChangeNotification
               object:nil];

    [self.monitor start];
    [self syncBarsToScreens];
    [self scheduleStartupVisibilityRechecks];

    self.minimizeInterceptor = [[MLMinimizeInterceptor alloc] init];
    self.minimizeInterceptor.taskbar = self;
    [self.minimizeInterceptor start];

    self.workAreaEnforcer = [[MLWorkAreaEnforcer alloc] init];
    self.workAreaEnforcer.monitor = self.monitor;
    self.workAreaEnforcer.barHeight = (CGFloat)MLTaskbarBarHeight;
    [self.workAreaEnforcer start];
}

- (void)stop {
    if (!self.started) {
        return;
    }
    self.started = NO;
    self.fullscreenCheckPending = NO;
    self.startupVisibilityGeneration += 1;
    self.fullscreenScreenIDs = nil;
    [self.workAreaEnforcer stop];
    self.workAreaEnforcer = nil;
    [self.minimizeInterceptor stop];
    self.minimizeInterceptor = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self.monitor stop];
    for (MLTaskbarScreenBar *bar in self.bars) {
        [bar.window orderOut:nil];
        bar.window = nil;
        bar.barView = nil;
    }
    [self.bars removeAllObjects];
    [self.iconCache purge];
}

- (void)pinsDidChange:(NSNotification *)note {
    (void)note;
    [self rebuildItems];
}

- (void)runningDidChange:(NSNotification *)note {
    (void)note;
    [self rebuildItems];
    [self scheduleFullscreenVisibilityCheck];
}

- (void)frontAppDidChange:(NSNotification *)note {
    (void)note;
    [self rebuildItems];
    [self scheduleFullscreenVisibilityCheck];
    /* Video / Space fullscreen often settles after activation. */
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf refreshFullscreenVisibility];
                   });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf refreshFullscreenVisibility];
                   });
}

- (void)activeSpaceDidChange:(NSNotification *)note {
    (void)note;
    [self scheduleFullscreenVisibilityCheck];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf refreshFullscreenVisibility];
                   });
}

- (void)screenParamsChanged:(NSNotification *)note {
    (void)note;
    [self syncBarsToScreens];
    [self rebuildItems];
}

- (void)overlayWillShow {
    self.hiddenForOverlay = YES;
    for (MLTaskbarScreenBar *bar in self.bars) {
        [bar.window orderOut:nil];
    }
}

- (void)overlayDidHide {
    self.hiddenForOverlay = NO;
    if (self.started && self.enabled) {
        [self syncBarsToScreens];
        [self refreshFullscreenVisibility];
    }
}

/**
 * Screens where immersive / OS fullscreen content should cover the taskbar.
 * - Video / Space fullscreen / presentation: an on-screen window covers the full
 *   display (including menu-bar band). Ordinary zoom-to-visibleFrame does NOT match.
 * - Frontmost app reports AXFullScreen on a window we can map to a screen.
 *
 * Do NOT treat visibleFrame ≈ frame alone as fullscreen: auto-hide menu bar + Dock
 * (and unsettled WindowServer insets right after login) look identical and would
 * permanently or intermittently hide the taskbar on a normal desktop.
 */
- (NSSet<NSNumber *> *)detectFullscreenScreenIDs {
    NSMutableSet<NSNumber *> *ids = [NSMutableSet set];
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;

    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                     kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    if (list) {
        CFIndex count = CFArrayGetCount(list);
        for (CFIndex i = 0; i < count; i++) {
            CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
            if (!info) {
                continue;
            }

            CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
            pid_t pid = 0;
            if (pidRef) {
                CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
            }
            if (pid <= 0 || pid == selfPid) {
                continue;
            }

            CFStringRef ownerRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
            if (ownerRef && CFGetTypeID(ownerRef) == CFStringGetTypeID()) {
                NSString *owner = (__bridge NSString *)ownerRef;
                /* Login / system chrome can briefly span the display without being immersive. */
                if ([owner isEqualToString:@"Window Server"] ||
                    [owner isEqualToString:@"Dock"] ||
                    [owner isEqualToString:@"SystemUIServer"] ||
                    [owner isEqualToString:@"Control Center"] ||
                    [owner isEqualToString:@"Notification Center"] ||
                    [owner isEqualToString:@"loginwindow"] ||
                    [owner isEqualToString:@"Wallpaper"] ||
                    [owner isEqualToString:@"Spotlight"] ||
                    [owner isEqualToString:@"Screenshot"]) {
                    continue;
                }
            }

            CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
            int layer = 0;
            if (layerRef) {
                CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
            }
            /* Skip desktop wallpaper / shield / extreme overlays; keep normal + floating video. */
            if (layer < 0 || layer > 25) {
                continue;
            }

            CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
            if (alphaRef) {
                double alpha = 1.0;
                CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
                if (alpha < 0.85) {
                    continue;
                }
            }

            CGRect bounds = CGRectZero;
            CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
            if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)) {
                continue;
            }
            if (bounds.size.width < 200.0 || bounds.size.height < 200.0) {
                continue;
            }

            for (NSScreen *screen in NSScreen.screens) {
                NSNumber *sid = [[self class] screenIDForScreen:screen];
                if ([ids containsObject:sid]) {
                    continue;
                }
                NSRect sf = screen.frame;
                CGFloat screenArea = sf.size.width * sf.size.height;
                if (screenArea < 1.0) {
                    continue;
                }
                CGRect inter = CGRectIntersection(bounds, NSRectToCGRect(sf));
                if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) {
                    continue;
                }
                CGFloat cover = (inter.size.width * inter.size.height) / screenArea;
                /* Must cover the menu-bar band too — distinguishes from Zoom to visibleFrame. */
                BOOL coversDisplayHeight = bounds.size.height >= sf.size.height - 4.0;
                BOOL coversDisplayWidth = bounds.size.width >= sf.size.width - 4.0;
                BOOL bottomAtScreen = fabs(CGRectGetMinY(bounds) - NSMinY(sf)) <= 8.0;
                BOOL edgesClose =
                    fabs(CGRectGetMinX(bounds) - NSMinX(sf)) <= 8.0 &&
                    fabs(CGRectGetMaxX(bounds) - NSMaxX(sf)) <= 8.0 &&
                    fabs(CGRectGetMinY(bounds) - NSMinY(sf)) <= 8.0 &&
                    fabs(CGRectGetMaxY(bounds) - NSMaxY(sf)) <= 8.0;
                if (edgesClose || (cover >= 0.97 && coversDisplayHeight && coversDisplayWidth && bottomAtScreen)) {
                    [ids addObject:sid];
                }
            }
        }
        CFRelease(list);
    }

    /* AXFullScreen on the frontmost app (Douyin / players often set this). */
    if (AXIsProcessTrusted()) {
        NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
        pid_t frontPid = front.processIdentifier;
        if (frontPid > 0 && frontPid != selfPid) {
            AXUIElementRef appRef = AXUIElementCreateApplication(frontPid);
            if (appRef) {
                CFTypeRef windowsRef = NULL;
                if (AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef) == kAXErrorSuccess &&
                    windowsRef && CFGetTypeID(windowsRef) == CFArrayGetTypeID()) {
                    CFArrayRef axWindows = (CFArrayRef)windowsRef;
                    CFIndex n = CFArrayGetCount(axWindows);
                    for (CFIndex i = 0; i < n; i++) {
                        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
                        CFTypeRef fsRef = NULL;
                        BOOL isFS = NO;
                        if (AXUIElementCopyAttributeValue(win, CFSTR("AXFullScreen"), &fsRef) == kAXErrorSuccess &&
                            fsRef) {
                            if (CFGetTypeID(fsRef) == CFBooleanGetTypeID()) {
                                isFS = CFBooleanGetValue((CFBooleanRef)fsRef);
                            }
                            CFRelease(fsRef);
                        }
                        if (!isFS) {
                            continue;
                        }
                        /* Map fullscreen window to a screen via AX frame; skip if unmapped. */
                        CFTypeRef posRef = NULL;
                        CFTypeRef sizeRef = NULL;
                        CGPoint pos = CGPointZero;
                        CGSize size = CGSizeZero;
                        BOOL have = NO;
                        if (AXUIElementCopyAttributeValue(win, kAXPositionAttribute, &posRef) == kAXErrorSuccess &&
                            posRef) {
                            have = AXValueGetValue((AXValueRef)posRef, (AXValueType)kAXValueCGPointType, &pos);
                            CFRelease(posRef);
                        }
                        if (AXUIElementCopyAttributeValue(win, kAXSizeAttribute, &sizeRef) == kAXErrorSuccess &&
                            sizeRef) {
                            have = have && AXValueGetValue((AXValueRef)sizeRef, (AXValueType)kAXValueCGSizeType, &size);
                            CFRelease(sizeRef);
                        }
                        if (have && size.width > 2.0 && size.height > 2.0) {
                            NSRect main = NSScreen.mainScreen.frame;
                            NSRect cocoa = NSMakeRect(pos.x, NSMaxY(main) - pos.y - size.height,
                                                      size.width, size.height);
                            NSScreen *screen = [self screenForWindowBounds:NSRectToCGRect(cocoa)];
                            if (screen) {
                                [ids addObject:[[self class] screenIDForScreen:screen]];
                            }
                        }
                    }
                }
                if (windowsRef) {
                    CFRelease(windowsRef);
                }
                CFRelease(appRef);
            }
        }
    }

    return ids;
}

- (void)scheduleStartupVisibilityRechecks {
    self.startupVisibilityGeneration += 1;
    NSUInteger generation = self.startupVisibilityGeneration;
    __weak typeof(self) weakSelf = self;
    /* Login / launch-at-login: WindowServer insets and transient cover windows settle late. */
    static const double delays[] = { 0.4, 1.2, 3.0 };
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        double delay = delays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           __strong typeof(weakSelf) self = weakSelf;
                           if (!self || !self.started || self.startupVisibilityGeneration != generation) {
                               return;
                           }
                           [self refreshFullscreenVisibility];
                       });
    }
}

- (void)scheduleFullscreenVisibilityCheck {
    if (!self.started || self.fullscreenCheckPending) {
        return;
    }
    self.fullscreenCheckPending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        self.fullscreenCheckPending = NO;
        [self refreshFullscreenVisibility];
    });
}

- (void)refreshFullscreenVisibility {
    if (!self.started) {
        return;
    }
    NSSet<NSNumber *> *next = [self detectFullscreenScreenIDs];
    if (self.fullscreenScreenIDs && [self.fullscreenScreenIDs isEqualToSet:next]) {
        [self applyBarVisibility];
        return;
    }
    self.fullscreenScreenIDs = next;
    [self applyBarVisibility];
}

- (void)applyBarVisibility {
    if (self.hiddenForOverlay) {
        for (MLTaskbarScreenBar *bar in self.bars) {
            [bar.window orderOut:nil];
        }
        return;
    }
    if (!self.started || !self.enabled) {
        return;
    }
    NSSet<NSNumber *> *fs = self.fullscreenScreenIDs ?: [NSSet set];
    for (MLTaskbarScreenBar *bar in self.bars) {
        if ([fs containsObject:bar.screenID]) {
            [bar.window orderOut:nil];
        } else {
            [bar.window orderFrontRegardless];
        }
    }
}

- (NSRect)animationTargetRectForPID:(pid_t)pid
                              title:(NSString *)title
                       windowBounds:(CGRect)windowBounds {
    NSScreen *screen = [self screenForWindowBounds:windowBounds];
    if (!screen) {
        screen = NSScreen.mainScreen;
    }
    if (!screen) {
        return NSZeroRect;
    }

    NSNumber *sid = [[self class] screenIDForScreen:screen];
    MLTaskbarScreenBar *bar = nil;
    for (MLTaskbarScreenBar *b in self.bars) {
        if ([b.screenID isEqualToNumber:sid]) {
            bar = b;
            break;
        }
    }
    if (!bar.barView || !bar.window) {
        NSRect vis = screen.visibleFrame;
        return NSMakeRect(NSMidX(vis) - 40.0, NSMinY(vis) + 4.0, 80.0, 32.0);
    }

    NSInteger match = -1;
    NSInteger pidFallback = -1;
    for (NSInteger i = 0; i < (NSInteger)bar.barView.items.count; i++) {
        MLTaskbarItem *item = bar.barView.items[(NSUInteger)i];
        if (pid > 0 && item.pid == pid) {
            if (pidFallback < 0) {
                pidFallback = i;
            }
            if (title.length == 0 || item.title.length == 0 ||
                [item.title isEqualToString:title] ||
                [item.title hasPrefix:title] || [title hasPrefix:item.title]) {
                match = i;
                break;
            }
        }
    }
    if (match < 0) {
        match = pidFallback;
    }
    if (match < 0) {
        NSRect vis = bar.window.frame;
        return NSMakeRect(NSMidX(vis) - 40.0, NSMinY(vis) + 4.0, 80.0, 32.0);
    }

    NSRect local = [bar.barView rectForItemAtIndex:match];
    NSRect inWindow = [bar.barView convertRect:local toView:nil];
    return [bar.window convertRectToScreen:inWindow];
}

- (void)refreshAfterCustomMinimize {
    [self.monitor pollNow];
    [self rebuildItems];
}

- (void)softStateDidChange:(NSNotification *)note {
    (void)note;
    [self.monitor pollNow];
    [self rebuildItems];
}

- (CGWindowID)rememberWindowForCustomMinimizePID:(pid_t)pid
                                           title:(NSString *)title
                                          bounds:(CGRect)bounds
                                        windowID:(CGWindowID)windowID {
    return [self.monitor rememberBounds:bounds forPID:pid title:title windowID:windowID];
}

- (void)markSoftHiddenWindowID:(CGWindowID)windowID
                           pid:(pid_t)pid
                         title:(NSString *)title
                 restoreFrame:(NSRect)restoreFrame
                     screenID:(NSNumber *)screenID
                     axWindow:(AXUIElementRef)axWindow {
    NSString *path = nil;
    if (pid > 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        path = app.bundleURL.path;
    }
    [self.monitor markSoftHiddenWindowID:windowID
                                     pid:pid
                                    path:path
                                   title:title
                           restoreFrame:restoreFrame
                               screenID:screenID
                               axWindow:axWindow];
    [self rebuildItems];
}

- (void)updateSoftHideMethod:(MLWindowHideMethod)method forWindowID:(CGWindowID)windowID {
    [self.monitor.softState updateHideMethod:method forWindowID:windowID];
}

- (void)markSoftMinimizedWindowID:(CGWindowID)windowID {
    [self.monitor markSoftMinimizedWindowID:windowID];
    [self rebuildItems];
}

#pragma mark - MLTaskbarViewDelegate

typedef AXError (*MLAXGetWindowFn)(AXUIElementRef, CGWindowID *);

static MLAXGetWindowFn MLResolvedAXGetWindow(void) {
    static MLAXGetWindowFn sFn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sFn = (MLAXGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    });
    return sFn;
}

- (BOOL)title:(NSString *)full matchesHint:(NSString *)hint {
    if (hint.length == 0) {
        return YES;
    }
    if (full.length == 0) {
        return NO;
    }
    if ([full isEqualToString:hint]) {
        return YES;
    }
    NSString *prefix = hint;
    if ([hint hasSuffix:@"…"] || [hint hasSuffix:@"..."]) {
        NSUInteger trim = [hint hasSuffix:@"..."] ? 3 : 1;
        if (hint.length > trim) {
            prefix = [hint substringToIndex:hint.length - trim];
        }
    }
    return prefix.length > 0 && [full hasPrefix:prefix];
}

- (BOOL)frame:(NSRect)frame matchesRestore:(NSRect)restore tolerance:(CGFloat)tol {
    if (restore.size.width < 2.0 || restore.size.height < 2.0) {
        return frame.size.width > 50.0 && frame.size.height > 50.0;
    }
    return [MLScreenGeometry nearlyEqual:NSMinX(frame) b:NSMinX(restore) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMinY(frame) b:NSMinY(restore) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSWidth(frame) b:NSWidth(restore) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSHeight(frame) b:NSHeight(restore) tolerance:tol];
}

/** Apply restore geometry and clear soft only when AX frame matches (strict). */
- (BOOL)applyRestoreFrame:(NSRect)restoreFrame
                toAXWindow:(AXUIElementRef)target
                  windowID:(CGWindowID)wid
             clearIfMatched:(BOOL)clearIfMatched {
    if (!target || restoreFrame.size.width < 2.0 || restoreFrame.size.height < 2.0) {
        return NO;
    }
    [MLScreenGeometry applyCocoaFrame:restoreFrame toAXWindow:target];
    AXUIElementPerformAction(target, kAXRaiseAction);
    NSRect got = NSZeroRect;
    if (![MLScreenGeometry readCocoaFrame:&got fromAXWindow:target]) {
        return NO;
    }
    Boolean stillMin = false;
    CFTypeRef minRef = NULL;
    if (AXUIElementCopyAttributeValue(target, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
        if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
            stillMin = CFBooleanGetValue((CFBooleanRef)minRef);
        }
        CFRelease(minRef);
    }
    if (stillMin) {
        return NO;
    }
    BOOL matched = [self frame:got matchesRestore:restoreFrame tolerance:20.0];
    if (matched && clearIfMatched && wid != 0) {
        [self.monitor.softState clearVerifiedWindowID:wid];
        NSLog(@"[Taskbar] soft restore verified wid=%u frame=(%.0f,%.0f %.0fx%.0f)",
              (unsigned)wid, got.origin.x, got.origin.y, got.size.width, got.size.height);
    } else if (!matched) {
        NSLog(@"[Taskbar] soft restore mismatch wid=%u got=(%.0f,%.0f %.0fx%.0f) want=(%.0f,%.0f %.0fx%.0f)",
              (unsigned)wid,
              got.origin.x, got.origin.y, got.size.width, got.size.height,
              restoreFrame.origin.x, restoreFrame.origin.y, restoreFrame.size.width, restoreFrame.size.height);
    }
    return matched;
}

- (void)raiseAndFocusWindowForItem:(MLTaskbarItem *)item {
    if (item.pid <= 0) {
        return;
    }
    if (!AXIsProcessTrusted()) {
        return;
    }

    CGWindowID wid = item.windowID;
    MLWindowSoftRecord *soft = wid != 0 ? [self.monitor.softState recordForWindowID:wid] : nil;
    BOOL wasSoft = soft != nil;
    NSRect restoreFrame = soft ? soft.restoreFrameCocoa : NSZeroRect;
    MLWindowHideMethod hideMethod = soft ? soft.hideMethod : MLWindowHideMethodNone;
    BOOL needsGeometry = wasSoft && restoreFrame.size.width > 2.0 && restoreFrame.size.height > 2.0;
    AXUIElementRef softAX = soft ? soft.axWindow : NULL;

    AXUIElementRef appRef = AXUIElementCreateApplication(item.pid);
    if (!appRef) {
        return;
    }

    CFTypeRef windowsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
    if (err != kAXErrorSuccess || !windowsRef || CFGetTypeID(windowsRef) != CFArrayGetTypeID()) {
        if (windowsRef) {
            CFRelease(windowsRef);
        }
        /* Soft restore: still try retained AX element. */
        if (softAX && wasSoft) {
            if (hideMethod == MLWindowHideMethodAlpha && wid != 0) {
                MLCGSSetWindowAlpha(wid, 1.0f);
            }
            AXUIElementSetAttributeValue(softAX, kAXMinimizedAttribute, kCFBooleanFalse);
            AXUIElementPerformAction(softAX, kAXRaiseAction);
            AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
            if (needsGeometry) {
                [self applyRestoreFrame:restoreFrame toAXWindow:softAX windowID:wid clearIfMatched:YES];
            }
        } else {
            AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
        }
        CFRelease(appRef);
        return;
    }

    CFArrayRef windows = (CFArrayRef)windowsRef;
    CFIndex count = CFArrayGetCount(windows);
    MLAXGetWindowFn getWid = MLResolvedAXGetWindow();

    AXUIElementRef matchedByID = NULL;
    AXUIElementRef matchedByTitle = NULL;
    AXUIElementRef firstMinimized = NULL;
    AXUIElementRef firstAny = NULL;
    BOOL softAXStillListed = NO;

    NSString *appDisplay = [self displayNameForPath:item.path];
    BOOL titleIsAppNameOnly =
        (appDisplay.length > 0 && item.title.length > 0 && [item.title isEqualToString:appDisplay]);

    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        if (!firstAny) {
            firstAny = win;
        }
        if (softAX && win == softAX) {
            softAXStillListed = YES;
        }

        CGWindowID axWid = 0;
        if (getWid && getWid(win, &axWid) == kAXErrorSuccess && wid != 0 && axWid == wid) {
            matchedByID = win;
        }

        CFTypeRef minRef = NULL;
        Boolean isMin = false;
        if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
            if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                isMin = CFBooleanGetValue((CFBooleanRef)minRef);
            }
            CFRelease(minRef);
        }
        if (isMin && !firstMinimized) {
            firstMinimized = win;
        }

        if (!matchedByTitle && !titleIsAppNameOnly && soft) {
            CFTypeRef titleRef = NULL;
            NSString *title = nil;
            if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &titleRef) == kAXErrorSuccess &&
                titleRef) {
                if (CFGetTypeID(titleRef) == CFStringGetTypeID()) {
                    title = (__bridge NSString *)titleRef;
                }
                CFRelease(titleRef);
            }
            NSString *hint = soft.title.length > 0 ? soft.title : item.title;
            if (![hint isEqualToString:appDisplay] && [self title:title ?: @"" matchesHint:hint]) {
                matchedByTitle = win;
            }
        }
    }

    /* Prefer retained AX from minimize; then windowID; then title; then minimized. */
    AXUIElementRef target = nil;
    if (softAX && (softAXStillListed || wasSoft)) {
        target = softAX;
    }
    if (!target) {
        target = matchedByID ?: matchedByTitle;
    }
    if (!target) {
        if (wasSoft || item.minimized) {
            target = firstMinimized ?: firstAny;
        } else {
            target = firstAny ?: firstMinimized;
        }
    }

    BOOL verified = NO;
    if (target) {
        if (wasSoft && hideMethod == MLWindowHideMethodAlpha && wid != 0) {
            MLCGSSetWindowAlpha(wid, 1.0f);
        }

        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute, kCFBooleanFalse);
        AXUIElementPerformAction(target, kAXRaiseAction);
        AXUIElementSetAttributeValue(target, kAXMainAttribute, kCFBooleanTrue);
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute, kCFBooleanTrue);
        AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);

        if (needsGeometry) {
            verified = [self applyRestoreFrame:restoreFrame
                                     toAXWindow:target
                                       windowID:wid
                                  clearIfMatched:YES];

            if (!verified) {
                AXUIElementRef winKeep = (AXUIElementRef)CFRetain(target);
                NSRect frameKeep = restoreFrame;
                CGWindowID widKeep = wid;
                __weak typeof(self) weakSelf = self;
                /* Finder often needs several ticks after deminiaturize before AX size sticks. */
                static const double kDelays[] = { 0.05, 0.12, 0.25, 0.45, 0.75, 1.20 };
                __block NSInteger pending = (NSInteger)(sizeof(kDelays) / sizeof(kDelays[0]));
                for (size_t i = 0; i < sizeof(kDelays) / sizeof(kDelays[0]); i++) {
                    double delay = kDelays[i];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                                       __strong typeof(weakSelf) self = weakSelf;
                                       if (self &&
                                           [self.monitor.softState isSoftHiddenWindowID:widKeep]) {
                                           AXUIElementSetAttributeValue(winKeep, kAXMinimizedAttribute,
                                                                        kCFBooleanFalse);
                                           [self applyRestoreFrame:frameKeep
                                                         toAXWindow:winKeep
                                                           windowID:widKeep
                                                      clearIfMatched:YES];
                                       }
                                       if (--pending == 0) {
                                           CFRelease(winKeep);
                                       }
                                   });
                }
            }
        } else if (wasSoft) {
            /* Soft without frame — clear once deminiaturized / raised. */
            Boolean stillMin = false;
            CFTypeRef minRef = NULL;
            if (AXUIElementCopyAttributeValue(target, kAXMinimizedAttribute, &minRef) ==
                    kAXErrorSuccess &&
                minRef) {
                if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                    stillMin = CFBooleanGetValue((CFBooleanRef)minRef);
                }
                CFRelease(minRef);
            }
            if (!stillMin && wid != 0) {
                [self.monitor.softState clearVerifiedWindowID:wid];
                verified = YES;
            }
        }

        if (wasSoft) {
            if (verified) {
                NSLog(@"[Taskbar] soft restore ok wid=%u", (unsigned)wid);
            } else if (needsGeometry) {
                NSLog(@"[Taskbar] soft restore pending wid=%u (chip kept, retries scheduled)",
                      (unsigned)wid);
            }
        }
    } else {
        AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
        NSLog(@"[Taskbar] soft restore fail — no AX target wid=%u", (unsigned)wid);
    }

    CFRelease(windowsRef);
    CFRelease(appRef);
}

- (void)activateApplicationForItem:(MLTaskbarItem *)item {
    NSRunningApplication *app = nil;
    if (item.pid > 0) {
        app = [NSRunningApplication runningApplicationWithProcessIdentifier:item.pid];
    }
    if ((!app || app.isTerminated) && item.path.length > 0) {
        NSString *std = item.path.stringByStandardizingPath;
        for (NSRunningApplication *ra in [NSWorkspace sharedWorkspace].runningApplications) {
            NSString *p = ra.bundleURL.path;
            if ([p isEqualToString:item.path] ||
                (std.length > 0 && [p.stringByStandardizingPath isEqualToString:std])) {
                app = ra;
                item.pid = ra.processIdentifier;
                break;
            }
        }
    }
    if (!app || app.isTerminated) {
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL softRestore =
        item.minimized ||
        (item.windowID != 0 && [self.monitor isSoftMinimizedWindowID:item.windowID]);
    NSApplicationActivationOptions opts = NSApplicationActivateIgnoringOtherApps;
    if (!softRestore) {
        opts |= NSApplicationActivateAllWindows;
    }
    [app activateWithOptions:opts];
#pragma clang diagnostic pop

    if (@available(macOS 14.0, *)) {
        [app unhide];
    }
}

- (void)openApplicationAtPath:(NSString *)path {
    if (path.length == 0) {
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                          configuration:cfg
                                      completionHandler:^(__unused NSRunningApplication *app, NSError *error) {
                                          if (error) {
                                              NSLog(@"[MeoLaunch] taskbar launch failed: %@", error);
                                          }
                                      }];
}

- (BOOL)isApplicationRunningAtPath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    NSString *std = path.stringByStandardizingPath;
    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        NSString *p = app.bundleURL.path;
        if (p.length == 0) {
            continue;
        }
        if ([p isEqualToString:path] ||
            (std.length > 0 && [p.stringByStandardizingPath isEqualToString:std])) {
            return !app.isTerminated;
        }
    }
    return NO;
}

- (void)activateOrLaunchItem:(MLTaskbarItem *)item {
    if (item.kind == MLTaskbarItemPinnedOnly) {
        [self activateApplicationForItem:item];
        [self openApplicationAtPath:item.path];
        return;
    }

    if (item.pid > 0 || item.path.length > 0) {
        BOOL softRestore =
            item.minimized ||
            (item.windowID != 0 && [self.monitor isSoftMinimizedWindowID:item.windowID]);
        if (softRestore) {
            [self activateApplicationForItem:item];
            [self raiseAndFocusWindowForItem:item];
        } else {
            [self raiseAndFocusWindowForItem:item];
            [self activateApplicationForItem:item];
        }
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf raiseAndFocusWindowForItem:item];
                           [weakSelf activateApplicationForItem:item];
                       });
        if (softRestore) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               [weakSelf raiseAndFocusWindowForItem:item];
                           });
        }
        if (item.pid > 0) {
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:item.pid];
            if (app && !app.isTerminated) {
                return;
            }
        }
        if ([self isApplicationRunningAtPath:item.path]) {
            return;
        }
    }

    [self openApplicationAtPath:item.path];
}

- (void)taskbarView:(MLTaskbarView *)view didClickItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    [self activateOrLaunchItem:view.items[(NSUInteger)index]];
}

- (void)taskbarView:(MLTaskbarView *)view didRequestPinToggleAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    MLTaskbarItem *item = view.items[(NSUInteger)index];
    if (item.path.length == 0) {
        return;
    }
    if (item.pinned) {
        [self.pinStore unpinPath:item.path];
    } else {
        [self.pinStore pinPath:item.path];
    }
}

@end
