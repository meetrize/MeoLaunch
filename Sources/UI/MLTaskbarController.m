#import "MLTaskbarController+Private.h"

#import "MLAppLauncher.h"
#import "MLAXWindowHelper.h"
#import "MLCGSAlpha.h"
#import "MLDebugLog.h"
#import "MLMinimizeInterceptor.h"
#import "MLRunningAppsMonitor.h"
#import "MLScreenGeometry.h"
#import "MLTaskbarPinStore.h"
#import "MLTaskbarView.h"
#import "MLWindowSoftState.h"
#import "MLWorkAreaEnforcer.h"

#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>

@implementation MLTaskbarController

- (instancetype)initWithPinStore:(MLTaskbarPinStore *)pins
                         monitor:(MLRunningAppsMonitor *)monitor
                       iconCache:(MLIconCache *)icons {
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
        _chipScreenAffinityByWid = [NSMutableDictionary dictionary];
        _fullscreenScreenIDs = [NSSet set];
        _desktopRevealScreenIDs = [NSSet set];
        _itemsFrozenForDesktopReveal = NO;
        _lastStableLiveWindowCount = 0;
        _freezeLiveBaseline = 0;
        _desktopRevealArmTime = 0;
        _desktopPeekUserArmed = NO;
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
        [bar.window orderFrontRegardless];
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
                                             selector:@selector(frontWindowDidChange:)
                                                 name:MLRunningAppsFrontWindowDidChangeNotification
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
    self.desktopPeekUserArmed = NO;
    [self.frozenItemsByScreenID removeAllObjects];
    [self.chipScreenAffinityByWid removeAllObjects];

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
    self.desktopPeekUserArmed = NO;
    self.lastStableLiveWindowCount = 0;
    self.freezeLiveBaseline = 0;
    self.desktopRevealArmTime = 0;
    [self.frozenItemsByScreenID removeAllObjects];
    [self.chipScreenAffinityByWid removeAllObjects];
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
    [self applyActiveHighlightImmediate];
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

- (void)frontWindowDidChange:(NSNotification *)note {
    NSNumber *widNum = note.userInfo[MLRunningAppsFrontWindowIDKey];
    CGWindowID wid = widNum.unsignedIntValue;
    [self applyActiveHighlightForWindowID:wid];
}

- (void)frontAppDidChange:(NSNotification *)note {
    (void)note;
    [self applyActiveHighlightImmediate];
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
    /* CG window order can lag NSWorkspace by a frame — re-paint highlight once settled. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf applyActiveHighlightImmediate];
                   });
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
                       [self applyActiveHighlightImmediate];
                   });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf refreshFullscreenVisibility];
                   });
}

- (void)activeSpaceDidChange:(NSNotification *)note {
    (void)note;
    [self applyActiveHighlightImmediate];
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
    /* Overlay uses NSStatusWindowLevel; taskbars stay at NSFloatingWindowLevel and
       remain visible underneath — the scrim covers them on the overlay screen. */
}

- (void)overlayDidHide {
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
    if (!self.started || !self.enabled) {
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
    if (!self.started || !self.enabled) {
        return;
    }

    /*
     * Hard stop: passive minimize-all / all-closed must never keep peek presentation.
     * Never cancel user-armed desktop peek here — that path owns the Y offset.
     */
    BOOL anyPeek = self.itemsFrozenForDesktopReveal || self.desktopRevealScreenIDs.count > 0;
    if (!anyPeek) {
        for (MLTaskbarScreenBar *bar in self.bars) {
            if (bar.mode == MLTaskbarBarModePeek) {
                anyPeek = YES;
                break;
            }
        }
    }
    if (anyPeek &&
        !self.desktopPeekUserArmed &&
        [self shouldIgnoreDesktopRevealBecauseAllMinimized]) {
        [self unfreezeDesktopRevealAndRefresh];
        [self updateVisibilitySafetyTimer];
        return;
    }

    /* User-armed OR auto Show Desktop peek: keep forcing the half-down frame. */
    if (self.itemsFrozenForDesktopReveal) {
        [self applyUserArmedPeekPresentationAnimated:NO];
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

/**
 * YES when the click is on exposed desktop / Finder wallpaper (not an app window,
 * not our taskbar). Soft-hidden alpha=0 windows are ignored.
 */
- (BOOL)cocoaPointHitsOwnTaskbar:(NSPoint)cocoaPoint {
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.window || !bar.window.isVisible) {
            continue;
        }
        if (NSPointInRect(cocoaPoint, bar.window.frame)) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)cocoaPointIsExposedDesktop:(NSPoint)cocoaPoint {
    /* Taskbar sits above the desktop — never treat chip clicks as desktop peek. */
    if ([self cocoaPointHitsOwnTaskbar:cocoaPoint]) {
        return NO;
    }

    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    NSRect main = NSScreen.mainScreen.frame;
    CGPoint q = CGPointMake(cocoaPoint.x, NSMaxY(main) - cocoaPoint.y);
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                     kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    if (!list) {
        return YES;
    }

    BOOL hitApp = NO;
    BOOL hitFinderDesktop = NO;
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
        if (pid <= 0) {
            continue;
        }
        /*
         * Frontmost hit is our own window (taskbar / prefs) → not desktop.
         * Do not "look through" self to Finder wallpaper behind the bar.
         */
        if (pid == selfPid) {
            CGRect boundsQ = CGRectZero;
            CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
            if (boundsDict && CGRectMakeWithDictionaryRepresentation(boundsDict, &boundsQ) &&
                CGRectContainsPoint(boundsQ, q)) {
                CFRelease(list);
                return NO;
            }
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
        CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (alphaRef) {
            double alpha = 1.0;
            CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
            if (alpha < 0.2) {
                continue;
            }
        }
        CGRect boundsQ = CGRectZero;
        CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &boundsQ)) {
            continue;
        }
        if (!CGRectContainsPoint(boundsQ, q)) {
            continue;
        }
        if (boundsQ.size.width < 60.0 || boundsQ.size.height < 40.0) {
            continue;
        }

        CFStringRef ownerRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
        NSString *owner = nil;
        if (ownerRef && CFGetTypeID(ownerRef) == CFStringGetTypeID()) {
            owner = (__bridge NSString *)ownerRef;
        }
        if ([[self class] isSystemWindowOwner:owner]) {
            continue;
        }
        if ([owner isEqualToString:@"Finder"]) {
            /* Near-full-screen Finder surface ≈ desktop wallpaper, not a folder window. */
            NSRect cocoaBounds = [MLScreenGeometry cocoaRectFromQuartzBounds:boundsQ];
            NSScreen *screen = [MLScreenGeometry screenForCocoaRect:cocoaBounds];
            NSRect sf = screen ? screen.frame : NSScreen.mainScreen.frame;
            CGFloat cover = 0;
            if (NSWidth(sf) > 1.0 && NSHeight(sf) > 1.0) {
                NSRect hit = NSIntersectionRect(cocoaBounds, sf);
                cover = (NSWidth(hit) * NSHeight(hit)) / (NSWidth(sf) * NSHeight(sf));
            }
            if (cover >= 0.80) {
                hitFinderDesktop = YES;
                break; /* frontmost meaningful hit */
            }
            hitApp = YES;
            break;
        }
        hitApp = YES;
        break;
    }
    CFRelease(list);
    return hitFinderDesktop || !hitApp;
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
    if (self.itemsFrozenForDesktopReveal) {
        if ([self shouldUnfreezeDesktopReveal]) {
            [self unfreezeDesktopRevealAndRefresh];
        } else {
            [self restoreFrozenItemsOntoBars];
        }
        return;
    }
    [self rebuildItemsImmediate:YES];
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
    AXUIElementRef found = NULL;
    CFArrayRef windows = (CFArrayRef)windowsRef;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        CGWindowID axWid = [MLAXWindowHelper windowIDForAXWindow:win];
        if (axWid == item.windowID) {
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

        CGWindowID axWid = [MLAXWindowHelper windowIDForAXWindow:win];
        if (wid != 0 && axWid == wid) {
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
    [MLAppLauncher openApplicationAtPath:path];
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
