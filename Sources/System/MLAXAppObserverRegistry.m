#import "MLAXAppObserverRegistry.h"

#import "MLAXWindowHelper.h"

#import <ApplicationServices/ApplicationServices.h>

@interface MLAXPidWatch : NSObject
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) AXObserverRef observer;
@property (nonatomic, assign) AXUIElementRef appElement;
- (void)invalidate;
@end

@implementation MLAXPidWatch

- (void)invalidate {
    if (self.observer) {
        CFRunLoopSourceRef src = AXObserverGetRunLoopSource(self.observer);
        if (src) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
        }
        CFRelease(self.observer);
        self.observer = NULL;
    }
    if (self.appElement) {
        CFRelease(self.appElement);
        self.appElement = NULL;
    }
}

- (void)dealloc {
    [self invalidate];
}

@end

@interface MLAXAppObserverRegistry ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, MLAXPidWatch *> *watchByPid;
@end

@implementation MLAXAppObserverRegistry

- (instancetype)init {
    self = [super init];
    if (self) {
        _watchByPid = [NSMutableDictionary dictionary];
    }
    return self;
}

static void MLAXRegistryCallback(AXObserverRef observer,
                                 AXUIElementRef element,
                                 CFStringRef notification,
                                 void *refcon) {
    (void)observer;
    MLAXAppObserverRegistry *registry = (__bridge MLAXAppObserverRegistry *)refcon;
    id<MLAXAppObserverRegistryDelegate> delegate = registry.delegate;
    if (!registry.active || !delegate || !notification) {
        return;
    }

    if (CFEqual(notification, kAXWindowCreatedNotification) && element) {
        [delegate axRegistry:registry didCreateWindow:element];
        [delegate axRegistryDidRequestStructuralPoll:registry];
        return;
    }
    if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        [delegate axRegistry:registry didDestroyElement:element];
        [delegate axRegistryDidRequestStructuralPoll:registry];
        return;
    }
    if (CFEqual(notification, kAXWindowMiniaturizedNotification) ||
        CFEqual(notification, kAXWindowDeminiaturizedNotification)) {
        [delegate axRegistryDidRequestStructuralPoll:registry];
        return;
    }
    if (CFEqual(notification, kAXTitleChangedNotification)) {
        [delegate axRegistry:registry didChangeTitleOnElement:element];
        [delegate axRegistryDidRequestStructuralPoll:registry];
        return;
    }
    if (CFEqual(notification, kAXFocusedWindowChangedNotification)) {
        CGWindowID wid = 0;
        if (element) {
            CFTypeRef focusedRef = NULL;
            if (AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute, &focusedRef) ==
                    kAXErrorSuccess &&
                focusedRef) {
                wid = [delegate axRegistry:registry windowIDForElement:(AXUIElementRef)focusedRef];
                CFRelease(focusedRef);
            }
        }
        [delegate axRegistry:registry didChangeFocusedWindow:wid pid:0];
        return;
    }
    if (CFEqual(notification, kAXMovedNotification) || CFEqual(notification, kAXResizedNotification)) {
        [delegate axRegistry:registry didMoveOrResizeElement:element];
        [delegate axRegistryDidRequestGeometryPoll:registry];
        return;
    }
    [delegate axRegistryDidRequestStructuralPoll:registry];
}

- (void)registerNotificationsOnWindow:(AXUIElementRef)win {
    if (!win || !self.active) {
        return;
    }
    pid_t pid = 0;
    if (AXUIElementGetPid(win, &pid) != kAXErrorSuccess || pid <= 0) {
        return;
    }
    MLAXPidWatch *watch = self.watchByPid[@(pid)];
    if (!watch || !watch.observer) {
        return;
    }
    void *refcon = (__bridge void *)self;
    AXObserverAddNotification(watch.observer, win, kAXUIElementDestroyedNotification, refcon);
    AXObserverAddNotification(watch.observer, win, kAXWindowMiniaturizedNotification, refcon);
    AXObserverAddNotification(watch.observer, win, kAXWindowDeminiaturizedNotification, refcon);
    AXObserverAddNotification(watch.observer, win, kAXTitleChangedNotification, refcon);
    AXObserverAddNotification(watch.observer, win, kAXMovedNotification, refcon);
    AXObserverAddNotification(watch.observer, win, kAXResizedNotification, refcon);
}

- (void)installWatchForPID:(pid_t)pid {
    if (pid <= 0 || !self.active || !AXIsProcessTrusted()) {
        return;
    }
    if (self.watchByPid[@(pid)]) {
        return;
    }

    AXObserverRef observer = NULL;
    if (AXObserverCreate(pid, MLAXRegistryCallback, &observer) != kAXErrorSuccess || !observer) {
        return;
    }
    AXUIElementRef appElement = AXUIElementCreateApplication(pid);
    if (!appElement) {
        CFRelease(observer);
        return;
    }

    MLAXPidWatch *watch = [[MLAXPidWatch alloc] init];
    watch.pid = pid;
    watch.observer = observer;
    watch.appElement = appElement;
    self.watchByPid[@(pid)] = watch;

    void *refcon = (__bridge void *)self;
    AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification, refcon);
    AXObserverAddNotification(observer, appElement, kAXFocusedWindowChangedNotification, refcon);

    CFTypeRef windowsRef = NULL;
    if (AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &windowsRef) == kAXErrorSuccess &&
        windowsRef && CFGetTypeID(windowsRef) == CFArrayGetTypeID()) {
        CFArrayRef axWindows = (CFArrayRef)windowsRef;
        CFIndex count = CFArrayGetCount(axWindows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            [self registerNotificationsOnWindow:win];
        }
    }
    if (windowsRef) {
        CFRelease(windowsRef);
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
}

- (void)removeWatchForPID:(pid_t)pid {
    if (pid <= 0) {
        return;
    }
    MLAXPidWatch *watch = self.watchByPid[@(pid)];
    if (!watch) {
        return;
    }
    [watch invalidate];
    [self.watchByPid removeObjectForKey:@(pid)];
}

- (void)syncWatchesForPIDs:(NSSet<NSNumber *> *)pids {
    if (!AXIsProcessTrusted()) {
        if (self.watchByPid.count > 0) {
            NSArray<NSNumber *> *keys = self.watchByPid.allKeys;
            for (NSNumber *pidNum in keys) {
                [self removeWatchForPID:(pid_t)pidNum.intValue];
            }
        }
        return;
    }
    NSSet<NSNumber *> *wanted = pids ?: [NSSet set];
    NSArray<NSNumber *> *existing = self.watchByPid.allKeys;
    for (NSNumber *pidNum in existing) {
        if (![wanted containsObject:pidNum]) {
            [self removeWatchForPID:(pid_t)pidNum.intValue];
        }
    }
    for (NSNumber *pidNum in wanted) {
        [self installWatchForPID:(pid_t)pidNum.intValue];
    }
}

- (void)removeAllWatches {
    NSArray<NSNumber *> *keys = self.watchByPid.allKeys;
    for (NSNumber *pidNum in keys) {
        [self removeWatchForPID:(pid_t)pidNum.intValue];
    }
}

@end
