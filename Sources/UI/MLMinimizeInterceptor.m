#import "MLMinimizeInterceptor.h"

#import "MLCGSAlpha.h"
#import "MLScreenGeometry.h"
#import "MLTaskbarController.h"
#import "MLWindowSoftState.h"

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

/**
 * Hide without 1×1 tuck (Finder clamps tiny sizes and won't grow back).
 * Finder: always AXMinimized (system remembers frame; CGS alpha is unreliable).
 * Others: CGS alpha=0 if verified, else AXMinimized=true.
 * No local proxy animation — avoids double-animate with Dock genie.
 */
static MLWindowHideMethod MLSoftMinimizeWindow(AXUIElementRef win, CGWindowID windowID, pid_t pid) {
    BOOL isFinder = NO;
    if (pid > 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        isFinder = [app.bundleIdentifier isEqualToString:@"com.apple.finder"];
    }

    if (!isFinder && windowID != kCGNullWindowID && windowID != 0 && MLCGSWindowAlphaAvailable()) {
        if (MLCGSSetWindowAlpha(windowID, 0.0f)) {
            NSLog(@"[Taskbar] soft hide wid=%u via alpha", (unsigned)windowID);
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
    Boolean isMin = false;
    CFTypeRef minRef = NULL;
    if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
        if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
            isMin = CFBooleanGetValue((CFBooleanRef)minRef);
        }
        CFRelease(minRef);
    }
    NSLog(@"[Taskbar] soft hide wid=%u via AXMinimized confirmed=%d finder=%d",
          (unsigned)windowID, (int)isMin, (int)isFinder);
    return MLWindowHideMethodAXMinimized;
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
    if (![MLScreenGeometry readCocoaFrame:&cocoaFrame fromAXWindow:win]) {
        CFRelease(win);
        return event;
    }

    CGWindowID wid = MLAXCopyCGWindowID(win);

    NSScreen *screen = [MLScreenGeometry screenForCocoaRect:cocoaFrame];
    NSNumber *screenID = [MLScreenGeometry screenIDForScreen:screen];

    CGWindowID remembered =
        [self.taskbar rememberWindowForCustomMinimizePID:pid
                                                   title:title ?: @""
                                                  bounds:NSRectToCGRect(cocoaFrame)
                                                windowID:(wid != kCGNullWindowID ? wid : 0)];
    if (wid == kCGNullWindowID || wid == 0) {
        wid = remembered;
    }

    /* Mark soft BEFORE hide so poll never drops the chip. */
    if (wid != 0) {
        [self.taskbar markSoftHiddenWindowID:wid
                                         pid:pid
                                       title:title ?: @""
                               restoreFrame:cocoaFrame
                                   screenID:screenID
                                   axWindow:win];
    }

    MLWindowHideMethod method = MLSoftMinimizeWindow(win, wid, pid);
    if (wid != 0 && method != MLWindowHideMethodNone) {
        [self.taskbar updateSoftHideMethod:method forWindowID:wid];
    }
    CFRelease(win);
    [self.taskbar refreshAfterCustomMinimize];

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
