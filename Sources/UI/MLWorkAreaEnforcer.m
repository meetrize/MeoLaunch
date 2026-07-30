#import "MLWorkAreaEnforcer.h"

#import "MLRunningAppsMonitor.h"

#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

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

typedef AXError (*MLAXGetWindowFn)(AXUIElementRef, CGWindowID *);

static MLAXGetWindowFn MLResolvedAXGetWindow(void) {
    static MLAXGetWindowFn sFn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sFn = (MLAXGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    });
    return sFn;
}

static NSRect MLAXRectToCocoa(CGPoint axPos, CGSize axSize) {
    NSRect main = NSScreen.mainScreen.frame;
    CGFloat cocoaY = NSMaxY(main) - axPos.y - axSize.height;
    return NSMakeRect(axPos.x, cocoaY, axSize.width, axSize.height);
}

static void MLApplyCocoaFrameAX(AXUIElementRef win, NSRect cocoa) {
    if (!win || cocoa.size.width < 2.0 || cocoa.size.height < 2.0) {
        return;
    }
    NSRect main = NSScreen.mainScreen.frame;
    CGSize axSize = CGSizeMake(cocoa.size.width, cocoa.size.height);
    CGPoint axPos = CGPointMake(cocoa.origin.x, NSMaxY(main) - cocoa.origin.y - cocoa.size.height);
    AXValueRef sizeVal = AXValueCreate((AXValueType)kAXValueCGSizeType, &axSize);
    AXValueRef posVal = AXValueCreate((AXValueType)kAXValueCGPointType, &axPos);
    if (sizeVal) {
        AXUIElementSetAttributeValue(win, kAXSizeAttribute, sizeVal);
        CFRelease(sizeVal);
    }
    if (posVal) {
        AXUIElementSetAttributeValue(win, kAXPositionAttribute, posVal);
        CFRelease(posVal);
    }
    sizeVal = AXValueCreate((AXValueType)kAXValueCGSizeType, &axSize);
    if (sizeVal) {
        AXUIElementSetAttributeValue(win, kAXSizeAttribute, sizeVal);
        CFRelease(sizeVal);
    }
}

static BOOL MLAXReadCocoaFrame(AXUIElementRef win, NSRect *outCocoa) {
    if (!win || !outCocoa) {
        return NO;
    }
    CFTypeRef posRef = NULL;
    CFTypeRef sizeRef = NULL;
    CGPoint pos = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL havePos = NO;
    BOOL haveSize = NO;
    if (AXUIElementCopyAttributeValue(win, kAXPositionAttribute, &posRef) == kAXErrorSuccess && posRef) {
        havePos = AXValueGetValue((AXValueRef)posRef, (AXValueType)kAXValueCGPointType, &pos);
        CFRelease(posRef);
    }
    if (AXUIElementCopyAttributeValue(win, kAXSizeAttribute, &sizeRef) == kAXErrorSuccess && sizeRef) {
        haveSize = AXValueGetValue((AXValueRef)sizeRef, (AXValueType)kAXValueCGSizeType, &size);
        CFRelease(sizeRef);
    }
    if (!havePos || !haveSize || size.width < 2.0 || size.height < 2.0) {
        return NO;
    }
    *outCocoa = MLAXRectToCocoa(pos, size);
    return YES;
}

static BOOL MLAXIsFullscreen(AXUIElementRef win) {
    if (!win) {
        return NO;
    }
    CFTypeRef ref = NULL;
    if (AXUIElementCopyAttributeValue(win, CFSTR("AXFullScreen"), &ref) != kAXErrorSuccess || !ref) {
        return NO;
    }
    BOOL fs = NO;
    if (CFGetTypeID(ref) == CFBooleanGetTypeID()) {
        fs = CFBooleanGetValue((CFBooleanRef)ref);
    }
    CFRelease(ref);
    return fs;
}

static BOOL MLNearlyEqual(CGFloat a, CGFloat b, CGFloat tol) {
    return fabs(a - b) <= tol;
}

static NSScreen *MLScreenForBounds(NSRect bounds) {
    NSScreen *best = nil;
    CGFloat bestArea = -1.0;
    for (NSScreen *s in NSScreen.screens) {
        CGRect inter = CGRectIntersection(NSRectToCGRect(bounds), NSRectToCGRect(s.frame));
        if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) {
            continue;
        }
        CGFloat area = inter.size.width * inter.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = s;
        }
    }
    return best ?: NSScreen.mainScreen;
}

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

/**
 * Window fills the screen's visibleFrame (standard zoom / maximize),
 * which places its bottom under our floating taskbar.
 */
static BOOL MLFrameFillsVisible(NSRect frame, NSRect visible) {
    const CGFloat tol = (CGFloat)MLWorkAreaEdgeTol;
    if (frame.size.width < MLWorkAreaMinSize || frame.size.height < MLWorkAreaMinSize) {
        return NO;
    }
    return MLNearlyEqual(NSMinX(frame), NSMinX(visible), tol) &&
           MLNearlyEqual(NSMaxX(frame), NSMaxX(visible), tol) &&
           MLNearlyEqual(NSMaxY(frame), NSMaxY(visible), tol) &&
           MLNearlyEqual(NSMinY(frame), NSMinY(visible), tol);
}

/** Already covering the intended work area (after our inset). */
static BOOL MLFrameMatchesWork(NSRect frame, NSRect work) {
    const CGFloat tol = (CGFloat)MLWorkAreaEdgeTol;
    return MLNearlyEqual(NSMinX(frame), NSMinX(work), tol) &&
           MLNearlyEqual(NSMaxX(frame), NSMaxX(work), tol) &&
           MLNearlyEqual(NSMaxY(frame), NSMaxY(work), tol) &&
           MLNearlyEqual(NSMinY(frame), NSMinY(work), tol);
}

/** True fullscreen Space — leave alone. */
static BOOL MLFrameFillsScreen(NSRect frame, NSRect screenFrame) {
    const CGFloat tol = (CGFloat)MLWorkAreaEdgeTol;
    return MLNearlyEqual(NSMinX(frame), NSMinX(screenFrame), tol) &&
           MLNearlyEqual(NSMaxX(frame), NSMaxX(screenFrame), tol) &&
           MLNearlyEqual(NSMaxY(frame), NSMaxY(screenFrame), tol) &&
           MLNearlyEqual(NSMinY(frame), NSMinY(screenFrame), tol);
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
    /* Catch zoom animations that finish after the first geometry event. */
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
    /* Zoom/green-button animation often settles after the first notify. */
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

    /* Pre-filter with CG/snapshot bounds — only touch AX for likely zoomed windows. */
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
        NSRect frame = NSRectFromCGRect(info.bounds);
        NSScreen *screen = MLScreenForBounds(frame);
        if (!screen) {
            continue;
        }
        if (MLFrameFillsScreen(frame, screen.frame)) {
            continue;
        }
        NSRect work = MLWorkRectForScreen(screen, barH);
        if (MLFrameMatchesWork(frame, work)) {
            continue;
        }
        if (!MLFrameFillsVisible(frame, screen.visibleFrame)) {
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

    MLAXGetWindowFn getWid = MLResolvedAXGetWindow();
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
            if (MLAXIsFullscreen(win)) {
                continue;
            }

            CGWindowID wid = 0;
            if (getWid) {
                getWid(win, &wid);
            }
            if (wid != 0 && wantedIDs.count > 0 && ![wantedIDs containsObject:@(wid)]) {
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
            if (!MLAXReadCocoaFrame(win, &frame)) {
                continue;
            }

            NSScreen *screen = MLScreenForBounds(frame);
            if (!screen) {
                continue;
            }
            if (MLFrameFillsScreen(frame, screen.frame)) {
                continue;
            }

            NSRect visible = screen.visibleFrame;
            NSRect work = MLWorkRectForScreen(screen, barH);
            if (MLFrameMatchesWork(frame, work)) {
                continue;
            }
            if (!MLFrameFillsVisible(frame, visible)) {
                /* Snapshot said zoomed; AX may still be mid-animation — skip this pass. */
                continue;
            }

            MLApplyCocoaFrameAX(win, work);
            AXUIElementRef winRetry = (AXUIElementRef)CFRetain(win);
            NSRect workRetry = work;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               MLApplyCocoaFrameAX(winRetry, workRetry);
                               CFRelease(winRetry);
                           });
        }

        CFRelease(windowsRef);
        CFRelease(appRef);
    }

    self.applying = NO;
}

@end
