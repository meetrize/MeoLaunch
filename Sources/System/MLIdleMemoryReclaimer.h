#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Periodic idle + system memory-pressure reclaim.
 * Only frees rebuildable caches and asks libmalloc to return free pages —
 * does not stop the taskbar monitor or clear soft-min / peek state.
 *
 * Also emits an hourly diagnostics heartbeat (Z0) when `collectHeartbeat` is set.
 */
@interface MLIdleMemoryReclaimer : NSObject

/** Return YES while Launchpad overlay is showing (skip periodic trim). */
@property (nonatomic, copy, nullable) BOOL (^isOverlayVisible)(void);

/**
 * Perform reclaim work on the main queue.
 * underMemoryPressure == YES → may purge taskbar icons; NO → lighter idle trim.
 */
@property (nonatomic, copy, nullable) void (^performReclaim)(BOOL underMemoryPressure);

/**
 * Optional diagnostics payload for hourly heartbeat.
 * Return a short status string (e.g. counts); footprint is logged by the reclaimer.
 */
@property (nonatomic, copy, nullable) NSString * _Nullable (^collectHeartbeat)(void);

/** Heartbeat interval seconds (default 3600). Values &lt; 60 clamped to 60 except in tests via setter. */
@property (nonatomic, assign) NSTimeInterval heartbeatIntervalSeconds;

- (void)start;
- (void)stop;

/** Fire heartbeat once (for tests / manual verify). */
- (void)emitHeartbeatNow;

@end

NS_ASSUME_NONNULL_END
