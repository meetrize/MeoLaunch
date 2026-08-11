#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Periodic idle + system memory-pressure reclaim.
 * Only frees rebuildable caches and asks libmalloc to return free pages —
 * does not stop the taskbar monitor or clear soft-min / peek state.
 */
@interface MLIdleMemoryReclaimer : NSObject

/** Return YES while Launchpad overlay is showing (skip periodic trim). */
@property (nonatomic, copy, nullable) BOOL (^isOverlayVisible)(void);

/**
 * Perform reclaim work on the main queue.
 * underMemoryPressure == YES → may purge taskbar icons; NO → lighter idle trim.
 */
@property (nonatomic, copy, nullable) void (^performReclaim)(BOOL underMemoryPressure);

- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END
