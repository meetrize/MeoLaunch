#import <Foundation/Foundation.h>

/** Debounced one-shot action (default 300 ms), shared by JSON persistence stores. */
@interface MLDebouncedSave : NSObject

@property (nonatomic, assign) NSTimeInterval interval; /* default 0.3 */

- (instancetype)initWithAction:(void (^)(void))action;
- (void)schedule;
- (void)cancel;

@end
