#import "MLMinimizeInterceptor.h"

#import "MLScreenGeometry.h"
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
    return [MLScreenGeometry axPositionFromCocoaRect:NSMakeRect(cocoa.x, cocoa.y, 1, 1)];
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

    NSPoint cocoaMouse = [NSEvent mouseLocation];

    if (!AXIsProcessTrusted()) {
        /* Still allow desktop-peek arming via CG hit-test when AX is off. */
        [self.taskbar handleDesktopPeekClickAtCocoaPoint:cocoaMouse];
        return event;
    }

    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) {
        [self.taskbar handleDesktopPeekClickAtCocoaPoint:cocoaMouse];
        return event;
    }
    CGPoint axPt = MLCocoaPointToAX(cocoaMouse);
    AXUIElementRef under = NULL;
    AXError err = AXUIElementCopyElementAtPosition(systemWide, (float)axPt.x, (float)axPt.y, &under);
    CFRelease(systemWide);
    if (err != kAXErrorSuccess || !under) {
        [self.taskbar handleDesktopPeekClickAtCocoaPoint:cocoaMouse];
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
        [self.taskbar handleDesktopPeekClickAtCocoaPoint:cocoaMouse];
        return event;
    }

    AXUIElementRef win = MLAXCopyWindowElement(under);
    CFRelease(under);
    if (!win) {
        [self.taskbar handleDesktopPeekClickAtCocoaPoint:cocoaMouse];
        return event;
    }

    pid_t pid = 0;
    AXUIElementGetPid(win, &pid);

    NSString *title = nil;
    MLAXGetRole(win, kAXTitleAttribute, &title);

    NSRect cocoaFrame = NSZeroRect;
    if (![MLScreenGeometry readCocoaFrame:&cocoaFrame fromAXWindow:win]) {
        CFRelease(win);
        return event;
    }

    CGWindowID wid = MLAXCopyCGWindowID(win);
    if (wid == kCGNullWindowID) {
        wid = 0;
    }

    [self.taskbar softMinimizeWindowWithAX:win
                                  windowID:wid
                                       pid:pid
                                     title:title ?: @""
                              restoreFrame:cocoaFrame];
    CFRelease(win);

    return NULL; /* Swallow yellow-button click; we own minimize. */
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
    NSLog(@"[MeoLaunch] minimize interceptor started (instant hide, no proxy animation)");
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

@end
