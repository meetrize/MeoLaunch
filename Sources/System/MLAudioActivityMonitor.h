#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MLAudioActivityDidChangeNotification;

/**
 * Tracks which PIDs currently have Core Audio IsRunningOutput (doc/19 A1).
 * No-op below macOS 14.2. Debounced change notifications on the main queue.
 */
@interface MLAudioActivityMonitor : NSObject

@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;
/** Snapshot of PIDs with active output (excludes self). */
@property (nonatomic, copy, readonly) NSSet<NSNumber *> *runningOutputPIDs;
/** Bundle IDs of processes with active output (helpers share parent bid). */
@property (nonatomic, copy, readonly) NSSet<NSString *> *runningOutputBundleIDs;
/** Host .app paths for outputting audio (WebKit/Electron helpers resolved). */
@property (nonatomic, copy, readonly) NSSet<NSString *> *runningOutputOwnerAppPaths;

- (void)start;
- (void)stop;

- (BOOL)isPIDRunningOutput:(pid_t)pid;
/** YES if pid / bundle / app path matches an active output owner. */
- (BOOL)isAudioActiveForPID:(pid_t)pid
                   bundleID:(nullable NSString *)bundleID
                    appPath:(nullable NSString *)appPath;

@end

NS_ASSUME_NONNULL_END
