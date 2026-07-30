#import "MLRunningAppsMonitor.h"

#import <ApplicationServices/ApplicationServices.h>

NSNotificationName const MLRunningAppsDidChangeNotification = @"MLRunningAppsDidChangeNotification";

@implementation MLTaskbarWindowInfo
@end

@interface MLRunningAppsSnapshot ()
@property (nonatomic, copy, readwrite) NSArray<NSString *> *runningAppPaths;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *pathsWithVisibleWindows;
@property (nonatomic, copy, readwrite) NSArray<MLTaskbarWindowInfo *> *windows;
@property (nonatomic, copy, readwrite) NSDictionary<NSNumber *, NSString *> *pidToPath;
@end

@implementation MLRunningAppsSnapshot
@end

@interface MLRunningAppsMonitor ()
@property (nonatomic, strong, readwrite) MLRunningAppsSnapshot *snapshot;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *pidPathMap;
/** Last on-screen task windows, keyed by CGWindowID — used to keep minimized items on the right display. */
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, MLTaskbarWindowInfo *> *lastSeenWindows;
@property (nonatomic, assign) NSUInteger nextSeenOrder;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, copy) NSString *selfBundleID;
@property (nonatomic, copy) NSString *lastFingerprint;
@end

@implementation MLRunningAppsMonitor

- (instancetype)init {
    self = [super init];
    if (self) {
        _windowPollInterval = 1.0;
        _maxWindowEntries = MLTaskbarMaxWindowEntries;
        _titleMaxChars = MLTaskbarTitleMaxChars;
        _pidPathMap = [NSMutableDictionary dictionary];
        _lastSeenWindows = [NSMutableDictionary dictionary];
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

- (BOOL)isIgnoredOwnerName:(NSString *)owner {
    if (owner.length == 0) {
        return NO;
    }
    static NSSet<NSString *> *ignored;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ignored = [NSSet setWithArray:@[
            @"Window Server",
            @"Dock",
            @"SystemUIServer",
            @"Control Center",
            @"Notification Center",
            @"Spotlight",
            @"loginwindow",
        ]];
    });
    return [ignored containsObject:owner];
}

- (MLTaskbarWindowInfo *)windowInfoFromCGDict:(CFDictionaryRef)info {
    if (!info) {
        return nil;
    }

    CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
    int layer = 0;
    if (layerRef) {
        CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
    }
    if (layer != 0) {
        return nil;
    }

    CGRect bounds = CGRectZero;
    CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
    if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)) {
        return nil;
    }
    /* Drop tiny chrome / status scraps — not real taskbar windows */
    if (bounds.size.width < 100.0 || bounds.size.height < 80.0) {
        return nil;
    }

    CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
    if (alphaRef) {
        double alpha = 1.0;
        CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
        if (alpha < 0.1) {
            return nil;
        }
    }

    CFStringRef ownerNameRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
    if (ownerNameRef) {
        NSString *ownerName = (__bridge NSString *)ownerNameRef;
        if ([self isIgnoredOwnerName:ownerName]) {
            return nil;
        }
    }

    CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
    pid_t pid = 0;
    if (pidRef) {
        CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
    }
    if (pid <= 0) {
        return nil;
    }

    NSString *path = self.pidPathMap[@(pid)];
    if (path.length == 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (![self shouldTrackApplication:app]) {
            return nil;
        }
        path = app.bundleURL.path;
        if (path.length > 0) {
            self.pidPathMap[@(pid)] = path;
        }
    }
    if (path.length == 0) {
        return nil;
    }

    CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
    CGWindowID wid = 0;
    if (winRef) {
        CFNumberGetValue(winRef, kCFNumberIntType, &wid);
    }

    NSString *title = @"";
    CFStringRef nameRef = CFDictionaryGetValue(info, kCGWindowName);
    if (nameRef) {
        title = [self truncateTitle:(__bridge NSString *)nameRef];
    }
    /* Nameless small-ish panels are rarely useful; large nameless windows still count
       (titles often empty without Screen Recording). */
    if (title.length == 0 && (bounds.size.width < 200.0 || bounds.size.height < 150.0)) {
        return nil;
    }

    MLTaskbarWindowInfo *w = [[MLTaskbarWindowInfo alloc] init];
    w.path = path;
    w.pid = pid;
    w.windowID = wid;
    w.title = title;
    w.bundleID = nil;
    w.bounds = bounds;
    w.minimized = NO;
    return w;
}

- (void)appendOnScreenWindowsFromList:(CFArrayRef)list
                                 into:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                        seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                          withWindows:(NSMutableSet<NSString *> *)withWindows
                                  cap:(NSUInteger)cap {
    if (!list) {
        return;
    }
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count && windows.count < cap; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        MLTaskbarWindowInfo *w = [self windowInfoFromCGDict:info];
        if (!w) {
            continue;
        }
        if (w.windowID != 0 && [seen containsObject:@(w.windowID)]) {
            continue;
        }
        if (w.windowID != 0) {
            [seen addObject:@(w.windowID)];
        }
        [windows addObject:w];
        if (w.path.length > 0) {
            [withWindows addObject:w.path];
        }
    }
}

- (MLTaskbarWindowInfo *)copyWindowInfo:(MLTaskbarWindowInfo *)src minimized:(BOOL)minimized {
    MLTaskbarWindowInfo *w = [[MLTaskbarWindowInfo alloc] init];
    w.path = src.path;
    w.bundleID = src.bundleID;
    w.pid = src.pid;
    w.windowID = src.windowID;
    w.title = src.title;
    w.bounds = src.bounds;
    w.minimized = minimized;
    w.seenOrder = src.seenOrder;
    return w;
}

- (BOOL)title:(NSString *)a matchesTitle:(NSString *)b {
    if (a.length == 0 && b.length == 0) {
        return YES;
    }
    if (a.length == 0 || b.length == 0) {
        return NO;
    }
    if ([a isEqualToString:b]) {
        return YES;
    }
    return [a hasPrefix:b] || [b hasPrefix:a];
}

- (NSString *)dedupeKeyForWindow:(MLTaskbarWindowInfo *)w {
    if (w.windowID != 0) {
        return [NSString stringWithFormat:@"id:%u", (unsigned)w.windowID];
    }
    return [NSString stringWithFormat:@"p:%d|%@|%@", (int)w.pid, w.path ?: @"", w.title ?: @""];
}

/** One entry per window; prefer visible over minimized; keep earliest seenOrder. */
- (NSArray<MLTaskbarWindowInfo *> *)dedupeWindows:(NSArray<MLTaskbarWindowInfo *> *)windows {
    NSMutableDictionary<NSString *, MLTaskbarWindowInfo *> *byKey = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];

    for (MLTaskbarWindowInfo *w in windows) {
        if (!w) {
            continue;
        }
        NSString *key = [self dedupeKeyForWindow:w];
        /* Also collapse AX (windowID=0) onto a cached id entry with same path+title */
        if (w.windowID == 0 && w.path.length > 0) {
            for (MLTaskbarWindowInfo *seen in self.lastSeenWindows.allValues) {
                if (![seen.path isEqualToString:w.path]) {
                    continue;
                }
                if (![self title:seen.title matchesTitle:w.title] && w.title.length > 0 && seen.title.length > 0) {
                    continue;
                }
                if (seen.windowID != 0) {
                    key = [NSString stringWithFormat:@"id:%u", (unsigned)seen.windowID];
                    if (w.seenOrder == 0) {
                        w.seenOrder = seen.seenOrder;
                    }
                    if (CGRectIsEmpty(w.bounds) || CGRectEqualToRect(w.bounds, CGRectZero)) {
                        w.bounds = seen.bounds;
                    }
                    w.windowID = seen.windowID;
                    break;
                }
            }
        }

        MLTaskbarWindowInfo *existing = byKey[key];
        if (!existing) {
            byKey[key] = w;
            [order addObject:key];
            continue;
        }
        /* Prefer non-minimized; otherwise keep existing (stable). */
        if (existing.minimized && !w.minimized) {
            NSUInteger ord = existing.seenOrder > 0 ? existing.seenOrder : w.seenOrder;
            w.seenOrder = ord;
            byKey[key] = w;
        } else if (existing.seenOrder == 0 && w.seenOrder > 0) {
            existing.seenOrder = w.seenOrder;
        } else if (w.seenOrder > 0 && existing.seenOrder > 0) {
            existing.seenOrder = MIN(existing.seenOrder, w.seenOrder);
        }
    }

    NSMutableArray<MLTaskbarWindowInfo *> *out = [NSMutableArray arrayWithCapacity:order.count];
    for (NSString *key in order) {
        MLTaskbarWindowInfo *w = byKey[key];
        if (w) {
            [out addObject:w];
        }
    }
    return out;
}

- (MLTaskbarWindowInfo *)cachedWindowMatchingPath:(NSString *)path title:(NSString *)title {
    MLTaskbarWindowInfo *best = nil;
    for (MLTaskbarWindowInfo *seen in self.lastSeenWindows.allValues) {
        if (path.length > 0 && ![seen.path isEqualToString:path]) {
            continue;
        }
        if (title.length == 0) {
            if (!best) {
                best = seen;
            }
            continue;
        }
        if ([seen.title isEqualToString:title] ||
            (seen.title.length > 0 && [title hasPrefix:seen.title]) ||
            (title.length > 0 && [seen.title hasPrefix:title])) {
            return seen;
        }
        if (!best) {
            best = seen;
        }
    }
    return best;
}

- (void)rememberOnScreenWindows:(NSArray<MLTaskbarWindowInfo *> *)windows {
    for (MLTaskbarWindowInfo *w in windows) {
        if (w.minimized || w.windowID == 0) {
            continue;
        }
        NSNumber *key = @(w.windowID);
        MLTaskbarWindowInfo *prev = self.lastSeenWindows[key];
        MLTaskbarWindowInfo *stored = [self copyWindowInfo:w minimized:NO];
        if (prev && prev.seenOrder > 0) {
            stored.seenOrder = prev.seenOrder;
        } else if (w.seenOrder > 0) {
            stored.seenOrder = w.seenOrder;
        } else {
            stored.seenOrder = self.nextSeenOrder++;
        }
        w.seenOrder = stored.seenOrder;
        self.lastSeenWindows[key] = stored;
    }
    NSArray<NSNumber *> *keys = self.lastSeenWindows.allKeys;
    for (NSNumber *key in keys) {
        MLTaskbarWindowInfo *seen = self.lastSeenWindows[key];
        if (seen.pid > 0 && !self.pidPathMap[@(seen.pid)]) {
            [self.lastSeenWindows removeObjectForKey:key];
        }
    }
}

/** Off-screen CG windows that we previously showed on-screen → real minimized tasks. */
- (void)appendMinimizedFromCacheAndOffscreenList:(CFArrayRef)all
                                            into:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                                   seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                                     withWindows:(NSMutableSet<NSString *> *)withWindows
                                             cap:(NSUInteger)cap {
    if (!all || self.lastSeenWindows.count == 0) {
        return;
    }

    NSMutableSet<NSNumber *> *offscreenIDs = [NSMutableSet set];
    CFIndex count = CFArrayGetCount(all);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(all, i);
        if (!info) {
            continue;
        }
        CFBooleanRef onScreenRef = CFDictionaryGetValue(info, kCGWindowIsOnscreen);
        if (onScreenRef && CFGetTypeID(onScreenRef) == CFBooleanGetTypeID() &&
            CFBooleanGetValue(onScreenRef)) {
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
        CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
        CGWindowID wid = 0;
        if (winRef) {
            CFNumberGetValue(winRef, kCFNumberIntType, &wid);
        }
        if (wid == 0) {
            continue;
        }
        [offscreenIDs addObject:@(wid)];
    }

    for (NSNumber *widNum in self.lastSeenWindows.allKeys) {
        if (windows.count >= cap) {
            break;
        }
        if ([seen containsObject:widNum]) {
            continue; /* still on-screen */
        }
        if (![offscreenIDs containsObject:widNum]) {
            continue; /* closed for real */
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[widNum];
        if (!cached || cached.path.length == 0) {
            continue;
        }
        if (cached.pid > 0 && !self.pidPathMap[@(cached.pid)]) {
            [self.lastSeenWindows removeObjectForKey:widNum];
            continue;
        }
        MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
        /* Keep last on-screen bounds so the item stays on the same display's taskbar. */
        [windows addObject:w];
        [seen addObject:widNum];
        [withWindows addObject:w.path];
    }
}

/** AX minimized as backup (Electron etc.); prefer cached bounds for screen affinity. */
- (void)appendMinimizedWindowsFromAccessibility:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                                    withWindows:(NSMutableSet<NSString *> *)withWindows
                                            cap:(NSUInteger)cap {
    if (!AXIsProcessTrusted()) {
        return;
    }

    CGRect fallbackBounds = NSRectToCGRect(NSScreen.mainScreen.frame);
    NSMutableSet<NSString *> *alreadyPathTitle = [NSMutableSet set];
    for (MLTaskbarWindowInfo *existing in windows) {
        if (existing.minimized) {
            [alreadyPathTitle addObject:[NSString stringWithFormat:@"%@\n%@", existing.path ?: @"", existing.title ?: @""]];
        }
    }

    NSArray<NSNumber *> *pids = self.pidPathMap.allKeys;
    for (NSNumber *pidNum in pids) {
        if (windows.count >= cap) {
            break;
        }
        pid_t pid = (pid_t)pidNum.intValue;
        NSString *path = self.pidPathMap[pidNum];
        if (path.length == 0 || pid <= 0) {
            continue;
        }

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
        for (CFIndex i = 0; i < count && windows.count < cap; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            CFTypeRef minRef = NULL;
            Boolean isMin = false;
            if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
                if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                    isMin = CFBooleanGetValue((CFBooleanRef)minRef);
                }
                CFRelease(minRef);
            }
            if (!isMin) {
                continue;
            }

            NSString *title = @"";
            CFTypeRef titleRef = NULL;
            if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &titleRef) == kAXErrorSuccess && titleRef) {
                if (CFGetTypeID(titleRef) == CFStringGetTypeID()) {
                    title = [self truncateTitle:(__bridge NSString *)titleRef];
                }
                CFRelease(titleRef);
            }

            NSString *dedupe = [NSString stringWithFormat:@"%@\n%@", path, title];
            if ([alreadyPathTitle containsObject:dedupe]) {
                continue;
            }

            MLTaskbarWindowInfo *cached = [self cachedWindowMatchingPath:path title:title];
            CGRect bounds = cached ? cached.bounds : fallbackBounds;
            CGWindowID wid = cached ? cached.windowID : 0;

            if (!cached) {
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
                if (havePos && haveSize && size.width >= 2.0 && size.height >= 2.0) {
                    bounds = CGRectMake(pos.x, pos.y, size.width, size.height);
                }
            }

            MLTaskbarWindowInfo *w = [[MLTaskbarWindowInfo alloc] init];
            w.path = path;
            w.pid = pid;
            w.windowID = wid;
            w.title = title.length > 0 ? title : (cached.title ?: @"");
            w.bounds = bounds;
            w.minimized = YES;
            w.seenOrder = cached && cached.seenOrder > 0 ? cached.seenOrder : self.nextSeenOrder++;
            [windows addObject:w];
            [alreadyPathTitle addObject:dedupe];
            [withWindows addObject:path];
        }

        CFRelease(windowsRef);
        CFRelease(appRef);
    }
}

- (BOOL)applicationPIDHasMinimizedWindow:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return NO;
    }
    AXUIElementRef appRef = AXUIElementCreateApplication(pid);
    if (!appRef) {
        return NO;
    }
    CFTypeRef windowsRef = NULL;
    BOOL found = NO;
    if (AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef) == kAXErrorSuccess &&
        windowsRef && CFGetTypeID(windowsRef) == CFArrayGetTypeID()) {
        CFArrayRef axWindows = (CFArrayRef)windowsRef;
        CFIndex count = CFArrayGetCount(axWindows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            CFTypeRef minRef = NULL;
            if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
                if (CFGetTypeID(minRef) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)minRef)) {
                    found = YES;
                }
                CFRelease(minRef);
            }
            if (found) {
                break;
            }
        }
    }
    if (windowsRef) {
        CFRelease(windowsRef);
    }
    CFRelease(appRef);
    return found;
}

/** Some apps (e.g. Electron) drop minimized windows from CG lists — keep cache if AX says minimized. */
- (void)appendMinimizedFromCacheWhenVanished:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                               seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                                 withWindows:(NSMutableSet<NSString *> *)withWindows
                                         cap:(NSUInteger)cap
                                    aliveIDs:(NSSet<NSNumber *> *)aliveIDs {
    for (NSNumber *widNum in self.lastSeenWindows.allKeys) {
        if (windows.count >= cap) {
            break;
        }
        if ([seen containsObject:widNum]) {
            continue;
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[widNum];
        if (!cached || cached.pid <= 0 || !self.pidPathMap[@(cached.pid)]) {
            continue;
        }
        /* Still present off-screen in CG — handled earlier */
        if ([aliveIDs containsObject:widNum]) {
            continue;
        }
        if (![self applicationPIDHasMinimizedWindow:cached.pid]) {
            continue;
        }
        MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
        [windows addObject:w];
        [seen addObject:widNum];
        if (w.path.length > 0) {
            [withWindows addObject:w.path];
        }
    }
}

- (void)pruneClosedCachedWindows:(NSSet<NSNumber *> *)aliveIDs {
    NSArray<NSNumber *> *keys = self.lastSeenWindows.allKeys;
    for (NSNumber *key in keys) {
        if ([aliveIDs containsObject:key]) {
            continue;
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[key];
        if (!cached || cached.pid <= 0 || !self.pidPathMap[@(cached.pid)]) {
            [self.lastSeenWindows removeObjectForKey:key];
            continue;
        }
        /* Keep cache while AX reports minimized so the item can stay on the bar. */
        if ([self applicationPIDHasMinimizedWindow:cached.pid]) {
            continue;
        }
        [self.lastSeenWindows removeObjectForKey:key];
    }
}

- (void)pollWindows {
    [self rebuildPidMapFromWorkspace];
    NSArray<NSString *> *runningPaths = [self orderedRunningPaths];

    NSMutableArray<MLTaskbarWindowInfo *> *windows = [NSMutableArray array];
    NSMutableSet<NSString *> *withWindows = [NSMutableSet set];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];

    NSUInteger screenCount = MAX(1u, (NSUInteger)NSScreen.screens.count);
    NSUInteger perScreen = self.maxWindowEntries > 0 ? self.maxWindowEntries : MLTaskbarMaxWindowEntries;
    NSUInteger cap = perScreen * screenCount;

    CFArrayRef onScreen = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                         kCGWindowListExcludeDesktopElements,
                                                     kCGNullWindowID);
    [self appendOnScreenWindowsFromList:onScreen
                                   into:windows
                          seenWindowIDs:seen
                            withWindows:withWindows
                                    cap:cap];
    if (onScreen) {
        CFRelease(onScreen);
    }

    [self rememberOnScreenWindows:windows];

    CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionAll |
                                                    kCGWindowListExcludeDesktopElements,
                                                kCGNullWindowID);
    [self appendMinimizedFromCacheAndOffscreenList:all
                                              into:windows
                                     seenWindowIDs:seen
                                       withWindows:withWindows
                                               cap:cap];

    NSMutableSet<NSNumber *> *aliveIDs = [NSMutableSet setWithSet:seen];
    if (all) {
        CFIndex count = CFArrayGetCount(all);
        for (CFIndex i = 0; i < count; i++) {
            CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(all, i);
            CFNumberRef winRef = info ? CFDictionaryGetValue(info, kCGWindowNumber) : NULL;
            CGWindowID wid = 0;
            if (winRef) {
                CFNumberGetValue(winRef, kCFNumberIntType, &wid);
            }
            if (wid != 0) {
                [aliveIDs addObject:@(wid)];
            }
        }
        CFRelease(all);
    }

    /* Electron-style: minimized window disappears from CG entirely. */
    [self appendMinimizedFromCacheWhenVanished:windows
                                 seenWindowIDs:seen
                                   withWindows:withWindows
                                           cap:cap
                                      aliveIDs:aliveIDs];

    /* AX backup when CG does not keep minimized window IDs (some Electron apps). */
    [self appendMinimizedWindowsFromAccessibility:windows withWindows:withWindows cap:cap];

    [self pruneClosedCachedWindows:aliveIDs];

    NSArray<MLTaskbarWindowInfo *> *deduped = [self dedupeWindows:windows];

    MLRunningAppsSnapshot *snap = [[MLRunningAppsSnapshot alloc] init];
    snap.runningAppPaths = runningPaths;
    snap.pathsWithVisibleWindows = [withWindows copy];
    snap.windows = deduped;
    snap.pidToPath = [self.pidPathMap copy];

    NSString *fp = [self fingerprintForPaths:runningPaths windows:deduped];
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
    }
    [self refreshRunningOnly];
}

- (void)appDidTerminate:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (app.processIdentifier > 0) {
        [self.pidPathMap removeObjectForKey:@(app.processIdentifier)];
    }
    [self refreshRunningOnly];
}

- (void)start {
    if (self.running) {
        return;
    }
    self.running = YES;

    NSNotificationCenter *nc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [nc addObserver:self
           selector:@selector(appDidLaunch:)
               name:NSWorkspaceDidLaunchApplicationNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(appDidTerminate:)
               name:NSWorkspaceDidTerminateApplicationNotification
             object:nil];

    [self rebuildPidMapFromWorkspace];
    [self pollWindows];

    NSTimeInterval interval = self.windowPollInterval > 0.2 ? self.windowPollInterval : 1.0;
    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                     repeats:YES
                                                       block:^(__unused NSTimer *timer) {
                                                           [weakSelf pollWindows];
                                                       }];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    self.snapshot = [self emptySnapshot];
    self.lastFingerprint = nil;
    [self.pidPathMap removeAllObjects];
    [self.lastSeenWindows removeAllObjects];
    self.nextSeenOrder = 1;
}

@end
