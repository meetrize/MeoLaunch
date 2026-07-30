#import <Cocoa/Cocoa.h>

@class MLTaskbarController;

@interface MLMinimizeInterceptor : NSObject

@property (nonatomic, weak) MLTaskbarController *taskbar;

- (void)start;
- (void)stop;

@end
