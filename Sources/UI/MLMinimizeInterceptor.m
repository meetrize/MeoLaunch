#import "MLMinimizeInterceptor.h"

#import "MLAXWindowHelper.h"
#import "MLScreenGeometry.h"
#import "MLTaskbarController.h"

#import <ApplicationServices/ApplicationServices.h>

@interface MLMinimizeInterceptor ()
@property (nonatomic, assign) CFMachPortRef tap;
@property (nonatomic, assign) CFRunLoopSourceRef source;
@property (nonatomic, assign) BOOL started;
@end

@implementation MLMinimizeInterceptor

static CGPoint MLCocoaPointToAX(NSPoint cocoa) {
    return [MLScreenGeometry axPositionFromCocoaRect:NSMakeRect(cocoa.x, cocoa.y, 1, 1)];
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
    [MLAXWindowHelper copyStringAttribute:kAXRoleAttribute fromElement:under into:&role];
    [MLAXWindowHelper copyStringAttribute:kAXSubroleAttribute fromElement:under into:&subrole];
    BOOL isMinimize = [role isEqualToString:(__bridge NSString *)kAXButtonRole] &&
                      [subrole isEqualToString:(__bridge NSString *)kAXMinimizeButtonSubrole];
    if (!isMinimize) {
        CFRelease(under);
        [self.taskbar handleDesktopPeekClickAtCocoaPoint:cocoaMouse];
        return event;
    }

    AXUIElementRef win = [MLAXWindowHelper copyWindowElementFromElement:under];
    CFRelease(under);
    if (!win) {
        [self.taskbar handleDesktopPeekClickAtCocoaPoint:cocoaMouse];
        return event;
    }

    pid_t pid = 0;
    AXUIElementGetPid(win, &pid);

    NSString *title = nil;
    [MLAXWindowHelper copyStringAttribute:kAXTitleAttribute fromElement:win into:&title];

    NSRect cocoaFrame = NSZeroRect;
    if (![MLScreenGeometry readCocoaFrame:&cocoaFrame fromAXWindow:win]) {
        CFRelease(win);
        return event;
    }

    CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
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
