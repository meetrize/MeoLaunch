#import "MLOverlayWindow.h"

@interface MLOverlayWindow ()
@property (nonatomic, strong) NSTextView *mlOwnedFieldEditor;
@end

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

- (NSTextView *)ml_styledFieldEditor {
    if (!self.mlOwnedFieldEditor) {
        NSTextView *tv = [[NSTextView alloc] initWithFrame:NSZeroRect];
        tv.fieldEditor = YES;
        tv.richText = NO;
        tv.importsGraphics = NO;
        tv.allowsUndo = YES;
        tv.focusRingType = NSFocusRingTypeNone;
        tv.insertionPointColor = [NSColor whiteColor];
        tv.textColor = [NSColor whiteColor];
        tv.selectedTextAttributes = @{
            NSBackgroundColorAttributeName: [[NSColor selectedControlColor] colorWithAlphaComponent:0.55],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        self.mlOwnedFieldEditor = tv;
    }
    [self ml_restyleFieldEditor];
    return self.mlOwnedFieldEditor;
}

- (NSTextView *)ml_ownedFieldEditorIfAny {
    return self.mlOwnedFieldEditor;
}

- (void)ml_restyleFieldEditor {
    NSTextView *tv = self.mlOwnedFieldEditor;
    if (!tv) {
        return;
    }
    tv.drawsBackground = NO;
    tv.backgroundColor = [NSColor clearColor];
    tv.textContainerInset = NSZeroSize;
    if (tv.wantsLayer) {
        tv.layer.backgroundColor = [NSColor clearColor].CGColor;
    }
    NSScrollView *scroll = tv.enclosingScrollView;
    if (scroll) {
        scroll.drawsBackground = NO;
        scroll.backgroundColor = [NSColor clearColor];
        scroll.borderType = NSNoBorder;
        scroll.hasVerticalScroller = NO;
        scroll.hasHorizontalScroller = NO;
        if (scroll.wantsLayer) {
            scroll.layer.backgroundColor = [NSColor clearColor].CGColor;
        }
        NSView *clip = scroll.contentView;
        if ([clip isKindOfClass:[NSClipView class]]) {
            ((NSClipView *)clip).drawsBackground = NO;
            ((NSClipView *)clip).backgroundColor = [NSColor clearColor];
        }
    }
}

- (NSText *)fieldEditor:(BOOL)create forObject:(id)object {
    (void)object;
    if (!create && !self.mlOwnedFieldEditor) {
        return nil;
    }
    return [self ml_styledFieldEditor];
}

@end
