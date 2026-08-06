#import "MLWorkAreaEnforcer.h"

#import "MLAXWindowHelper.h"
#import "MLRunningAppsMonitor.h"
#import "MLScreenGeometry.h"
#import "MLWindowSoftState.h"

#import <ApplicationServices/ApplicationServices.h>

enum {
    MLWorkAreaEdgeTol = 12,
    MLWorkAreaMinSize = 80,
};

@interface MLWorkAreaEnforcer ()
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL enforcePending;
@property (nonatomic, assign) BOOL applying;
@property (nonatomic, assign) NSUInteger enforceGeneration;
@end

@implementation MLWorkAreaEnforcer

/** Work rect = visibleFrame minus taskbar strip at the bottom. */
static NSRect MLWorkRectForScreen(NSScreen *screen, CGFloat barHeight) {
    NSRect visible = screen.visibleFrame;
    CGFloat h = MAX(0.0, barHeight);
    if (h < 1.0 || visible.size.height <= h + MLWorkAreaMinSize) {
        return visible;
    }
    NSRect work = visible;
    work.origin.y += h;
    work.size.height -= h;
    return work;
}

static BOOL MLFrameFillsVisible(NSRect frame, NSRect visible) {
    const CGFloat tol = (CGFloat)MLWorkAreaEdgeTol;
    if (frame.size.width < MLWorkAreaMinSize || frame.size.height < MLWorkAreaMinSize) {
        return NO;
    }
    return [MLScreenGeometry nearlyEqual:NSMinX(frame) b:NSMinX(visible) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMaxX(frame) b:NSMaxX(visible) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMaxY(frame) b:NSMaxY(visible) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMinY(frame) b:NSMinY(visible) tolerance:tol];
}

static BOOL MLFrameMatchesWork(NSRect frame, NSRect work) {
    const CGFloat tol = (CGFloat)MLWorkAreaEdgeTol;
    return [MLScreenGeometry nearlyEqual:NSMinX(frame) b:NSMinX(work) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMaxX(frame) b:NSMaxX(work) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMaxY(frame) b:NSMaxY(work) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMinY(frame) b:NSMinY(work) tolerance:tol];
}

static BOOL MLFrameFillsScreen(NSRect frame, NSRect screenFrame) {
    const CGFloat tol = (CGFloat)MLWorkAreaEdgeTol;
    return [MLScreenGeometry nearlyEqual:NSMinX(frame) b:NSMinX(screenFrame) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMaxX(frame) b:NSMaxX(screenFrame) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMaxY(frame) b:NSMaxY(screenFrame) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMinY(frame) b:NSMinY(screenFrame) tolerance:tol];
}

/** Immersive fullscreen covering the menu-bar band on a display that has one. */
static BOOL MLFrameLooksLikeImmersiveFullscreen(NSRect frame, NSScreen *screen) {
    if (!screen) {
        return NO;
    }
    CGFloat topInset = NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame);
    return topInset >= 2.0 && MLFrameFillsScreen(frame, screen.frame);
}

/**
 * Zoom that sits under the taskbar:
 * - fills visibleFrame, or
 * - on displays with no menu-bar inset, fills screen.frame
 */
static BOOL MLFrameLooksLikeZoomNeedingInset(NSRect frame, NSScreen *screen) {
    if (!screen) {
        return NO;
    }
    if (frame.size.width < MLWorkAreaMinSize || frame.size.height < MLWorkAreaMinSize) {
        return NO;
    }
    if (MLFrameFillsVisible(frame, screen.visibleFrame)) {
        return YES;
    }
    CGFloat topInset = NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame);
    if (topInset < 2.0 && MLFrameFillsScreen(frame, screen.frame)) {
        return YES;
    }
    return NO;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _barHeight = 40.0;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (self.started) {
        return;
    }
    self.started = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(runningDidChange:)
                                                 name:MLRunningAppsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenParamsChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
    [self scheduleEnforce];
    [self scheduleEnforceAfter:0.2];
    [self scheduleEnforceAfter:0.55];
}

- (void)stop {
    if (!self.started) {
        return;
    }
    self.started = NO;
    self.enforcePending = NO;
    self.enforceGeneration += 1;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)enforceNow {
    if (!self.started) {
        return;
    }
    [self performEnforce];
}

- (void)runningDidChange:(NSNotification *)note {
    (void)note;
    [self scheduleEnforce];
    [self scheduleEnforceAfter:0.18];
    [self scheduleEnforceAfter:0.45];
}

- (void)screenParamsChanged:(NSNotification *)note {
    (void)note;
    [self scheduleEnforce];
    [self scheduleEnforceAfter:0.25];
}

- (void)scheduleEnforce {
    if (!self.started || self.enforcePending) {
        return;
    }
    self.enforcePending = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        self.enforcePending = NO;
        if (self.started) {
            [self performEnforce];
        }
    });
}

- (void)scheduleEnforceAfter:(NSTimeInterval)delay {
    NSUInteger gen = self.enforceGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (!self || !self.started || self.enforceGeneration != gen) {
                           return;
                       }
                       [self performEnforce];
                   });
}

- (void)performEnforce {
    if (!self.started || self.applying) {
        return;
    }
    if (!AXIsProcessTrusted()) {
        return;
    }

    CGFloat barH = self.barHeight > 0 ? self.barHeight : 40.0;
    pid_t selfPid = NSProcessInfo.processInfo.processIdentifier;
    MLRunningAppsMonitor *monitor = self.monitor;
    NSArray<MLTaskbarWindowInfo *> *windows = monitor.snapshot.windows ?: @[];
    if (windows.count == 0) {
        return;
    }

    NSMutableDictionary<NSNumber *, NSMutableArray<MLTaskbarWindowInfo *> *> *byPid =
        [NSMutableDictionary dictionary];
    for (MLTaskbarWindowInfo *info in windows) {
        if (info.pid <= 0 || info.pid == selfPid || info.minimized) {
            continue;
        }
        if (info.windowID != 0 && [monitor isSoftMinimizedWindowID:info.windowID]) {
            continue;
        }
        if (CGRectIsEmpty(info.bounds)) {
            continue;
        }
        /* Snapshot CG bounds are Quartz — convert before comparing to NSScreen. */
        NSRect frame = [MLScreenGeometry cocoaRectFromQuartzBounds:info.bounds];
        /* Soft reinject may already be Cocoa; if Quartz conversion misses, try raw. */
        NSScreen *screen = [MLScreenGeometry screenForCocoaRect:frame];
        if (!screen) {
            frame = NSRectFromCGRect(info.bounds);
            screen = [MLScreenGeometry screenForCocoaRect:frame];
        }
        if (!screen) {
            continue;
        }
        if (MLFrameLooksLikeImmersiveFullscreen(frame, screen)) {
            continue;
        }
        NSRect work = MLWorkRectForScreen(screen, barH);
        if (MLFrameMatchesWork(frame, work)) {
            continue;
        }
        if (!MLFrameLooksLikeZoomNeedingInset(frame, screen)) {
            continue;
        }
        NSNumber *key = @(info.pid);
        NSMutableArray *list = byPid[key];
        if (!list) {
            list = [NSMutableArray array];
            byPid[key] = list;
        }
        [list addObject:info];
    }

    if (byPid.count == 0) {
        return;
    }

    self.applying = YES;

    for (NSNumber *pidKey in byPid) {
        pid_t pid = pidKey.intValue;
        AXUIElementRef appRef = AXUIElementCreateApplication(pid);
        if (!appRef) {
            continue;
        }

        CFTypeRef windowsRef = NULL;
        AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
        if (err != kAXErrorSuccess || !windowsRef || CFGetTypeID(windowsRef) != CFArrayGetTypeID()) {
            if (windowsRef) {
                CFRelease(windowsRef);
            }
            CFRelease(appRef);
            continue;
        }

        CFArrayRef axWindows = (CFArrayRef)windowsRef;
        CFIndex count = CFArrayGetCount(axWindows);
        NSArray<MLTaskbarWindowInfo *> *targets = byPid[pidKey];
        NSMutableSet<NSNumber *> *wantedIDs = [NSMutableSet set];
        for (MLTaskbarWindowInfo *info in targets) {
            if (info.windowID != 0) {
                [wantedIDs addObject:@(info.windowID)];
            }
        }

        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            if ([MLAXWindowHelper isFullscreen:win]) {
                continue;
            }

            CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
            if (wid != 0 && wantedIDs.count > 0 && ![wantedIDs containsObject:@(wid)]) {
                continue;
            }
            if (wid != 0 && [monitor isSoftMinimizedWindowID:wid]) {
                continue;
            }

            CFTypeRef minRef = NULL;
            Boolean isMin = false;
            if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess &&
                minRef) {
                if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                    isMin = CFBooleanGetValue((CFBooleanRef)minRef);
                }
                CFRelease(minRef);
            }
            if (isMin) {
                continue;
            }

            NSRect frame = NSZeroRect;
            if (![MLScreenGeometry readCocoaFrame:&frame fromAXWindow:win]) {
                continue;
            }

            NSScreen *screen = [MLScreenGeometry screenForCocoaRect:frame];
            if (!screen) {
                continue;
            }
            if (MLFrameLooksLikeImmersiveFullscreen(frame, screen)) {
                continue;
            }

            NSRect work = MLWorkRectForScreen(screen, barH);
            if (MLFrameMatchesWork(frame, work)) {
                continue;
            }
            if (!MLFrameLooksLikeZoomNeedingInset(frame, screen)) {
                continue;
            }

            [MLScreenGeometry applyCocoaFrame:work toAXWindow:win];
            AXUIElementRef winRetry = (AXUIElementRef)CFRetain(win);
            NSRect workRetry = work;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               [MLScreenGeometry applyCocoaFrame:workRetry toAXWindow:winRetry];
                               CFRelease(winRetry);
                           });
        }

        CFRelease(windowsRef);
        CFRelease(appRef);
    }

    self.applying = NO;
}

@end
