#import "MLOverlayWindow.h"
#import "MLGhostPanelProbe.h"
#import "MLSearchField.h"

#import <objc/message.h>

/**
 * AppKit's default field editor intermittently paints an opaque control-background
 * (light gray rounded rect) under the search bar on a clear key window.
 * Override setters + drawing so the ghost panel cannot reappear after restyle.
 */
@interface MLFieldEditorTextView : NSTextView
- (void)ml_forceClearChrome;
- (void)ml_clearEnclosingScrollChrome;
- (void)ml_disableAutomaticPanels;
@end

@implementation MLFieldEditorTextView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self ml_forceClearChrome];
        [self ml_disableAutomaticPanels];
    }
    return self;
}

- (void)ml_disableAutomaticPanels {
    self.richText = NO;
    self.importsGraphics = NO;
    self.allowsUndo = YES;
    self.usesFindBar = NO;
    self.usesInspectorBar = NO;
    self.continuousSpellCheckingEnabled = NO;
    self.grammarCheckingEnabled = NO;
    self.automaticSpellingCorrectionEnabled = NO;
    self.automaticQuoteSubstitutionEnabled = NO;
    self.automaticDashSubstitutionEnabled = NO;
    self.automaticTextReplacementEnabled = NO;
    self.automaticDataDetectionEnabled = NO;
    self.automaticLinkDetectionEnabled = NO;
    self.smartInsertDeleteEnabled = NO;
    self.incrementalSearchingEnabled = NO;
    if ([self respondsToSelector:@selector(setAutomaticTextCompletionEnabled:)]) {
        [(id)self setAutomaticTextCompletionEnabled:NO];
    }
    if ([self respondsToSelector:@selector(setInlinePredictionType:)]) {
        /* NSTextInputTraitTypeNo = 1 */
        [(id)self setInlinePredictionType:(NSInteger)1];
    }
    /* Writing Tools is macOS 15+; call via msgSend so older SDKs still compile. */
    SEL writingToolsSel = NSSelectorFromString(@"setWritingToolsBehavior:");
    if ([self respondsToSelector:writingToolsSel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(self, writingToolsSel, 0);
    }
    if ([self respondsToSelector:@selector(setAllowsCharacterPickerTouchBarItem:)]) {
        [(id)self setAllowsCharacterPickerTouchBarItem:NO];
    }
    if ([self respondsToSelector:@selector(setContentType:)]) {
        [(id)self setContentType:@"org.meolaunch.search"];
    }
}

- (void)ml_forceClearChrome {
    [super setDrawsBackground:NO];
    [super setBackgroundColor:[NSColor clearColor]];
    self.focusRingType = NSFocusRingTypeNone;
    if (self.wantsLayer) {
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
        self.layer.opaque = NO;
    }
}

- (void)setDrawsBackground:(BOOL)drawsBackground {
    (void)drawsBackground;
    [super setDrawsBackground:NO];
}

- (void)setBackgroundColor:(NSColor *)backgroundColor {
    (void)backgroundColor;
    [super setBackgroundColor:[NSColor clearColor]];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self ml_forceClearChrome];
    [self ml_disableAutomaticPanels];
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    [self ml_forceClearChrome];
    [self ml_clearEnclosingScrollChrome];
    NSView *host = self.superview;
    while (host && ![host isKindOfClass:[NSTextField class]]) {
        host = host.superview;
    }
    if (!host) {
        [MLGhostPanelProbe noteStrayEditor:self host:self.superview reason:@"moved-no-textfield-host"];
    }
}

- (void)ml_clearEnclosingScrollChrome {
    NSScrollView *scroll = self.enclosingScrollView;
    if (!scroll) {
        return;
    }
    scroll.drawsBackground = NO;
    scroll.backgroundColor = [NSColor clearColor];
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = NO;
    scroll.hasHorizontalScroller = NO;
    if (scroll.wantsLayer) {
        scroll.layer.backgroundColor = [NSColor clearColor].CGColor;
        scroll.layer.opaque = NO;
    }
    NSView *clip = scroll.contentView;
    if ([clip isKindOfClass:[NSClipView class]]) {
        ((NSClipView *)clip).drawsBackground = NO;
        ((NSClipView *)clip).backgroundColor = [NSColor clearColor];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    [self ml_forceClearChrome];
    NSView *host = self.superview;
    while (host && ![host isKindOfClass:[NSTextField class]]) {
        host = host.superview;
    }
    NSRect selfWin = [self convertRect:self.bounds toView:nil];
    if (!host) {
        [MLGhostPanelProbe noteStrayEditor:self host:nil reason:@"draw-no-host"];
    } else {
        NSRect hostWin = [host convertRect:host.bounds toView:nil];
        if (!NSContainsRect(NSInsetRect(hostWin, -16.0, -16.0), selfWin)) {
            [MLGhostPanelProbe noteStrayEditor:self host:host reason:@"draw-outside-host"];
        }
    }
    [super drawRect:dirtyRect];
}

- (void)complete:(id)sender {
    (void)sender;
}

- (NSArray *)completionsForPartialWordRange:(NSRange)charRange
                        indexOfSelectedItem:(NSInteger *)index {
    (void)charRange;
    if (index) {
        *index = -1;
    }
    return @[];
}

@end

@interface MLOverlayWindow ()
@property (nonatomic, strong) NSTextView *mlOwnedFieldEditor;
@property (nonatomic, weak) NSTextField *mlHostSearchField;
@property (nonatomic, weak) NSTextField *mlHostTitleField;
@property (nonatomic, assign) BOOL mlInFieldEditorRequest;
@property (nonatomic, assign) BOOL mlInPinFieldEditor;
@end

@interface MLOverlayContentView : NSView
@property (nonatomic, weak) MLOverlayWindow *mlOverlayWindow;
@end

@implementation MLOverlayContentView

- (void)didAddSubview:(NSView *)subview {
    [super didAddSubview:subview];
    [self ml_handleInsertedView:subview];
}

- (BOOL)ml_viewLooksLikeFieldEditorChrome:(NSView *)view {
    if ([view isKindOfClass:[NSTextView class]]) {
        NSTextView *tv = (NSTextView *)view;
        return tv.isFieldEditor || tv == self.mlOverlayWindow.ml_ownedFieldEditorIfAny;
    }
    if ([view isKindOfClass:[NSScrollView class]]) {
        NSView *doc = ((NSScrollView *)view).documentView;
        return [self ml_viewLooksLikeFieldEditorChrome:doc];
    }
    if ([view isKindOfClass:[NSClipView class]]) {
        NSView *doc = ((NSClipView *)view).documentView;
        return [self ml_viewLooksLikeFieldEditorChrome:doc];
    }
    return NO;
}

- (BOOL)ml_isKnownOverlayChrome:(NSView *)view {
    for (NSView *v = view; v; v = v.superview) {
        if ([v.identifier hasPrefix:@"ml."]) {
            return YES;
        }
        if ([self ml_viewLooksLikeFieldEditorChrome:v]) {
            return YES;
        }
    }
    return NO;
}

- (void)ml_handleInsertedView:(NSView *)view {
    if (!view || self.mlOverlayWindow.mlInFieldEditorRequest || self.mlOverlayWindow.mlInPinFieldEditor) {
        return;
    }
    NSString *cls = NSStringFromClass(view.class);
    /* Never strip AppKit keyboard-focus chrome — removing it crashes in dealloc. */
    if ([cls isEqualToString:@"_NSKeyboardFocusClipView"] ||
        [cls isEqualToString:@"NSTextIndicatorOverlay"] ||
        [cls isEqualToString:@"NSTextInsertionIndicator"]) {
        return;
    }
    if ([self ml_viewLooksLikeFieldEditorChrome:view]) {
        [self.mlOverlayWindow ml_restyleFieldEditor];
        return;
    }
    if ([self ml_isKnownOverlayChrome:view]) {
        return;
    }
    /* AppKit injects NSVisualEffectView / NSBox / extra clip views as the gray ghost. */
    __weak typeof(self) weakSelf = self;
    NSView *captured = view;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !captured.superview) {
            return;
        }
        if ([self ml_isKnownOverlayChrome:captured] ||
            [self ml_viewLooksLikeFieldEditorChrome:captured]) {
            return;
        }
        NSLog(@"[MeoLaunch][ChromeAnomaly] contentView stripping class=%@ frame=%@ ident=%@",
              NSStringFromClass(captured.class),
              NSStringFromRect(captured.frame),
              captured.identifier ?: @"");
        [MLGhostPanelProbe dumpSnapshot:@"contentView-strip"];
        [captured removeFromSuperview];
        NSLog(@"[MeoLaunch][ChromeAnomaly] contentView stripped class=%@ frame=%@",
              NSStringFromClass(captured.class), NSStringFromRect(captured.frame));
    });
}

@end

@implementation MLOverlayWindow

- (instancetype)initWithContentRect:(NSRect)contentRect
                          styleMask:(NSWindowStyleMask)style
                            backing:(NSBackingStoreType)backingStoreType
                              defer:(BOOL)flag {
    self = [super initWithContentRect:contentRect
                            styleMask:style
                              backing:backingStoreType
                                defer:flag];
    if (self) {
        MLOverlayContentView *content = [[MLOverlayContentView alloc] initWithFrame:NSMakeRect(0, 0, contentRect.size.width, contentRect.size.height)];
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        content.mlOverlayWindow = self;
        self.contentView = content;
    }
    return self;
}

- (BOOL)makeFirstResponder:(NSResponder *)responder {
    if ([responder isKindOfClass:[NSTextField class]] &&
        [(NSTextField *)responder refusesFirstResponder]) {
        responder = nil;
    }
    NSResponder *prev = self.firstResponder;
    BOOL ok = [super makeFirstResponder:responder];
    if (responder != prev) {
        [MLGhostPanelProbe noteFirstResponder:responder result:ok previous:prev];
    }
    return ok;
}

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
    /* Option+Space (launcher hotkey) must not reach the field editor — it inserts
     * a non-breaking space and races `_NSKeyboardFocusClipView` teardown. */
    NSEventModifierFlags mods = event.modifierFlags &
        (NSEventModifierFlagShift | NSEventModifierFlagControl |
         NSEventModifierFlagOption | NSEventModifierFlagCommand);
    if (event.keyCode == 49 && mods == NSEventModifierFlagOption) {
        return YES;
    }
    NSResponder *responder = [self firstResponder];
    if (responder && responder != self && [responder performKeyEquivalent:event]) {
        return YES;
    }
    return [super performKeyEquivalent:event];
}

- (void)ml_setHostSearchField:(NSTextField *)field titleField:(NSTextField *)titleField {
    self.mlHostSearchField = field;
    self.mlHostTitleField = titleField;
}

- (NSTextField *)ml_activeHostField {
    NSResponder *fr = self.firstResponder;
    if (self.mlHostTitleField && !self.mlHostTitleField.hidden &&
        (fr == self.mlHostTitleField ||
         ([fr isKindOfClass:[NSTextView class]] &&
          ((NSTextView *)fr).delegate == (id)self.mlHostTitleField))) {
        return self.mlHostTitleField;
    }
    return self.mlHostSearchField;
}

- (NSTextView *)ml_styledFieldEditor {
    NSText *editor = [self fieldEditor:YES forObject:self.mlHostSearchField];
    if ([editor isKindOfClass:[NSTextView class]]) {
        return (NSTextView *)editor;
    }
    return nil;
}

- (NSTextView *)ml_ownedFieldEditorIfAny {
    return self.mlOwnedFieldEditor;
}

- (void)ml_restyleFieldEditor {
    NSTextView *tv = self.mlOwnedFieldEditor;
    if (!tv) {
        return;
    }
    NSFont *font = self.mlHostSearchField.font
        ?: [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
    tv.font = font;
    tv.alignment = NSTextAlignmentCenter;
    tv.drawsBackground = NO;
    tv.backgroundColor = [NSColor clearColor];
    tv.textColor = [NSColor whiteColor];
    tv.insertionPointColor = [NSColor whiteColor];
    tv.textContainerInset = NSZeroSize;
    tv.focusRingType = NSFocusRingTypeNone;
    if ([tv isKindOfClass:[MLFieldEditorTextView class]]) {
        [(MLFieldEditorTextView *)tv ml_forceClearChrome];
        [(MLFieldEditorTextView *)tv ml_clearEnclosingScrollChrome];
        [(MLFieldEditorTextView *)tv ml_disableAutomaticPanels];
    }
    NSScrollView *scroll = tv.enclosingScrollView;
    if (scroll) {
        scroll.drawsBackground = NO;
        scroll.backgroundColor = [NSColor clearColor];
        scroll.borderType = NSNoBorder;
        scroll.hasVerticalScroller = NO;
        scroll.hasHorizontalScroller = NO;
        NSView *clip = scroll.contentView;
        if ([clip isKindOfClass:[NSClipView class]]) {
            ((NSClipView *)clip).drawsBackground = NO;
            ((NSClipView *)clip).backgroundColor = [NSColor clearColor];
        }
    }
}

- (void)ml_pinFieldEditorToHostField {
    if (self.mlInPinFieldEditor || self.mlInFieldEditorRequest) {
        return;
    }
    NSTextView *tv = self.mlOwnedFieldEditor;
    NSTextField *field = [self ml_activeHostField];
    if (!tv || !field || field.hidden) {
        return;
    }
    self.mlInPinFieldEditor = YES;

    if ([field isKindOfClass:[MLSearchField class]]) {
        [(MLSearchField *)field ml_fitFocusChromeInPlace];
        self.mlInPinFieldEditor = NO;
        return;
    }

    NSRect titleRect = NSInsetRect(field.bounds, 18.0, 8.0);
    if (NSWidth(titleRect) < 4.0 || NSHeight(titleRect) < 4.0) {
        titleRect = field.bounds;
    }
    NSView *host = tv.enclosingScrollView ?: (NSView *)tv;
    /* Never reparent out of `_NSKeyboardFocusClipView` — only size in place. */
    for (NSView *v = host.superview; v && v != field; v = v.superview) {
        NSString *n = NSStringFromClass(v.class);
        if ([n isEqualToString:@"_NSKeyboardFocusClipView"]) {
            if ([v isKindOfClass:[NSClipView class]]) {
                ((NSClipView *)v).drawsBackground = NO;
                ((NSClipView *)v).backgroundColor = [NSColor clearColor];
            }
            v.focusRingType = NSFocusRingTypeNone;
            v.frame = titleRect;
            host.frame = v.bounds;
            if (host != tv) {
                tv.frame = host.bounds;
            }
            field.clipsToBounds = YES;
            self.mlInPinFieldEditor = NO;
            return;
        }
    }
    if (host.superview == field) {
        host.frame = titleRect;
        if (host != tv) {
            tv.frame = host.bounds;
        }
    }
    field.clipsToBounds = YES;
    self.mlInPinFieldEditor = NO;
}

- (NSText *)fieldEditor:(BOOL)create forObject:(id)object {
    if (self.mlInFieldEditorRequest) {
        return [super fieldEditor:create forObject:object];
    }
    self.mlInFieldEditorRequest = YES;
    /* Use AppKit's own field editor. Returning a long-lived custom NSTextView
     * as documentView of `_NSKeyboardFocusClipView` over-releases that clip
     * on the next Option+Space (SIGABRT in dealloc). */
    NSText *editor = [super fieldEditor:create forObject:object];
    self.mlInFieldEditorRequest = NO;
    if ([editor isKindOfClass:[NSTextView class]]) {
        self.mlOwnedFieldEditor = (NSTextView *)editor;
        [self ml_restyleFieldEditor];
    }
    [MLGhostPanelProbe noteFieldEditorRequest:create object:object editor:editor];
    return editor;
}

@end
