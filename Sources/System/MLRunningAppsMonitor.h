#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

enum {
    MLTaskbarTitleMaxChars = 40,
    MLTaskbarMaxWindowEntries = 24,
};

FOUNDATION_EXPORT NSNotificationName const MLRunningAppsDidChangeNotification;

@interface MLTaskbarWindowInfo : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) CGWindowID windowID;
@property (nonatomic, copy) NSString *title; /* truncated; may be empty */
@property (nonatomic, assign) CGRect bounds; /* global Cocoa/Quartz coords; for per-screen filter */
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

- (void)start;
- (void)stop;
/** Force an immediate window snapshot refresh. */
- (void)pollNow;
- (CGRect)cachedBoundsForWindowID:(CGWindowID)windowID;
- (CGRect)cachedBoundsForPID:(pid_t)pid title:(NSString *)title;
/** Upsert last-seen frame; returns matched CGWindowID (0 if unknown). */
- (CGWindowID)rememberBounds:(CGRect)bounds forPID:(pid_t)pid title:(NSString *)title;
- (void)markSoftMinimizedWindowID:(CGWindowID)windowID;
- (void)clearSoftMinimizedWindowID:(CGWindowID)windowID;
- (BOOL)isSoftMinimizedWindowID:(CGWindowID)windowID;
- (BOOL)hasFrozenRestoreBoundsForWindowID:(CGWindowID)windowID;
- (void)clearFrozenRestoreBoundsForWindowID:(CGWindowID)windowID;

@end
