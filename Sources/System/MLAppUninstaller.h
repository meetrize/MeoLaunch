#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** Gate + trash helpers for overlay “Uninstall…” (no UI). */
@interface MLAppUninstaller : NSObject

/** SIP / system / self — never offer uninstall. */
+ (BOOL)isProtectedAppPath:(NSString *)path;

/** Exists, looks like .app, not protected. */
+ (BOOL)canAttemptUninstallAtPath:(NSString *)path;

+ (NSString *)displayNameAtPath:(NSString *)path;

/** CFBundleIdentifier, or empty. */
+ (NSString *)bundleIdentifierAtPath:(NSString *)path;

+ (BOOL)isAppRunningAtPath:(NSString *)path;

/**
 * Sibling or nested Uninstall*.app / *卸载*.app near the target.
 * Returns standardized path or nil.
 */
+ (nullable NSString *)findUninstallerNearAppAtPath:(NSString *)path;

/**
 * High-confidence leftover paths under ~/Library (shallow).
 * Never includes the .app itself. May be empty.
 */
+ (NSArray<NSString *> *)discoverLeftoversAtPath:(NSString *)path;

/**
 * Move the .app bundle into Trash (not permanent delete).
 * Returns YES on success. Does not remove leftovers (use movePathsToTrash:).
 */
+ (BOOL)moveAppToTrashAtPath:(NSString *)path error:(NSError *_Nullable *_Nullable)error;

/** Trash each existing path; returns count successfully moved. */
+ (NSUInteger)movePathsToTrash:(NSArray<NSString *> *)paths;

@end

NS_ASSUME_NONNULL_END
