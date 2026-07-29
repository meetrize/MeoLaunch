#import "MLPrefsWindow.h"

#import "MLConfigStore.h"

@interface MLPrefsWindow () <NSTextFieldDelegate>
@property (nonatomic, weak) MLConfigStore *config;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSSlider *colsSlider;
@property (nonatomic, strong) NSTextField *colsValueLabel;
@property (nonatomic, strong) NSSlider *rowsSlider;
@property (nonatomic, strong) NSTextField *rowsValueLabel;
@property (nonatomic, strong) NSSlider *iconSizeSlider;
@property (nonatomic, strong) NSTextField *iconSizeValueLabel;
@property (nonatomic, strong) NSSlider *opacitySlider;
@property (nonatomic, strong) NSTextField *opacityValueLabel;
@property (nonatomic, strong) NSButton *hotCornerEnabled;
@property (nonatomic, strong) NSPopUpButton *cornerPopup;
@property (nonatomic, strong) NSTextField *sizeField;
@property (nonatomic, strong) NSTextField *pathLabel;
@property (nonatomic, assign) BOOL suppressApply;
@end

@implementation MLPrefsWindow

- (instancetype)initWithConfigStore:(MLConfigStore *)config {
    self = [super init];
    if (self) {
        _config = config;
    }
    return self;
}

- (NSTextField *)makeLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *f = [NSTextField labelWithString:text];
    f.frame = frame;
    f.editable = NO;
    f.bordered = NO;
    f.backgroundColor = [NSColor clearColor];
    return f;
}

- (NSTextField *)makeField:(NSRect)frame {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    f.editable = YES;
    f.bezeled = YES;
    return f;
}

- (NSSlider *)makeIntSliderMin:(double)min max:(double)max action:(SEL)action {
    NSSlider *s = [NSSlider sliderWithValue:min
                                   minValue:min
                                   maxValue:max
                                     target:self
                                     action:action];
    s.numberOfTickMarks = (NSInteger)(max - min) + 1;
    s.allowsTickMarkValuesOnly = YES;
    s.tickMarkPosition = NSTickMarkPositionBelow;
    return s;
}

- (void)ensureWindow {
    if (self.window) {
        return;
    }

    NSRect rect = NSMakeRect(0, 0, 480, 384);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:rect
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"MeoLaunch Preferences";
    w.releasedWhenClosed = NO;
    /* Above overlay (NSStatusWindowLevel) so Preferences stays visible on top. */
    w.level = NSStatusWindowLevel + 1;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                           NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSView *c = w.contentView;

    CGFloat y = 324;

    [c addSubview:[self makeLabel:@"Grid columns" frame:NSMakeRect(20, y, 120, 22)]];
    self.colsSlider = [self makeIntSliderMin:4 max:10 action:@selector(colsChanged:)];
    self.colsSlider.frame = NSMakeRect(140, y - 4, 260, 28);
    [c addSubview:self.colsSlider];
    self.colsValueLabel = [self makeLabel:@"7" frame:NSMakeRect(410, y, 40, 22)];
    self.colsValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.colsValueLabel];
    y -= 44;

    [c addSubview:[self makeLabel:@"Grid rows" frame:NSMakeRect(20, y, 120, 22)]];
    self.rowsSlider = [self makeIntSliderMin:3 max:8 action:@selector(rowsChanged:)];
    self.rowsSlider.frame = NSMakeRect(140, y - 4, 260, 28);
    [c addSubview:self.rowsSlider];
    self.rowsValueLabel = [self makeLabel:@"5" frame:NSMakeRect(410, y, 40, 22)];
    self.rowsValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.rowsValueLabel];
    y -= 44;

    [c addSubview:[self makeLabel:@"Icon size" frame:NSMakeRect(20, y, 120, 22)]];
    /* 0 = Auto; 48…160 = fixed pt */
    self.iconSizeSlider = [NSSlider sliderWithValue:0
                                           minValue:0
                                           maxValue:160
                                             target:self
                                             action:@selector(iconSizeChanged:)];
    self.iconSizeSlider.numberOfTickMarks = 11;
    self.iconSizeSlider.allowsTickMarkValuesOnly = NO;
    self.iconSizeSlider.tickMarkPosition = NSTickMarkPositionBelow;
    self.iconSizeSlider.frame = NSMakeRect(140, y - 4, 260, 28);
    [c addSubview:self.iconSizeSlider];
    self.iconSizeValueLabel = [self makeLabel:@"Auto" frame:NSMakeRect(410, y, 50, 22)];
    self.iconSizeValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.iconSizeValueLabel];
    y -= 44;

    [c addSubview:[self makeLabel:@"Overlay opacity" frame:NSMakeRect(20, y, 120, 22)]];
    self.opacitySlider = [NSSlider sliderWithValue:55
                                          minValue:0
                                          maxValue:100
                                            target:self
                                            action:@selector(opacityChanged:)];
    self.opacitySlider.numberOfTickMarks = 11;
    self.opacitySlider.allowsTickMarkValuesOnly = NO;
    self.opacitySlider.tickMarkPosition = NSTickMarkPositionBelow;
    self.opacitySlider.frame = NSMakeRect(140, y - 4, 260, 28);
    [c addSubview:self.opacitySlider];
    self.opacityValueLabel = [self makeLabel:@"55%" frame:NSMakeRect(410, y, 50, 22)];
    self.opacityValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.opacityValueLabel];
    y -= 44;

    self.hotCornerEnabled = [NSButton checkboxWithTitle:@"Hot corner enabled"
                                                 target:self
                                                 action:@selector(prefsChanged:)];
    self.hotCornerEnabled.frame = NSMakeRect(20, y, 220, 24);
    [c addSubview:self.hotCornerEnabled];
    y -= 36;

    [c addSubview:[self makeLabel:@"Hot corner" frame:NSMakeRect(20, y, 120, 22)]];
    self.cornerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(150, y - 3, 180, 26) pullsDown:NO];
    [self.cornerPopup addItemsWithTitles:@[
        @"Top Left", @"Top Right", @"Bottom Left", @"Bottom Right", @"Off"
    ]];
    self.cornerPopup.target = self;
    self.cornerPopup.action = @selector(prefsChanged:);
    [c addSubview:self.cornerPopup];
    y -= 36;

    [c addSubview:[self makeLabel:@"Hot size (pt)" frame:NSMakeRect(20, y, 120, 22)]];
    self.sizeField = [self makeField:NSMakeRect(150, y - 2, 60, 24)];
    self.sizeField.delegate = self;
    self.sizeField.target = self;
    self.sizeField.action = @selector(prefsChanged:);
    [c addSubview:self.sizeField];

    self.pathLabel = [self makeLabel:@"" frame:NSMakeRect(20, 16, 440, 36)];
    self.pathLabel.font = [NSFont systemFontOfSize:10];
    self.pathLabel.textColor = [NSColor secondaryLabelColor];
    self.pathLabel.maximumNumberOfLines = 2;
    [c addSubview:self.pathLabel];

    self.window = w;
}

- (void)colsChanged:(id)sender {
    (void)sender;
    self.colsValueLabel.stringValue =
        [NSString stringWithFormat:@"%.0f", self.colsSlider.doubleValue];
    [self applyLive];
}

- (void)rowsChanged:(id)sender {
    (void)sender;
    self.rowsValueLabel.stringValue =
        [NSString stringWithFormat:@"%.0f", self.rowsSlider.doubleValue];
    [self applyLive];
}

- (float)iconSizeFromSlider {
    double v = self.iconSizeSlider.doubleValue;
    if (v < 1.0) {
        return 0.f; /* Auto */
    }
    /* Skip the dead zone between Auto and the minimum fixed size. */
    if (v < 48.0) {
        v = 48.0;
        self.iconSizeSlider.doubleValue = v;
    }
    return (float)lround(v);
}

- (void)updateIconSizeLabel {
    float size = [self iconSizeFromSlider];
    if (size <= 0.f) {
        self.iconSizeValueLabel.stringValue = @"Auto";
    } else {
        self.iconSizeValueLabel.stringValue =
            [NSString stringWithFormat:@"%.0f", size];
    }
}

- (void)iconSizeChanged:(id)sender {
    (void)sender;
    [self updateIconSizeLabel];
    [self applyLive];
}

- (void)opacityChanged:(id)sender {
    (void)sender;
    self.opacityValueLabel.stringValue =
        [NSString stringWithFormat:@"%.0f%%", self.opacitySlider.doubleValue];
    [self applyLive];
}

- (void)prefsChanged:(id)sender {
    (void)sender;
    [self applyLive];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == self.sizeField) {
        [self applyLive];
    }
}

- (MLHotCornerPosition)positionFromPopup {
    switch (self.cornerPopup.indexOfSelectedItem) {
        case 0: return MLHotCornerPositionTopLeft;
        case 1: return MLHotCornerPositionTopRight;
        case 2: return MLHotCornerPositionBottomLeft;
        case 3: return MLHotCornerPositionBottomRight;
        default: return MLHotCornerPositionOff;
    }
}

- (void)selectPopupForPosition:(MLHotCornerPosition)p {
    NSInteger idx = 4;
    switch (p) {
        case MLHotCornerPositionTopLeft: idx = 0; break;
        case MLHotCornerPositionTopRight: idx = 1; break;
        case MLHotCornerPositionBottomLeft: idx = 2; break;
        case MLHotCornerPositionBottomRight: idx = 3; break;
        default: idx = 4; break;
    }
    [self.cornerPopup selectItemAtIndex:idx];
}

- (void)reloadFields {
    self.suppressApply = YES;
    self.colsSlider.doubleValue = self.config.gridConfig.cols;
    self.rowsSlider.doubleValue = self.config.gridConfig.rows;
    self.colsValueLabel.stringValue =
        [NSString stringWithFormat:@"%.0f", self.colsSlider.doubleValue];
    self.rowsValueLabel.stringValue =
        [NSString stringWithFormat:@"%.0f", self.rowsSlider.doubleValue];
    float icon = self.config.gridConfig.icon_size;
    if (icon <= 0.f) {
        self.iconSizeSlider.doubleValue = 0;
    } else {
        if (icon < 48.f) icon = 48.f;
        if (icon > 160.f) icon = 160.f;
        self.iconSizeSlider.doubleValue = icon;
    }
    [self updateIconSizeLabel];
    self.opacitySlider.doubleValue = self.config.overlayOpacity * 100.0;
    self.opacityValueLabel.stringValue =
        [NSString stringWithFormat:@"%.0f%%", self.opacitySlider.doubleValue];
    self.hotCornerEnabled.state = self.config.hotCornerEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self selectPopupForPosition:self.config.hotCornerPosition];
    self.sizeField.stringValue = [NSString stringWithFormat:@"%.0f", self.config.hotCornerSizePt];
    self.pathLabel.stringValue =
        [NSString stringWithFormat:@"Config: %@", [MLConfigStore configFileURL].path];
    self.suppressApply = NO;
}

- (void)applyLive {
    if (self.suppressApply || !self.window) {
        return;
    }
    int cols = (int)lround(self.colsSlider.doubleValue);
    int rows = (int)lround(self.rowsSlider.doubleValue);
    [self.config updateGridCols:cols rows:rows];
    [self.config updateGridIconSize:[self iconSizeFromSlider]];
    [self.config updateOverlayOpacity:self.opacitySlider.doubleValue / 100.0];

    CGFloat size = self.sizeField.doubleValue;
    [self.config updateHotCornerEnabled:(self.hotCornerEnabled.state == NSControlStateValueOn)
                               position:[self positionFromPopup]
                                 sizePt:size
                                delayMs:self.config.hotCornerDelayMs];
}

- (void)show {
    [self ensureWindow];
    [self reloadFields];
    [self.window center];
    [self.window orderFrontRegardless];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

@end
