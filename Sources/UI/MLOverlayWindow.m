#import "MLOverlayWindow.h"

@implementation MLOverlayWindow

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSResponder *responder = [self firstResponder];
    if (responder && responder != self && [responder performKeyEquivalent:event]) {
        return YES;
    }
    return [super performKeyEquivalent:event];
}

@end
