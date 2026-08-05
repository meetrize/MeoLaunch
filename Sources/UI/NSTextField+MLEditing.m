#import "NSTextField+MLEditing.h"

@implementation NSTextField (MLEditing)

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    NSText *editor = [self currentEditor];
    if (editor && [editor performKeyEquivalent:event]) {
        return YES;
    }
    return [super performKeyEquivalent:event];
}

@end
