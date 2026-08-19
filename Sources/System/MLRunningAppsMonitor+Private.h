#import "MLRunningAppsMonitor.h"

#import "MLAXAppObserverRegistry.h"
#import "MLWindowCensus.h"
#import "MLWindowSoftState.h"

#import <ApplicationServices/ApplicationServices.h>

enum {
    MLPollOptionNone = 0,
    MLPollOptionSkipPidRebuild = 1 << 0,
    MLPollOptionSkipTitleEnrich = 1 << 1,
    MLPollOptionSkipGhostSweep = 1 << 2,
    MLPollOptionSkipAXMinimizedBackup = 1 << 3,
};
typedef NSInteger MLPollOptions;

FOUNDATION_EXPORT const MLPollOptions MLPollOptionsFast;

@interface MLRunningAppsSnapshot ()
@property (nonatomic, copy, readwrite) NSArray<NSString *> *runningAppPaths;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *pathsWithVisibleWindows;
@property (nonatomic, copy, readwrite) NSArray<MLTaskbarWindowInfo *> *windows;
@property (nonatomic, copy, readwrite) NSDictionary<NSNumber *, NSString *> *pidToPath;
@end

@interface MLRunningAppsMonitor () <MLAXAppObserverRegistryDelegate>
@property (nonatomic, strong, readwrite) MLRunningAppsSnapshot *snapshot;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *pidPathMap;
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
@property (nonatomic, strong) NSTimer *censusTimer;
@property (nonatomic, copy) NSString *lastCensusToken;
@property (nonatomic, assign) NSTimeInterval censusBoostUntil;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSValue *> *pollAXWindowsByPid;
@property (nonatomic, strong) NSTimer *focusPollTimer;
@property (nonatomic, assign) CGWindowID lastPublishedFocusedWID;
@property (nonatomic, assign) pid_t lastPublishedFocusedPID;
@property (nonatomic, assign) BOOL hotCornerProximityActive;
@property (nonatomic, assign) BOOL overlayVisibleThrottle;

- (NSString *)truncateTitle:(NSString *)title;
- (BOOL)shouldTrackApplication:(NSRunningApplication *)app;
- (void)rebuildPidMapFromWorkspace;
- (NSArray<NSString *> *)orderedRunningPaths;
- (void)publishSnapshot:(MLRunningAppsSnapshot *)snap fingerprint:(NSString *)fp;
- (NSString *)fingerprintForPaths:(NSArray<NSString *> *)paths windows:(NSArray<MLTaskbarWindowInfo *> *)windows;
- (NSString *)computeWindowCensusToken;
- (void)updateFocusPollTimer;
- (void)trimLastSeenWindowsIfNeeded;
- (void)removeLastSeenAndSoftForPID:(pid_t)pid;
/** Drop soft records whose pid is no longer running (Z6). */
- (void)auditSoftStateForDeadPIDs;
/** Pressure: trim lastSeen toward a lower water mark (keeps soft-hidden). */
- (void)trimLastSeenWindowsForMemoryPressure;
@end

@interface MLRunningAppsMonitor (SnapshotBuilder)

- (void)pollWindows;
- (void)pollWindowsWithOptions:(MLPollOptions)options;
- (MLTaskbarWindowInfo *)copyWindowInfo:(MLTaskbarWindowInfo *)src minimized:(BOOL)minimized;
- (NSString *)appDisplayNameForPid:(pid_t)pid path:(NSString *)path;
- (NSString *)preferredTaskTitleFromWindowTitle:(NSString *)title appName:(NSString *)appName;
- (void)beginPollAXWindowsCache;
- (void)endPollAXWindowsCache;

@end
