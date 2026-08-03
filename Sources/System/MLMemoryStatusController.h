#import <Cocoa/Cocoa.h>

/** Menu-bar free-memory % (doc/13-menubar-memory.md). */
@interface MLMemoryStatusController : NSObject

@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

- (void)startWithInterval:(NSTimeInterval)seconds;
- (void)stop;
/** Apply interval while running; no-op if stopped. */
- (void)applyInterval:(NSTimeInterval)seconds;

@end
