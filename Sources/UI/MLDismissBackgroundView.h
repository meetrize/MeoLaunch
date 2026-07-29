#import <Cocoa/Cocoa.h>

@class MLDismissBackgroundView;

@protocol MLDismissBackgroundViewDelegate <NSObject>
- (void)dismissBackgroundViewClicked:(MLDismissBackgroundView *)view;
@end

/** Full-window click catcher; anything not handled by views above dismisses overlay. */
@interface MLDismissBackgroundView : NSView
@property (nonatomic, weak) id<MLDismissBackgroundViewDelegate> delegate;
@end
