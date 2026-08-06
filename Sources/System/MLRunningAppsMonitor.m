#import "MLRunningAppsMonitor.h"

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

@interface MLRunningAppsSnapshot ()
@property (nonatomic, copy, readwrite) NSArray<NSString *> *runningAppPaths;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *pathsWithVisibleWindows;
@property (nonatomic, copy, readwrite) NSArray<MLTaskbarWindowInfo *> *windows;
@property (nonatomic, copy, readwrite) NSDictionary<NSNumber *, NSString *> *pidToPath;
@end

@implementation MLRunningAppsSnapshot
@end

@interface MLRunningAppsMonitor () <MLAXAppObserverRegistryDelegate>
@property (nonatomic, strong, readwrite) MLRunningAppsSnapshot *snapshot;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *pidPathMap;
/** Last on-screen task windows, keyed by CGWindowID — used to keep minimized items on the right display. */
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, MLTaskbarWindowInfo *> *lastSeenWindows;
@property (nonatomic, strong, readwrite) MLWindowSoftState *softState;
@property (nonatomic, strong) MLAXAppObserverRegistry *axRegistry;
@property (nonatomic, strong) MLWindowCensus *windowCensus;
@property (nonatomic, assign) NSUInteger nextSeenOrder;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, copy) NSString *selfBundleID;
@property (nonatomic, copy) NSString *lastFingerprint;
@property (nonatomic, assign) BOOL axStructuralPollPending;
@property (nonatomic, assign) BOOL axGeometryPollPending;
/** High-frequency CG census (no AX) — catches open/close/display-move without waiting for AX. */
@property (nonatomic, strong) NSTimer *censusTimer;
@property (nonatomic, copy) NSString *lastCensusToken;
@property (nonatomic, assign) NSTimeInterval censusBoostUntil;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *pollAXWindowsByPid;
/** Fast AX focus poll when front app has multiple windows (same-app switch). */
@property (nonatomic, strong) NSTimer *focusPollTimer;
@property (nonatomic, assign) CGWindowID lastPublishedFocusedWID;
@property (nonatomic, assign) pid_t lastPublishedFocusedPID;
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

#pragma mark - Poll-scoped AX windows cache

- (void)beginPollAXWindowsCache {
    [self endPollAXWindowsCache];
    self.pollAXWindowsByPid = [NSMutableDictionary dictionary];
}

- (void)endPollAXWindowsCache {
    for (NSValue *v in self.pollAXWindowsByPid.allValues) {
        CFArrayRef arr = (CFArrayRef)v.pointerValue;
        if (arr) {
            CFRelease(arr);
        }
    }
    [self.pollAXWindowsByPid removeAllObjects];
    self.pollAXWindowsByPid = nil;
}

/** Borrowed CFArrayRef owned by poll cache; NULL if unavailable. */
- (CFArrayRef)axWindowsArrayForPID:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return NULL;
    }
    if (!self.pollAXWindowsByPid) {
        self.pollAXWindowsByPid = [NSMutableDictionary dictionary];
    }
    NSNumber *key = @(pid);
    NSValue *hit = self.pollAXWindowsByPid[key];
    if (hit) {
        return (CFArrayRef)hit.pointerValue;
    }
    AXUIElementRef appRef = AXUIElementCreateApplication(pid);
    if (!appRef) {
        return NULL;
    }
    CFTypeRef windowsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
    CFRelease(appRef);
    if (err != kAXErrorSuccess || !windowsRef || CFGetTypeID(windowsRef) != CFArrayGetTypeID()) {
        if (windowsRef) {
            CFRelease(windowsRef);
        }
        return NULL;
    }
    CFArrayRef arr = (CFArrayRef)windowsRef;
    CFRetain(arr);
    CFRelease(windowsRef);
    self.pollAXWindowsByPid[key] = [NSValue valueWithPointer:(const void *)arr];
    return arr;
}

/**
 * When CGWindowName is blank (common without Screen Recording), read kAXTitle.
 * Batched per PID. Used for Cursor editor titles and browser current-tab titles.
 */
- (void)enrichTitlesFromAccessibility:(NSMutableArray<MLTaskbarWindowInfo *> *)windows {
    if (!windows.count || !AXIsProcessTrusted()) {
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
        CFArrayRef axWindows = [self axWindowsArrayForPID:pid];
        if (!axWindows) {
            continue;
        }

        NSMutableDictionary<NSNumber *, NSString *> *titleByWid = [NSMutableDictionary dictionary];
        CFIndex count = CFArrayGetCount(axWindows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
            if (wid == 0) {
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
        /* While soft-hidden, keep the frozen pre-minimize frame (screen + restore). */
        if ([self.softState isSoftHiddenWindowID:w.windowID]) {
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
        if ([self.softState isSoftHiddenWindowID:(CGWindowID)key.unsignedIntValue]) {
            continue; /* soft chips survive pid-map blips */
        }
        MLTaskbarWindowInfo *seen = self.lastSeenWindows[key];
        if (seen.pid > 0 && !self.pidPathMap[@(seen.pid)]) {
            [self.lastSeenWindows removeObjectForKey:key];
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

        if ([self.softState isSoftHiddenWindowID:(CGWindowID)widNum.unsignedIntValue]) {
            MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
            NSRect rf = [self.softState restoreFrameForWindowID:(CGWindowID)widNum.unsignedIntValue];
            if (rf.size.width > 2.0 && rf.size.height > 2.0) {
                w.bounds = NSRectToCGRect(rf);
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

        CFArrayRef axWindows = [self axWindowsArrayForPID:pid];
        if (!axWindows) {
            continue;
        }

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

            CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
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
    CFArrayRef axWindows = [self axWindowsArrayForPID:pid];
    if (!axWindows) {
        return [NSSet set];
    }
    NSMutableSet<NSNumber *> *out = [NSMutableSet set];
    CFIndex count = CFArrayGetCount(axWindows);
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
        CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
        if (wid != 0) {
            [out addObject:@(wid)];
        }
    }
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
        if ([self.softState isSoftHiddenWindowID:w.windowID]) {
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
                /* Never clear soft-hidden here — chip survival is SoftState's job. */
                if (![self.softState isSoftHiddenWindowID:w.windowID]) {
                    [self.lastSeenWindows removeObjectForKey:@(w.windowID)];
                }
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
    CFArrayRef axWindows = [self axWindowsArrayForPID:pid];
    if (!axWindows) {
        return [NSSet set];
    }
    NSMutableSet<NSNumber *> *out = [NSMutableSet set];
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
        CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
        if (wid != 0) {
            [out addObject:@(wid)];
        }
    }
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
        if ([self.softState isSoftHiddenWindowID:(CGWindowID)widNum.unsignedIntValue]) {
            MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
            NSRect rf = [self.softState restoreFrameForWindowID:(CGWindowID)widNum.unsignedIntValue];
            if (rf.size.width > 2.0 && rf.size.height > 2.0) {
                w.bounds = NSRectToCGRect(rf);
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
        if ([self.softState isSoftHiddenWindowID:(CGWindowID)key.unsignedIntValue]) {
            continue; /* absolute soft protection */
        }
        if (onScreenIDs && [onScreenIDs containsObject:key]) {
            continue;
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[key];
        if (!cached || cached.pid <= 0 || !self.pidPathMap[@(cached.pid)]) {
            [self.lastSeenWindows removeObjectForKey:key];
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
    }
}

- (void)pollWindows {
    [self pollWindowsWithOptions:MLPollOptionNone];
}

- (void)pollWindowsWithOptions:(MLPollOptions)options {
    /* Always scope AX windows cache for this poll so Fast-path helpers cannot retain forever. */
    [self beginPollAXWindowsCache];
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
        [self endPollAXWindowsCache];
        [self updateFocusPollTimer];
        return;
    }
    [self publishSnapshot:snap fingerprint:fp];
    self.lastCensusToken = [self computeWindowCensusToken];
    [self endPollAXWindowsCache];
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
        [self.pidPathMap removeObjectForKey:@(app.processIdentifier)];
        [self.axRegistry removeWatchForPID:app.processIdentifier];
    }
    [self scheduleStructuralFastPoll];
}

#pragma mark - AX window observers (via MLAXAppObserverRegistry)

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
    if (!self.running) {
        return;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (self.censusBoostUntil > 0 && now >= self.censusBoostUntil) {
        self.censusBoostUntil = 0;
        [self rescheduleCensusTimer];
    }

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

- (void)rescheduleCensusTimer {
    if (!self.running) {
        return;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    BOOL boost = (self.censusBoostUntil > now);
    NSTimeInterval interval = boost ? (1.0 / 12.0) : (1.0 / 4.0);
    if (self.censusTimer && fabs(self.censusTimer.timeInterval - interval) < 0.001) {
        return;
    }
    [self.censusTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.censusTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                        repeats:YES
                                                          block:^(__unused NSTimer *timer) {
                                                              [weakSelf censusTick];
                                                          }];
    [[NSRunLoop mainRunLoop] addTimer:self.censusTimer forMode:NSRunLoopCommonModes];
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
                                                           [weakSelf syncAXWindowObservers];
                                                           [weakSelf pollWindows];
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

- (void)appendSoftMinimizedWindows:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                     seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                       withWindows:(NSMutableSet<NSString *> *)withWindows
                               cap:(NSUInteger)cap {
    for (MLWindowSoftRecord *rec in self.softState.allRecords) {
        if (windows.count >= cap) {
            break;
        }
        NSNumber *widNum = @(rec.windowID);
        if ([seen containsObject:widNum]) {
            continue;
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[widNum];
        MLTaskbarWindowInfo *w = nil;
        if (cached) {
            w = [self copyWindowInfo:cached minimized:YES];
        } else {
            w = [[MLTaskbarWindowInfo alloc] init];
            w.windowID = rec.windowID;
            w.pid = rec.pid;
            w.path = rec.path;
            w.title = rec.title ?: @"";
            w.seenOrder = rec.seenOrder;
            w.minimized = YES;
        }
        if (w.path.length == 0) {
            continue;
        }
        if (rec.restoreFrameCocoa.size.width > 2.0) {
            w.bounds = NSRectToCGRect(rec.restoreFrameCocoa);
        }
        if (rec.seenOrder > 0) {
            w.seenOrder = rec.seenOrder;
        }
        w.minimized = YES;
        [windows addObject:w];
        [seen addObject:widNum];
        [withWindows addObject:w.path];
        /* Ensure lastSeen keeps affinity for later polls. */
        if (!self.lastSeenWindows[widNum]) {
            self.lastSeenWindows[widNum] = [self copyWindowInfo:w minimized:YES];
        }
    }
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
            CFRelease(list);
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

@end
