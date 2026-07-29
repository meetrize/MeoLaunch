#import "MLDismissBackgroundView.h"

@implementation MLDismissBackgroundView

- (BOOL)acceptsFirstResponder {
    return NO;
}

- (void)mouseDown:(NSEvent *)event {
    (void)event;
    [self.delegate dismissBackgroundViewClicked:self];
}

@end
