#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

@class MLWindowSoftState;
@class MLWindowCensus;

enum {
    MLTaskbarTitleMaxChars = 40,
    MLTaskbarMaxWindowEntries = 24,
    /** Hard cap for lastSeenWindows (Z5); soft-hidden entries are never trimmed. */
    MLLastSeenWindowsMax = 256,
};

FOUNDATION_EXPORT NSNotificationName const MLRunningAppsDidChangeNotification;
/** Frontmost window within an app changed (same-app focus switch). */
FOUNDATION_EXPORT NSNotificationName const MLRunningAppsFrontWindowDidChangeNotification;
/** userInfo[MLRunningAppsFrontWindowIDKey] → NSNumber (CGWindowID) */
FOUNDATION_EXPORT NSString *const MLRunningAppsFrontWindowIDKey;

@interface MLTaskbarWindowInfo : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) CGWindowID windowID;
@property (nonatomic, copy) NSString *title; /* truncated; may be empty */
/** Prefer Cocoa when from soft-state; CG polls store Quartz — convert via MLScreenGeometry before NSScreen compares. */
@property (nonatomic, assign) CGRect bounds;
@property (nonatomic, assign) BOOL minimized;
/** Monotonic order when the window was first shown on a taskbar; stable across minimize. */
@property (nonatomic, assign) NSUInteger seenOrder;
@end

@interface MLRunningAppsSnapshot : NSObject
@property (nonatomic, copy, readonly) NSArray<NSString *> *runningAppPaths;
@property (nonatomic, copy, readonly) NSSet<NSString *> *pathsWithVisibleWindows;
@property (nonatomic, copy, readonly) NSArray<MLTaskbarWindowInfo *> *windows;
@property (nonatomic, copy, readonly) NSDictionary<NSNumber *, NSString *> *pidToPath;
@end

@interface MLRunningAppsMonitor : NSObject

@property (nonatomic, assign) NSTimeInterval windowPollInterval; /* default 1.0s */
@property (nonatomic, assign) NSUInteger maxWindowEntries;       /* default 24 */
@property (nonatomic, assign) NSUInteger titleMaxChars;          /* default 40 */
@property (nonatomic, strong, readonly) MLRunningAppsSnapshot *snapshot;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
/** Soft-hidden window lifecycle (chip survival + restore frames). */
@property (nonatomic, strong, readonly) MLWindowSoftState *softState;
/** Shared CGWindowList cache (census tick + taskbar visibility). */
@property (nonatomic, strong, readonly) MLWindowCensus *windowCensus;

/**
 * When YES (mouse near hot corner), census drops to ~1Hz and focus poll stops
 * so the main thread can serve showCritical promptly.
 */
- (void)setHotCornerProximityActive:(BOOL)active;

/**
 * When YES (Launchpad overlay visible), census/full poll slow down (Z7).
 */
- (void)setOverlayVisible:(BOOL)visible;

- (void)start;
- (void)stop;
/** Apply poll interval; recreates timer if already running. */
- (void)applyWindowPollInterval:(NSTimeInterval)seconds;
/** Force an immediate window snapshot refresh. */
- (void)pollNow;
/** AX focused window for a process (0 if unknown). */
- (CGWindowID)focusedWindowIDForPID:(pid_t)pid;
/** AX title of the focused window (nil if unknown). */
- (NSString *)focusedWindowTitleForPID:(pid_t)pid;
/** Upsert last-seen frame; pass known AX windowID when available. */
- (CGWindowID)rememberBounds:(CGRect)bounds
                      forPID:(pid_t)pid
                       title:(NSString *)title
                    windowID:(CGWindowID)windowID;

- (void)markSoftMinimizedWindowID:(CGWindowID)windowID;
- (BOOL)isSoftMinimizedWindowID:(CGWindowID)windowID;

/** Diagnostics for hourly memory heartbeat (Z0). */
@property (nonatomic, assign, readonly) NSUInteger lastSeenWindowCount;
@property (nonatomic, assign, readonly) NSUInteger softHiddenCount;
@property (nonatomic, assign, readonly) NSUInteger axWatchCount;

/** Idle/pressure reclaim helpers (Z6). */
- (void)reclaimStaleSoftStateAndCachesUnderPressure:(BOOL)underPressure;

/**
 * Persist user-chosen taskbar window order into last-seen state (and live snapshot
 * entries) so the next poll / rebuild keeps the new sequence.
 * Keys and values are NSNumber-wrapped CGWindowID → seenOrder (1-based preferred).
 */
- (void)applySeenOrderByWindowID:(NSDictionary<NSNumber *, NSNumber *> *)orderByWid;

/** Convenience: mark soft-hidden with full metadata (preferred). axWindow is retained. */
- (void)markSoftHiddenWindowID:(CGWindowID)windowID
                           pid:(pid_t)pid
                          path:(NSString *)path
                         title:(NSString *)title
                 restoreFrame:(NSRect)restoreFrameCocoa
                     screenID:(NSNumber *)screenID
                     axWindow:(AXUIElementRef)axWindow;

@end
