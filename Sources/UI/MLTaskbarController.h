#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

@class MLTaskbarPinStore;
@class MLRunningAppsMonitor;
@class MLIconCache;

@protocol MLTaskbarAppActions;

typedef NS_ENUM(NSInteger, MLWindowHideMethod);

@interface MLTaskbarController : NSObject

@property (nonatomic, assign, getter=isEnabled) BOOL enabled;
/** About / Preferences / Quit — typically AppDelegate. */
@property (nonatomic, weak) id<MLTaskbarAppActions> appActions;

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
