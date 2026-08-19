#import "MLRunningAppsMonitor+Private.h"

#import "MLAXAppObserverRegistry.h"
#import "MLAXWindowHelper.h"
#import "MLScreenGeometry.h"
#import "MLWindowCensus.h"
#import "MLWindowSoftState.h"

#import <ApplicationServices/ApplicationServices.h>

NSNotificationName const MLRunningAppsDidChangeNotification = @"MLRunningAppsDidChangeNotification";
NSNotificationName const MLRunningAppsFrontWindowDidChangeNotification =
    @"MLRunningAppsFrontWindowDidChangeNotification";
NSString *const MLRunningAppsFrontWindowIDKey = @"MLRunningAppsFrontWindowIDKey";

@implementation MLTaskbarWindowInfo
@end

@implementation MLRunningAppsSnapshot
@end

const MLPollOptions MLPollOptionsFast =
    MLPollOptionSkipPidRebuild | MLPollOptionSkipTitleEnrich | MLPollOptionSkipGhostSweep |
    MLPollOptionSkipAXMinimizedBackup;

@implementation MLRunningAppsMonitor

- (instancetype)init {
    self = [super init];
    if (self) {
        _windowPollInterval = 1.0;
        _maxWindowEntries = MLTaskbarMaxWindowEntries;
        _titleMaxChars = MLTaskbarTitleMaxChars;
        _pidPathMap = [NSMutableDictionary dictionary];
        _lastSeenWindows = [NSMutableDictionary dictionary];
        _softState = [[MLWindowSoftState alloc] init];
        _axRegistry = [[MLAXAppObserverRegistry alloc] init];
        _axRegistry.delegate = self;
        _windowCensus = [[MLWindowCensus alloc] init];
        _nextSeenOrder = 1;
        _selfBundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        _snapshot = [self emptySnapshot];
    }
    return self;
}
- (void)dealloc {
    [self stop];
}
- (MLRunningAppsSnapshot *)emptySnapshot {
    MLRunningAppsSnapshot *s = [[MLRunningAppsSnapshot alloc] init];
    s.runningAppPaths = @[];
    s.pathsWithVisibleWindows = [NSSet set];
    s.windows = @[];
    s.pidToPath = @{};
    return s;
}
- (NSString *)truncateTitle:(NSString *)title {
    if (title.length == 0) {
        return @"";
    }
    NSUInteger maxChars = self.titleMaxChars > 0 ? self.titleMaxChars : MLTaskbarTitleMaxChars;
    if (title.length <= maxChars) {
        return title;
    }
    if (maxChars <= 1) {
        return @"…";
    }
    return [[title substringToIndex:maxChars - 1] stringByAppendingString:@"…"];
}
- (BOOL)shouldTrackApplication:(NSRunningApplication *)app {
    if (!app || app.isTerminated) {
        return NO;
    }
    if (app.activationPolicy != NSApplicationActivationPolicyRegular) {
        return NO;
    }
    NSString *bid = app.bundleIdentifier;
    if (bid.length > 0 && [bid isEqualToString:self.selfBundleID]) {
        return NO;
    }
    NSURL *url = app.bundleURL;
    if (!url.path.length) {
        return NO;
    }
    return YES;
}
- (void)rebuildPidMapFromWorkspace {
    [self.pidPathMap removeAllObjects];
    NSArray<NSRunningApplication *> *apps = [[NSWorkspace sharedWorkspace] runningApplications];
    for (NSRunningApplication *app in apps) {
        if (![self shouldTrackApplication:app]) {
            continue;
        }
        NSString *path = app.bundleURL.path;
        if (path.length > 0 && app.processIdentifier > 0) {
            self.pidPathMap[@(app.processIdentifier)] = path;
        }
    }
}
- (NSArray<NSString *> *)orderedRunningPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSArray<NSRunningApplication *> *apps = [[NSWorkspace sharedWorkspace] runningApplications];
    for (NSRunningApplication *app in apps) {
        if (![self shouldTrackApplication:app]) {
            continue;
        }
        NSString *path = app.bundleURL.path;
        if (path.length == 0 || [seen containsObject:path]) {
            continue;
        }
        [seen addObject:path];
        [paths addObject:path];
    }
    return paths;
}
- (void)publishSnapshot:(MLRunningAppsSnapshot *)snap fingerprint:(NSString *)fp {
    self.snapshot = snap;
    self.lastFingerprint = fp;
    [[NSNotificationCenter defaultCenter] postNotificationName:MLRunningAppsDidChangeNotification
                                                        object:self];
    [self updateFocusPollTimer];
}
- (NSString *)fingerprintForPaths:(NSArray<NSString *> *)paths
                          windows:(NSArray<MLTaskbarWindowInfo *> *)windows {
    NSMutableString *fp = [NSMutableString string];
    [fp appendString:@"R:"];
    for (NSString *p in paths) {
        [fp appendString:p];
        [fp appendString:@"\n"];
    }
    [fp appendString:@"W:"];
    for (MLTaskbarWindowInfo *w in windows) {
        [fp appendFormat:@"%u|%@|%@|%d|%.0f,%.0f,%.0f,%.0f\n",
         (unsigned)w.windowID,
         w.path ?: @"",
         w.title ?: @"",
         w.minimized ? 1 : 0,
         w.bounds.origin.x, w.bounds.origin.y, w.bounds.size.width, w.bounds.size.height];
    }
    return fp;
}
- (void)refreshRunningOnly {
    [self rebuildPidMapFromWorkspace];
    NSArray<NSString *> *paths = [self orderedRunningPaths];
    MLRunningAppsSnapshot *prev = self.snapshot;
    MLRunningAppsSnapshot *snap = [[MLRunningAppsSnapshot alloc] init];
    snap.runningAppPaths = paths;
    snap.pathsWithVisibleWindows = prev.pathsWithVisibleWindows ?: [NSSet set];
    snap.windows = prev.windows ?: @[];
    snap.pidToPath = [self.pidPathMap copy];

    NSString *fp = [self fingerprintForPaths:paths windows:snap.windows];
    if ([fp isEqualToString:self.lastFingerprint]) {
        self.snapshot = snap;
        return;
    }
    [self publishSnapshot:snap fingerprint:fp];
}
- (void)appDidLaunch:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if ([self shouldTrackApplication:app] && app.processIdentifier > 0) {
        self.pidPathMap[@(app.processIdentifier)] = app.bundleURL.path;
        [self.axRegistry installWatchForPID:app.processIdentifier];
    }
    [self scheduleStructuralFastPoll];
}
- (void)appDidTerminate:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (app.processIdentifier > 0) {
        pid_t pid = app.processIdentifier;
        [self.pidPathMap removeObjectForKey:@(pid)];
        [self.axRegistry removeWatchForPID:pid];
        [self removeLastSeenAndSoftForPID:pid];
    }
    [self scheduleStructuralFastPoll];
}

- (void)removeLastSeenAndSoftForPID:(pid_t)pid {
    if (pid <= 0) {
        return;
    }
    [self.softState removeAllForPID:pid];
    NSArray<NSNumber *> *keys = self.lastSeenWindows.allKeys;
    for (NSNumber *key in keys) {
        MLTaskbarWindowInfo *w = self.lastSeenWindows[key];
        if (w.pid == pid) {
            [self.lastSeenWindows removeObjectForKey:key];
        }
    }
}

- (void)trimLastSeenWindowsIfNeeded {
    NSUInteger max = MLLastSeenWindowsMax;
    if (self.lastSeenWindows.count <= max) {
        return;
    }
    /* Evict oldest seenOrder first; never touch soft-hidden. */
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    for (NSNumber *key in self.lastSeenWindows.allKeys) {
        if ([self.softState isSoftHiddenWindowID:(CGWindowID)key.unsignedIntValue]) {
            continue;
        }
        [candidates addObject:key];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSUInteger oa = self.lastSeenWindows[a].seenOrder;
        NSUInteger ob = self.lastSeenWindows[b].seenOrder;
        if (oa < ob) {
            return NSOrderedAscending;
        }
        if (oa > ob) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    NSUInteger need = self.lastSeenWindows.count - max;
    NSUInteger removed = 0;
    for (NSNumber *key in candidates) {
        if (removed >= need) {
            break;
        }
        [self.lastSeenWindows removeObjectForKey:key];
        removed++;
    }
}

- (void)trimLastSeenWindowsForMemoryPressure {
    /* Aim for half the hard cap under pressure. */
    NSUInteger target = MLLastSeenWindowsMax / 2;
    if (target < 64) {
        target = 64;
    }
    if (self.lastSeenWindows.count <= target) {
        return;
    }
    NSMutableArray<NSNumber *> *candidates = [NSMutableArray array];
    for (NSNumber *key in self.lastSeenWindows.allKeys) {
        if ([self.softState isSoftHiddenWindowID:(CGWindowID)key.unsignedIntValue]) {
            continue;
        }
        [candidates addObject:key];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        NSUInteger oa = self.lastSeenWindows[a].seenOrder;
        NSUInteger ob = self.lastSeenWindows[b].seenOrder;
        if (oa < ob) {
            return NSOrderedAscending;
        }
        if (oa > ob) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    NSUInteger need = self.lastSeenWindows.count - target;
    NSUInteger removed = 0;
    for (NSNumber *key in candidates) {
        if (removed >= need) {
            break;
        }
        [self.lastSeenWindows removeObjectForKey:key];
        removed++;
    }
}

- (void)auditSoftStateForDeadPIDs {
    NSArray<MLWindowSoftRecord *> *recs = [self.softState allRecords];
    for (MLWindowSoftRecord *r in recs) {
        if (r.pid <= 0) {
            continue;
        }
        if (!self.pidPathMap[@(r.pid)]) {
            [self.softState removeAllForPID:r.pid];
            NSArray<NSNumber *> *keys = self.lastSeenWindows.allKeys;
            for (NSNumber *key in keys) {
                MLTaskbarWindowInfo *w = self.lastSeenWindows[key];
                if (w.pid == r.pid) {
                    [self.lastSeenWindows removeObjectForKey:key];
                }
            }
        }
    }
}

- (void)reclaimStaleSoftStateAndCachesUnderPressure:(BOOL)underPressure {
    [self auditSoftStateForDeadPIDs];
    if (underPressure) {
        [self trimLastSeenWindowsForMemoryPressure];
    } else {
        [self trimLastSeenWindowsIfNeeded];
    }
}
- (void)syncAXWindowObservers {
    [self.axRegistry syncWatchesForPIDs:[NSSet setWithArray:self.pidPathMap.allKeys]];
}
- (void)removeAllAXWatches {
    [self.axRegistry removeAllWatches];
}
- (void)axRegistryDidRequestStructuralPoll:(MLAXAppObserverRegistry *)registry {
    (void)registry;
    [self scheduleStructuralFastPoll];
}
- (void)axRegistryDidRequestGeometryPoll:(MLAXAppObserverRegistry *)registry {
    (void)registry;
    [self scheduleGeometryFastPoll];
}
- (void)axRegistry:(MLAXAppObserverRegistry *)registry didDestroyElement:(AXUIElementRef)element {
    (void)registry;
    [self optimisticRemoveWindowElement:element];
}
- (void)axRegistry:(MLAXAppObserverRegistry *)registry didCreateWindow:(AXUIElementRef)element {
    (void)registry;
    [self.axRegistry registerNotificationsOnWindow:element];
}
- (void)axRegistry:(MLAXAppObserverRegistry *)registry didChangeTitleOnElement:(AXUIElementRef)element {
    (void)registry;
    [self optimisticUpdateTitleFromElement:element];
}
- (void)axRegistry:(MLAXAppObserverRegistry *)registry didMoveOrResizeElement:(AXUIElementRef)element {
    (void)registry;
    [self optimisticUpdateBoundsFromElement:element];
}
- (void)axRegistry:(MLAXAppObserverRegistry *)registry
    didChangeFocusedWindow:(CGWindowID)wid
                       pid:(pid_t)pid {
    (void)registry;
    [self publishFocusedWindowChange:wid pid:pid];
}
- (CGWindowID)axRegistry:(MLAXAppObserverRegistry *)registry windowIDForElement:(AXUIElementRef)el {
    (void)registry;
    return [self cgWindowIDFromAXElement:el];
}
- (void)scheduleStructuralFastPoll {
    if (!self.running) {
        return;
    }
    if (self.axStructuralPollPending) {
        return;
    }
    self.axStructuralPollPending = YES;
    __weak typeof(self) weakSelf = self;
    /* Next run-loop turn — no artificial 40ms delay. */
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strong = weakSelf;
        if (!strong) {
            return;
        }
        strong.axStructuralPollPending = NO;
        if (strong.running) {
            [strong pollWindowsWithOptions:MLPollOptionsFast];
        }
    });
}
- (void)scheduleGeometryFastPoll {
    if (!self.running) {
        return;
    }
    if (self.axGeometryPollPending) {
        return;
    }
    self.axGeometryPollPending = YES;
    __weak typeof(self) weakSelf = self;
    /* Coalesce move spam while dragging; optimistic path already updated screen affinity. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       typeof(self) strong = weakSelf;
                       if (!strong) {
                           return;
                       }
                       strong.axGeometryPollPending = NO;
                       if (strong.running) {
                           [strong pollWindowsWithOptions:MLPollOptionsFast];
                       }
                   });
}
- (CGWindowID)cgWindowIDFromAXElement:(AXUIElementRef)el {
    return [MLAXWindowHelper windowIDForAXWindow:el];
}
- (CGWindowID)focusedWindowIDForPID:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return 0;
    }
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) {
        return 0;
    }
    CGWindowID wid = 0;
    CFTypeRef focusedRef = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &focusedRef) == kAXErrorSuccess &&
        focusedRef) {
        wid = [self cgWindowIDFromAXElement:(AXUIElementRef)focusedRef];
        CFRelease(focusedRef);
    }
    CFRelease(app);
    return wid;
}
- (NSString *)focusedWindowTitleForPID:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return nil;
    }
    AXUIElementRef app = AXUIElementCreateApplication(pid);
    if (!app) {
        return nil;
    }
    NSString *title = nil;
    CFTypeRef focusedRef = NULL;
    if (AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &focusedRef) == kAXErrorSuccess &&
        focusedRef) {
        CFTypeRef titleRef = NULL;
        if (AXUIElementCopyAttributeValue((AXUIElementRef)focusedRef, kAXTitleAttribute, &titleRef) ==
                kAXErrorSuccess &&
            titleRef) {
            if (CFGetTypeID(titleRef) == CFStringGetTypeID()) {
                title = [(__bridge NSString *)titleRef copy];
            }
            CFRelease(titleRef);
        }
        CFRelease(focusedRef);
    }
    CFRelease(app);
    return title;
}
- (NSInteger)onScreenWindowCountForPID:(pid_t)pid {
    if (pid <= 0) {
        return 0;
    }
    NSInteger n = 0;
    for (MLTaskbarWindowInfo *w in self.snapshot.windows) {
        if (w.pid == pid && !w.minimized && w.windowID != 0) {
            n++;
        }
    }
    return n;
}
- (void)publishFocusedWindowChange:(CGWindowID)wid pid:(pid_t)hintPid {
    if (!self.running) {
        return;
    }
    pid_t pid = hintPid;
    if (pid <= 0) {
        NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
        pid = front.processIdentifier;
    }
    if (wid == 0 && pid > 0) {
        wid = [self focusedWindowIDForPID:pid];
    }
    if (wid == 0) {
        return;
    }
    if (wid == self.lastPublishedFocusedWID && pid == self.lastPublishedFocusedPID) {
        return;
    }
    self.lastPublishedFocusedWID = wid;
    self.lastPublishedFocusedPID = pid;
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MLRunningAppsFrontWindowDidChangeNotification
                      object:self
                    userInfo:@{ MLRunningAppsFrontWindowIDKey: @(wid) }];
}
- (void)pollFocusedWindowIfChanged {
    if (!self.running || !AXIsProcessTrusted()) {
        return;
    }
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (!front || front.isTerminated || front.processIdentifier <= 0) {
        return;
    }
    if (front.activationPolicy != NSApplicationActivationPolicyRegular) {
        return;
    }
    if (self.selfBundleID.length > 0 &&
        [front.bundleIdentifier isEqualToString:self.selfBundleID]) {
        return;
    }
    pid_t pid = front.processIdentifier;
    CGWindowID wid = [self focusedWindowIDForPID:pid];
    if (wid == 0) {
        return;
    }
    [self publishFocusedWindowChange:wid pid:pid];
}
- (void)updateFocusPollTimer {
    if (!self.running) {
        [self.focusPollTimer invalidate];
        self.focusPollTimer = nil;
        return;
    }
    if (self.hotCornerProximityActive || self.overlayVisibleThrottle) {
        [self.focusPollTimer invalidate];
        self.focusPollTimer = nil;
        return;
    }
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    pid_t pid = front.processIdentifier;
    NSInteger count = (pid > 0 && AXIsProcessTrusted()) ? [self onScreenWindowCountForPID:pid] : 0;
    if (count < 2) {
        [self.focusPollTimer invalidate];
        self.focusPollTimer = nil;
        return;
    }
    if (self.focusPollTimer) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.focusPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                          repeats:YES
                                                            block:^(__unused NSTimer *timer) {
                                                                [weakSelf pollFocusedWindowIfChanged];
                                                            }];
    [[NSRunLoop mainRunLoop] addTimer:self.focusPollTimer forMode:NSRunLoopCommonModes];
    [self pollFocusedWindowIfChanged];
}
- (void)frontAppDidActivate:(NSNotification *)note {
    (void)note;
    self.lastPublishedFocusedWID = 0;
    self.lastPublishedFocusedPID = 0;
    [self updateFocusPollTimer];
    [self pollFocusedWindowIfChanged];
}
- (BOOL)axReadCocoaFrame:(NSRect *)outFrame fromElement:(AXUIElementRef)el {
    if (!el || !outFrame) {
        return NO;
    }
    CFTypeRef posRef = NULL;
    CFTypeRef sizeRef = NULL;
    CGPoint pos = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL havePos = NO;
    BOOL haveSize = NO;
    if (AXUIElementCopyAttributeValue(el, kAXPositionAttribute, &posRef) == kAXErrorSuccess && posRef) {
        havePos = AXValueGetValue((AXValueRef)posRef, (AXValueType)kAXValueCGPointType, &pos);
        CFRelease(posRef);
    }
    if (AXUIElementCopyAttributeValue(el, kAXSizeAttribute, &sizeRef) == kAXErrorSuccess && sizeRef) {
        haveSize = AXValueGetValue((AXValueRef)sizeRef, (AXValueType)kAXValueCGSizeType, &size);
        CFRelease(sizeRef);
    }
    if (!havePos || !haveSize || size.width < 2.0 || size.height < 2.0) {
        return NO;
    }
    NSRect main = NSScreen.mainScreen.frame;
    *outFrame = NSMakeRect(pos.x, NSMaxY(main) - pos.y - size.height, size.width, size.height);
    return YES;
}
- (NSScreen *)screenForCocoaBounds:(CGRect)bounds {
    NSScreen *best = nil;
    CGFloat bestArea = -1.0;
    for (NSScreen *screen in NSScreen.screens) {
        CGRect inter = CGRectIntersection(bounds, NSRectToCGRect(screen.frame));
        if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) {
            continue;
        }
        CGFloat area = inter.size.width * inter.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = screen;
        }
    }
    return best;
}
- (void)republishSnapshotWindows:(NSArray<MLTaskbarWindowInfo *> *)windows {
    NSMutableSet<NSString *> *withWindows = [NSMutableSet set];
    for (MLTaskbarWindowInfo *w in windows) {
        if (w.path.length > 0) {
            [withWindows addObject:w.path];
        }
    }
    NSArray<NSString *> *runningPaths = self.snapshot.runningAppPaths ?: [self orderedRunningPaths];
    MLRunningAppsSnapshot *snap = [[MLRunningAppsSnapshot alloc] init];
    snap.runningAppPaths = runningPaths;
    snap.pathsWithVisibleWindows = [withWindows copy];
    snap.windows = windows;
    snap.pidToPath = [self.pidPathMap copy];
    NSString *fp = [self fingerprintForPaths:runningPaths windows:windows];
    if ([fp isEqualToString:self.lastFingerprint]) {
        self.snapshot = snap;
        return;
    }
    [self publishSnapshot:snap fingerprint:fp];
}
- (void)optimisticRemoveWindowElement:(AXUIElementRef)el {
    CGWindowID wid = [self cgWindowIDFromAXElement:el];
    if (wid == 0) {
        return;
    }
    if ([self.softState isSoftHiddenWindowID:wid]) {
        return;
    }
    [self.lastSeenWindows removeObjectForKey:@(wid)];

    NSArray<MLTaskbarWindowInfo *> *prev = self.snapshot.windows ?: @[];
    NSMutableArray<MLTaskbarWindowInfo *> *next = [NSMutableArray arrayWithCapacity:prev.count];
    BOOL removed = NO;
    for (MLTaskbarWindowInfo *w in prev) {
        if (w.windowID == wid) {
            removed = YES;
            continue;
        }
        [next addObject:w];
    }
    if (removed) {
        [self republishSnapshotWindows:next];
    }
}
- (void)optimisticUpdateBoundsFromElement:(AXUIElementRef)el {
    CGWindowID wid = [self cgWindowIDFromAXElement:el];
    if (wid == 0 || [self.softState isSoftHiddenWindowID:wid]) {
        return;
    }
    NSRect cocoa = NSZeroRect;
    if (![self axReadCocoaFrame:&cocoa fromElement:el]) {
        return;
    }
    CGRect bounds = NSRectToCGRect(cocoa);
    MLTaskbarWindowInfo *cached = self.lastSeenWindows[@(wid)];
    CGRect oldBounds = cached ? cached.bounds : CGRectZero;
    if (cached && ![self.softState isSoftHiddenWindowID:wid]) {
        cached.bounds = bounds;
    }

    NSScreen *oldScreen = [self screenForCocoaBounds:oldBounds];
    NSScreen *newScreen = [self screenForCocoaBounds:bounds];
    BOOL screenChanged = (oldScreen != newScreen);

    NSArray<MLTaskbarWindowInfo *> *prev = self.snapshot.windows ?: @[];
    NSMutableArray<MLTaskbarWindowInfo *> *next = [NSMutableArray arrayWithCapacity:prev.count];
    BOOL changed = NO;
    for (MLTaskbarWindowInfo *w in prev) {
        if (w.windowID == wid) {
            MLTaskbarWindowInfo *copy = [self copyWindowInfo:w minimized:w.minimized];
            copy.bounds = bounds;
            [next addObject:copy];
            changed = YES;
        } else {
            [next addObject:w];
        }
    }
    /* Only push UI immediately when the owning display changes (cross-screen drag). */
    if (changed && screenChanged) {
        [self republishSnapshotWindows:next];
    }
}
- (void)optimisticUpdateTitleFromElement:(AXUIElementRef)el {
    CGWindowID wid = [self cgWindowIDFromAXElement:el];
    if (wid == 0) {
        return;
    }
    CFTypeRef titleRef = NULL;
    NSString *title = nil;
    if (AXUIElementCopyAttributeValue(el, kAXTitleAttribute, &titleRef) == kAXErrorSuccess && titleRef) {
        if (CFGetTypeID(titleRef) == CFStringGetTypeID()) {
            title = (__bridge NSString *)titleRef;
        }
        CFRelease(titleRef);
    }
    if (title.length == 0) {
        return;
    }
    pid_t pid = 0;
    AXUIElementGetPid(el, &pid);
    NSString *appName = [self appDisplayNameForPid:pid path:self.pidPathMap[@(pid)]];
    title = [self truncateTitle:[self preferredTaskTitleFromWindowTitle:title appName:appName]];
    if (title.length == 0) {
        return;
    }

    MLTaskbarWindowInfo *cached = self.lastSeenWindows[@(wid)];
    if (cached) {
        cached.title = title;
    }

    NSArray<MLTaskbarWindowInfo *> *prev = self.snapshot.windows ?: @[];
    NSMutableArray<MLTaskbarWindowInfo *> *next = [NSMutableArray arrayWithCapacity:prev.count];
    BOOL changed = NO;
    for (MLTaskbarWindowInfo *w in prev) {
        if (w.windowID == wid && ![w.title isEqualToString:title]) {
            MLTaskbarWindowInfo *copy = [self copyWindowInfo:w minimized:w.minimized];
            copy.title = title;
            [next addObject:copy];
            changed = YES;
        } else {
            [next addObject:w];
        }
    }
    if (changed) {
        [self republishSnapshotWindows:next];
    }
}
- (NSString *)computeWindowCensusToken {
    return [self.windowCensus computeTokenSkippingSoftHidden:self.softState.softHiddenWindowIDs];
}
- (void)censusTick {
    @autoreleasepool {
        if (!self.running) {
            return;
        }
        NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
        if (self.censusBoostUntil > 0 && now >= self.censusBoostUntil) {
            self.censusBoostUntil = 0;
            [self rescheduleCensusTimer];
        }

        [self.windowCensus refreshWindowLists];
        NSString *token = [self computeWindowCensusToken];
        if ([token isEqualToString:self.lastCensusToken ?: @""]) {
            return;
        }
        self.lastCensusToken = token;
        /* Burst to 12Hz for ~2s after CG sees a structural change. */
        self.censusBoostUntil = now + 2.0;
        [self rescheduleCensusTimer];
        /* CG already saw the change — refresh taskbar without waiting for AX. */
        [self pollWindowsWithOptions:MLPollOptionsFast];
    }
}
- (void)rescheduleCensusTimer {
    if (!self.running) {
        return;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    BOOL boost = (self.censusBoostUntil > now);
    NSTimeInterval interval;
    if (self.hotCornerProximityActive || self.overlayVisibleThrottle) {
        /* Yield main thread near hot corner / while overlay open (Z4/Z7). */
        interval = 1.0;
    } else {
        interval = boost ? (1.0 / 12.0) : (1.0 / 4.0);
    }
    if (self.censusTimer && fabs(self.censusTimer.timeInterval - interval) < 0.001) {
        return;
    }
    [self.censusTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.censusTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                        repeats:YES
                                                          block:^(__unused NSTimer *timer) {
                                                              @autoreleasepool {
                                                                  [weakSelf censusTick];
                                                              }
                                                          }];
    [[NSRunLoop mainRunLoop] addTimer:self.censusTimer forMode:NSRunLoopCommonModes];
}

- (void)setHotCornerProximityActive:(BOOL)active {
    if (_hotCornerProximityActive == active) {
        return;
    }
    _hotCornerProximityActive = active;
    if (!self.running) {
        return;
    }
    [self rescheduleCensusTimer];
    [self updateFocusPollTimer];
}

- (void)setOverlayVisible:(BOOL)visible {
    if (_overlayVisibleThrottle == visible) {
        return;
    }
    _overlayVisibleThrottle = visible;
    if (!self.running) {
        return;
    }
    [self rescheduleCensusTimer];
    [self updateFocusPollTimer];
    /* Slow full poll while overlay is up; restore config interval when hiding. */
    if (visible) {
        [self.pollTimer invalidate];
        __weak typeof(self) weakSelf = self;
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                         repeats:YES
                                                           block:^(__unused NSTimer *timer) {
                                                               @autoreleasepool {
                                                                   [weakSelf syncAXWindowObservers];
                                                                   [weakSelf pollWindows];
                                                               }
                                                           }];
        [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
    } else {
        [self applyWindowPollInterval:self.windowPollInterval];
    }
}
- (void)start {
    if (self.running) {
        return;
    }
    self.running = YES;
    self.axRegistry.active = YES;

    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc addObserver:self
           selector:@selector(appDidLaunch:)
               name:NSWorkspaceDidLaunchApplicationNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(appDidTerminate:)
               name:NSWorkspaceDidTerminateApplicationNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(frontAppDidActivate:)
               name:NSWorkspaceDidActivateApplicationNotification
             object:nil];

    [self rebuildPidMapFromWorkspace];
    [self syncAXWindowObservers];
    [self.windowCensus refreshWindowLists];
    [self pollWindows];

    self.censusBoostUntil = 0;
    /* Idle ~4 Hz CG census; bursts to 12 Hz for 2s after token change. */
    [self rescheduleCensusTimer];

    /* Slow full poll: titles / AX ghost cleanup / observer sync. */
    NSTimeInterval interval = self.windowPollInterval > 0.2 ? self.windowPollInterval : 1.0;
    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                     repeats:YES
                                                       block:^(__unused NSTimer *timer) {
                                                           @autoreleasepool {
                                                               [weakSelf syncAXWindowObservers];
                                                               [weakSelf pollWindows];
                                                           }
                                                       }];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}
- (void)applyWindowPollInterval:(NSTimeInterval)seconds {
    if (seconds < 0.5) {
        seconds = 0.5;
    }
    if (seconds > 5.0) {
        seconds = 5.0;
    }
    self.windowPollInterval = seconds;
    if (!self.running) {
        return;
    }
    [self.pollTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:seconds
                                                     repeats:YES
                                                       block:^(__unused NSTimer *timer) {
                                                           @autoreleasepool {
                                                               [weakSelf syncAXWindowObservers];
                                                               [weakSelf pollWindows];
                                                           }
                                                       }];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}
- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    self.axRegistry.active = NO;
    [self.censusTimer invalidate];
    self.censusTimer = nil;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.focusPollTimer invalidate];
    self.focusPollTimer = nil;
    self.lastPublishedFocusedWID = 0;
    self.lastPublishedFocusedPID = 0;
    self.censusBoostUntil = 0;
    self.lastCensusToken = nil;
    [self endPollAXWindowsCache];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self removeAllAXWatches];
    self.axStructuralPollPending = NO;
    self.axGeometryPollPending = NO;
    self.snapshot = [self emptySnapshot];
    self.lastFingerprint = nil;
    [self.pidPathMap removeAllObjects];
    [self.lastSeenWindows removeAllObjects];
    [self.softState removeAll];
    self.nextSeenOrder = 1;
}
- (void)pollNow {
    [self pollWindows];
}
- (CGWindowID)rememberBounds:(CGRect)bounds
                      forPID:(pid_t)pid
                       title:(NSString *)title
                    windowID:(CGWindowID)knownWindowID {
    if (pid <= 0 || CGRectIsEmpty(bounds)) {
        return 0;
    }
    NSString *path = self.pidPathMap[@(pid)];
    if (path.length == 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        path = app.bundleURL.path;
        if (path.length > 0) {
            self.pidPathMap[@(pid)] = path;
        }
    }

    CGWindowID wid = knownWindowID;
    MLTaskbarWindowInfo *existing = (wid != 0) ? self.lastSeenWindows[@(wid)] : nil;

    if (wid == 0) {
        for (MLTaskbarWindowInfo *seen in self.lastSeenWindows.allValues) {
            if (seen.pid != pid) {
                continue;
            }
            if (title.length == 0 || seen.title.length == 0 ||
                [seen.title isEqualToString:title] ||
                [seen.title hasPrefix:title ?: @""] || [title hasPrefix:seen.title ?: @""]) {
                existing = seen;
                wid = seen.windowID;
                break;
            }
        }
    }

    if (wid == 0) {
        /* bounds are Cocoa; CG list is Quartz. */
        CGRect quartzHint = [MLScreenGeometry quartzBoundsFromCocoaRect:NSRectFromCGRect(bounds)];
        CFArrayRef list = [self.windowCensus cachedOnScreenWindowListRefreshingIfNeeded:YES];
        if (list) {
            CFIndex count = CFArrayGetCount(list);
            CGFloat bestArea = -1;
            for (CFIndex i = 0; i < count; i++) {
                CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
                CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
                pid_t wpid = 0;
                if (pidRef) {
                    CFNumberGetValue(pidRef, kCFNumberIntType, &wpid);
                }
                if (wpid != pid) {
                    continue;
                }
                CGRect b = CGRectZero;
                CFDictionaryRef bd = CFDictionaryGetValue(info, kCGWindowBounds);
                if (!bd || !CGRectMakeWithDictionaryRepresentation(bd, &b)) {
                    continue;
                }
                CGRect inter = CGRectIntersection(b, quartzHint);
                CGFloat area = CGRectIsNull(inter) ? 0 : inter.size.width * inter.size.height;
                if (area > bestArea) {
                    bestArea = area;
                    CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
                    if (winRef) {
                        CFNumberGetValue(winRef, kCFNumberIntType, &wid);
                    }
                }
            }
        }
        if (wid != 0) {
            existing = self.lastSeenWindows[@(wid)];
        }
    }

    if (wid == 0) {
        return 0;
    }

    MLTaskbarWindowInfo *byWid = self.lastSeenWindows[@(wid)];
    if (!existing) {
        existing = byWid;
    }
    NSUInteger keepOrder = 0;
    if (existing && existing.seenOrder > 0) {
        keepOrder = existing.seenOrder;
    } else if (byWid && byWid.seenOrder > 0) {
        keepOrder = byWid.seenOrder;
    }

    MLTaskbarWindowInfo *stored = existing ? [self copyWindowInfo:existing minimized:NO]
                                           : [[MLTaskbarWindowInfo alloc] init];
    stored.path = path.length > 0 ? path : stored.path;
    stored.pid = pid;
    stored.windowID = wid;
    stored.title = [self truncateTitle:title ?: (stored.title ?: @"")];
    stored.bounds = bounds; /* Cocoa from AX */
    stored.minimized = NO;
    stored.seenOrder = keepOrder > 0 ? keepOrder : self.nextSeenOrder++;
    self.lastSeenWindows[@(wid)] = stored;
    return wid;
}
- (void)markSoftHiddenWindowID:(CGWindowID)windowID
                           pid:(pid_t)pid
                          path:(NSString *)path
                         title:(NSString *)title
                 restoreFrame:(NSRect)restoreFrameCocoa
                     screenID:(NSNumber *)screenID
                     axWindow:(AXUIElementRef)axWindow {
    NSUInteger order = 0;
    MLTaskbarWindowInfo *seen = self.lastSeenWindows[@(windowID)];
    if (seen.seenOrder > 0) {
        order = seen.seenOrder;
    }
    if (path.length == 0) {
        path = self.pidPathMap[@(pid)] ?: seen.path;
    }
    [self.softState markSoftHiddenWindowID:windowID
                                       pid:pid
                                      path:path
                                     title:title
                             restoreFrame:restoreFrameCocoa
                                 screenID:screenID
                               hideMethod:MLWindowHideMethodNone
                                seenOrder:order
                                 axWindow:axWindow];
    /* Keep lastSeen so reinject always has a path. */
    if (!seen && path.length > 0) {
        MLTaskbarWindowInfo *w = [[MLTaskbarWindowInfo alloc] init];
        w.windowID = windowID;
        w.pid = pid;
        w.path = path;
        w.title = [self truncateTitle:title ?: @""];
        w.bounds = NSRectToCGRect(restoreFrameCocoa);
        w.minimized = YES;
        w.seenOrder = order > 0 ? order : self.nextSeenOrder++;
        self.lastSeenWindows[@(windowID)] = w;
    }
}
- (void)markSoftMinimizedWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return;
    }
    MLTaskbarWindowInfo *seen = self.lastSeenWindows[@(windowID)];
    NSRect frame = [self.softState restoreFrameForWindowID:windowID];
    if (frame.size.width < 2.0 && seen) {
        /* lastSeen may be Cocoa (from remember) or Quartz — prefer soft record. */
        frame = NSRectFromCGRect(seen.bounds);
    }
    MLWindowSoftRecord *rec = [self.softState recordForWindowID:windowID];
    [self markSoftHiddenWindowID:windowID
                             pid:seen.pid
                            path:seen.path
                           title:seen.title
                   restoreFrame:frame
                       screenID:nil
                       axWindow:rec.axWindow];
}
- (BOOL)isSoftMinimizedWindowID:(CGWindowID)windowID {
    return [self.softState isSoftHiddenWindowID:windowID];
}

- (NSUInteger)lastSeenWindowCount {
    return self.lastSeenWindows.count;
}

- (NSUInteger)softHiddenCount {
    return self.softState.softHiddenWindowIDs.count;
}

- (NSUInteger)axWatchCount {
    return self.axRegistry.watchCount;
}

- (void)applySeenOrderByWindowID:(NSDictionary<NSNumber *, NSNumber *> *)orderByWid {
    if (orderByWid.count == 0) {
        return;
    }
    for (NSNumber *key in orderByWid) {
        NSUInteger ord = orderByWid[key].unsignedIntegerValue;
        if (ord == 0) {
            continue;
        }
        MLTaskbarWindowInfo *seen = self.lastSeenWindows[key];
        if (seen) {
            seen.seenOrder = ord;
        }
        if (ord >= self.nextSeenOrder) {
            self.nextSeenOrder = ord + 1;
        }
    }
    NSArray<MLTaskbarWindowInfo *> *windows = self.snapshot.windows;
    if (windows.count == 0) {
        return;
    }
    NSMutableArray<MLTaskbarWindowInfo *> *updated = [NSMutableArray arrayWithCapacity:windows.count];
    BOOL changed = NO;
    for (MLTaskbarWindowInfo *w in windows) {
        if (w.windowID == 0) {
            [updated addObject:w];
            continue;
        }
        NSNumber *ordNum = orderByWid[@(w.windowID)];
        if (!ordNum || ordNum.unsignedIntegerValue == 0) {
            [updated addObject:w];
            continue;
        }
        if (w.seenOrder != ordNum.unsignedIntegerValue) {
            MLTaskbarWindowInfo *copy = [self copyWindowInfo:w minimized:w.minimized];
            copy.seenOrder = ordNum.unsignedIntegerValue;
            [updated addObject:copy];
            changed = YES;
        } else {
            [updated addObject:w];
        }
    }
    if (changed) {
        self.snapshot.windows = [updated copy];
    }
}

@end
