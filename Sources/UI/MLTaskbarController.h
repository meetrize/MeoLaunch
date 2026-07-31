#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

@class MLTaskbarPinStore;
@class MLRunningAppsMonitor;
@class MLTaskbarIconCache;

typedef NS_ENUM(NSInteger, MLWindowHideMethod);

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
                                          bounds:(CGRect)bounds
                                        windowID:(CGWindowID)windowID;

- (void)markSoftHiddenWindowID:(CGWindowID)windowID
                           pid:(pid_t)pid
                         title:(NSString *)title
                 restoreFrame:(NSRect)restoreFrame
                     screenID:(NSNumber *)screenID
                     axWindow:(AXUIElementRef)axWindow;

- (void)updateSoftHideMethod:(MLWindowHideMethod)method forWindowID:(CGWindowID)windowID;

- (void)markSoftMinimizedWindowID:(CGWindowID)windowID;

@end
