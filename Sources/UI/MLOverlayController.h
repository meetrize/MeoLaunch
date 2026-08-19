#import <Cocoa/Cocoa.h>

#include "ml_app_index.h"

@class MLConfigStore;
@class MLLayoutStore;
@class MLOverlayController;

@protocol MLOverlayControllerDelegate <NSObject>
@optional
- (void)overlayControllerDidRequestPreferences:(MLOverlayController *)controller;
- (void)overlayControllerWillShow:(MLOverlayController *)controller;
- (void)overlayControllerDidHide:(MLOverlayController *)controller;
@end

@interface MLOverlayController : NSObject

@property (nonatomic, weak) id<MLOverlayControllerDelegate> delegate;

- (instancetype)initWithConfigStore:(MLConfigStore *)config
                        layoutStore:(MLLayoutStore *)layoutStore;
- (void)reloadWithAppIndex:(const MLAppIndex *)index;
- (void)show;
/** Same as show but skips fade-in (for hot corner — instant appearance). */
- (void)showImmediate;
/**
 * Critical path: window on-screen at alpha=1 (≤1 frame). Does not focus/search/sanitize.
 * Safe to call when already warm.
 */
- (void)showCritical;
/** Deferred chrome after showCritical: filter, focus, monitors, watchdog. */
- (void)showDeferredChrome;
- (void)hide;
- (BOOL)isVisible;
/**
 * Residence for diagnostics: @"visible" | @"warm" (window kept, hidden) | @"cold" (no window).
 */
- (NSString *)overlayResidenceState;
/** YES when a parked fullscreen window exists but overlay is not visible. */
- (BOOL)isOverlayWindowWarm;
/** P2: apply overlay icon LRU cap from prefs. */
- (void)setIconCacheMaxEntries:(NSUInteger)maxEntries;
/** Idle / memory-pressure: purge rebuildable overlay caches when not visible. */
- (void)reclaimIdleCachesIfHidden;
/**
 * Cold-destroy a parked warm window.
 * force=YES (memory pressure) always destroys if warm;
 * force=NO destroys only after idle park timeout (~15 min).
 */
- (void)destroyWarmOverlayIfNeededForce:(BOOL)force;

@end
