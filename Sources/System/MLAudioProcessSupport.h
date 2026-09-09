#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

/** One Core Audio process object with output activity (macOS 14.2+). */
@interface MLAudioProcessInfo : NSObject
@property (nonatomic, assign, readonly) AudioObjectID objectID;
@property (nonatomic, assign, readonly) pid_t pid;
@property (nonatomic, copy, readonly, nullable) NSString *bundleID;
@property (nonatomic, assign, readonly) BOOL isRunningOutput;
@end

/**
 * Thin Core Audio process helpers for taskbar audio indicator (doc/19).
 * All entry points are safe below 14.2 (return NO / empty).
 */
@interface MLAudioProcessSupport : NSObject

/** YES when Process Object list + Process Tap APIs are usable (macOS 14.2+). */
+ (BOOL)isAvailable;

/** Enumerate HAL process objects; on failure returns empty array. */
+ (NSArray<MLAudioProcessInfo *> *)copyProcessInfos;

/** PIDs with IsRunningOutput == YES (excludes pid 0 / unknown). */
+ (NSArray<NSNumber *> *)copyRunningOutputPIDsExcluding:(pid_t)selfPid;

/**
 * Host app bundle IDs for processes currently outputting audio.
 * Resolves WebKit/Electron helpers to the owning Regular app when possible.
 */
+ (NSSet<NSString *> *)copyRunningOutputOwnerBundleIDsExcluding:(pid_t)selfPid;

/** Host .app paths for outputting processes (when resolvable). */
+ (NSSet<NSString *> *)copyRunningOutputOwnerAppPathsExcluding:(pid_t)selfPid;

/**
 * Owner bundle IDs for one process (helper → host). Empty if unknown.
 * Used by mute to tap the actual outputting helper(s) for a chip's app.
 */
+ (NSArray<NSString *> *)copyOwnerBundleIDsForPID:(pid_t)pid
                                        bundleID:(nullable NSString *)bundleID;

/** Translate pid → process AudioObjectID; kAudioObjectUnknown if none. */
+ (AudioObjectID)processObjectIDForPID:(pid_t)pid;

/**
 * Process object IDs that should be muted for a taskbar chip identity
 * (main pid + helpers attributed to the same owner bundle/path).
 */
+ (NSArray<NSNumber *> *)copyProcessObjectIDsToMuteForPID:(pid_t)pid
                                                 bundleID:(nullable NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END
