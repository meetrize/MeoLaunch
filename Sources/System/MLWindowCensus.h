#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/** Shared CGWindowList cache — refreshed by MLRunningAppsMonitor census tick. */
@interface MLWindowCensus : NSObject

+ (NSInteger)screenIndexForCocoaPoint:(CGPoint)point;

/**
 * Refresh on-screen + all window lists from CGWindowList.
 * Safe to call frequently; replaces prior cache atomically on the main thread.
 */
- (void)refreshWindowLists;

/** Max age before `cachedOnScreenWindowListRefreshingIfNeeded:` triggers refresh (default 0.25s). */
@property (nonatomic, assign) NSTimeInterval maxStaleInterval;

/**
 * Borrowed CFArrayRef of kCGWindowListOptionOnScreenOnly dictionaries.
 * Valid until the next refresh on the main thread — do not CFRelease.
 */
- (CFArrayRef)cachedOnScreenWindowListRefreshingIfNeeded:(BOOL)refreshIfStale;

/**
 * Borrowed CFArrayRef of kCGWindowListOptionAll dictionaries.
 * Valid until the next refresh on the main thread — do not CFRelease.
 */
- (CFArrayRef)cachedAllWindowListRefreshingIfNeeded:(BOOL)refreshIfStale;

/** Token string; skips soft-hidden window IDs when provided. Uses cached on-screen list. */
- (NSString *)computeTokenSkippingSoftHidden:(NSSet<NSNumber *> *)softHiddenIDs;

@end
