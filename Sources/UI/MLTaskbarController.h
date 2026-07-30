#import <Cocoa/Cocoa.h>

@class MLTaskbarPinStore;
@class MLRunningAppsMonitor;
@class MLTaskbarIconCache;

@interface MLTaskbarController : NSObject

@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

- (instancetype)initWithPinStore:(MLTaskbarPinStore *)pins
                         monitor:(MLRunningAppsMonitor *)monitor
                       iconCache:(MLTaskbarIconCache *)icons;

- (void)start;
- (void)stop;
- (void)rebuildItems;

- (void)overlayWillShow;
- (void)overlayDidHide;

@end
