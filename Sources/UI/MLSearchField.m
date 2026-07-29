#import "MLSearchField.h"

static const CGFloat kMLSearchLeftInset = 18.0;
static const CGFloat kMLSearchRightInset = 44.0;
static const CGFloat kMLSettingsButtonSize = 28.0;

@interface MLVerticallyCenteredTextFieldCell : NSTextFieldCell
@end

@implementation MLVerticallyCenteredTextFieldCell

- (NSRect)titleRectForBounds:(NSRect)rect {
    /* Extra right inset clears the settings gear */
    NSRect r = NSMakeRect(NSMinX(rect) + kMLSearchLeftInset,
                          NSMinY(rect),
                          MAX(0, NSWidth(rect) - kMLSearchLeftInset - kMLSearchRightInset),
                          NSHeight(rect));
    NSSize textSize = [[self attributedStringValue] size];
    if (textSize.height < 1.0 && self.placeholderAttributedString) {
        textSize = [self.placeholderAttributedString size];
    }
    if (textSize.height < 1.0 && self.font) {
        textSize.height = self.font.boundingRectForFont.size.height;
    }
    CGFloat h = MIN(textSize.height, NSHeight(r));
    r.origin.y += floor((NSHeight(r) - h) * 0.5);
    r.size.height = h;
    return r;
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

        self.wantsLayer = YES;
        self.layer.backgroundColor = [[NSColor colorWithWhite:0.08 alpha:0.48] CGColor];
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.22] CGColor];
        self.layer.masksToBounds = YES;
        [self applyCapsuleMask];

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

- (void)applyCapsuleMask {
    CGFloat h = MAX(NSHeight(self.bounds), 36.0);
    self.layer.cornerRadius = h * 0.5;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self applyCapsuleMask];
    [self layoutSettingsButton];
}

- (void)layout {
    [super layout];
    [self applyCapsuleMask];
    [self layoutSettingsButton];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (NSSize)intrinsicContentSize {
    NSSize s = [super intrinsicContentSize];
    s.height = MAX(s.height, 40.0);
    return s;
}

@end
