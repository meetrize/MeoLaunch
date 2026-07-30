#import "MLMinimizeInterceptor.h"

#import "MLCGSAlpha.h"
#import "MLMinimizeAnimator.h"
#import "MLTaskbarController.h"

#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

@interface MLMinimizeInterceptor ()
@property (nonatomic, assign) CFMachPortRef tap;
@property (nonatomic, assign) CFRunLoopSourceRef source;
@property (nonatomic, assign) BOOL started;
@end

@implementation MLMinimizeInterceptor

static CGPoint MLCocoaPointToAX(NSPoint cocoa) {
    /* AX uses top-left origin of the main display. */
    NSRect main = NSScreen.mainScreen.frame;
    return CGPointMake(cocoa.x, NSMaxY(main) - cocoa.y);
}

static NSRect MLAXRectToCocoa(CGPoint axPos, CGSize axSize) {
    NSRect main = NSScreen.mainScreen.frame;
    CGFloat cocoaY = NSMaxY(main) - axPos.y - axSize.height;
    return NSMakeRect(axPos.x, cocoaY, axSize.width, axSize.height);
}

static BOOL MLAXGetRole(AXUIElementRef el, CFStringRef attr, NSString **out) {
    if (!el || !out) {
        return NO;
    }
    CFTypeRef ref = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &ref) != kAXErrorSuccess || !ref) {
        return NO;
    }
    BOOL ok = NO;
    if (CFGetTypeID(ref) == CFStringGetTypeID()) {
        *out = [(__bridge NSString *)ref copy];
        ok = YES;
    }
    CFRelease(ref);
    return ok;
}

static AXUIElementRef MLAXCopyWindowElement(AXUIElementRef el) {
    if (!el) {
        return NULL;
    }
    CFTypeRef winRef = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXWindowAttribute, &winRef) == kAXErrorSuccess && winRef) {
        return (AXUIElementRef)winRef;
    }
    AXUIElementRef cur = (AXUIElementRef)CFRetain(el);
    for (int i = 0; i < 8; i++) {
        NSString *role = nil;
        MLAXGetRole(cur, kAXRoleAttribute, &role);
        if ([role isEqualToString:(__bridge NSString *)kAXWindowRole]) {
            return cur;
        }
        CFTypeRef parent = NULL;
        if (AXUIElementCopyAttributeValue(cur, kAXParentAttribute, &parent) != kAXErrorSuccess || !parent) {
            CFRelease(cur);
            return NULL;
        }
        CFRelease(cur);
        cur = (AXUIElementRef)parent;
    }
    CFRelease(cur);
    return NULL;
}

static BOOL MLAXReadFrame(AXUIElementRef win, NSRect *outCocoa) {
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

/** Private AX → CGWindowID (stable; avoids multi-monitor AX parking). */
static CGWindowID MLAXCopyCGWindowID(AXUIElementRef win) {
    if (!win) {
        return kCGNullWindowID;
    }
    typedef AXError (*MLAXGetWindowFn)(AXUIElementRef, CGWindowID *);
    static MLAXGetWindowFn sFn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sFn = (MLAXGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    });
    if (!sFn) {
        return kCGNullWindowID;
    }
    CGWindowID wid = kCGNullWindowID;
    if (sFn(win, &wid) != kAXErrorSuccess) {
        return kCGNullWindowID;
    }
    return wid;
}

static NSImage *MLCaptureWindowImage(pid_t pid, NSRect cocoaBounds, NSString *title) {
    (void)title;
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSImage *icon = app.icon;
    if (!icon && app.bundleURL.path.length > 0) {
        icon = [[NSWorkspace sharedWorkspace] iconForFile:app.bundleURL.path];
    }

    NSSize size = cocoaBounds.size;
    if (size.width < 2.0 || size.height < 2.0) {
        size = NSMakeSize(320, 220);
    }
    NSImage *shot = [[NSImage alloc] initWithSize:size];
    [shot lockFocus];
    [[NSColor colorWithCalibratedWhite:0.18 alpha:0.95] setFill];
    NSBezierPath *round = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(0, 0, size.width, size.height)
                                                          xRadius:10.0
                                                          yRadius:10.0];
    [round fill];
    if (icon) {
        CGFloat side = MIN(96.0, MIN(size.width, size.height) * 0.35);
        NSRect iconRect = NSMakeRect((size.width - side) * 0.5, (size.height - side) * 0.5, side, side);
        [icon drawInRect:iconRect
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0
          respectFlipped:YES
                   hints:nil];
    }
    [shot unlockFocus];
    return shot;
}

static NSRect MLFallbackTargetOnWindowScreen(NSRect cocoaFrame) {
    NSScreen *screen = nil;
    CGFloat best = -1;
    for (NSScreen *s in NSScreen.screens) {
        CGRect inter = CGRectIntersection(NSRectToCGRect(cocoaFrame), s.frame);
        CGFloat a = CGRectIsNull(inter) ? 0 : inter.size.width * inter.size.height;
        if (a > best) {
            best = a;
            screen = s;
        }
    }
    if (!screen) {
        return cocoaFrame;
    }
    NSRect vis = screen.visibleFrame;
    return NSMakeRect(NSMidX(vis) - 40.0, NSMinY(vis) + 4.0, 80.0, 32.0);
}

/**
 * Hide WITHOUT AXMinimized — Dock genie always flies to the primary display and
 * would duplicate our local taskbar proxy animation.
 *
 * 1) CGS alpha=0 if privileged (rare)
 * 2) Else tuck to a 1×1 under this screen's taskbar chip (same display, under our bar)
 * Restore uses the frozen pre-minimize frame — tuck size is never kept.
 */
static void MLApplyCocoaFrameAX(AXUIElementRef win, NSRect cocoa) {
    if (!win || cocoa.size.width < 1.0 || cocoa.size.height < 1.0) {
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
}

static BOOL MLSoftMinimizeWindow(AXUIElementRef win, CGWindowID windowID, NSRect tuckRect) {
    if (windowID != kCGNullWindowID && windowID != 0 && MLCGSWindowAlphaAvailable()) {
        if (MLCGSSetWindowAlpha(windowID, 0.0f)) {
            return YES;
        }
    }
    if (!win) {
        return NO;
    }
    /* Keep un-minimized so Dock never genies to the primary screen. */
    AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanFalse);

    NSRect tuck = tuckRect;
    if (NSIsEmptyRect(tuck)) {
        tuck = NSMakeRect(0, 0, 1, 1);
    }
    /* 1×1 under the chip — covered by our opaque taskbar after the proxy lands. */
    tuck.size = NSMakeSize(1.0, 1.0);
    MLApplyCocoaFrameAX(win, tuck);
    return YES;
}

static CGEventRef MLTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy;
    MLMinimizeInterceptor *self = (__bridge MLMinimizeInterceptor *)refcon;
    if (!self || !self.taskbar) {
        return event;
    }
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (self.tap) {
            CGEventTapEnable(self.tap, true);
        }
        return event;
    }
    if (type != kCGEventLeftMouseDown) {
        return event;
    }
    if (!AXIsProcessTrusted()) {
        return event;
    }

    NSPoint cocoaMouse = [NSEvent mouseLocation];
    CGPoint axPt = MLCocoaPointToAX(cocoaMouse);

    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) {
        return event;
    }
    AXUIElementRef under = NULL;
    AXError err = AXUIElementCopyElementAtPosition(systemWide, (float)axPt.x, (float)axPt.y, &under);
    CFRelease(systemWide);
    if (err != kAXErrorSuccess || !under) {
        return event;
    }

    NSString *role = nil;
    NSString *subrole = nil;
    MLAXGetRole(under, kAXRoleAttribute, &role);
    MLAXGetRole(under, kAXSubroleAttribute, &subrole);
    BOOL isMinimize = [role isEqualToString:(__bridge NSString *)kAXButtonRole] &&
                      [subrole isEqualToString:(__bridge NSString *)kAXMinimizeButtonSubrole];
    if (!isMinimize) {
        CFRelease(under);
        return event;
    }

    AXUIElementRef win = MLAXCopyWindowElement(under);
    CFRelease(under);
    if (!win) {
        return event;
    }

    pid_t pid = 0;
    AXUIElementGetPid(win, &pid);

    NSString *title = nil;
    MLAXGetRole(win, kAXTitleAttribute, &title);

    NSRect cocoaFrame = NSZeroRect;
    if (!MLAXReadFrame(win, &cocoaFrame)) {
        CFRelease(win);
        return event;
    }

    CGWindowID wid = MLAXCopyCGWindowID(win);

    NSImage *shot = MLCaptureWindowImage(pid, cocoaFrame, title);
    if (!shot) {
        shot = [[NSImage alloc] initWithSize:cocoaFrame.size];
        [shot lockFocus];
        [[NSColor colorWithCalibratedWhite:0.25 alpha:0.9] setFill];
        NSRectFill(NSMakeRect(0, 0, cocoaFrame.size.width, cocoaFrame.size.height));
        [shot unlockFocus];
    }

    CGWindowID remembered =
        [self.taskbar rememberWindowForCustomMinimizePID:pid
                                                   title:title ?: @""
                                                  bounds:NSRectToCGRect(cocoaFrame)];
    if (wid == kCGNullWindowID || wid == 0) {
        wid = remembered;
    }

    /*
     * Fast path: do NOT rebuildItems here (expensive). Aim at existing chip or
     * the window's own screen taskbar strip; refine after hide via refresh.
     */
    NSRect target = [self.taskbar animationTargetRectForPID:pid
                                                      title:title ?: @""
                                               windowBounds:NSRectToCGRect(cocoaFrame)];
    if (NSIsEmptyRect(target)) {
        target = MLFallbackTargetOnWindowScreen(cocoaFrame);
    }

    AXUIElementRef winKeep = (AXUIElementRef)CFRetain(win);
    CFRelease(win);
    CGWindowID widKeep = wid;
    NSRect tuckKeep = target;

    /*
     * 1) Proxy covers the real window on THIS screen
     * 2) Tuck real window under THIS screen's taskbar (no AXMinimized → no Dock genie)
     * 3) Shrink proxy to THIS screen's taskbar chip — the only visible animation
     */
    [MLMinimizeAnimator animateImage:shot
                            fromRect:cocoaFrame
                              toRect:target
                           onCovered:^{
                               if (widKeep != 0) {
                                   [self.taskbar markSoftMinimizedWindowID:widKeep];
                               }
                               MLSoftMinimizeWindow(winKeep, widKeep, tuckKeep);
                           }
                          completion:^{
                              CFRelease(winKeep);
                              [self.taskbar refreshAfterCustomMinimize];
                          }];

    /* Swallow the click so the yellow button does not trigger Dock minimize. */
    return NULL;
}

- (void)start {
    if (self.started) {
        return;
    }
    if (!AXIsProcessTrusted()) {
        NSLog(@"[MeoLaunch] minimize interceptor needs Accessibility");
        return;
    }

    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown);
    self.tap = CGEventTapCreate(kCGSessionEventTap,
                                kCGHeadInsertEventTap,
                                kCGEventTapOptionDefault,
                                mask,
                                MLTapCallback,
                                (__bridge void *)self);
    if (!self.tap) {
        NSLog(@"[MeoLaunch] failed to create minimize event tap (Input Monitoring?)");
        return;
    }
    self.source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
    CGEventTapEnable(self.tap, true);
    self.started = YES;
    NSLog(@"[MeoLaunch] minimize interceptor started (local taskbar anim, no Dock genie)");
}

- (void)stop {
    if (!self.started) {
        return;
    }
    self.started = NO;
    if (self.tap) {
        CGEventTapEnable(self.tap, false);
    }
    if (self.source) {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), self.source, kCFRunLoopCommonModes);
        CFRelease(self.source);
        self.source = NULL;
    }
    if (self.tap) {
        CFRelease(self.tap);
        self.tap = NULL;
    }
}

- (void)dealloc {
    [self stop];
}

@end
