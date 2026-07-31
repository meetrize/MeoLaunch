#import "MLTaskbarController.h"

#import "MLCGSAlpha.h"
#import "MLDebugLog.h"
#import "MLMinimizeInterceptor.h"
#import "MLRunningAppsMonitor.h"
#import "MLScreenGeometry.h"
#import "MLTaskbarIconCache.h"
#import "MLTaskbarPinStore.h"
#import "MLTaskbarView.h"
#import "MLWindowSoftState.h"
#import "MLWorkAreaEnforcer.h"

#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>

enum {
    MLTaskbarBarHeight = 40,
    MLTaskbarPeekOffset = 28,
    MLTaskbarHideConfirmCount = 2,
};

/** Quiet period before painting live candidates — absorbs Show Desktop / Exposé churn. */
static const NSTimeInterval MLTaskbarItemsCommitDelay = 0.32;
/** After leaving peek, wait for window list to settle before one atomic paint. */
static const NSTimeInterval MLTaskbarExitSettleDelay = 0.45;

typedef NS_ENUM(NSInteger, MLTaskbarBarMode) {
    MLTaskbarBarModeNormal = 0,
    MLTaskbarBarModePeek = 1,   /* Show Desktop: keep bar, slide down slightly */
    MLTaskbarBarModeHidden = 2, /* Immersive / Space fullscreen */
};

@interface MLTaskbarScreenBar : NSObject
@property (nonatomic, strong) NSNumber *screenID;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) MLTaskbarView *barView;
@property (nonatomic, assign) MLTaskbarBarMode mode;
/** Latest computed chips; painted only via commit (not on every monitor tick). */
@property (nonatomic, strong) NSArray<MLTaskbarItem *> *pendingItems;
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
@property (nonatomic, strong) NSSet<NSNumber *> *desktopRevealScreenIDs;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *fullscreenHideStreaks;
/** Per-screen window-chip counts from the last successful (unfrozen) rebuild. */
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *lastStableWindowCountByScreen;
/** Deep-copied chips per screen, captured at freeze time. */
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<MLTaskbarItem *> *> *frozenItemsByScreenID;
/** While YES, chips stay exactly as frozen — no live rebuild. */
@property (nonatomic, assign) BOOL itemsFrozenForDesktopReveal;
/** Live on-screen window count while desktop was normal; used to detect sudden drop. */
@property (nonatomic, assign) NSInteger lastStableLiveWindowCount;
/** Live count captured at freeze time (unfreeze when live returns). */
@property (nonatomic, assign) NSInteger freezeLiveBaseline;
/** Wall time when start finished; freeze disabled until armed. */
@property (nonatomic, assign) NSTimeInterval desktopRevealArmTime;
/** Debounced painter: display list is sticky until this fires. */
@property (nonatomic, strong) NSTimer *itemsCommitTimer;
/** Until this time, refuse painting a much-smaller chip set (exit Show Desktop settle). */
@property (nonatomic, assign) NSTimeInterval stickyDisplayUntil;
/** One frontmost wid per rebuild pass — avoids N× CGWindowList on multi-monitor. */
@property (nonatomic, assign) CGWindowID rebuildPassFrontmostWID;
@property (nonatomic, assign) BOOL rebuildPassFrontmostValid;
@property (nonatomic, assign) CGWindowID cachedTopmostUserWID;
@property (nonatomic, assign) NSTimeInterval cachedTopmostUserAt;
@property (nonatomic, strong) NSTimer *visibilitySafetyTimer;
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
        _fullscreenHideStreaks = [NSMutableDictionary dictionary];
        _lastStableWindowCountByScreen = [NSMutableDictionary dictionary];
        _frozenItemsByScreenID = [NSMutableDictionary dictionary];
        _fullscreenScreenIDs = [NSSet set];
        _desktopRevealScreenIDs = [NSSet set];
        _itemsFrozenForDesktopReveal = NO;
        _lastStableLiveWindowCount = 0;
        _freezeLiveBaseline = 0;
        _desktopRevealArmTime = 0;
        _stickyDisplayUntil = 0;
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

/**
 * Topmost on-screen layer-0 user window, ignoring MeoLaunch.
 * Used for taskbar re-click minimize: clicking the bar often makes us frontmost,
 * so NSWorkspace.frontmostApplication is unreliable at click time.
 */
- (CGWindowID)topmostUserWindowIDExcludingSelf {
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (self.cachedTopmostUserAt > 0 && (now - self.cachedTopmostUserAt) < 0.08 &&
        self.cachedTopmostUserWID != 0) {
        return self.cachedTopmostUserWID;
    }
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
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
        if (wpid <= 0 || wpid == selfPid) {
            continue;
        }
        NSRunningApplication *owner = [NSRunningApplication runningApplicationWithProcessIdentifier:wpid];
        if (!owner || owner.isTerminated ||
            owner.activationPolicy != NSApplicationActivationPolicyRegular) {
            continue;
        }
        CFStringRef ownerRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (ownerRef && CFGetTypeID(ownerRef) == CFStringGetTypeID()) {
            NSString *ownerName = (__bridge NSString *)ownerRef;
            if ([[self class] isSystemWindowOwner:ownerName]) {
                continue;
            }
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
        CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (alphaRef) {
            double alpha = 1.0;
            CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
            if (alpha < 0.2) {
                continue;
            }
        }
        CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
        if (winRef) {
            CFNumberGetValue(winRef, kCFNumberIntType, &best);
        }
        break;
    }
    CFRelease(list);
    self.cachedTopmostUserWID = best;
    self.cachedTopmostUserAt = now;
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

- (NSInteger)windowChipCountInItems:(NSArray<MLTaskbarItem *> *)items {
    NSInteger n = 0;
    for (MLTaskbarItem *it in items ?: @[]) {
        if (it.kind == MLTaskbarItemRunningWindow) {
            n += 1;
        }
    }
    return n;
}

- (NSArray<MLTaskbarItem *> *)deepCopyItems:(NSArray<MLTaskbarItem *> *)src {
    NSMutableArray<MLTaskbarItem *> *out = [NSMutableArray arrayWithCapacity:src.count];
    for (MLTaskbarItem *it in src ?: @[]) {
        MLTaskbarItem *c = [[MLTaskbarItem alloc] init];
        c.path = it.path;
        c.bundleID = it.bundleID;
        c.pid = it.pid;
        c.windowID = it.windowID;
        c.title = it.title;
        c.kind = it.kind;
        c.pinned = it.pinned;
        c.minimized = it.minimized;
        c.active = it.active;
        c.seenOrder = it.seenOrder;
        [out addObject:c];
    }
    return out;
}

/**
 * Compute chips for one bar into pendingItems — does NOT paint.
 * Painting goes through commitPendingItemsForce: so Show Desktop churn stays invisible.
 */
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
    CGWindowID frontWid = self.rebuildPassFrontmostValid
                              ? self.rebuildPassFrontmostWID
                              : [self frontmostTrackedWindowID];
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
    bar.pendingItems = items;
}

- (NSInteger)windowChipCountOnBar:(MLTaskbarScreenBar *)bar {
    return [self windowChipCountInItems:bar.barView.items];
}

- (void)cancelItemsCommitTimer {
    [self.itemsCommitTimer invalidate];
    self.itemsCommitTimer = nil;
}

- (void)scheduleItemsCommitWithDelay:(NSTimeInterval)delay {
    [self cancelItemsCommitTimer];
    if (delay < 0.01) {
        [self commitPendingItemsForce:NO];
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.itemsCommitTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                             repeats:NO
                                                               block:^(__unused NSTimer *timer) {
                                                                   __strong typeof(weakSelf) self = weakSelf;
                                                                   if (!self) {
                                                                       return;
                                                                   }
                                                                   self.itemsCommitTimer = nil;
                                                                   [self commitPendingItemsForce:NO];
                                                               }];
    [[NSRunLoop mainRunLoop] addTimer:self.itemsCommitTimer forMode:NSRunLoopCommonModes];
}

/**
 * Paint pending → barView in one shot.
 * force=YES: pin / soft-min / user actions (skip reveal-hold).
 * force=NO: refuse large drops while desktop looks revealed — freeze instead.
 */
- (void)commitPendingItemsForce:(BOOL)force {
    if (!self.started) {
        return;
    }
    if (self.itemsFrozenForDesktopReveal) {
        [self restoreFrozenItemsOntoBars];
        return;
    }

    if (!force && [self looksLikeDesktopReveal] && [self totalWindowChipsOnBars] >= 1) {
        /* Keep displayed chips; enter peek freeze so monitor churn never paints. */
        [self freezeDesktopReveal];
        return;
    }

    NSInteger pendingWindows = 0;
    NSInteger shownWindows = 0;
    for (MLTaskbarScreenBar *bar in self.bars) {
        pendingWindows += [self windowChipCountInItems:bar.pendingItems];
        shownWindows += [self windowChipCountOnBar:bar];
    }
    /* Large chip drop while reveal-armed → freeze even if cover heuristic is still catching up. */
    if (!force && shownWindows >= 2 && pendingWindows + 1 < shownWindows &&
        [self isDesktopRevealArmed] &&
        ([self looksLikeDesktopReveal] || [self shouldFreezeForDesktopReveal] ||
         pendingWindows * 2 < shownWindows)) {
        [self freezeDesktopReveal];
        return;
    }

    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (!force && now < self.stickyDisplayUntil) {
        NSInteger expect = MAX(self.lastStableLiveWindowCount, shownWindows);
        if (expect >= 2 && pendingWindows + 1 < expect) {
            CGFloat cover = 0;
            NSInteger onScreen = 0;
            NSInteger all = 0;
            [self measureDesktopRevealWithCenterCover:&cover onScreen:&onScreen all:&all];
            BOOL newReality = (cover >= 0.15 && onScreen <= pendingWindows + 1 &&
                               all <= pendingWindows + 1);
            if (!newReality) {
                /* Windows still flying back — keep old chips, try again after quiet. */
                [self scheduleItemsCommitWithDelay:MLTaskbarItemsCommitDelay];
                return;
            }
        }
    }

    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.barView || !bar.pendingItems) {
            continue;
        }
        bar.barView.items = bar.pendingItems;
        NSInteger windowChips = [self windowChipCountOnBar:bar];
        if (bar.screenID && windowChips > 0) {
            self.lastStableWindowCountByScreen[bar.screenID] = @(windowChips);
        } else if (bar.screenID && ![self looksLikeDesktopReveal]) {
            self.lastStableWindowCountByScreen[bar.screenID] = @(windowChips);
        }
    }
}

- (void)restoreFrozenItemsOntoBars {
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.screenID || !bar.barView) {
            continue;
        }
        NSArray<MLTaskbarItem *> *frozen = self.frozenItemsByScreenID[bar.screenID];
        if (frozen) {
            bar.barView.items = frozen;
            bar.pendingItems = frozen;
        }
    }
}

- (BOOL)isDesktopRevealArmed {
    if (self.desktopRevealArmTime <= 0) {
        return NO;
    }
    return [NSDate date].timeIntervalSinceReferenceDate >= self.desktopRevealArmTime;
}

/**
 * Scan app windows: center coverage (0…1 max across screens), on-screen count,
 * and all-spaces count (includes Show Desktop off-screen / edge windows).
 */
- (void)measureDesktopRevealWithCenterCover:(CGFloat *)outCover
                                   onScreen:(NSInteger *)outOnScreen
                                        all:(NSInteger *)outAll {
    __block CGFloat maxCover = 0.0;
    __block NSInteger onScreen = 0;
    __block NSInteger all = 0;
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;

    void (^consume)(CFDictionaryRef, BOOL) = ^(CFDictionaryRef info, BOOL countAllOnly) {
        if (!info) {
            return;
        }
        CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        pid_t pid = 0;
        if (pidRef) {
            CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
        }
        if (pid <= 0 || pid == selfPid) {
            return;
        }
        CFStringRef ownerRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (ownerRef && CFGetTypeID(ownerRef) == CFStringGetTypeID()) {
            NSString *owner = (__bridge NSString *)ownerRef;
            if ([[self class] isSystemWindowOwner:owner] ||
                [owner isEqualToString:@"Finder"]) {
                return;
            }
        }
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        int layer = 0;
        if (layerRef) {
            CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        }
        if (layer != 0) {
            return;
        }
        CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (alphaRef) {
            double alpha = 1.0;
            CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
            if (alpha < 0.2) {
                return;
            }
        }
        CGRect boundsQ = CGRectZero;
        CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &boundsQ)) {
            return;
        }
        if (boundsQ.size.width < 60.0 || boundsQ.size.height < 40.0) {
            return;
        }
        if (countAllOnly) {
            all += 1;
            return;
        }
        NSRect bounds = [MLScreenGeometry cocoaRectFromQuartzBounds:boundsQ];
        onScreen += 1;
        for (NSScreen *screen in NSScreen.screens) {
            NSRect sf = screen.frame;
            NSRect center = NSInsetRect(sf, NSWidth(sf) * 0.18, NSHeight(sf) * 0.18);
            NSRect hit = NSIntersectionRect(bounds, center);
            if (NSIsEmptyRect(hit)) {
                continue;
            }
            CGFloat area = NSWidth(center) * NSHeight(center);
            if (area < 1.0) {
                continue;
            }
            CGFloat cover = (NSWidth(hit) * NSHeight(hit)) / area;
            if (cover > maxCover) {
                maxCover = cover;
            }
        }
    };

    CFArrayRef onList = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                       kCGWindowListExcludeDesktopElements,
                                                   kCGNullWindowID);
    if (onList) {
        CFIndex count = CFArrayGetCount(onList);
        for (CFIndex i = 0; i < count; i++) {
            consume((CFDictionaryRef)CFArrayGetValueAtIndex(onList, i), NO);
        }
        CFRelease(onList);
    }
    CFArrayRef allList = CGWindowListCopyWindowInfo(kCGWindowListOptionAll |
                                                        kCGWindowListExcludeDesktopElements,
                                                    kCGNullWindowID);
    if (allList) {
        CFIndex count = CFArrayGetCount(allList);
        for (CFIndex i = 0; i < count; i++) {
            consume((CFDictionaryRef)CFArrayGetValueAtIndex(allList, i), YES);
        }
        CFRelease(allList);
    }

    if (outCover) {
        *outCover = maxCover;
    }
    if (outOnScreen) {
        *outOnScreen = onScreen;
    }
    if (outAll) {
        *outAll = all;
    }
}

- (void)updateStableLiveCensus {
    if (self.itemsFrozenForDesktopReveal) {
        return;
    }
    NSInteger live = [self liveNonMinimizedWindowCount];
    if (live > 0) {
        self.lastStableLiveWindowCount = live;
    }
}

- (NSInteger)frozenWindowChipTotal {
    NSInteger n = 0;
    for (NSNumber *sid in self.frozenItemsByScreenID) {
        for (MLTaskbarItem *it in self.frozenItemsByScreenID[sid] ?: @[]) {
            if (it.kind == MLTaskbarItemRunningWindow) {
                n += 1;
            }
        }
    }
    return n;
}

- (BOOL)shouldUnfreezeDesktopReveal {
    if (!self.itemsFrozenForDesktopReveal) {
        return NO;
    }
    if (![self isDesktopRevealArmed]) {
        return YES;
    }
    CGFloat cover = 0;
    NSInteger onScreen = 0;
    NSInteger all = 0;
    [self measureDesktopRevealWithCenterCover:&cover onScreen:&onScreen all:&all];
    /* Truly empty — not Show Desktop; leave peek. */
    if (all < 1 && onScreen < 1) {
        return YES;
    }
    /* Windows back covering the desktop center. */
    if (cover >= 0.18) {
        return YES;
    }
    NSInteger live = [self liveNonMinimizedWindowCount];
    if (live >= 1 && cover >= 0.10) {
        return YES;
    }
    if (live >= MAX(1, self.freezeLiveBaseline) && onScreen >= live) {
        return YES;
    }
    return NO;
}

- (void)freezeDesktopReveal {
    if (self.itemsFrozenForDesktopReveal) {
        [self restoreFrozenItemsOntoBars];
        return;
    }
    if (![self isDesktopRevealArmed]) {
        return;
    }
    [self cancelItemsCommitTimer];
    [self.frozenItemsByScreenID removeAllObjects];
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.screenID || !bar.barView) {
            continue;
        }
        NSArray<MLTaskbarItem *> *shot = [self deepCopyItems:bar.barView.items];
        self.frozenItemsByScreenID[bar.screenID] = shot;
        bar.pendingItems = shot;
        NSInteger chips = [self windowChipCountOnBar:bar];
        if (chips > 0) {
            self.lastStableWindowCountByScreen[bar.screenID] = @(chips);
        }
    }
    self.freezeLiveBaseline = MAX(self.lastStableLiveWindowCount, [self frozenWindowChipTotal]);
    self.itemsFrozenForDesktopReveal = YES;
    NSMutableSet<NSNumber *> *all = [NSMutableSet set];
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (bar.screenID) {
            [all addObject:bar.screenID];
        }
    }
    self.desktopRevealScreenIDs = all;
    self.fullscreenScreenIDs = [NSSet set];
    MLDebugLog(@"[Taskbar] desktop reveal FREEZE baseline=%ld chips=%ld",
          (long)self.freezeLiveBaseline, (long)[self frozenWindowChipTotal]);
    [self applyBarVisibility];
}

- (void)unfreezeDesktopRevealAndRefresh {
    BOOL hadPeek = self.itemsFrozenForDesktopReveal || self.desktopRevealScreenIDs.count > 0;
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (bar.mode == MLTaskbarBarModePeek) {
            hadPeek = YES;
            break;
        }
    }
    if (!hadPeek) {
        return;
    }

    NSSet<NSNumber *> *wasReveal = [self.desktopRevealScreenIDs copy] ?: [NSSet set];
    self.itemsFrozenForDesktopReveal = NO;
    self.desktopRevealScreenIDs = [NSSet set];
    self.freezeLiveBaseline = 0;
    /* Keep frozenItems until first successful commit so a partial live list cannot paint. */
    NSDictionary<NSNumber *, NSArray<MLTaskbarItem *> *> *hold =
        [self.frozenItemsByScreenID copy] ?: @{};
    [self.frozenItemsByScreenID removeAllObjects];

    for (NSNumber *sid in wasReveal) {
        [self.fullscreenHideStreaks removeObjectForKey:sid];
    }
    if (wasReveal.count > 0) {
        NSMutableSet<NSNumber *> *fs = [self.fullscreenScreenIDs mutableCopy] ?: [NSMutableSet set];
        [fs minusSet:wasReveal];
        self.fullscreenScreenIDs = fs;
    }

    NSDictionary<NSNumber *, NSScreen *> *screensByID = [self screensByID];
    for (MLTaskbarScreenBar *bar in self.bars) {
        NSScreen *screen = screensByID[bar.screenID];
        if (!screen || !bar.window) {
            continue;
        }
        bar.mode = MLTaskbarBarModeNormal;
        CGFloat height = [self barHeightForBar:bar];
        NSRect home = [self normalFrameForScreen:screen height:height];
        [bar.window setFrame:home display:YES];
        bar.barView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        bar.barView.frame = bar.window.contentView.bounds;
        /* Hold last peek composition until settle commit — no incremental chip morph. */
        NSArray<MLTaskbarItem *> *kept = hold[bar.screenID];
        if (kept.count > 0) {
            bar.barView.items = kept;
            bar.pendingItems = kept;
        }
        [bar.window orderFrontRegardless];
    }

    self.stickyDisplayUntil = [NSDate date].timeIntervalSinceReferenceDate + 1.25;
    /* One atomic paint after window list quiet — not on each window that flies back. */
    [self computePendingItemsForAllBars];
    [self scheduleItemsCommitWithDelay:MLTaskbarExitSettleDelay];
    [self updateStableLiveCensus];
    MLDebugLog(@"[Taskbar] desktop reveal UNFREEZE + settle commit");
}

- (NSInteger)liveNonMinimizedWindowCount {
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    NSInteger n = 0;
    for (MLTaskbarWindowInfo *w in self.monitor.snapshot.windows ?: @[]) {
        if (w.pid == selfPid || w.minimized) {
            continue;
        }
        n += 1;
    }
    return n;
}

- (NSInteger)totalWindowChipsOnBars {
    NSInteger n = 0;
    for (MLTaskbarScreenBar *bar in self.bars) {
        n += [self windowChipCountOnBar:bar];
    }
    return n;
}

/** Desktop center clear while app windows still exist somewhere (Show Desktop / Exposé). */
- (BOOL)looksLikeDesktopReveal {
    if (![self isDesktopRevealArmed]) {
        return NO;
    }
    CGFloat cover = 0;
    NSInteger onScreen = 0;
    NSInteger all = 0;
    [self measureDesktopRevealWithCenterCover:&cover onScreen:&onScreen all:&all];
    if (all < 1) {
        return NO;
    }
    if (cover < 0.14 && onScreen <= 1) {
        return YES;
    }
    if (cover < 0.10) {
        return YES;
    }
    NSInteger live = [self liveNonMinimizedWindowCount];
    if (self.lastStableLiveWindowCount >= 1 && live == 0 && cover < 0.20) {
        return YES;
    }
    return NO;
}

/**
 * Show Desktop: desktop center cleared while app windows still exist (edges / off-screen),
 * or on-screen live count collapsed after we had a stable census.
 */
- (BOOL)shouldFreezeForDesktopReveal {
    if (![self isDesktopRevealArmed] || self.itemsFrozenForDesktopReveal) {
        return NO;
    }
    if (self.lastStableLiveWindowCount < 1 && [self totalWindowChipsOnBars] < 1) {
        return NO;
    }

    CGFloat cover = 0;
    NSInteger onScreen = 0;
    NSInteger all = 0;
    [self measureDesktopRevealWithCenterCover:&cover onScreen:&onScreen all:&all];

    /* Windows still exist but desktop center is clear → Show Desktop / Exposé. */
    if (cover < 0.14 && all >= 1 && [self totalWindowChipsOnBars] >= 1) {
        if (onScreen < MAX(1, self.lastStableLiveWindowCount) || onScreen == 0 || cover < 0.08) {
            return YES;
        }
    }
    if (cover < 0.14 && all >= 1 && onScreen < MAX(1, self.lastStableLiveWindowCount)) {
        return YES;
    }
    if (cover < 0.14 && all >= 1 && [self totalWindowChipsOnBars] >= 1 && onScreen == 0) {
        return YES;
    }
    NSInteger live = [self liveNonMinimizedWindowCount];
    if (self.lastStableLiveWindowCount >= 1 && live == 0 && all >= 1 && cover < 0.20) {
        return YES;
    }
    return NO;
}

- (void)computePendingItemsForAllBars {
    self.rebuildPassFrontmostWID = [self frontmostTrackedWindowID];
    self.rebuildPassFrontmostValid = YES;
    NSDictionary<NSNumber *, NSScreen *> *screensByID = [self screensByID];
    for (MLTaskbarScreenBar *bar in self.bars) {
        NSScreen *screen = screensByID[bar.screenID];
        if (screen) {
            [self rebuildItemsForBar:bar screen:screen];
        }
    }
    self.rebuildPassFrontmostValid = NO;
}

/**
 * @param immediate YES = paint now (pin / soft-min). NO = debounce (monitor / Show Desktop churn).
 * Monitor paths must use NO so Show Desktop can freeze before chips morph.
 */
- (void)rebuildItemsImmediate:(BOOL)immediate {
    if (!self.started) {
        return;
    }
    if (self.itemsFrozenForDesktopReveal) {
        [self restoreFrozenItemsOntoBars];
        return;
    }
    if ([self shouldFreezeForDesktopReveal]) {
        [self freezeDesktopReveal];
        return;
    }
    [self computePendingItemsForAllBars];
    if (immediate) {
        [self cancelItemsCommitTimer];
        /* force=YES only for intentional user-driven paints (pin / soft-min callers). */
        [self commitPendingItemsForce:YES];
    } else {
        [self scheduleItemsCommitWithDelay:MLTaskbarItemsCommitDelay];
    }
}

- (void)rebuildItems {
    /* Always debounce — coalesces Show Desktop window-list churn before paint. */
    [self rebuildItemsImmediate:NO];
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

- (CGFloat)barHeightForBar:(MLTaskbarScreenBar *)bar {
    if (bar.barView.barHeight > 0) {
        return bar.barView.barHeight;
    }
    return (CGFloat)MLTaskbarBarHeight;
}

- (NSRect)normalFrameForScreen:(NSScreen *)screen height:(CGFloat)height {
    NSRect visible = screen.visibleFrame;
    return NSMakeRect(NSMinX(visible), NSMinY(visible), NSWidth(visible), height);
}

/**
 * Peek: move the whole taskbar window down by MLTaskbarPeekOffset.
 * (Content-offset alone is unreliable under Mission Control / autoresizing.)
 */
- (void)applyPeekPresentationForBar:(MLTaskbarScreenBar *)bar
                            peeking:(BOOL)peeking
                           animated:(BOOL)animated {
    if (!bar.window || !bar.barView) {
        return;
    }
    NSScreen *screen = nil;
    for (NSScreen *s in NSScreen.screens) {
        if ([[[self class] screenIDForScreen:s] isEqualToNumber:bar.screenID]) {
            screen = s;
            break;
        }
    }
    if (!screen) {
        screen = bar.window.screen ?: NSScreen.mainScreen;
    }
    if (!screen) {
        return;
    }

    CGFloat height = [self barHeightForBar:bar];
    NSRect home = [self normalFrameForScreen:screen height:height];
    NSRect target = home;
    if (peeking) {
        target.origin.y -= (CGFloat)MLTaskbarPeekOffset;
    }

    bar.barView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (animated && bar.window.isVisible &&
        fabs(NSMinY(bar.window.frame) - NSMinY(target)) > 0.5) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.18;
            [[bar.window animator] setFrame:target display:YES];
        } completionHandler:^{
            bar.barView.frame = bar.window.contentView.bounds;
        }];
    } else {
        [bar.window setFrame:target display:YES];
        bar.barView.frame = bar.window.contentView.bounds;
    }
}

- (void)setBar:(MLTaskbarScreenBar *)bar frame:(NSRect)frame animated:(BOOL)animated {
    if (!bar.window) {
        return;
    }
    if (NSEqualRects(bar.window.frame, frame)) {
        return;
    }
    if (animated && bar.window.isVisible) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.18;
            [[bar.window animator] setFrame:frame display:YES];
        }];
    } else {
        [bar.window setFrame:frame display:YES];
    }
}

- (MLTaskbarScreenBar *)makeBarForScreen:(NSScreen *)screen {
    CGFloat height = (CGFloat)MLTaskbarBarHeight;
    NSRect frame = [self normalFrameForScreen:screen height:height];

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

    NSView *content = w.contentView;
    content.clipsToBounds = YES;

    MLTaskbarView *view = [[MLTaskbarView alloc] initWithFrame:content.bounds];
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.delegate = self;
    view.iconCache = self.iconCache;
    view.barHeight = height;
    [content addSubview:view];

    MLTaskbarScreenBar *bar = [[MLTaskbarScreenBar alloc] init];
    bar.screenID = [[self class] screenIDForScreen:screen];
    bar.window = w;
    bar.barView = view;
    bar.mode = MLTaskbarBarModeNormal;
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
            if (bar.mode != MLTaskbarBarModeHidden) {
                CGFloat height = [self barHeightForBar:bar];
                [self setBar:bar frame:[self normalFrameForScreen:screen height:height] animated:NO];
                [self applyPeekPresentationForBar:bar
                                          peeking:(bar.mode == MLTaskbarBarModePeek)
                                         animated:NO];
            }
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

    [self refreshFullscreenVisibility];
    if (!self.itemsFrozenForDesktopReveal) {
        [self rebuildItemsImmediate:YES];
    } else {
        [self restoreFrozenItemsOntoBars];
    }
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
    /* Allow Show Desktop freeze only after census has settled (avoid startup false peek). */
    self.desktopRevealArmTime = [NSDate date].timeIntervalSinceReferenceDate + 1.0;
    self.lastStableLiveWindowCount = 0;
    self.freezeLiveBaseline = 0;
    self.itemsFrozenForDesktopReveal = NO;
    self.desktopRevealScreenIDs = [NSSet set];
    [self.frozenItemsByScreenID removeAllObjects];

    [self syncBarsToScreens];
    [self scheduleStartupVisibilityRechecks];
    [self updateVisibilitySafetyTimer];

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
    [self cancelItemsCommitTimer];
    [self.visibilitySafetyTimer invalidate];
    self.visibilitySafetyTimer = nil;
    self.fullscreenScreenIDs = [NSSet set];
    self.desktopRevealScreenIDs = [NSSet set];
    self.itemsFrozenForDesktopReveal = NO;
    self.lastStableLiveWindowCount = 0;
    self.freezeLiveBaseline = 0;
    self.desktopRevealArmTime = 0;
    [self.frozenItemsByScreenID removeAllObjects];
    [self.fullscreenHideStreaks removeAllObjects];
    [self.lastStableWindowCountByScreen removeAllObjects];
    self.stickyDisplayUntil = 0;
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
    [self.displayNameCache removeAllObjects];
}

- (void)pinsDidChange:(NSNotification *)note {
    (void)note;
    if (self.itemsFrozenForDesktopReveal) {
        return;
    }
    [self rebuildItemsImmediate:YES];
}

- (void)runningDidChange:(NSNotification *)note {
    (void)note;
    if ([self shouldFreezeForDesktopReveal]) {
        [self freezeDesktopReveal];
    }
    [self refreshFullscreenVisibility];
    if (!self.itemsFrozenForDesktopReveal) {
        /* Debounce monitor churn so Show Desktop can freeze before chips drop. */
        [self rebuildItemsImmediate:NO];
    } else {
        [self restoreFrozenItemsOntoBars];
    }
}

- (void)frontAppDidChange:(NSNotification *)note {
    (void)note;
    if ([self shouldFreezeForDesktopReveal]) {
        [self freezeDesktopReveal];
    }
    [self refreshFullscreenVisibility];
    if (!self.itemsFrozenForDesktopReveal) {
        [self rebuildItemsImmediate:NO];
    } else {
        [self restoreFrozenItemsOntoBars];
    }
    [self updateVisibilitySafetyTimer];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (!self) {
                           return;
                       }
                       if ([self shouldFreezeForDesktopReveal]) {
                           [self freezeDesktopReveal];
                       }
                       [self refreshFullscreenVisibility];
                   });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
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
    if (!self.itemsFrozenForDesktopReveal) {
        [self rebuildItems];
    }
}

- (void)overlayWillShow {
    self.hiddenForOverlay = YES;
    [self.visibilitySafetyTimer invalidate];
    self.visibilitySafetyTimer = nil;
    for (MLTaskbarScreenBar *bar in self.bars) {
        bar.mode = MLTaskbarBarModeHidden;
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

+ (BOOL)isSystemWindowOwner:(NSString *)owner {
    if (owner.length == 0) {
        return NO;
    }
    static NSSet<NSString *> *owners;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        owners = [NSSet setWithArray:@[
            @"Window Server",
            @"Dock",
            @"SystemUIServer",
            @"Control Center",
            @"Notification Center",
            @"loginwindow",
            @"Wallpaper",
            @"Spotlight",
            @"Screenshot",
            @"CoreServicesUIAgent",
            @"UserNotificationCenter",
            @"Universal Control",
            @"AirPlayUIAgent",
            @"WiFiAgent",
            @"TextInputMenuAgent",
            @"ViewBridgeAuxiliary",
            @"Accessibility",
            @"AXVisualSupportAgent",
        ]];
    });
    return [owners containsObject:owner];
}

/**
 * Screens where immersive / OS fullscreen content should cover the taskbar.
 * - Frontmost app has an on-screen window covering the full display (incl. menu bar).
 * - Frontmost app reports AXFullScreen on a window we can map to a screen.
 *
 * Do NOT treat visibleFrame ≈ frame alone as fullscreen.
 * Do NOT treat Finder / Show Desktop chrome as immersive fullscreen.
 */
- (NSSet<NSNumber *> *)detectFullscreenScreenIDs {
    NSMutableSet<NSNumber *> *ids = [NSMutableSet set];
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    pid_t frontPid = front.processIdentifier;
    NSString *frontBundle = front.bundleIdentifier ?: @"";
    if ([frontBundle isEqualToString:@"com.apple.finder"] || frontPid == selfPid) {
        return ids;
    }

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
            /* Cover-based hide only for the frontmost app — avoids sticky false hides. */
            if (pid <= 0 || pid == selfPid || pid != frontPid) {
                continue;
            }

            CFStringRef ownerRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
            if (ownerRef && CFGetTypeID(ownerRef) == CFStringGetTypeID()) {
                NSString *owner = (__bridge NSString *)ownerRef;
                if ([[self class] isSystemWindowOwner:owner] ||
                    [owner isEqualToString:@"Finder"]) {
                    continue;
                }
            }

            CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
            int layer = 0;
            if (layerRef) {
                CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
            }
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
    if (AXIsProcessTrusted() && frontPid > 0 && frontPid != selfPid) {
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

    return ids;
}

/**
 * Show Desktop peek: chips are frozen (or lastStable > 0) and screen center is clear.
 * Exit when center cover returns (windows back).
 */
- (NSSet<NSNumber *> *)detectDesktopRevealScreenIDsExcludingFullscreen:(NSSet<NSNumber *> *)fullscreenIDs {
    NSMutableSet<NSNumber *> *ids = [NSMutableSet set];
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;

    NSMutableDictionary<NSNumber *, NSNumber *> *centerCoverByScreen = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *onScreenByScreen = [NSMutableDictionary dictionary];

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
                if ([[self class] isSystemWindowOwner:owner] ||
                    [owner isEqualToString:@"Finder"]) {
                    continue;
                }
            }
            CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
            int layer = 0;
            if (layerRef) {
                CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
            }
            if (layer < 0 || layer > 25) {
                continue;
            }
            CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
            if (alphaRef) {
                double alpha = 1.0;
                CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
                if (alpha < 0.35) {
                    continue;
                }
            }
            CGRect boundsQ = CGRectZero;
            CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
            if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &boundsQ)) {
                continue;
            }
            if (boundsQ.size.width < 60.0 || boundsQ.size.height < 40.0) {
                continue;
            }
            NSRect bounds = [MLScreenGeometry cocoaRectFromQuartzBounds:boundsQ];

            for (NSScreen *screen in NSScreen.screens) {
                NSNumber *sid = [[self class] screenIDForScreen:screen];
                if ([fullscreenIDs containsObject:sid]) {
                    continue;
                }
                NSRect sf = screen.frame;
                if (NSIsEmptyRect(NSIntersectionRect(bounds, sf))) {
                    continue;
                }
                onScreenByScreen[sid] = @([onScreenByScreen[sid] integerValue] + 1);

                NSRect center = NSInsetRect(sf, NSWidth(sf) * 0.18, NSHeight(sf) * 0.18);
                NSRect centerHit = NSIntersectionRect(bounds, center);
                if (!NSIsEmptyRect(centerHit)) {
                    CGFloat area = NSWidth(centerHit) * NSHeight(centerHit);
                    centerCoverByScreen[sid] = @([centerCoverByScreen[sid] doubleValue] + area);
                }
            }
        }
        CFRelease(list);
    }

    for (MLTaskbarScreenBar *bar in self.bars) {
        NSNumber *sid = bar.screenID;
        if (!sid || [fullscreenIDs containsObject:sid]) {
            continue;
        }
        NSScreen *screen = nil;
        for (NSScreen *s in NSScreen.screens) {
            if ([[[self class] screenIDForScreen:s] isEqualToNumber:sid]) {
                screen = s;
                break;
            }
        }
        if (!screen) {
            continue;
        }

        NSInteger chips = [self windowChipCountOnBar:bar];
        NSInteger stable = [self.lastStableWindowCountByScreen[sid] integerValue];
        NSInteger basis = MAX(chips, stable);
        if (self.itemsFrozenForDesktopReveal && self.frozenItemsByScreenID[sid].count > 0) {
            basis = MAX(basis, 1);
        }
        if (basis < 1) {
            continue;
        }

        NSRect sf = screen.frame;
        NSRect center = NSInsetRect(sf, NSWidth(sf) * 0.18, NSHeight(sf) * 0.18);
        CGFloat centerArea = NSWidth(center) * NSHeight(center);
        CGFloat centerCover = centerArea > 1.0
                                  ? [centerCoverByScreen[sid] doubleValue] / centerArea
                                  : 1.0;
        NSInteger onScreen = [onScreenByScreen[sid] integerValue];

        BOOL desktopShown = (centerCover < 0.12) || (onScreen == 0);
        /* Require freeze (or imminent freeze) so empty-desktop after closing windows is not peek. */
        if (desktopShown &&
            (self.itemsFrozenForDesktopReveal || [self shouldFreezeForDesktopReveal])) {
            [ids addObject:sid];
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

- (void)updateVisibilitySafetyTimer {
    if (!self.started || self.hiddenForOverlay || !self.enabled) {
        [self.visibilitySafetyTimer invalidate];
        self.visibilitySafetyTimer = nil;
        return;
    }

    BOOL anyNonNormal = self.itemsFrozenForDesktopReveal ||
                        self.desktopRevealScreenIDs.count > 0 ||
                        self.fullscreenScreenIDs.count > 0;
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (bar.mode != MLTaskbarBarModeNormal || !bar.window.isVisible) {
            anyNonNormal = YES;
            break;
        }
    }
    NSTimeInterval interval = anyNonNormal ? 0.2 : 0.45;
    if (self.visibilitySafetyTimer &&
        fabs(self.visibilitySafetyTimer.timeInterval - interval) < 0.01) {
        return;
    }
    [self.visibilitySafetyTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.visibilitySafetyTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                                 repeats:YES
                                                                   block:^(__unused NSTimer *timer) {
                                                                       [weakSelf refreshFullscreenVisibility];
                                                                   }];
    [[NSRunLoop mainRunLoop] addTimer:self.visibilitySafetyTimer forMode:NSRunLoopCommonModes];
}

- (void)refreshFullscreenVisibility {
    if (!self.started) {
        return;
    }

    /* Startup grace: never peek; clear any stuck offset and learn live census. */
    if (![self isDesktopRevealArmed]) {
        BOOL stuckPeek = self.itemsFrozenForDesktopReveal || self.desktopRevealScreenIDs.count > 0;
        if (!stuckPeek) {
            for (MLTaskbarScreenBar *b in self.bars) {
                if (b.mode == MLTaskbarBarModePeek || NSMinY(b.barView.frame) < -0.5) {
                    stuckPeek = YES;
                    break;
                }
            }
        }
        if (stuckPeek) {
            [self unfreezeDesktopRevealAndRefresh];
        }
        [self updateStableLiveCensus];

        NSSet<NSNumber *> *rawFS = [self detectFullscreenScreenIDs];
        NSMutableSet<NSNumber *> *committedFS = [NSMutableSet set];
        NSMutableDictionary<NSNumber *, NSNumber *> *nextStreaks = [NSMutableDictionary dictionary];
        NSSet<NSNumber *> *previousFS = self.fullscreenScreenIDs ?: [NSSet set];
        for (NSScreen *screen in NSScreen.screens) {
            NSNumber *sid = [[self class] screenIDForScreen:screen];
            if ([rawFS containsObject:sid]) {
                NSInteger streak = [self.fullscreenHideStreaks[sid] integerValue] + 1;
                nextStreaks[sid] = @(streak);
                if (streak >= (NSInteger)MLTaskbarHideConfirmCount || [previousFS containsObject:sid]) {
                    [committedFS addObject:sid];
                }
            }
        }
        self.fullscreenHideStreaks = nextStreaks;
        self.fullscreenScreenIDs = committedFS;
        self.desktopRevealScreenIDs = [NSSet set];
        [self applyBarVisibility];
        return;
    }

    [self updateStableLiveCensus];

    if ([self shouldFreezeForDesktopReveal]) {
        [self freezeDesktopReveal];
    }

    if (self.itemsFrozenForDesktopReveal) {
        [self restoreFrozenItemsOntoBars];
        if ([self shouldUnfreezeDesktopReveal]) {
            [self unfreezeDesktopRevealAndRefresh];
            [self updateVisibilitySafetyTimer];
            return;
        }
        NSMutableSet<NSNumber *> *all = [NSMutableSet set];
        for (MLTaskbarScreenBar *bar in self.bars) {
            if (bar.screenID) {
                [all addObject:bar.screenID];
            }
        }
        self.desktopRevealScreenIDs = all;
        self.fullscreenScreenIDs = [NSSet set];
        [self applyBarVisibility];
        return;
    }

    NSSet<NSNumber *> *rawFS = [self detectFullscreenScreenIDs];

    NSMutableSet<NSNumber *> *committedFS = [NSMutableSet set];
    NSMutableDictionary<NSNumber *, NSNumber *> *nextStreaks = [NSMutableDictionary dictionary];
    NSSet<NSNumber *> *previousFS = self.fullscreenScreenIDs ?: [NSSet set];

    for (NSScreen *screen in NSScreen.screens) {
        NSNumber *sid = [[self class] screenIDForScreen:screen];
        if ([rawFS containsObject:sid]) {
            NSInteger streak = [self.fullscreenHideStreaks[sid] integerValue] + 1;
            nextStreaks[sid] = @(streak);
            if (streak >= (NSInteger)MLTaskbarHideConfirmCount || [previousFS containsObject:sid]) {
                [committedFS addObject:sid];
            }
        }
    }
    self.fullscreenHideStreaks = nextStreaks;
    self.fullscreenScreenIDs = committedFS;
    self.desktopRevealScreenIDs = [NSSet set];

    [self applyBarVisibility];
}

- (void)applyBarVisibility {
    if (self.hiddenForOverlay) {
        for (MLTaskbarScreenBar *bar in self.bars) {
            bar.mode = MLTaskbarBarModeHidden;
            [bar.window orderOut:nil];
        }
        [self updateVisibilitySafetyTimer];
        return;
    }
    if (!self.started || !self.enabled) {
        return;
    }

    NSDictionary<NSNumber *, NSScreen *> *screensByID = [self screensByID];
    NSSet<NSNumber *> *fs = self.fullscreenScreenIDs ?: [NSSet set];
    NSSet<NSNumber *> *reveal = self.desktopRevealScreenIDs ?: [NSSet set];

    for (MLTaskbarScreenBar *bar in self.bars) {
        NSScreen *screen = screensByID[bar.screenID];
        if (!screen || !bar.window) {
            continue;
        }

        MLTaskbarBarMode previous = bar.mode;

        /* Peek screens must never be treated as fullscreen-hidden in the same pass. */
        if ([reveal containsObject:bar.screenID] || self.itemsFrozenForDesktopReveal) {
            bar.mode = MLTaskbarBarModePeek;
            BOOL animate = (previous != MLTaskbarBarModePeek);
            [self applyPeekPresentationForBar:bar peeking:YES animated:animate];
            [bar.window orderFrontRegardless];
            continue;
        }

        if ([fs containsObject:bar.screenID]) {
            bar.mode = MLTaskbarBarModeHidden;
            [self applyPeekPresentationForBar:bar peeking:NO animated:NO];
            [bar.window orderOut:nil];
            continue;
        }

        bar.mode = MLTaskbarBarModeNormal;
        [self applyPeekPresentationForBar:bar peeking:NO animated:(previous == MLTaskbarBarModePeek)];
        [bar.window orderFrontRegardless];
    }

    [self updateVisibilitySafetyTimer];
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
    if (!self.itemsFrozenForDesktopReveal) {
        [self rebuildItemsImmediate:YES];
    }
}

- (void)softStateDidChange:(NSNotification *)note {
    (void)note;
    [self.monitor pollNow];
    if (!self.itemsFrozenForDesktopReveal) {
        [self rebuildItemsImmediate:YES];
    }
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
    [self rebuildItemsImmediate:YES];
}

- (void)updateSoftHideMethod:(MLWindowHideMethod)method forWindowID:(CGWindowID)windowID {
    [self.monitor.softState updateHideMethod:method forWindowID:windowID];
}

- (void)markSoftMinimizedWindowID:(CGWindowID)windowID {
    [self.monitor markSoftMinimizedWindowID:windowID];
    [self rebuildItemsImmediate:YES];
}

typedef AXError (*MLAXGetWindowFn)(AXUIElementRef, CGWindowID *);

static MLAXGetWindowFn MLResolvedAXGetWindow(void) {
    static MLAXGetWindowFn sFn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sFn = (MLAXGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    });
    return sFn;
}

/**
 * Hide without 1×1 tuck (Finder clamps tiny sizes and won't grow back).
 * Finder: always AXMinimized. Others: CGS alpha=0 if verified, else AXMinimized.
 */
- (MLWindowHideMethod)applySoftHideToWindow:(AXUIElementRef)win
                                   windowID:(CGWindowID)windowID
                                        pid:(pid_t)pid {
    BOOL isFinder = NO;
    if (pid > 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        isFinder = [app.bundleIdentifier isEqualToString:@"com.apple.finder"];
    }

    if (!isFinder && windowID != kCGNullWindowID && windowID != 0 && MLCGSWindowAlphaAvailable()) {
        if (MLCGSSetWindowAlpha(windowID, 0.0f)) {
            MLDebugLog(@"[Taskbar] soft hide wid=%u via alpha", (unsigned)windowID);
            return MLWindowHideMethodAlpha;
        }
    }
    if (!win) {
        return MLWindowHideMethodNone;
    }
    AXError err = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanTrue);
    if (err != kAXErrorSuccess) {
        NSLog(@"[Taskbar] soft hide wid=%u AXMinimized failed err=%d", (unsigned)windowID, (int)err);
        return MLWindowHideMethodNone;
    }
#if ML_ENABLE_DEBUG_LOG
    Boolean isMin = false;
    CFTypeRef minRef = NULL;
    if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
        if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
            isMin = CFBooleanGetValue((CFBooleanRef)minRef);
        }
        CFRelease(minRef);
    }
    MLDebugLog(@"[Taskbar] soft hide wid=%u via AXMinimized confirmed=%d finder=%d",
          (unsigned)windowID, (int)isMin, (int)isFinder);
#endif
    return MLWindowHideMethodAXMinimized;
}

- (BOOL)softMinimizeWindowWithAX:(AXUIElementRef)win
                        windowID:(CGWindowID)windowID
                             pid:(pid_t)pid
                           title:(NSString *)title
                    restoreFrame:(NSRect)restoreFrame {
    NSRect frame = restoreFrame;
    if ((frame.size.width < 2.0 || frame.size.height < 2.0) && win) {
        if (![MLScreenGeometry readCocoaFrame:&frame fromAXWindow:win]) {
            frame = NSZeroRect;
        }
    }
    if (frame.size.width < 2.0 || frame.size.height < 2.0) {
        NSLog(@"[Taskbar] soft minimize aborted — no restore frame wid=%u", (unsigned)windowID);
        return NO;
    }

    CGWindowID wid = windowID;
    if (wid == kCGNullWindowID) {
        wid = 0;
    }
    CGWindowID remembered =
        [self rememberWindowForCustomMinimizePID:pid
                                           title:title ?: @""
                                          bounds:NSRectToCGRect(frame)
                                        windowID:wid];
    if (wid == 0) {
        wid = remembered;
    }

    NSScreen *screen = [MLScreenGeometry screenForCocoaRect:frame];
    NSNumber *screenID = [MLScreenGeometry screenIDForScreen:screen];

    /* Mark soft BEFORE hide so poll never drops the chip. */
    if (wid != 0) {
        [self markSoftHiddenWindowID:wid
                                 pid:pid
                               title:title ?: @""
                       restoreFrame:frame
                           screenID:screenID
                           axWindow:win];
    }

    MLWindowHideMethod method = [self applySoftHideToWindow:win windowID:wid pid:pid];
    if (wid != 0 && method != MLWindowHideMethodNone) {
        [self updateSoftHideMethod:method forWindowID:wid];
    }
    [self refreshAfterCustomMinimize];
    return method != MLWindowHideMethodNone;
}

/** Retained AX window matching item.windowID, or NULL. Caller must CFRelease. */
- (AXUIElementRef)copyAXWindowForItem:(MLTaskbarItem *)item {
    if (!item || item.pid <= 0 || item.windowID == 0 || !AXIsProcessTrusted()) {
        return NULL;
    }
    AXUIElementRef appRef = AXUIElementCreateApplication(item.pid);
    if (!appRef) {
        return NULL;
    }
    CFTypeRef windowsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
    CFRelease(appRef);
    if (err != kAXErrorSuccess || !windowsRef || CFGetTypeID(windowsRef) != CFArrayGetTypeID()) {
        if (windowsRef) {
            CFRelease(windowsRef);
        }
        return NULL;
    }
    MLAXGetWindowFn getWid = MLResolvedAXGetWindow();
    AXUIElementRef found = NULL;
    CFArrayRef windows = (CFArrayRef)windowsRef;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        CGWindowID axWid = 0;
        if (getWid && getWid(win, &axWid) == kAXErrorSuccess && axWid == item.windowID) {
            found = (AXUIElementRef)CFRetain(win);
            break;
        }
    }
    CFRelease(windowsRef);
    return found;
}

- (BOOL)isItemSoftHiddenOrMinimized:(MLTaskbarItem *)item {
    if (!item) {
        return NO;
    }
    if (item.minimized) {
        return YES;
    }
    if (item.windowID != 0 && [self.monitor isSoftMinimizedWindowID:item.windowID]) {
        return YES;
    }
    return NO;
}

- (BOOL)isItemFrontmostWindow:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0 || item.pid <= 0) {
        return NO;
    }
    if ([self isItemSoftHiddenOrMinimized:item]) {
        return NO;
    }
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    if (item.pid == selfPid) {
        return NO;
    }
    /*
     * Do NOT require NSWorkspace.frontmostApplication == item.pid.
     * Clicking the taskbar often activates MeoLaunch first, which made the old
     * check fail and turned "minimize" into a no-op activate (felt like double-click).
     * Compare against the topmost on-screen user window, excluding ourselves.
     */
    return [self topmostUserWindowIDExcludingSelf] == item.windowID;
}

- (BOOL)softMinimizeItem:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0) {
        return NO;
    }
    if (!AXIsProcessTrusted()) {
        NSLog(@"[Taskbar] soft minimize item needs Accessibility");
        return NO;
    }

    AXUIElementRef win = [self copyAXWindowForItem:item];
    NSRect frame = NSZeroRect;
    if (win) {
        [MLScreenGeometry readCocoaFrame:&frame fromAXWindow:win];
    }
    if (frame.size.width < 2.0 || frame.size.height < 2.0) {
        /* Fallback: CG on-screen bounds for this windowID. */
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
                                                     item.windowID);
        if (list && CFArrayGetCount(list) > 0) {
            CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, 0);
            CFDictionaryRef boundsDict = info ? CFDictionaryGetValue(info, kCGWindowBounds) : NULL;
            CGRect q = CGRectZero;
            if (boundsDict && CGRectMakeWithDictionaryRepresentation(boundsDict, &q)) {
                frame = [MLScreenGeometry cocoaRectFromQuartzBounds:q];
            }
        }
        if (list) {
            CFRelease(list);
        }
    }

    BOOL ok = [self softMinimizeWindowWithAX:win
                                    windowID:item.windowID
                                         pid:item.pid
                                       title:item.title ?: @""
                                restoreFrame:frame];
    if (win) {
        CFRelease(win);
    }
    if (!ok) {
        NSLog(@"[Taskbar] soft minimize item failed wid=%u", (unsigned)item.windowID);
    }
    return ok;
}

#pragma mark - MLTaskbarViewDelegate

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
        MLDebugLog(@"[Taskbar] soft restore verified wid=%u frame=(%.0f,%.0f %.0fx%.0f)",
              (unsigned)wid, got.origin.x, got.origin.y, got.size.width, got.size.height);
    } else if (!matched) {
        MLDebugLog(@"[Taskbar] soft restore mismatch wid=%u got=(%.0f,%.0f %.0fx%.0f) want=(%.0f,%.0f %.0fx%.0f)",
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
                MLDebugLog(@"[Taskbar] soft restore ok wid=%u", (unsigned)wid);
            } else if (needsGeometry) {
                MLDebugLog(@"[Taskbar] soft restore pending wid=%u (chip kept, retries scheduled)",
                      (unsigned)wid);
            }
        }
    } else {
        AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
        MLDebugLog(@"[Taskbar] soft restore fail — no AX target wid=%u", (unsigned)wid);
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
        BOOL softRestore = [self isItemSoftHiddenOrMinimized:item];
        if (softRestore) {
            /* Minimized / soft-hidden → restore geometry + activate. */
            [self activateApplicationForItem:item];
            [self raiseAndFocusWindowForItem:item];
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               [weakSelf raiseAndFocusWindowForItem:item];
                               [weakSelf activateApplicationForItem:item];
                           });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               [weakSelf raiseAndFocusWindowForItem:item];
                           });
            return;
        }

        if ([self isItemFrontmostWindow:item]) {
            /* Already frontmost → soft-minimize (same as yellow button). */
            [self softMinimizeItem:item];
            return;
        }

        /* Visible but not front → raise + activate. */
        [self raiseAndFocusWindowForItem:item];
        [self activateApplicationForItem:item];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf raiseAndFocusWindowForItem:item];
                           [weakSelf activateApplicationForItem:item];
                       });
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

- (BOOL)readFullscreenForAXWindow:(AXUIElementRef)win {
    if (!win) {
        return NO;
    }
    CFTypeRef fsRef = NULL;
    if (AXUIElementCopyAttributeValue(win, CFSTR("AXFullScreen"), &fsRef) != kAXErrorSuccess || !fsRef) {
        return NO;
    }
    BOOL on = NO;
    if (CFGetTypeID(fsRef) == CFBooleanGetTypeID()) {
        on = CFBooleanGetValue((CFBooleanRef)fsRef);
    }
    CFRelease(fsRef);
    return on;
}

- (BOOL)canReadFullscreenForAXWindow:(AXUIElementRef)win {
    if (!win) {
        return NO;
    }
    CFTypeRef fsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(win, CFSTR("AXFullScreen"), &fsRef);
    if (fsRef) {
        CFRelease(fsRef);
    }
    return err == kAXErrorSuccess;
}

- (void)taskbarView:(MLTaskbarView *)view
         menuFlags:(MLTaskbarMenuFlags *)flags
          forIndex:(NSInteger)index {
    (void)view;
    if (!flags) {
        return;
    }
    flags.hasWindow = NO;
    flags.minimized = NO;
    flags.fullscreen = NO;
    flags.fullscreenSupported = NO;
    flags.pinned = NO;
    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    MLTaskbarItem *item = view.items[(NSUInteger)index];
    flags.pinned = item.pinned;
    flags.hasWindow = (item.kind == MLTaskbarItemRunningWindow && item.windowID != 0);
    flags.minimized = [self isItemSoftHiddenOrMinimized:item];
    if (!flags.hasWindow || !AXIsProcessTrusted()) {
        return;
    }
    AXUIElementRef win = [self copyAXWindowForItem:item];
    if (!win) {
        /* Soft-hidden may still have retained AX. */
        MLWindowSoftRecord *soft =
            item.windowID != 0 ? [self.monitor.softState recordForWindowID:item.windowID] : nil;
        if (soft.axWindow) {
            win = (AXUIElementRef)CFRetain(soft.axWindow);
        }
    }
    if (win) {
        flags.fullscreenSupported = [self canReadFullscreenForAXWindow:win];
        flags.fullscreen = flags.fullscreenSupported ? [self readFullscreenForAXWindow:win] : NO;
        CFRelease(win);
    }
}

- (void)closeWindowForItem:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0 || !AXIsProcessTrusted()) {
        return;
    }
    BOOL wasSoft = [self isItemSoftHiddenOrMinimized:item];
    if (wasSoft) {
        [self raiseAndFocusWindowForItem:item];
    }

    AXUIElementRef win = [self copyAXWindowForItem:item];
    if (!win) {
        MLWindowSoftRecord *soft = [self.monitor.softState recordForWindowID:item.windowID];
        if (soft.axWindow) {
            win = (AXUIElementRef)CFRetain(soft.axWindow);
        }
    }
    if (!win) {
        NSLog(@"[Taskbar] close failed — no AX window wid=%u", (unsigned)item.windowID);
        return;
    }

    /* Prefer close button press (widely supported). */
    BOOL closed = NO;
    CFTypeRef btnRef = NULL;
    if (AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute, &btnRef) == kAXErrorSuccess &&
        btnRef) {
        if (CFGetTypeID(btnRef) == AXUIElementGetTypeID()) {
            AXError err = AXUIElementPerformAction((AXUIElementRef)btnRef, kAXPressAction);
            closed = (err == kAXErrorSuccess);
        }
        CFRelease(btnRef);
    }
    if (!closed) {
        /* Fallback: some apps expose AXClose on the window. */
        AXUIElementPerformAction(win, CFSTR("AXPress"));
    }
    CFRelease(win);

    if (item.windowID != 0) {
        [self.monitor.softState removeClosedWindowID:item.windowID];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf.monitor pollNow];
                       [weakSelf rebuildItemsImmediate:YES];
                   });
}

- (void)toggleMinimizeForItem:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0) {
        return;
    }
    if ([self isItemSoftHiddenOrMinimized:item]) {
        [self activateApplicationForItem:item];
        [self raiseAndFocusWindowForItem:item];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf raiseAndFocusWindowForItem:item];
                           [weakSelf activateApplicationForItem:item];
                       });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf raiseAndFocusWindowForItem:item];
                       });
    } else {
        [self softMinimizeItem:item];
    }
}

- (void)toggleFullscreenForItem:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0 || !AXIsProcessTrusted()) {
        return;
    }
    if ([self isItemSoftHiddenOrMinimized:item]) {
        [self raiseAndFocusWindowForItem:item];
    }
    AXUIElementRef win = [self copyAXWindowForItem:item];
    if (!win) {
        return;
    }
    if (![self canReadFullscreenForAXWindow:win]) {
        CFRelease(win);
        return;
    }
    BOOL on = [self readFullscreenForAXWindow:win];
    AXUIElementSetAttributeValue(win, CFSTR("AXFullScreen"), on ? kCFBooleanFalse : kCFBooleanTrue);
    CFRelease(win);
    [self activateApplicationForItem:item];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf refreshFullscreenVisibility];
                   });
}

- (void)taskbarView:(MLTaskbarView *)view
    didSelectAction:(MLTaskbarMenuAction)action
            atIndex:(NSInteger)index {
    (void)view;
    switch (action) {
        case MLTaskbarMenuActionAbout:
            [self.appActions taskbarShowAbout];
            return;
        case MLTaskbarMenuActionPreferences:
            [self.appActions taskbarShowPreferences];
            return;
        case MLTaskbarMenuActionQuit:
            [self.appActions taskbarQuitApp];
            return;
        default:
            break;
    }

    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    MLTaskbarItem *item = view.items[(NSUInteger)index];
    switch (action) {
        case MLTaskbarMenuActionClose:
            [self closeWindowForItem:item];
            break;
        case MLTaskbarMenuActionMinimizeToggle:
            [self toggleMinimizeForItem:item];
            break;
        case MLTaskbarMenuActionFullscreenToggle:
            [self toggleFullscreenForItem:item];
            break;
        case MLTaskbarMenuActionPinToggle:
            if (item.path.length == 0) {
                break;
            }
            if (item.pinned) {
                [self.pinStore unpinPath:item.path];
            } else {
                [self.pinStore pinPath:item.path];
            }
            break;
        default:
            break;
    }
}

@end
