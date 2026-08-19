#import "MLSearchField.h"
#import "MLGhostPanelProbe.h"

#import <objc/message.h>

static const CGFloat kMLSearchLeftInset = 18.0;
static const CGFloat kMLSearchRightInset = 44.0;
static const CGFloat kMLSettingsButtonSize = 28.0;

@interface MLVerticallyCenteredTextFieldCell : NSTextFieldCell
@end

@implementation MLVerticallyCenteredTextFieldCell

- (NSRect)titleRectForBounds:(NSRect)rect {
    /* Extra right inset clears the settings gear.
     * Must NOT call attributedStringValue: that validates editing → currentEditor
     * → window fieldEditor: → pin → titleRect (infinite recursion / crash). */
    NSRect r = NSMakeRect(NSMinX(rect) + kMLSearchLeftInset,
                          NSMinY(rect),
                          MAX(0, NSWidth(rect) - kMLSearchLeftInset - kMLSearchRightInset),
                          NSHeight(rect));
    CGFloat textH = self.font ? self.font.boundingRectForFont.size.height : 16.0;
    CGFloat h = MIN(textH, NSHeight(r));
    r.origin.y += floor((NSHeight(r) - h) * 0.5);
    r.size.height = h;
    return r;
}

- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
    NSText *editor = [super setUpFieldEditorAttributes:textObj];
    if ([editor isKindOfClass:[NSTextView class]]) {
        NSTextView *tv = (NSTextView *)editor;
        NSFont *font = self.font ?: [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
        tv.font = font;
        tv.alignment = NSTextAlignmentCenter;
        tv.drawsBackground = NO;
        tv.backgroundColor = [NSColor clearColor];
        tv.focusRingType = NSFocusRingTypeNone;
        tv.textColor = [NSColor whiteColor];
        tv.insertionPointColor = [NSColor whiteColor];
        tv.continuousSpellCheckingEnabled = NO;
        tv.grammarCheckingEnabled = NO;
        tv.automaticSpellingCorrectionEnabled = NO;
        tv.automaticQuoteSubstitutionEnabled = NO;
        tv.automaticDashSubstitutionEnabled = NO;
        tv.automaticTextReplacementEnabled = NO;
        if ([tv respondsToSelector:@selector(setAutomaticTextCompletionEnabled:)]) {
            [(id)tv setAutomaticTextCompletionEnabled:NO];
        }
        if ([tv respondsToSelector:@selector(setInlinePredictionType:)]) {
            [(id)tv setInlinePredictionType:(NSInteger)1];
        }
        SEL writingToolsSel = NSSelectorFromString(@"setWritingToolsBehavior:");
        if ([tv respondsToSelector:writingToolsSel]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(tv, writingToolsSel, 0);
        }
        if ([tv respondsToSelector:@selector(setContentType:)]) {
            [(id)tv setContentType:@"org.meolaunch.search"];
        }
    }
    return editor;
}

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
    [super drawInteriorWithFrame:[self titleRectForBounds:cellFrame] inView:controlView];
}

- (void)editWithFrame:(NSRect)aRect
               inView:(NSView *)controlView
               editor:(NSText *)textObj
             delegate:(id)anObject
                event:(NSEvent *)theEvent {
    [super editWithFrame:[self titleRectForBounds:aRect]
                  inView:controlView
                  editor:textObj
                delegate:anObject
                   event:theEvent];
}

- (void)selectWithFrame:(NSRect)aRect
                 inView:(NSView *)controlView
                 editor:(NSText *)textObj
               delegate:(id)anObject
                  start:(NSInteger)selStart
                 length:(NSInteger)selLength {
    [super selectWithFrame:[self titleRectForBounds:aRect]
                    inView:controlView
                    editor:textObj
                  delegate:anObject
                     start:selStart
                    length:selLength];
}

@end

@interface MLSearchField ()
@property (nonatomic, strong) NSButton *settingsButton;
@end

@implementation MLSearchField

+ (Class)cellClass {
    return [MLVerticallyCenteredTextFieldCell class];
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.bezeled = NO;
        self.bordered = NO;
        self.drawsBackground = NO;
        self.editable = YES;
        self.selectable = YES;
        self.alignment = NSTextAlignmentCenter;
        self.font = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
        self.textColor = [NSColor whiteColor];
        self.focusRingType = NSFocusRingTypeNone;
        /* Do NOT wantsLayer: AppKit injects a rounded gray NSVisualEffectView
         * beside layer-backed text fields (the intermittent ghost panel). */
        self.wantsLayer = NO;
        if ([self respondsToSelector:@selector(setClipsToBounds:)]) {
            self.clipsToBounds = YES;
        }
        /* Stop OTP / password AutoFill from parking a small panel under search. */
        if ([self respondsToSelector:@selector(setContentType:)]) {
            [(id)self setContentType:@"org.meolaunch.search"];
        }

        self.placeholderString = nil;
        self.placeholderAttributedString = nil;

        [self setupSettingsButton];
    }
    return self;
}

- (void)setupSettingsButton {
    NSButton *btn = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, kMLSettingsButtonSize, kMLSettingsButtonSize)];
    btn.bordered = NO;
    btn.imagePosition = NSImageOnly;
    btn.bezelStyle = NSBezelStyleInline;
    btn.focusRingType = NSFocusRingTypeNone;
    btn.toolTip = @"Preferences";
    btn.target = self;
    btn.action = @selector(settingsClicked:);

    NSImage *image = [NSImage imageWithSystemSymbolName:@"gearshape"
                               accessibilityDescription:@"Preferences"];
    if (!image) {
        image = [NSImage imageNamed:NSImageNameAdvanced];
    }
    image.template = YES;
    btn.image = image;
    btn.contentTintColor = [[NSColor whiteColor] colorWithAlphaComponent:0.85];

    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration *cfg =
            [NSImageSymbolConfiguration configurationWithPointSize:14
                                                            weight:NSFontWeightMedium];
        btn.symbolConfiguration = cfg;
    }

    self.settingsButton = btn;
    [self addSubview:btn];
}

- (void)settingsClicked:(id)sender {
    (void)sender;
    [self.settingsDelegate searchFieldDidClickSettings:self];
}

- (void)layoutSettingsButton {
    if (!self.settingsButton) {
        return;
    }
    CGFloat h = NSHeight(self.bounds);
    CGFloat y = floor((h - kMLSettingsButtonSize) * 0.5);
    CGFloat x = NSWidth(self.bounds) - kMLSettingsButtonSize - 10.0;
    self.settingsButton.frame = NSMakeRect(x, y, kMLSettingsButtonSize, kMLSettingsButtonSize);
}

- (void)didAddSubview:(NSView *)subview {
    [super didAddSubview:subview];
    if (subview == self.settingsButton) {
        return;
    }
    NSString *cls = NSStringFromClass(subview.class);
    if ([cls isEqualToString:@"NSTextInsertionIndicator"]) {
        return;
    }
    [MLGhostPanelProbe noteSearchFieldSubview:subview];
    /* Only kill bezel paint — never hide/remove/reparent AppKit focus chrome.
     * Mutating `_NSKeyboardFocusClipView` mid-setup over-releases it (Option+Space SIGABRT). */
    if ([cls isEqualToString:@"_NSKeyboardFocusClipView"] &&
        [subview isKindOfClass:[NSClipView class]]) {
        ((NSClipView *)subview).drawsBackground = NO;
        ((NSClipView *)subview).backgroundColor = [NSColor clearColor];
        subview.focusRingType = NSFocusRingTypeNone;
        /* Defer fit until AppKit finishes nesting the field editor. */
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf ml_fitFocusChromeInPlace];
        });
    }
}

/**
 * Soften AppKit focus / indicator chrome paint only.
 * Do not remove, hide, zero-frame, or reparent `_NSKeyboardFocusClipView`.
 */
- (void)ml_purgeStaleFocusChrome {
    for (NSView *sub in self.subviews) {
        NSString *n = NSStringFromClass(sub.class);
        if (![n isEqualToString:@"_NSKeyboardFocusClipView"] &&
            ![n isEqualToString:@"NSTextIndicatorOverlay"]) {
            continue;
        }
        if ([sub isKindOfClass:[NSClipView class]]) {
            ((NSClipView *)sub).drawsBackground = NO;
            ((NSClipView *)sub).backgroundColor = [NSColor clearColor];
        }
        sub.focusRingType = NSFocusRingTypeNone;
    }
}

- (void)ml_fitFocusChromeInPlace {
    NSRect titleRect = [[self cell] titleRectForBounds:self.bounds];
    if (NSWidth(titleRect) < 4.0 || NSHeight(titleRect) < 4.0) {
        titleRect = NSInsetRect(self.bounds, kMLSearchLeftInset, 8.0);
    }

    NSFont *font = self.font ?: [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
    NSText *editor = [self currentEditor];
    NSView *editorView = [editor isKindOfClass:[NSView class]] ? (NSView *)editor : nil;

    for (NSView *sub in self.subviews) {
        NSString *n = NSStringFromClass(sub.class);
        BOOL isFocusClip = [n isEqualToString:@"_NSKeyboardFocusClipView"];
        if (!isFocusClip) {
            continue;
        }
        if ([sub isKindOfClass:[NSClipView class]]) {
            ((NSClipView *)sub).drawsBackground = NO;
            ((NSClipView *)sub).backgroundColor = [NSColor clearColor];
        }
        sub.focusRingType = NSFocusRingTypeNone;
        if (!NSEqualRects(NSIntegralRect(sub.frame), NSIntegralRect(titleRect))) {
            sub.frame = titleRect;
        }

        NSView *doc = nil;
        if ([sub isKindOfClass:[NSClipView class]]) {
            doc = ((NSClipView *)sub).documentView;
        }
        if (!doc && editorView) {
            for (NSView *v = editorView; v && v != self; v = v.superview) {
                if (v.superview == sub) {
                    doc = v;
                    break;
                }
            }
        }
        if (doc) {
            if (!NSEqualRects(NSIntegralRect(doc.frame), NSIntegralRect(sub.bounds))) {
                doc.frame = sub.bounds;
            }
            if ([doc isKindOfClass:[NSTextView class]]) {
                NSTextView *tv = (NSTextView *)doc;
                tv.font = font;
                tv.alignment = NSTextAlignmentCenter;
                tv.drawsBackground = NO;
                tv.backgroundColor = [NSColor clearColor];
                tv.textColor = [NSColor whiteColor];
                tv.insertionPointColor = [NSColor whiteColor];
                tv.focusRingType = NSFocusRingTypeNone;
                tv.textContainerInset = NSZeroSize;
            }
        }
    }

    if (editorView && [editorView isKindOfClass:[NSTextView class]]) {
        NSTextView *tv = (NSTextView *)editorView;
        tv.font = font;
        tv.alignment = NSTextAlignmentCenter;
        tv.drawsBackground = NO;
        tv.backgroundColor = [NSColor clearColor];
        tv.textColor = [NSColor whiteColor];
        tv.insertionPointColor = [NSColor whiteColor];
        tv.focusRingType = NSFocusRingTypeNone;
        tv.textContainerInset = NSZeroSize;

        BOOL insideClip = NO;
        for (NSView *v = editorView.superview; v && v != self; v = v.superview) {
            if ([NSStringFromClass(v.class) isEqualToString:@"_NSKeyboardFocusClipView"]) {
                insideClip = YES;
                break;
            }
        }
        if (!insideClip && editorView.superview == self) {
            if (!NSEqualRects(NSIntegralRect(editorView.frame), NSIntegralRect(titleRect))) {
                editorView.frame = titleRect;
            }
        }
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    if (NSHeight(self.bounds) > 48.0 || NSWidth(self.bounds) > 520.0) {
        static NSRect sLastOdd = {{0, 0}, {0, 0}};
        if (!NSEqualRects(NSIntegralRect(self.bounds), NSIntegralRect(sLastOdd))) {
            sLastOdd = self.bounds;
            NSLog(@"[MeoLaunch][GhostPanel] searchField ODD bounds=%@ win=%@ subviews=%lu",
                  NSStringFromRect(self.bounds),
                  NSStringFromRect([self convertRect:self.bounds toView:nil]),
                  (unsigned long)self.subviews.count);
        }
    }
    CGFloat h = NSHeight(self.bounds);
    CGFloat radius = h * 0.5;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
                                                        xRadius:radius
                                                        yRadius:radius];
    [[NSColor colorWithWhite:0.08 alpha:0.48] setFill];
    [path fill];
    [[NSColor colorWithWhite:1.0 alpha:0.22] setStroke];
    path.lineWidth = 1.0;
    [path stroke];
    [super drawRect:self.bounds];
}

- (BOOL)isOpaque {
    return NO;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self layoutSettingsButton];
}

- (void)layout {
    [super layout];
    [self layoutSettingsButton];
}

- (BOOL)acceptsFirstResponder {
    /* Must honor refusesFirstResponder. Returning YES here let makeKeyAndOrderFront
     * inject `_NSKeyboardFocusClipView` at zero size during showCritical, and
     * Option+Space then raced that clip view's dealloc. */
    return !self.refusesFirstResponder;
}

- (NSSize)intrinsicContentSize {
    NSSize s = [super intrinsicContentSize];
    s.height = MAX(s.height, 40.0);
    return s;
}

@end
