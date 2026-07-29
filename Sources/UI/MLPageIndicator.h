#import <Cocoa/Cocoa.h>

@class MLPageIndicator;

@protocol MLPageIndicatorDelegate <NSObject>
- (void)pageIndicator:(MLPageIndicator *)indicator didSelectPage:(NSInteger)page;
@optional
- (void)pageIndicatorDidClickBackground:(MLPageIndicator *)indicator;
@end

@interface MLPageIndicator : NSView

@property (nonatomic, weak) id<MLPageIndicatorDelegate> delegate;
@property (nonatomic, assign) NSInteger pageCount;
@property (nonatomic, assign) NSInteger currentPage;

- (void)updateWithPage:(NSInteger)page pageCount:(NSInteger)pageCount;

@end
