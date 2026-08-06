#import "MLTaskbarController+Private.h"

#import "MLDebugLog.h"
#import "MLMinimizeInterceptor.h"
#import "MLRunningAppsMonitor.h"
#import "MLScreenGeometry.h"
#import "MLTaskbarConstants.h"
#import "MLTaskbarPinStore.h"
#import "MLTaskbarView.h"
#import "MLWorkAreaEnforcer.h"

#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>

@implementation MLTaskbarController (Bars)

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

@end
