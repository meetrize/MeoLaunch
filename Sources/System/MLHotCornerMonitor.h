#import <Cocoa/Cocoa.h>

#import "MLConfigStore.h"

@class MLHotCornerMonitor;

@protocol MLHotCornerMonitorDelegate <NSObject>
- (void)hotCornerMonitorDidTrigger:(MLHotCornerMonitor *)monitor;
@end

@interface MLHotCornerMonitor : NSObject

@property (nonatomic, weak) id<MLHotCornerMonitorDelegate> delegate;

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, assign) MLHotCornerPosition position;
@property (nonatomic, assign) CGFloat sizePt;
@property (nonatomic, assign) NSInteger delayMs;

- (void)applyConfig:(MLConfigStore *)config;
- (void)start;
- (void)stop;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

/// Returns YES if Accessibility is granted. If prompt is YES, may show system dialog.
+ (BOOL)isAccessibilityTrustedPrompting:(BOOL)prompt;

@end
