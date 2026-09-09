#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

@class MLTaskbarPinStore;
@class MLRunningAppsMonitor;
@class MLIconCache;
@class MLAudioActivityMonitor;
@class MLAppAudioMuteController;

@protocol MLTaskbarAppActions;

typedef NS_ENUM(NSInteger, MLWindowHideMethod);

@interface MLTaskbarController : NSObject

@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
/** About / Preferences / Quit — typically AppDelegate. */
@property (nonatomic, weak) id<MLTaskbarAppActions> appActions;
/** Optional; set before start. Drives chip audio badges (doc/19). */
@property (nonatomic, strong) MLAudioActivityMonitor *audioActivity;
/** Optional; set before start. Per-app Process Tap mute (doc/19 A2). */
@property (nonatomic, strong) MLAppAudioMuteController *audioMute;
/** When NO, stop monitor and clear mute taps (prefs). Default YES. */
@property (nonatomic, assign) BOOL audioIndicatorEnabled;

- (instancetype)initWithPinStore:(MLTaskbarPinStore *)pins
                         monitor:(MLRunningAppsMonitor *)monitor
                       iconCache:(MLIconCache *)icons;

- (void)start;
- (void)stop;

- (void)overlayWillShow;
- (void)overlayDidHide;

/** Idle reclaim: drop display-name strings only (icons stay warm). */
- (void)clearDisplayNameCacheForIdleReclaim;
/** Memory pressure: purge icon LRU + display names (reload on next paint). */
- (void)purgeRebuildableCachesForMemoryPressure;

@end

#import "MLTaskbarController+Categories.h"
