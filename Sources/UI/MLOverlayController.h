#import <Cocoa/Cocoa.h>

#include "ml_app_index.h"

@class MLConfigStore;
@class MLLayoutStore;
@class MLTaskbarPinStore;
@class MLOverlayController;

@protocol MLOverlayControllerDelegate <NSObject>
@optional
- (void)overlayControllerDidRequestPreferences:(MLOverlayController *)controller;
- (void)overlayControllerWillShow:(MLOverlayController *)controller;
- (void)overlayControllerDidHide:(MLOverlayController *)controller;
/** After an app was removed from disk — rescan index + layout sync. */
- (void)overlayControllerDidRequestAppRescan:(MLOverlayController *)controller;
@end

@interface MLOverlayController : NSObject

@property (nonatomic, weak) id<MLOverlayControllerDelegate> delegate;
/** Shared with taskbar; used by overlay icon context menu pin toggle. */
@property (nonatomic, weak) MLTaskbarPinStore *pinStore;

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
/**
 * Drop overlay icon RAM + disk thumbnails (and folder composites).
 * Next show / paint reloads icons from app bundles via Workspace.
 */
- (void)refreshIconCachesFromApps;
/**
 * Idle / memory-pressure reclaim while overlay is hidden.
 * underPressure=YES → purge icon RAM (+ filter/folder caches).
 * underPressure=NO → light trim only (filter/folder); keep icon RAM for fast re-show.
 * Disk thumbnails are never cleared here.
 */
- (void)reclaimIdleCachesIfHiddenUnderPressure:(BOOL)underPressure;
/**
 * Cold-destroy a parked warm window.
 * force=YES (memory pressure) always destroys if warm;
 * force=NO destroys only after idle park timeout (~15 min).
 */
- (void)destroyWarmOverlayIfNeededForce:(BOOL)force;

@end
