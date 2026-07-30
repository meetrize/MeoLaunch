#import "MLRunningAppsMonitor.h"

#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>

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
/** Windows hidden via CGSSetWindowAlpha(0) — stay on their screen's taskbar as minimized. */
@property (nonatomic, strong) NSMutableSet<NSNumber *> *softMinimizedWindowIDs;
/** Pre-minimize Cocoa frames; never overwritten by poll while custom-minimized. */
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *frozenRestoreFrames;
@property (nonatomic, assign) NSUInteger nextSeenOrder;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, copy) NSString *selfBundleID;
@property (nonatomic, copy) NSString *lastFingerprint;
/** pid → AXObserver watch; drives near-instant taskbar updates on close/min. */
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id> *axWatchByPid;
@property (nonatomic, assign) BOOL axStructuralPollPending;
@property (nonatomic, assign) BOOL axGeometryPollPending;
/** High-frequency CG census (no AX) — catches open/close/display-move without waiting for AX. */
@property (nonatomic, strong) NSTimer *censusTimer;
@property (nonatomic, copy) NSString *lastCensusToken;
@end

/** Per-process AXObserver (window create/destroy/miniaturize/title). */
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

enum {
    MLPollOptionNone = 0,
    MLPollOptionSkipPidRebuild = 1 << 0,
    MLPollOptionSkipTitleEnrich = 1 << 1,
    MLPollOptionSkipGhostSweep = 1 << 2,
    MLPollOptionSkipAXMinimizedBackup = 1 << 3,
};
typedef NSInteger MLPollOptions;

static const MLPollOptions MLPollOptionsFast =
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
        _softMinimizedWindowIDs = [NSMutableSet set];
        _frozenRestoreFrames = [NSMutableDictionary dictionary];
        _axWatchByPid = [NSMutableDictionary dictionary];
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
            MLTaskbarWindowInfo *prev = self.lastSeenWindows[@(w.windowID)];
            if (prev && prev.seenOrder > 0) {
                w.seenOrder = prev.seenOrder;
            }
            if (w.title.length == 0 && prev.title.length > 0) {
                w.title = prev.title;
            }
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

typedef AXError (*MLAXGetWindowFn)(AXUIElementRef, CGWindowID *);

static MLAXGetWindowFn MLResolvedAXGetWindow(void) {
    static MLAXGetWindowFn sFn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sFn = (MLAXGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    });
    return sFn;
}

- (NSString *)appDisplayNameForPid:(pid_t)pid path:(NSString *)path {
    if (pid > 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (app.localizedName.length > 0) {
            return app.localizedName;
        }
    }
    if (path.length > 0) {
        return path.lastPathComponent.stringByDeletingPathExtension;
    }
    return @"";
}

/** Empty or just the app name — needs AX document / tab title. */
- (BOOL)title:(NSString *)title isGenericForAppName:(NSString *)appName {
    if (title.length == 0) {
        return YES;
    }
    if (appName.length == 0) {
        return NO;
    }
    if ([title caseInsensitiveCompare:appName] == NSOrderedSame) {
        return YES;
    }
    /* "Google Chrome", "Cursor", "Code" etc. as sole title */
    return NO;
}

/**
 * Prefer the document/tab portion: strip trailing " - Google Chrome" / " — Cursor".
 * Keeps "file — project" for Cursor after removing the app suffix.
 */
- (NSString *)preferredTaskTitleFromWindowTitle:(NSString *)title appName:(NSString *)appName {
    if (title.length == 0) {
        return @"";
    }
    NSString *t = title;
    if (appName.length > 0) {
        for (NSString *sep in @[ @" — ", @" – ", @" - " ]) {
            NSString *suffix = [sep stringByAppendingString:appName];
            if ([t hasSuffix:suffix] && t.length > suffix.length) {
                t = [t substringToIndex:t.length - suffix.length];
                break;
            }
        }
    }
    return t;
}

/**
 * When CGWindowName is blank (common without Screen Recording), read kAXTitle.
 * Batched per PID. Used for Cursor editor titles and browser current-tab titles.
 */
- (void)enrichTitlesFromAccessibility:(NSMutableArray<MLTaskbarWindowInfo *> *)windows {
    if (!windows.count || !AXIsProcessTrusted()) {
        return;
    }
    MLAXGetWindowFn getWid = MLResolvedAXGetWindow();
    if (!getWid) {
        return;
    }

    NSMutableDictionary<NSNumber *, NSMutableArray<MLTaskbarWindowInfo *> *> *needByPid =
        [NSMutableDictionary dictionary];
    for (MLTaskbarWindowInfo *w in windows) {
        if (w.windowID == 0 || w.pid <= 0) {
            continue;
        }
        NSString *appName = [self appDisplayNameForPid:w.pid path:w.path];
        if (![self title:w.title isGenericForAppName:appName]) {
            continue;
        }
        NSNumber *key = @(w.pid);
        NSMutableArray<MLTaskbarWindowInfo *> *arr = needByPid[key];
        if (!arr) {
            arr = [NSMutableArray array];
            needByPid[key] = arr;
        }
        [arr addObject:w];
    }
    if (needByPid.count == 0) {
        return;
    }

    for (NSNumber *pidNum in needByPid) {
        pid_t pid = (pid_t)pidNum.intValue;
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
        NSMutableDictionary<NSNumber *, NSString *> *titleByWid = [NSMutableDictionary dictionary];
        CFIndex count = CFArrayGetCount(axWindows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            CGWindowID wid = 0;
            if (getWid(win, &wid) != kAXErrorSuccess || wid == 0) {
                continue;
            }
            CFTypeRef titleRef = NULL;
            if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &titleRef) != kAXErrorSuccess ||
                !titleRef) {
                continue;
            }
            if (CFGetTypeID(titleRef) == CFStringGetTypeID()) {
                NSString *raw = [(__bridge NSString *)titleRef copy];
                if (raw.length > 0) {
                    titleByWid[@(wid)] = raw;
                }
            }
            CFRelease(titleRef);
        }
        CFRelease(windowsRef);
        CFRelease(appRef);

        NSArray<MLTaskbarWindowInfo *> *need = needByPid[pidNum];
        NSString *appName = [self appDisplayNameForPid:pid path:need.firstObject.path];
        for (MLTaskbarWindowInfo *w in need) {
            NSString *ax = titleByWid[@(w.windowID)];
            if (ax.length == 0) {
                continue;
            }
            NSString *doc = [self preferredTaskTitleFromWindowTitle:ax appName:appName];
            if (doc.length == 0) {
                doc = ax;
            }
            w.title = [self truncateTitle:doc];
            MLTaskbarWindowInfo *cached = self.lastSeenWindows[@(w.windowID)];
            if (cached) {
                cached.title = w.title;
            }
        }
    }
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
        /* While custom-minimized, keep the frozen pre-minimize frame (screen + restore). */
        NSValue *frozen = self.frozenRestoreFrames[key];
        if (frozen) {
            continue;
        }
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
            [self.frozenRestoreFrames removeObjectForKey:key];
            [self.softMinimizedWindowIDs removeObject:key];
        }
    }
}

/** Off-screen CG windows that we previously showed on-screen → only real minimizes.
 * WeChat (and similar) often leave closed chats in the CG list as off-screen ghosts —
 * those must NOT stay on the taskbar unless AX says this windowID is minimized (or soft-min). */
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

    NSMutableDictionary<NSNumber *, NSSet<NSNumber *> *> *axMinByPid = [NSMutableDictionary dictionary];

    for (NSNumber *widNum in self.lastSeenWindows.allKeys) {
        if (windows.count >= cap) {
            break;
        }
        if ([seen containsObject:widNum]) {
            continue; /* still on-screen */
        }
        if (![offscreenIDs containsObject:widNum]) {
            continue; /* not in CG off-screen list */
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[widNum];
        if (!cached || cached.path.length == 0) {
            continue;
        }
        if (cached.pid > 0 && !self.pidPathMap[@(cached.pid)]) {
            [self.lastSeenWindows removeObjectForKey:widNum];
            continue;
        }

        if ([self.softMinimizedWindowIDs containsObject:widNum]) {
            MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
            NSValue *frozen = self.frozenRestoreFrames[widNum];
            if (frozen) {
                w.bounds = NSRectToCGRect(frozen.rectValue);
            }
            [windows addObject:w];
            [seen addObject:widNum];
            [withWindows addObject:w.path];
            continue;
        }

        NSNumber *pidKey = @(cached.pid);
        NSSet<NSNumber *> *axMin = axMinByPid[pidKey];
        if (!axMin) {
            axMin = [self axMinimizedWindowIDsForPID:cached.pid];
            axMinByPid[pidKey] = axMin ?: [NSSet set];
            axMin = axMinByPid[pidKey];
        }
        if (![axMin containsObject:widNum]) {
            /* Off-screen ghost (closed WeChat chat, etc.) — drop. */
            continue;
        }

        MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
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

            CGWindowID wid = 0;
            MLAXGetWindowFn getWid = MLResolvedAXGetWindow();
            if (getWid) {
                getWid(win, &wid);
            }
            /* Prefer cache by real window id — never glue a closed chat's stale id onto another window. */
            MLTaskbarWindowInfo *cached = (wid != 0) ? self.lastSeenWindows[@(wid)] : nil;
            if (!cached) {
                cached = [self cachedWindowMatchingPath:path title:title];
                /* Title-only match is for bounds hint only; don't reuse a different windowID. */
                if (cached && wid != 0 && cached.windowID != 0 && cached.windowID != wid) {
                    cached = nil;
                }
            }
            CGRect bounds = cached ? cached.bounds : fallbackBounds;
            if (wid == 0 && cached) {
                wid = cached.windowID;
            }

            if ((!cached || CGRectIsEmpty(bounds)) && (CGRectEqualToRect(bounds, fallbackBounds) || !cached)) {
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
                    NSRect main = NSScreen.mainScreen.frame;
                    CGFloat cocoaY = NSMaxY(main) - pos.y - size.height;
                    bounds = CGRectMake(pos.x, cocoaY, size.width, size.height);
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

/**
 * All CGWindowIDs exposed via AX for this PID (minimized or not).
 * Empty set means "unknown / unsupported" — callers must not treat that as "no windows".
 */
- (NSSet<NSNumber *> *)axAllWindowIDsForPID:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return [NSSet set];
    }
    MLAXGetWindowFn getWid = MLResolvedAXGetWindow();
    if (!getWid) {
        return [NSSet set];
    }
    AXUIElementRef appRef = AXUIElementCreateApplication(pid);
    if (!appRef) {
        return [NSSet set];
    }
    CFTypeRef windowsRef = NULL;
    NSMutableSet<NSNumber *> *out = [NSMutableSet set];
    if (AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef) == kAXErrorSuccess &&
        windowsRef && CFGetTypeID(windowsRef) == CFArrayGetTypeID()) {
        CFArrayRef axWindows = (CFArrayRef)windowsRef;
        CFIndex count = CFArrayGetCount(axWindows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            CGWindowID wid = 0;
            if (getWid(win, &wid) == kAXErrorSuccess && wid != 0) {
                [out addObject:@(wid)];
            }
        }
    }
    if (windowsRef) {
        CFRelease(windowsRef);
    }
    CFRelease(appRef);
    return out;
}

/**
 * CG often keeps closed WeChat chats as on-screen/off-screen ghosts.
 * If AX lists windows for the app but this id is absent, drop it.
 */
- (void)removeCGGhostWindowsNotInAccessibility:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                                 seenWindowIDs:(NSMutableSet<NSNumber *> *)seen {
    if (!windows.count || !AXIsProcessTrusted()) {
        return;
    }
    NSMutableDictionary<NSNumber *, NSMutableArray<MLTaskbarWindowInfo *> *> *byPid =
        [NSMutableDictionary dictionary];
    for (MLTaskbarWindowInfo *w in windows) {
        if (w.windowID == 0 || w.pid <= 0 || w.minimized) {
            continue;
        }
        if ([self.softMinimizedWindowIDs containsObject:@(w.windowID)]) {
            continue;
        }
        NSNumber *key = @(w.pid);
        NSMutableArray *arr = byPid[key];
        if (!arr) {
            arr = [NSMutableArray array];
            byPid[key] = arr;
        }
        [arr addObject:w];
    }
    if (byPid.count == 0) {
        return;
    }

    NSMutableSet<MLTaskbarWindowInfo *> *drop = [NSMutableSet set];
    for (NSNumber *pidNum in byPid) {
        NSSet<NSNumber *> *axIDs = [self axAllWindowIDsForPID:(pid_t)pidNum.intValue];
        if (axIDs.count == 0) {
            continue; /* AX gave nothing — don't purge */
        }
        for (MLTaskbarWindowInfo *w in byPid[pidNum]) {
            if (![axIDs containsObject:@(w.windowID)]) {
                [drop addObject:w];
                [seen removeObject:@(w.windowID)];
                [self.lastSeenWindows removeObjectForKey:@(w.windowID)];
                [self.frozenRestoreFrames removeObjectForKey:@(w.windowID)];
                [self.softMinimizedWindowIDs removeObject:@(w.windowID)];
            }
        }
    }
    if (drop.count > 0) {
        [windows removeObjectsInArray:drop.allObjects];
    }
}

/**
 * CGWindowIDs that AX currently reports as minimized for this PID.
 * Used instead of "any window minimized on PID" so closing one WeChat chat
 * does not resurrect other cached chats when another window is minimized.
 */
- (NSSet<NSNumber *> *)axMinimizedWindowIDsForPID:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return [NSSet set];
    }
    MLAXGetWindowFn getWid = MLResolvedAXGetWindow();
    AXUIElementRef appRef = AXUIElementCreateApplication(pid);
    if (!appRef) {
        return [NSSet set];
    }
    CFTypeRef windowsRef = NULL;
    NSMutableSet<NSNumber *> *out = [NSMutableSet set];
    if (AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef) == kAXErrorSuccess &&
        windowsRef && CFGetTypeID(windowsRef) == CFArrayGetTypeID()) {
        CFArrayRef axWindows = (CFArrayRef)windowsRef;
        CFIndex count = CFArrayGetCount(axWindows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            CFTypeRef minRef = NULL;
            Boolean isMin = false;
            if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess &&
                minRef) {
                if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                    isMin = CFBooleanGetValue((CFBooleanRef)minRef);
                }
                CFRelease(minRef);
            }
            if (!isMin) {
                continue;
            }
            CGWindowID wid = 0;
            if (getWid && getWid(win, &wid) == kAXErrorSuccess && wid != 0) {
                [out addObject:@(wid)];
            }
        }
    }
    if (windowsRef) {
        CFRelease(windowsRef);
    }
    CFRelease(appRef);
    return out;
}

/** Some apps (e.g. Electron) drop minimized windows from CG lists — keep cache only if THIS wid is AX-minimized (or soft-min). */
- (void)appendMinimizedFromCacheWhenVanished:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                               seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                                 withWindows:(NSMutableSet<NSString *> *)withWindows
                                         cap:(NSUInteger)cap
                                    aliveIDs:(NSSet<NSNumber *> *)aliveIDs {
    NSMutableDictionary<NSNumber *, NSSet<NSNumber *> *> *axMinByPid = [NSMutableDictionary dictionary];

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

        /* Our custom soft-minimize always keeps the chip. */
        if ([self.softMinimizedWindowIDs containsObject:widNum]) {
            MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
            NSValue *frozen = self.frozenRestoreFrames[widNum];
            if (frozen) {
                w.bounds = NSRectToCGRect(frozen.rectValue);
            }
            [windows addObject:w];
            [seen addObject:widNum];
            if (w.path.length > 0) {
                [withWindows addObject:w.path];
            }
            continue;
        }

        /* Closed windows vanish from CG — do NOT revive them just because another
           window of the same app (e.g. WeChat) is minimized. */
        NSNumber *pidKey = @(cached.pid);
        NSSet<NSNumber *> *axMin = axMinByPid[pidKey];
        if (!axMin) {
            axMin = [self axMinimizedWindowIDsForPID:cached.pid];
            axMinByPid[pidKey] = axMin ?: [NSSet set];
            axMin = axMinByPid[pidKey];
        }
        if (![axMin containsObject:widNum]) {
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

/**
 * Drop cache entries that are no longer visible task windows.
 * onScreenIDs = windows we accepted as visible this poll.
 * Do not keep WeChat-style off-screen ghosts just because the CGWindowID is still alive.
 */
- (void)pruneClosedCachedWindows:(NSSet<NSNumber *> *)aliveIDs
                     onScreenIDs:(NSSet<NSNumber *> *)onScreenIDs {
    (void)aliveIDs;
    NSMutableDictionary<NSNumber *, NSSet<NSNumber *> *> *axMinByPid = [NSMutableDictionary dictionary];
    NSArray<NSNumber *> *keys = self.lastSeenWindows.allKeys;
    for (NSNumber *key in keys) {
        if ([self.softMinimizedWindowIDs containsObject:key]) {
            continue;
        }
        if (onScreenIDs && [onScreenIDs containsObject:key]) {
            continue;
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[key];
        if (!cached || cached.pid <= 0 || !self.pidPathMap[@(cached.pid)]) {
            [self.lastSeenWindows removeObjectForKey:key];
            [self.frozenRestoreFrames removeObjectForKey:key];
            [self.softMinimizedWindowIDs removeObject:key];
            continue;
        }
        NSNumber *pidKey = @(cached.pid);
        NSSet<NSNumber *> *axMin = axMinByPid[pidKey];
        if (!axMin) {
            axMin = [self axMinimizedWindowIDsForPID:cached.pid];
            axMinByPid[pidKey] = axMin ?: [NSSet set];
            axMin = axMinByPid[pidKey];
        }
        if ([axMin containsObject:key]) {
            continue;
        }
        [self.lastSeenWindows removeObjectForKey:key];
        [self.frozenRestoreFrames removeObjectForKey:key];
        [self.softMinimizedWindowIDs removeObject:key];
    }
}

- (void)pollWindows {
    [self pollWindowsWithOptions:MLPollOptionNone];
}

- (void)pollWindowsWithOptions:(MLPollOptions)options {
    if ((options & MLPollOptionSkipPidRebuild) == 0) {
        [self rebuildPidMapFromWorkspace];
    }
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

    if ((options & MLPollOptionSkipGhostSweep) == 0) {
        [self removeCGGhostWindowsNotInAccessibility:windows seenWindowIDs:seen];
    }

    NSSet<NSNumber *> *onScreenIDs = [seen copy];

    if ((options & MLPollOptionSkipTitleEnrich) == 0) {
        [self enrichTitlesFromAccessibility:windows];
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

    [self appendSoftMinimizedWindows:windows
                       seenWindowIDs:seen
                         withWindows:withWindows
                                 cap:cap];

    [self appendMinimizedFromCacheWhenVanished:windows
                                 seenWindowIDs:seen
                                   withWindows:withWindows
                                           cap:cap
                                      aliveIDs:aliveIDs];

    if ((options & MLPollOptionSkipAXMinimizedBackup) == 0) {
        [self appendMinimizedWindowsFromAccessibility:windows withWindows:withWindows cap:cap];
        if ((options & MLPollOptionSkipTitleEnrich) == 0) {
            [self enrichTitlesFromAccessibility:windows];
        }
    }

    [self pruneClosedCachedWindows:aliveIDs onScreenIDs:onScreenIDs];

    NSArray<MLTaskbarWindowInfo *> *deduped = [self dedupeWindows:windows];

    MLRunningAppsSnapshot *snap = [[MLRunningAppsSnapshot alloc] init];
    snap.runningAppPaths = runningPaths;
    snap.pathsWithVisibleWindows = [withWindows copy];
    snap.windows = deduped;
    snap.pidToPath = [self.pidPathMap copy];

    NSString *fp = [self fingerprintForPaths:runningPaths windows:deduped];
    if ([fp isEqualToString:self.lastFingerprint]) {
        self.snapshot = snap;
        /* Keep census in sync even when snapshot fingerprint is unchanged. */
        self.lastCensusToken = [self computeWindowCensusToken];
        return;
    }
    [self publishSnapshot:snap fingerprint:fp];
    self.lastCensusToken = [self computeWindowCensusToken];
}

- (void)appDidLaunch:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if ([self shouldTrackApplication:app] && app.processIdentifier > 0) {
        self.pidPathMap[@(app.processIdentifier)] = app.bundleURL.path;
        [self installAXWatchForPID:app.processIdentifier];
    }
    [self scheduleStructuralFastPoll];
}

- (void)appDidTerminate:(NSNotification *)note {
    NSRunningApplication *app = note.userInfo[NSWorkspaceApplicationKey];
    if (app.processIdentifier > 0) {
        [self.pidPathMap removeObjectForKey:@(app.processIdentifier)];
        [self removeAXWatchForPID:app.processIdentifier];
    }
    [self scheduleStructuralFastPoll];
}

#pragma mark - AX window observers (low-latency close / minimize / move)

static void MLAXObserverCallback(AXObserverRef observer,
                                 AXUIElementRef element,
                                 CFStringRef notification,
                                 void *refcon) {
    (void)observer;
    MLRunningAppsMonitor *self = (__bridge MLRunningAppsMonitor *)refcon;
    if (!self || !self.running || !notification) {
        return;
    }

    if (CFEqual(notification, kAXWindowCreatedNotification) && element) {
        [self axWatchRegisterNotificationsOnWindow:element];
        [self scheduleStructuralFastPoll];
        return;
    }
    if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        [self optimisticRemoveWindowElement:element];
        [self scheduleStructuralFastPoll];
        return;
    }
    if (CFEqual(notification, kAXWindowMiniaturizedNotification) ||
        CFEqual(notification, kAXWindowDeminiaturizedNotification)) {
        [self scheduleStructuralFastPoll];
        return;
    }
    if (CFEqual(notification, kAXTitleChangedNotification)) {
        [self optimisticUpdateTitleFromElement:element];
        [self scheduleStructuralFastPoll];
        return;
    }
    if (CFEqual(notification, kAXMovedNotification) || CFEqual(notification, kAXResizedNotification)) {
        [self optimisticUpdateBoundsFromElement:element];
        [self scheduleGeometryFastPoll];
        return;
    }
    [self scheduleStructuralFastPoll];
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
    if (!el) {
        return 0;
    }
    MLAXGetWindowFn getWid = MLResolvedAXGetWindow();
    if (!getWid) {
        return 0;
    }
    CGWindowID wid = 0;
    if (getWid(el, &wid) != kAXErrorSuccess) {
        return 0;
    }
    return wid;
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
    if ([self.softMinimizedWindowIDs containsObject:@(wid)]) {
        return;
    }
    [self.lastSeenWindows removeObjectForKey:@(wid)];
    [self.frozenRestoreFrames removeObjectForKey:@(wid)];

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
    if (wid == 0 || [self.softMinimizedWindowIDs containsObject:@(wid)]) {
        return;
    }
    NSRect cocoa = NSZeroRect;
    if (![self axReadCocoaFrame:&cocoa fromElement:el]) {
        return;
    }
    CGRect bounds = NSRectToCGRect(cocoa);
    MLTaskbarWindowInfo *cached = self.lastSeenWindows[@(wid)];
    CGRect oldBounds = cached ? cached.bounds : CGRectZero;
    if (cached && !self.frozenRestoreFrames[@(wid)]) {
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

- (void)axWatchRegisterNotificationsOnWindow:(AXUIElementRef)win {
    if (!win) {
        return;
    }
    pid_t pid = 0;
    if (AXUIElementGetPid(win, &pid) != kAXErrorSuccess || pid <= 0) {
        return;
    }
    MLAXPidWatch *watch = self.axWatchByPid[@(pid)];
    if (!watch || !watch.observer) {
        return;
    }
    AXObserverAddNotification(watch.observer, win, kAXUIElementDestroyedNotification, NULL);
    AXObserverAddNotification(watch.observer, win, kAXWindowMiniaturizedNotification, NULL);
    AXObserverAddNotification(watch.observer, win, kAXWindowDeminiaturizedNotification, NULL);
    AXObserverAddNotification(watch.observer, win, kAXTitleChangedNotification, NULL);
    AXObserverAddNotification(watch.observer, win, kAXMovedNotification, NULL);
    AXObserverAddNotification(watch.observer, win, kAXResizedNotification, NULL);
}

- (void)installAXWatchForPID:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return;
    }
    if (self.axWatchByPid[@(pid)]) {
        return;
    }

    AXObserverRef observer = NULL;
    if (AXObserverCreate(pid, MLAXObserverCallback, &observer) != kAXErrorSuccess || !observer) {
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
    self.axWatchByPid[@(pid)] = watch;

    AXObserverAddNotification(observer, appElement, kAXWindowCreatedNotification, NULL);

    CFTypeRef windowsRef = NULL;
    if (AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &windowsRef) == kAXErrorSuccess &&
        windowsRef && CFGetTypeID(windowsRef) == CFArrayGetTypeID()) {
        CFArrayRef axWindows = (CFArrayRef)windowsRef;
        CFIndex count = CFArrayGetCount(axWindows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            [self axWatchRegisterNotificationsOnWindow:win];
        }
    }
    if (windowsRef) {
        CFRelease(windowsRef);
    }

    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
}

- (void)removeAXWatchForPID:(pid_t)pid {
    if (pid <= 0) {
        return;
    }
    MLAXPidWatch *watch = self.axWatchByPid[@(pid)];
    if (!watch) {
        return;
    }
    [watch invalidate];
    [self.axWatchByPid removeObjectForKey:@(pid)];
}

- (void)syncAXWindowObservers {
    if (!AXIsProcessTrusted()) {
        if (self.axWatchByPid.count > 0) {
            NSArray<NSNumber *> *keys = self.axWatchByPid.allKeys;
            for (NSNumber *pidNum in keys) {
                [self removeAXWatchForPID:(pid_t)pidNum.intValue];
            }
        }
        return;
    }
    NSSet<NSNumber *> *wanted = [NSSet setWithArray:self.pidPathMap.allKeys];
    NSArray<NSNumber *> *existing = self.axWatchByPid.allKeys;
    for (NSNumber *pidNum in existing) {
        if (![wanted containsObject:pidNum]) {
            [self removeAXWatchForPID:(pid_t)pidNum.intValue];
        }
    }
    for (NSNumber *pidNum in wanted) {
        [self installAXWatchForPID:(pid_t)pidNum.intValue];
    }
}

- (void)removeAllAXWatches {
    NSArray<NSNumber *> *keys = self.axWatchByPid.allKeys;
    for (NSNumber *pidNum in keys) {
        [self removeAXWatchForPID:(pid_t)pidNum.intValue];
    }
}

- (NSInteger)screenIndexForCocoaPoint:(CGPoint)point {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    for (NSInteger i = 0; i < (NSInteger)screens.count; i++) {
        if (NSPointInRect(NSMakePoint(point.x, point.y), screens[(NSUInteger)i].frame)) {
            return i;
        }
    }
    return -1;
}

/**
 * Lightweight on-screen window census: id + owner + display index (+ quantized size).
 * Ignores intra-display pixel moves so dragging does not spam refreshes.
 * Open / close / cross-display moves change this token immediately via CG — no AX wait.
 */
- (NSString *)computeWindowCensusToken {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                     kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    if (!list) {
        return @"";
    }
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        if (!info) {
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
        CGRect bounds = CGRectZero;
        CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)) {
            continue;
        }
        if (bounds.size.width < 100.0 || bounds.size.height < 80.0) {
            continue;
        }
        CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (alphaRef) {
            double alpha = 1.0;
            CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
            if (alpha < 0.1) {
                continue;
            }
        }
        CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
        CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        CGWindowID wid = 0;
        pid_t pid = 0;
        if (winRef) {
            CFNumberGetValue(winRef, kCFNumberIntType, &wid);
        }
        if (pidRef) {
            CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
        }
        if (wid == 0 || pid <= 0) {
            continue;
        }
        if ([self.softMinimizedWindowIDs containsObject:@(wid)]) {
            continue;
        }
        CGPoint mid = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
        NSInteger screenIdx = [self screenIndexForCocoaPoint:mid];
        /* Size buckets (~32pt) — ignore tiny resizes, keep big layout changes. */
        int bw = (int)(bounds.size.width / 32.0);
        int bh = (int)(bounds.size.height / 32.0);
        [rows addObject:[NSString stringWithFormat:@"%u:%d:%ld:%d:%d",
                                                   (unsigned)wid, (int)pid, (long)screenIdx, bw, bh]];
    }
    CFRelease(list);
    [rows sortUsingSelector:@selector(compare:)];
    /* Soft-min chips still count so census stays stable while tucked. */
    if (self.softMinimizedWindowIDs.count > 0) {
        NSArray *soft = [[self.softMinimizedWindowIDs allObjects]
            sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *widNum in soft) {
            [rows addObject:[NSString stringWithFormat:@"soft:%u", (unsigned)widNum.unsignedIntValue]];
        }
    }
    return [rows componentsJoinedByString:@"|"];
}

- (void)censusTick {
    if (!self.running) {
        return;
    }
    NSString *token = [self computeWindowCensusToken];
    if ([token isEqualToString:self.lastCensusToken ?: @""]) {
        return;
    }
    self.lastCensusToken = token;
    /* CG already saw the change — refresh taskbar without waiting for AX. */
    [self pollWindowsWithOptions:MLPollOptionsFast];
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
    [self syncAXWindowObservers];
    [self pollWindows];

    __weak typeof(self) weakSelf = self;
    /* ~12 Hz CG census: open/close/cross-screen move without AX latency. */
    self.censusTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 12.0)
                                                        repeats:YES
                                                          block:^(__unused NSTimer *timer) {
                                                              [weakSelf censusTick];
                                                          }];
    [[NSRunLoop mainRunLoop] addTimer:self.censusTimer forMode:NSRunLoopCommonModes];

    /* Slow full poll: titles / AX ghost cleanup / observer sync. */
    NSTimeInterval interval = self.windowPollInterval > 0.2 ? self.windowPollInterval : 1.0;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                     repeats:YES
                                                       block:^(__unused NSTimer *timer) {
                                                           [weakSelf syncAXWindowObservers];
                                                           [weakSelf pollWindows];
                                                       }];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    [self.censusTimer invalidate];
    self.censusTimer = nil;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self removeAllAXWatches];
    self.axStructuralPollPending = NO;
    self.axGeometryPollPending = NO;
    self.lastCensusToken = nil;
    self.snapshot = [self emptySnapshot];
    self.lastFingerprint = nil;
    [self.pidPathMap removeAllObjects];
    [self.lastSeenWindows removeAllObjects];
    [self.softMinimizedWindowIDs removeAllObjects];
    [self.frozenRestoreFrames removeAllObjects];
    self.nextSeenOrder = 1;
}

- (void)pollNow {
    [self pollWindows];
}

- (CGRect)cachedBoundsForWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return CGRectZero;
    }
    NSValue *frozen = self.frozenRestoreFrames[@(windowID)];
    if (frozen) {
        return frozen.rectValue;
    }
    MLTaskbarWindowInfo *seen = self.lastSeenWindows[@(windowID)];
    return seen ? seen.bounds : CGRectZero;
}

- (CGRect)cachedBoundsForPID:(pid_t)pid title:(NSString *)title {
    MLTaskbarWindowInfo *best = nil;
    for (MLTaskbarWindowInfo *seen in self.lastSeenWindows.allValues) {
        if (seen.pid != pid) {
            continue;
        }
        NSValue *frozen = (seen.windowID != 0) ? self.frozenRestoreFrames[@(seen.windowID)] : nil;
        CGRect bounds = frozen ? frozen.rectValue : seen.bounds;
        if (title.length == 0) {
            best = seen;
            continue;
        }
        if ([seen.title isEqualToString:title] ||
            (seen.title.length > 0 && [title hasPrefix:seen.title]) ||
            (title.length > 0 && [seen.title hasPrefix:title])) {
            return bounds;
        }
        if (!best) {
            best = seen;
        }
    }
    if (!best) {
        return CGRectZero;
    }
    NSValue *frozen = (best.windowID != 0) ? self.frozenRestoreFrames[@(best.windowID)] : nil;
    return frozen ? frozen.rectValue : best.bounds;
}

- (void)appendSoftMinimizedWindows:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                     seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                       withWindows:(NSMutableSet<NSString *> *)withWindows
                               cap:(NSUInteger)cap {
    for (NSNumber *widNum in self.softMinimizedWindowIDs) {
        if (windows.count >= cap) {
            break;
        }
        if ([seen containsObject:widNum]) {
            continue;
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[widNum];
        if (!cached || cached.path.length == 0) {
            continue;
        }
        if (cached.pid > 0 && !self.pidPathMap[@(cached.pid)]) {
            continue;
        }
        MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
        NSValue *frozen = self.frozenRestoreFrames[widNum];
        if (frozen) {
            w.bounds = NSRectToCGRect(frozen.rectValue);
        }
        [windows addObject:w];
        [seen addObject:widNum];
        [withWindows addObject:w.path];
    }
}

- (CGWindowID)rememberBounds:(CGRect)bounds forPID:(pid_t)pid title:(NSString *)title {
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

    MLTaskbarWindowInfo *existing = nil;
    for (MLTaskbarWindowInfo *seen in self.lastSeenWindows.allValues) {
        if (seen.pid != pid) {
            continue;
        }
        if (title.length == 0 || seen.title.length == 0 ||
            [seen.title isEqualToString:title] ||
            [seen.title hasPrefix:title ?: @""] || [title hasPrefix:seen.title ?: @""]) {
            existing = seen;
            break;
        }
    }

    CGWindowID wid = existing.windowID;
    if (wid == 0) {
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                         kCGWindowListExcludeDesktopElements,
                                                     kCGNullWindowID);
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
                CGRect inter = CGRectIntersection(b, bounds);
                CGFloat area = CGRectIsNull(inter) ? 0 : inter.size.width * inter.size.height;
                if (area > bestArea) {
                    bestArea = area;
                    CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
                    if (winRef) {
                        CFNumberGetValue(winRef, kCFNumberIntType, &wid);
                    }
                }
            }
            CFRelease(list);
        }
    }
    if (wid == 0) {
        for (MLTaskbarWindowInfo *seen in self.lastSeenWindows.allValues) {
            if (seen.pid != pid) {
                continue;
            }
            seen.bounds = bounds;
            if (title.length > 0) {
                seen.title = [self truncateTitle:title];
            }
        }
        return 0;
    }

    /* Always prefer the existing record for this windowID so seenOrder stays stable. */
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
    stored.bounds = bounds;
    stored.minimized = NO;
    stored.seenOrder = keepOrder > 0 ? keepOrder : self.nextSeenOrder++;
    self.lastSeenWindows[@(wid)] = stored;
    /* Freeze immediately so a later poll cannot clobber the restore frame. */
    if (!CGRectIsEmpty(bounds) && bounds.size.width > 2.0 && bounds.size.height > 2.0) {
        self.frozenRestoreFrames[@(wid)] = [NSValue valueWithRect:NSRectFromCGRect(bounds)];
    }
    return wid;
}

- (void)markSoftMinimizedWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return;
    }
    [self.softMinimizedWindowIDs addObject:@(windowID)];
}

- (void)clearSoftMinimizedWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return;
    }
    [self.softMinimizedWindowIDs removeObject:@(windowID)];
}

- (BOOL)isSoftMinimizedWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return NO;
    }
    return [self.softMinimizedWindowIDs containsObject:@(windowID)];
}

- (BOOL)hasFrozenRestoreBoundsForWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return NO;
    }
    return self.frozenRestoreFrames[@(windowID)] != nil;
}

- (void)clearFrozenRestoreBoundsForWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return;
    }
    [self.frozenRestoreFrames removeObjectForKey:@(windowID)];
}

@end
