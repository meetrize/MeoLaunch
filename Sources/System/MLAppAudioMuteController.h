#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Per-process / per-bundle mute via Core Audio Process Tap (doc/19).
 * Creates a private aggregate + discarding IOProc with muteBehavior=mutedWhenTapped
 * so the target app is silent while the session lives. Destroy session to unmute.
 * No-op / errors below macOS 14.2. Rebuilds when default output device changes.
 */
@interface MLAppAudioMuteController : NSObject

+ (BOOL)isAvailable;

- (BOOL)isMutedPID:(pid_t)pid;
- (BOOL)isMutedPID:(pid_t)pid bundleID:(nullable NSString *)bundleID;

- (BOOL)mutePID:(pid_t)pid error:(NSError *_Nullable *_Nullable)outError;
- (BOOL)mutePID:(pid_t)pid
       bundleID:(nullable NSString *)bundleID
          error:(NSError *_Nullable *_Nullable)outError;

- (BOOL)unmutePID:(pid_t)pid error:(NSError *_Nullable *_Nullable)outError;
- (BOOL)unmutePID:(pid_t)pid
         bundleID:(nullable NSString *)bundleID
            error:(NSError *_Nullable *_Nullable)outError;

- (BOOL)toggleMutePID:(pid_t)pid
             outMuted:(nullable BOOL *)outMuted
                error:(NSError *_Nullable *_Nullable)outError;
- (BOOL)toggleMutePID:(pid_t)pid
             bundleID:(nullable NSString *)bundleID
             outMuted:(nullable BOOL *)outMuted
                error:(NSError *_Nullable *_Nullable)outError;

- (void)unmuteAll;

- (NSArray<NSNumber *> *)copyMutedPIDs;
- (NSArray<NSString *> *)copyMutedIdentityKeys;

@end

NS_ASSUME_NONNULL_END
