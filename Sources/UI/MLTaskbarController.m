#import "MLTaskbarController.h"

#import "MLRunningAppsMonitor.h"
#import "MLTaskbarIconCache.h"
#import "MLTaskbarPinStore.h"
#import "MLTaskbarView.h"

#import <ApplicationServices/ApplicationServices.h>

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
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL hiddenForOverlay;
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
    for (NSNumber *pidNum in snap.pidToPath) {
        if ([snap.pidToPath[pidNum] isEqualToString:path]) {
            return (pid_t)pidNum.intValue;
        }
    }
    return 0;
}

- (MLTaskbarItem *)itemWithPath:(NSString *)path
                            pid:(pid_t)pid
                       windowID:(CGWindowID)windowID
                          title:(NSString *)title
                           kind:(MLTaskbarItemKind)kind
                         pinned:(BOOL)pinned
                      minimized:(BOOL)minimized
                      seenOrder:(NSUInteger)seenOrder {
    MLTaskbarItem *item = [[MLTaskbarItem alloc] init];
    item.path = path;
    item.pid = pid;
    item.windowID = windowID;
    item.title = title;
    item.kind = kind;
    item.pinned = pinned;
    item.minimized = minimized;
    item.seenOrder = seenOrder;
    return item;
}

/** Prefer the screen with the largest intersection; ties break to containing center. */
- (NSScreen *)screenForWindowBounds:(CGRect)bounds {
    NSScreen *best = nil;
    CGFloat bestArea = -1.0;
    CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    for (NSScreen *screen in NSScreen.screens) {
        CGRect inter = CGRectIntersection(bounds, screen.frame);
        if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) {
            continue;
        }
        CGFloat area = inter.size.width * inter.size.height;
        if (area > bestArea ||
            (fabs(area - bestArea) < 1.0 &&
             NSPointInRect(NSMakePoint(center.x, center.y), screen.frame))) {
            bestArea = area;
            best = screen;
        }
    }
    return best;
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
            /* Minimized bounds can be empty; fall back to main display. */
            owner = NSScreen.mainScreen;
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

    MLRunningAppsSnapshot *snap = self.monitor.snapshot;
    NSArray<NSString *> *pins = self.pinStore.pinnedPaths;
    NSSet<NSString *> *pinSet = [NSSet setWithArray:pins];
    NSSet<NSString *> *runningSet = [NSSet setWithArray:snap.runningAppPaths ?: @[]];

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
            } else if (existing.seenOrder == 0 && w.seenOrder > 0) {
                existing.seenOrder = w.seenOrder;
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
    for (MLTaskbarWindowInfo *w in uniqueWindows) {
        NSString *display = [self displayNameForPath:w.path];
        NSString *title = w.title.length > 0 ? w.title : display;
        BOOL pinned = [pinSet containsObject:w.path];
        [windowItems addObject:[self itemWithPath:w.path
                                              pid:w.pid
                                         windowID:w.windowID
                                            title:title
                                             kind:MLTaskbarItemRunningWindow
                                           pinned:pinned
                                        minimized:w.minimized
                                        seenOrder:w.seenOrder]];
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

    /* Pinned launchers (not running) stay at the leading edge in pin order. */
    NSMutableSet<NSString *> *pathsWithWindows = [NSMutableSet set];
    for (MLTaskbarWindowInfo *w in uniqueWindows) {
        if (w.path.length > 0) {
            [pathsWithWindows addObject:w.path];
        }
    }
    for (NSString *path in pins) {
        if ([pathsWithWindows containsObject:path] || [runningSet containsObject:path]) {
            continue;
        }
        [items addObject:[self itemWithPath:path
                                        pid:0
                                   windowID:0
                                      title:[self displayNameForPath:path]
                                       kind:MLTaskbarItemPinnedOnly
                                     pinned:YES
                                  minimized:NO
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
    CGFloat avail = width - 16.0;
    while (items.count > 0) {
        NSUInteger n = items.count;
        CGFloat need = n * minW + (n > 1 ? (n - 1) * spacing : 0);
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
    CGFloat height = 40.0;
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
            CGFloat height = bar.barView.barHeight > 0 ? bar.barView.barHeight : 40.0;
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
        if (!self.hiddenForOverlay) {
            [bar.window orderFrontRegardless];
        }
    }

    [self rebuildItems];
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

    [self.monitor start];
    [self syncBarsToScreens];
}

- (void)stop {
    if (!self.started) {
        return;
    }
    self.started = NO;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
}

- (void)screenParamsChanged:(NSNotification *)note {
    (void)note;
    [self syncBarsToScreens];
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
        for (MLTaskbarScreenBar *bar in self.bars) {
            [bar.window orderFrontRegardless];
        }
    }
}

#pragma mark - MLTaskbarViewDelegate

/** Title hint may be truncated with an ellipsis from the monitor. */
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

- (void)unminimizeWindowForItem:(MLTaskbarItem *)item {
    if (item.pid <= 0) {
        return;
    }
    if (!AXIsProcessTrusted()) {
        return;
    }

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
        CFRelease(appRef);
        return;
    }

    CFArrayRef windows = (CFArrayRef)windowsRef;
    CFIndex count = CFArrayGetCount(windows);
    AXUIElementRef matched = NULL;
    AXUIElementRef firstMinimized = NULL;

    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        CFTypeRef minRef = NULL;
        Boolean isMin = false;
        if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
            if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                isMin = CFBooleanGetValue((CFBooleanRef)minRef);
            }
            CFRelease(minRef);
        }
        if (!isMin) {
            continue;
        }
        if (!firstMinimized) {
            firstMinimized = win;
        }

        CFTypeRef titleRef = NULL;
        NSString *title = nil;
        if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &titleRef) == kAXErrorSuccess && titleRef) {
            if (CFGetTypeID(titleRef) == CFStringGetTypeID()) {
                title = (__bridge NSString *)titleRef;
            }
            CFRelease(titleRef);
        }
        if ([self title:title ?: @"" matchesHint:item.title]) {
            matched = win;
            break;
        }
    }

    AXUIElementRef target = matched ?: firstMinimized;
    if (target) {
        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute, kCFBooleanFalse);
        AXUIElementPerformAction(target, kAXRaiseAction);
    }

    CFRelease(windowsRef);
    CFRelease(appRef);
}

- (void)activateOrLaunchItem:(MLTaskbarItem *)item {
    if (item.minimized) {
        [self unminimizeWindowForItem:item];
    }
    if (item.pid > 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:item.pid];
        if (app && !app.isTerminated) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
            if (item.minimized) {
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                                   [weakSelf unminimizeWindowForItem:item];
                               });
            }
            return;
        }
    }
    if (item.path.length == 0) {
        return;
    }
    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        if ([app.bundleURL.path isEqualToString:item.path]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
#pragma clang diagnostic pop
            if (item.minimized) {
                item.pid = app.processIdentifier;
                [self unminimizeWindowForItem:item];
            }
            return;
        }
    }
    NSURL *url = [NSURL fileURLWithPath:item.path];
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
