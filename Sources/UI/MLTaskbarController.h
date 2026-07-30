#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

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

/** Screen-coordinate rect of the matching task item (for minimize animation). */
- (NSRect)animationTargetRectForPID:(pid_t)pid
                              title:(NSString *)title
                       windowBounds:(CGRect)windowBounds;

/** Called after a custom / soft minimize. */
- (void)refreshAfterCustomMinimize;

/** Record window frame before soft-minimize; returns matched CGWindowID (0 if unknown). */
- (CGWindowID)rememberWindowForCustomMinimizePID:(pid_t)pid
                                           title:(NSString *)title
                                          bounds:(CGRect)bounds;

- (void)markSoftMinimizedWindowID:(CGWindowID)windowID;

@end
