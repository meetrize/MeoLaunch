#import "MLPrefsWindow.h"

#import "MLConfigStore.h"
#import "MLLaunchAtLogin.h"
#import "MLScreenGeometry.h"
#import "MLHotKeyRecorder.h"
#import "MLHotKeyDisplay.h"
#import "MLStrings.h"

#import <Carbon/Carbon.h>

/** Top-down layout coordinates for the prefs form. */
@interface MLPrefsFormView : NSView
@end
@implementation MLPrefsFormView
- (BOOL)isFlipped {
    return YES;
}
@end

@interface MLPrefsWindow () <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak) MLConfigStore *config;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSScrollView *outerScroll;
@property (nonatomic, strong) NSView *bottomBar;
@property (nonatomic, strong) NSTextField *sectionGeneral;
@property (nonatomic, strong) NSTextField *sectionHot;
@property (nonatomic, strong) NSTextField *sectionPerf;
@property (nonatomic, strong) NSTextField *languageLabel;
@property (nonatomic, strong) NSPopUpButton *languagePopup;
@property (nonatomic, strong) NSTextField *colsLabel;
@property (nonatomic, strong) NSSlider *colsSlider;
@property (nonatomic, strong) NSTextField *colsValueLabel;
@property (nonatomic, strong) NSTextField *rowsLabel;
@property (nonatomic, strong) NSSlider *rowsSlider;
@property (nonatomic, strong) NSTextField *rowsValueLabel;
@property (nonatomic, strong) NSTextField *iconSizeLabel;
@property (nonatomic, strong) NSSlider *iconSizeSlider;
@property (nonatomic, strong) NSTextField *iconSizeValueLabel;
@property (nonatomic, strong) NSTextField *opacityLabel;
@property (nonatomic, strong) NSSlider *opacitySlider;
@property (nonatomic, strong) NSTextField *opacityValueLabel;
@property (nonatomic, strong) NSTextField *overlayScreenLabel;
@property (nonatomic, strong) NSPopUpButton *overlayScreenPopup;
@property (nonatomic, strong) NSButton *launchAtLoginCheckbox;
@property (nonatomic, strong) NSButton *hotCornerEnabled;
@property (nonatomic, strong) NSTextField *hotCornerLabel;
@property (nonatomic, strong) NSPopUpButton *cornerPopup;
@property (nonatomic, strong) NSTextField *sizeLabel;
@property (nonatomic, strong) NSTextField *sizeField;
@property (nonatomic, strong) NSButton *hotkeyEnabled;
@property (nonatomic, strong) NSTextField *hotkeyLabel;
@property (nonatomic, strong) MLHotKeyRecorder *hotkeyRecorder;
@property (nonatomic, strong) NSButton *taskbarEnabled;
@property (nonatomic, strong) NSButton *memoryFreeEnabled;
@property (nonatomic, strong) NSTextField *pollLabel;
@property (nonatomic, strong) NSSlider *pollSlider;
@property (nonatomic, strong) NSTextField *pollValueLabel;
@property (nonatomic, strong) NSTextField *iconCacheLabel;
@property (nonatomic, strong) NSSlider *iconCacheSlider;
@property (nonatomic, strong) NSTextField *iconCacheValueLabel;
@property (nonatomic, strong) NSTextField *scanTitle;
@property (nonatomic, strong) NSTextField *scanHint;
@property (nonatomic, strong) NSTextField *sysLabel;
@property (nonatomic, strong) NSTextField *extraLabel;
@property (nonatomic, strong) NSButton *addBtn;
@property (nonatomic, strong) NSButton *removeBtn;
@property (nonatomic, strong) NSButton *rescanBtn;
@property (nonatomic, strong) NSButton *doneBtn;
@property (nonatomic, strong) NSButton *resetBtn;
@property (nonatomic, strong) NSTextField *pathLabel;
@property (nonatomic, strong) NSTableView *extraRootsTable;
@property (nonatomic, strong) NSArray<NSString *> *extraRootsCache;
@property (nonatomic, assign) BOOL suppressApply;
@end

@implementation MLPrefsWindow

static const CGFloat kPrefsWinW = 820;
static const CGFloat kPrefsWinH = 720;
static const CGFloat kPrefsMinW = 760;
static const CGFloat kPrefsMinH = 640;
static const CGFloat kPrefsBottomBarH = 52;
static const CGFloat kPrefsPad = 20;
static const CGFloat kPrefsContentW = 780;
static const CGFloat kPrefsColGap = 20;
/** Wide enough for zh「叠层图标缓存」/ en「Overlay display」. */
static const CGFloat kPrefsLabelW = 128;
static const CGFloat kPrefsValueW = 48;

- (instancetype)initWithConfigStore:(MLConfigStore *)config {
    self = [super init];
    if (self) {
        _config = config;
        _extraRootsCache = @[];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(languageDidChange:)
                                                     name:MLLanguageDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Layout helpers

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

- (NSTextField *)makeSectionTitle:(NSString *)text atY:(CGFloat *)yInOut inView:(NSView *)c {
    CGFloat y = *yInOut;
    if (y > kPrefsPad + 4) {
        y += 6;
        NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(kPrefsPad, y, kPrefsContentW - kPrefsPad * 2, 1)];
        line.boxType = NSBoxSeparator;
        [c addSubview:line];
        y += 10;
    }
    NSTextField *title = [self makeLabel:text
                                   frame:NSMakeRect(kPrefsPad, y, kPrefsContentW - kPrefsPad * 2, 20)];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [c addSubview:title];
    *yInOut = y + 26;
    return title;
}

- (void)splitColumnsAtY:(CGFloat)y
                 height:(CGFloat)h
                   left:(NSRect *)outLeft
                  right:(NSRect *)outRight {
    CGFloat inner = kPrefsContentW - kPrefsPad * 2;
    CGFloat colW = floor((inner - kPrefsColGap) * 0.5);
    *outLeft = NSMakeRect(kPrefsPad, y, colW, h);
    *outRight = NSMakeRect(kPrefsPad + colW + kPrefsColGap, y, colW, h);
}

- (void)placeLabel:(NSTextField *)label
            slider:(NSSlider *)slider
             value:(NSTextField *)valueLabel
            inRect:(NSRect)r {
    CGFloat labelW = kPrefsLabelW;
    CGFloat valueW = kPrefsValueW;
    label.frame = NSMakeRect(NSMinX(r), NSMinY(r) + 2, labelW, 20);
    label.lineBreakMode = NSLineBreakByClipping;
    valueLabel.frame = NSMakeRect(NSMaxX(r) - valueW, NSMinY(r) + 2, valueW, 20);
    valueLabel.alignment = NSTextAlignmentRight;
    CGFloat sliderX = NSMinX(r) + labelW + 8;
    CGFloat sliderW = NSMaxX(r) - valueW - 6 - sliderX;
    if (sliderW < 60) {
        sliderW = 60;
    }
    slider.frame = NSMakeRect(sliderX, NSMinY(r), sliderW, 24);
}

- (void)placeLabel:(NSTextField *)label control:(NSView *)control inRect:(NSRect)r {
    CGFloat labelW = kPrefsLabelW;
    label.frame = NSMakeRect(NSMinX(r), NSMinY(r) + 2, labelW, 20);
    label.lineBreakMode = NSLineBreakByClipping;
    CGFloat ctrlX = NSMinX(r) + labelW + 8;
    control.frame = NSMakeRect(ctrlX, NSMinY(r), NSMaxX(r) - ctrlX, 26);
}

#pragma mark - Window

- (void)ensureWindow {
    if (self.window) {
        return;
    }

    NSRect rect = NSMakeRect(0, 0, kPrefsWinW, kPrefsWinH);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:rect
                                              styleMask:NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.releasedWhenClosed = NO;
    w.minSize = NSMakeSize(kPrefsMinW, kPrefsMinH);
    w.level = NSStatusWindowLevel + 1;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                           NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSView *content = w.contentView;
    CGFloat barH = kPrefsBottomBarH;
    NSRect barFrame = NSMakeRect(0, 0, NSWidth(content.bounds), barH);
    NSView *bar = [[NSView alloc] initWithFrame:barFrame];
    bar.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    self.bottomBar = bar;

    self.resetBtn = [NSButton buttonWithTitle:@""
                                       target:self
                                       action:@selector(resetDefaults:)];
    self.resetBtn.bezelStyle = NSBezelStyleRounded;
    self.resetBtn.frame = NSMakeRect(kPrefsPad, 10, 160, 28);
    self.resetBtn.autoresizingMask = NSViewMaxXMargin;
    [bar addSubview:self.resetBtn];

    self.doneBtn = [NSButton buttonWithTitle:@""
                                      target:self
                                      action:@selector(done:)];
    self.doneBtn.bezelStyle = NSBezelStyleRounded;
    self.doneBtn.keyEquivalent = @"\r";
    self.doneBtn.frame = NSMakeRect(NSWidth(barFrame) - kPrefsPad - 100, 10, 100, 28);
    self.doneBtn.autoresizingMask = NSViewMinXMargin;
    [bar addSubview:self.doneBtn];

    /* Esc closes prefs unless hotkey recorder consumes it while recording. */
    NSButton *escClose = [NSButton buttonWithTitle:@""
                                            target:self
                                            action:@selector(done:)];
    escClose.keyEquivalent = @"\033";
    escClose.frame = NSZeroRect;
    [bar addSubview:escClose];

    NSBox *barLine = [[NSBox alloc] initWithFrame:NSMakeRect(0, barH - 1, NSWidth(barFrame), 1)];
    barLine.boxType = NSBoxSeparator;
    barLine.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [bar addSubview:barLine];

    NSRect scrollFrame = NSMakeRect(0, barH, NSWidth(content.bounds), NSHeight(content.bounds) - barH);
    NSScrollView *outerScroll = [[NSScrollView alloc] initWithFrame:scrollFrame];
    outerScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    outerScroll.hasVerticalScroller = YES;
    outerScroll.hasHorizontalScroller = NO;
    outerScroll.autohidesScrollers = YES;
    outerScroll.borderType = NSNoBorder;
    outerScroll.drawsBackground = NO;
    self.outerScroll = outerScroll;

    CGFloat y = kPrefsPad;
    MLPrefsFormView *c = [[MLPrefsFormView alloc] initWithFrame:NSMakeRect(0, 0, kPrefsContentW, 10)];

    /* —— General —— */
    self.sectionGeneral = [self makeSectionTitle:@"" atY:&y inView:c];

    NSRect left, right;
    [self splitColumnsAtY:y height:28 left:&left right:&right];
    self.languageLabel = [self makeLabel:@"" frame:NSZeroRect];
    [c addSubview:self.languageLabel];
    self.languagePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.languagePopup addItemsWithTitles:@[ @"", @"" ]];
    self.languagePopup.target = self;
    self.languagePopup.action = @selector(languageChanged:);
    [c addSubview:self.languagePopup];
    [self placeLabel:self.languageLabel control:self.languagePopup inRect:left];

    self.overlayScreenLabel = [self makeLabel:@"" frame:NSZeroRect];
    [c addSubview:self.overlayScreenLabel];
    self.overlayScreenPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.overlayScreenPopup.target = self;
    self.overlayScreenPopup.action = @selector(overlayScreenChanged:);
    [c addSubview:self.overlayScreenPopup];
    [self placeLabel:self.overlayScreenLabel control:self.overlayScreenPopup inRect:right];
    y += 34;

    [self splitColumnsAtY:y height:28 left:&left right:&right];
    self.colsLabel = [self makeLabel:@"" frame:NSZeroRect];
    self.colsSlider = [self makeIntSliderMin:4 max:10 action:@selector(colsChanged:)];
    self.colsValueLabel = [self makeLabel:@"7" frame:NSZeroRect];
    [c addSubview:self.colsLabel];
    [c addSubview:self.colsSlider];
    [c addSubview:self.colsValueLabel];
    [self placeLabel:self.colsLabel slider:self.colsSlider value:self.colsValueLabel inRect:left];

    self.rowsLabel = [self makeLabel:@"" frame:NSZeroRect];
    self.rowsSlider = [self makeIntSliderMin:3 max:8 action:@selector(rowsChanged:)];
    self.rowsValueLabel = [self makeLabel:@"5" frame:NSZeroRect];
    [c addSubview:self.rowsLabel];
    [c addSubview:self.rowsSlider];
    [c addSubview:self.rowsValueLabel];
    [self placeLabel:self.rowsLabel slider:self.rowsSlider value:self.rowsValueLabel inRect:right];
    y += 34;

    [self splitColumnsAtY:y height:28 left:&left right:&right];
    self.iconSizeLabel = [self makeLabel:@"" frame:NSZeroRect];
    self.iconSizeSlider = [NSSlider sliderWithValue:0
                                           minValue:0
                                           maxValue:160
                                             target:self
                                             action:@selector(iconSizeChanged:)];
    self.iconSizeSlider.numberOfTickMarks = 11;
    self.iconSizeSlider.allowsTickMarkValuesOnly = NO;
    self.iconSizeSlider.tickMarkPosition = NSTickMarkPositionBelow;
    self.iconSizeValueLabel = [self makeLabel:@"" frame:NSZeroRect];
    [c addSubview:self.iconSizeLabel];
    [c addSubview:self.iconSizeSlider];
    [c addSubview:self.iconSizeValueLabel];
    [self placeLabel:self.iconSizeLabel
              slider:self.iconSizeSlider
               value:self.iconSizeValueLabel
              inRect:left];

    self.opacityLabel = [self makeLabel:@"" frame:NSZeroRect];
    self.opacitySlider = [NSSlider sliderWithValue:55
                                          minValue:0
                                          maxValue:100
                                            target:self
                                            action:@selector(opacityChanged:)];
    self.opacitySlider.numberOfTickMarks = 11;
    self.opacitySlider.allowsTickMarkValuesOnly = NO;
    self.opacitySlider.tickMarkPosition = NSTickMarkPositionBelow;
    self.opacityValueLabel = [self makeLabel:@"55%" frame:NSZeroRect];
    [c addSubview:self.opacityLabel];
    [c addSubview:self.opacitySlider];
    [c addSubview:self.opacityValueLabel];
    [self placeLabel:self.opacityLabel
              slider:self.opacitySlider
               value:self.opacityValueLabel
              inRect:right];
    y += 34;

    [self splitColumnsAtY:y height:24 left:&left right:&right];
    self.launchAtLoginCheckbox = [NSButton checkboxWithTitle:@""
                                                      target:self
                                                      action:@selector(launchAtLoginChanged:)];
    self.launchAtLoginCheckbox.frame = left;
    [c addSubview:self.launchAtLoginCheckbox];
    self.taskbarEnabled = [NSButton checkboxWithTitle:@""
                                               target:self
                                               action:@selector(prefsChanged:)];
    self.taskbarEnabled.frame = right;
    [c addSubview:self.taskbarEnabled];
    y += 28;

    self.memoryFreeEnabled = [NSButton checkboxWithTitle:@""
                                                  target:self
                                                  action:@selector(prefsChanged:)];
    self.memoryFreeEnabled.frame = NSMakeRect(kPrefsPad, y, kPrefsContentW - kPrefsPad * 2, 24);
    [c addSubview:self.memoryFreeEnabled];
    y += 30;

    /* —— Hot corner & shortcut —— */
    self.sectionHot = [self makeSectionTitle:@"" atY:&y inView:c];

    [self splitColumnsAtY:y height:28 left:&left right:&right];
    self.hotCornerEnabled = [NSButton checkboxWithTitle:@""
                                                 target:self
                                                 action:@selector(prefsChanged:)];
    self.hotCornerEnabled.frame = left;
    [c addSubview:self.hotCornerEnabled];

    /* Right: corner popup + size field (compact; checkbox carries the meaning). */
    CGFloat popupW = floor(NSWidth(right) * 0.58);
    self.hotCornerLabel = [self makeLabel:@"" frame:NSMakeRect(NSMinX(right), NSMinY(right) + 2, 1, 20)];
    self.hotCornerLabel.hidden = YES;
    [c addSubview:self.hotCornerLabel];
    self.cornerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(NSMinX(right), NSMinY(right), popupW, 26)
                                                  pullsDown:NO];
    [self.cornerPopup addItemsWithTitles:@[ @"", @"", @"", @"", @"" ]];
    self.cornerPopup.target = self;
    self.cornerPopup.action = @selector(prefsChanged:);
    [c addSubview:self.cornerPopup];
    CGFloat sizeX = NSMinX(right) + popupW + 6;
    self.sizeLabel = [self makeLabel:@"" frame:NSMakeRect(sizeX, NSMinY(right) + 2, 28, 20)];
    [c addSubview:self.sizeLabel];
    self.sizeField = [self makeField:NSMakeRect(sizeX + 30, NSMinY(right), NSMaxX(right) - (sizeX + 30), 24)];
    self.sizeField.delegate = self;
    self.sizeField.target = self;
    self.sizeField.action = @selector(prefsChanged:);
    [c addSubview:self.sizeField];
    y += 34;

    [self splitColumnsAtY:y height:28 left:&left right:&right];
    self.hotkeyEnabled = [NSButton checkboxWithTitle:@""
                                              target:self
                                              action:@selector(prefsChanged:)];
    self.hotkeyEnabled.frame = left;
    [c addSubview:self.hotkeyEnabled];
    self.hotkeyLabel = [self makeLabel:@"" frame:NSZeroRect];
    [c addSubview:self.hotkeyLabel];
    self.hotkeyRecorder = [[MLHotKeyRecorder alloc] initWithFrame:NSZeroRect];
    __weak typeof(self) weakSelf = self;
    self.hotkeyRecorder.onChange = ^{
        [weakSelf hotkeyRecorderChanged];
    };
    [c addSubview:self.hotkeyRecorder];
    [self placeLabel:self.hotkeyLabel control:self.hotkeyRecorder inRect:right];
    y += 34;

    /* —— Performance —— */
    self.sectionPerf = [self makeSectionTitle:@"" atY:&y inView:c];

    [self splitColumnsAtY:y height:28 left:&left right:&right];
    self.pollLabel = [self makeLabel:@"" frame:NSZeroRect];
    self.pollSlider = [NSSlider sliderWithValue:10
                                       minValue:5
                                       maxValue:50
                                         target:self
                                         action:@selector(pollChanged:)];
    self.pollSlider.numberOfTickMarks = 10;
    self.pollSlider.allowsTickMarkValuesOnly = NO;
    self.pollSlider.tickMarkPosition = NSTickMarkPositionBelow;
    self.pollValueLabel = [self makeLabel:@"1.0s" frame:NSZeroRect];
    [c addSubview:self.pollLabel];
    [c addSubview:self.pollSlider];
    [c addSubview:self.pollValueLabel];
    [self placeLabel:self.pollLabel slider:self.pollSlider value:self.pollValueLabel inRect:left];

    self.iconCacheLabel = [self makeLabel:@"" frame:NSZeroRect];
    self.iconCacheSlider = [self makeIntSliderMin:32 max:256 action:@selector(iconCacheChanged:)];
    self.iconCacheSlider.numberOfTickMarks = 8;
    self.iconCacheSlider.allowsTickMarkValuesOnly = YES;
    self.iconCacheValueLabel = [self makeLabel:@"128" frame:NSZeroRect];
    [c addSubview:self.iconCacheLabel];
    [c addSubview:self.iconCacheSlider];
    [c addSubview:self.iconCacheValueLabel];
    [self placeLabel:self.iconCacheLabel
              slider:self.iconCacheSlider
               value:self.iconCacheValueLabel
              inRect:right];
    y += 36;

    /* —— App folders —— */
    self.scanTitle = [self makeSectionTitle:@"" atY:&y inView:c];

    self.scanHint = [self makeLabel:@"" frame:NSMakeRect(kPrefsPad, y, kPrefsContentW - kPrefsPad * 2, 28)];
    self.scanHint.font = [NSFont systemFontOfSize:11];
    self.scanHint.textColor = [NSColor secondaryLabelColor];
    self.scanHint.maximumNumberOfLines = 2;
    self.scanHint.lineBreakMode = NSLineBreakByWordWrapping;
    [c addSubview:self.scanHint];
    y += 30;

    self.sysLabel = [self makeLabel:@"" frame:NSMakeRect(kPrefsPad, y, kPrefsContentW - kPrefsPad * 2, 16)];
    self.sysLabel.font = [NSFont systemFontOfSize:11];
    self.sysLabel.textColor = [NSColor secondaryLabelColor];
    self.sysLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [c addSubview:self.sysLabel];
    y += 20;

    self.extraLabel = [self makeLabel:@"" frame:NSMakeRect(kPrefsPad, y, 200, 16)];
    self.extraLabel.font = [NSFont systemFontOfSize:11];
    self.extraLabel.textColor = [NSColor secondaryLabelColor];
    [c addSubview:self.extraLabel];
    y += 18;

    CGFloat tableH = 92;
    CGFloat btnColW = 118;
    CGFloat tableW = kPrefsContentW - kPrefsPad * 2 - btnColW - 8;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(kPrefsPad, y, tableW, tableH)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;

    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    col.title = @"";
    col.width = tableW - 20;
    [table addTableColumn:col];
    table.headerView = nil;
    table.rowHeight = 20;
    table.allowsEmptySelection = YES;
    table.allowsMultipleSelection = NO;
    table.dataSource = self;
    table.delegate = self;
    scroll.documentView = table;
    self.extraRootsTable = table;
    [c addSubview:scroll];

    CGFloat bx = kPrefsPad + tableW + 8;
    self.addBtn = [NSButton buttonWithTitle:@""
                                     target:self
                                     action:@selector(addExtraRoot:)];
    self.addBtn.frame = NSMakeRect(bx, y + tableH - 28, btnColW, 26);
    [c addSubview:self.addBtn];
    self.removeBtn = [NSButton buttonWithTitle:@""
                                        target:self
                                        action:@selector(removeExtraRoot:)];
    self.removeBtn.frame = NSMakeRect(bx, y + tableH - 58, btnColW, 26);
    [c addSubview:self.removeBtn];
    self.rescanBtn = [NSButton buttonWithTitle:@""
                                        target:self
                                        action:@selector(rescanApps:)];
    self.rescanBtn.frame = NSMakeRect(bx, y + tableH - 88, btnColW, 26);
    [c addSubview:self.rescanBtn];
    y += tableH + 10;

    self.pathLabel = [self makeLabel:@"" frame:NSMakeRect(kPrefsPad, y, kPrefsContentW - kPrefsPad * 2, 16)];
    self.pathLabel.font = [NSFont systemFontOfSize:10];
    self.pathLabel.textColor = [NSColor secondaryLabelColor];
    self.pathLabel.maximumNumberOfLines = 1;
    self.pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [c addSubview:self.pathLabel];
    y += 28;

    c.frame = NSMakeRect(0, 0, kPrefsContentW, y);
    outerScroll.documentView = c;
    [content addSubview:outerScroll];
    [content addSubview:bar];

    /* Size window so the form fits without a vertical scroller. */
    CGFloat fitH = y + barH + 8;
    if (fitH < kPrefsWinH) {
        fitH = kPrefsWinH;
    }
    [w setContentSize:NSMakeSize(kPrefsWinW, fitH)];
    bar.frame = NSMakeRect(0, 0, kPrefsWinW, barH);
    self.doneBtn.frame = NSMakeRect(kPrefsWinW - kPrefsPad - 100, 12, 100, 28);
    outerScroll.frame = NSMakeRect(0, barH, kPrefsWinW, fitH - barH);
    outerScroll.hasVerticalScroller = YES;
    outerScroll.autohidesScrollers = YES;

    self.window = w;

    [self applyLocalizedStrings];
}

#pragma mark - Localization

- (void)applyLocalizedStrings {
    if (!self.window) {
        return;
    }
    self.window.title = [MLStrings t:@"prefs.title"];
    self.sectionGeneral.stringValue = [MLStrings t:@"prefs.section.general"];
    self.sectionHot.stringValue = [MLStrings t:@"prefs.section.hot"];
    self.sectionPerf.stringValue = [MLStrings t:@"prefs.section.performance"];
    self.languageLabel.stringValue = [MLStrings t:@"prefs.language"];
    [[self.languagePopup itemAtIndex:0] setTitle:[MLStrings t:@"prefs.lang.zh"]];
    [[self.languagePopup itemAtIndex:1] setTitle:[MLStrings t:@"prefs.lang.en"]];
    self.colsLabel.stringValue = [MLStrings t:@"prefs.grid_cols"];
    self.rowsLabel.stringValue = [MLStrings t:@"prefs.grid_rows"];
    self.iconSizeLabel.stringValue = [MLStrings t:@"prefs.icon_size"];
    self.opacityLabel.stringValue = [MLStrings t:@"prefs.overlay_opacity"];
    self.overlayScreenLabel.stringValue = [MLStrings t:@"prefs.overlay_screen"];
    [self rebuildOverlayScreenPopupPreservingSelection:YES];
    self.launchAtLoginCheckbox.title = [MLStrings t:@"prefs.launch_at_login"];
    self.hotCornerEnabled.title = [MLStrings t:@"prefs.hot_corner_enabled"];
    self.hotCornerLabel.stringValue = [MLStrings t:@"prefs.hot_corner"];

    NSInteger cornerIdx = self.cornerPopup.indexOfSelectedItem;
    [self.cornerPopup removeAllItems];
    [self.cornerPopup addItemsWithTitles:@[
        [MLStrings t:@"prefs.corner.top_left"],
        [MLStrings t:@"prefs.corner.top_right"],
        [MLStrings t:@"prefs.corner.bottom_left"],
        [MLStrings t:@"prefs.corner.bottom_right"],
        [MLStrings t:@"prefs.corner.off"],
    ]];
    if (cornerIdx >= 0 && cornerIdx < self.cornerPopup.numberOfItems) {
        [self.cornerPopup selectItemAtIndex:cornerIdx];
    }

    self.sizeLabel.stringValue = @"pt";
    self.hotkeyEnabled.title = [MLStrings t:@"prefs.hotkey_enabled"];
    self.hotkeyLabel.stringValue = [MLStrings t:@"prefs.hotkey_shortcut"];
    self.taskbarEnabled.title = [MLStrings t:@"prefs.taskbar_enabled"];
    self.memoryFreeEnabled.title = [MLStrings t:@"prefs.memory_free_enabled"];
    self.pollLabel.stringValue = [MLStrings t:@"prefs.window_poll"];
    self.iconCacheLabel.stringValue = [MLStrings t:@"prefs.overlay_icon_cache"];
    self.scanTitle.stringValue = [MLStrings t:@"prefs.scan_title"];
    self.scanHint.stringValue = [MLStrings t:@"prefs.scan_hint"];
    NSString *roots = [[MLConfigStore builtInScanRoots] componentsJoinedByString:@" · "];
    self.sysLabel.stringValue =
        [NSString stringWithFormat:[MLStrings t:@"prefs.system_dirs_inline"], roots];
    self.extraLabel.stringValue = [MLStrings t:@"prefs.extra_dirs"];
    self.addBtn.title = [MLStrings t:@"prefs.add_folder"];
    self.removeBtn.title = [MLStrings t:@"prefs.remove"];
    self.rescanBtn.title = [MLStrings t:@"prefs.rescan"];
    self.doneBtn.title = [MLStrings t:@"prefs.done"];
    self.resetBtn.title = [MLStrings t:@"prefs.reset"];
    [self updateIconSizeLabel];
    self.pathLabel.stringValue =
        [NSString stringWithFormat:[MLStrings t:@"prefs.config_path"],
                                   [MLConfigStore configFileURL].path];
    [self.extraRootsTable reloadData];
}

- (void)languageDidChange:(NSNotification *)note {
    (void)note;
    [self applyLocalizedStrings];
}

#pragma mark - Actions

- (void)done:(id)sender {
    (void)sender;
    if (self.hotkeyRecorder.isRecording) {
        return;
    }
    [self.window performClose:nil];
}

- (void)resetDefaults:(id)sender {
    (void)sender;
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [MLStrings t:@"prefs.reset_title"];
    alert.informativeText = [MLStrings t:@"prefs.reset_info"];
    [alert addButtonWithTitle:[MLStrings t:@"prefs.reset_confirm"]];
    [alert addButtonWithTitle:[MLStrings t:@"prefs.reset_cancel"]];
    [alert beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse returnCode) {
                      if (returnCode != NSAlertFirstButtonReturn) {
                          return;
                      }
                      [self applyFactoryDefaultsKeepingLanguageAndFolders];
                  }];
}

- (void)applyFactoryDefaultsKeepingLanguageAndFolders {
    self.suppressApply = YES;
    self.colsSlider.doubleValue = 7;
    self.rowsSlider.doubleValue = 5;
    self.colsValueLabel.stringValue = @"7";
    self.rowsValueLabel.stringValue = @"5";
    self.iconSizeSlider.doubleValue = 0;
    [self updateIconSizeLabel];
    self.opacitySlider.doubleValue = 55;
    self.opacityValueLabel.stringValue = @"55%";
    [self.config updateOverlayScreenMode:MLOverlayScreenModeMouse screenID:0];
    [self rebuildOverlayScreenPopupPreservingSelection:NO];
    self.hotCornerEnabled.state = NSControlStateValueOn;
    [self selectPopupForPosition:MLHotCornerPositionTopLeft];
    self.sizeField.stringValue = @"12";
    self.hotkeyEnabled.state = NSControlStateValueOn;
    [self.hotkeyRecorder setKeyCode:kVK_ANSI_8
                            command:YES
                             option:YES
                            control:NO
                              shift:YES];
    self.taskbarEnabled.state = NSControlStateValueOn;
    self.memoryFreeEnabled.state = NSControlStateValueOff;
    self.pollSlider.doubleValue = 10;
    [self updatePollValueLabel];
    self.iconCacheSlider.doubleValue = 128;
    self.iconCacheValueLabel.stringValue = @"128";
    [self updateDependentControlsEnabled];
    self.suppressApply = NO;
    [self applyLive];
}

- (void)updateDependentControlsEnabled {
    BOOL hotOn = (self.hotCornerEnabled.state == NSControlStateValueOn);
    self.cornerPopup.enabled = hotOn;
    self.sizeField.enabled = hotOn;
    self.hotCornerLabel.textColor = hotOn ? [NSColor labelColor] : [NSColor disabledControlTextColor];
    self.sizeLabel.textColor = hotOn ? [NSColor labelColor] : [NSColor disabledControlTextColor];

    BOOL keyOn = (self.hotkeyEnabled.state == NSControlStateValueOn);
    self.hotkeyRecorder.enabled = keyOn;
    self.hotkeyLabel.textColor = keyOn ? [NSColor labelColor] : [NSColor disabledControlTextColor];
}

- (void)languageChanged:(id)sender {
    (void)sender;
    if (self.suppressApply) {
        return;
    }
    MLLanguage lang = (self.languagePopup.indexOfSelectedItem == 0)
                          ? MLLanguageChinese
                          : MLLanguageEnglish;
    [self.config updateLanguage:lang];
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
    if (v < 24.0) {
        return 0.f;
    }
    if (v < 48.0) {
        return 48.f;
    }
    return (float)v;
}

- (void)updateIconSizeLabel {
    float size = [self iconSizeFromSlider];
    if (size <= 0.f) {
        self.iconSizeValueLabel.stringValue = [MLStrings t:@"prefs.icon_auto"];
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

- (NSString *)titleForScreen:(NSScreen *)screen {
    NSString *name = screen.localizedName;
    if (name.length == 0) {
        name = @"Display";
    }
    NSSize px = screen.frame.size;
    NSString *res = [NSString stringWithFormat:@"%ld×%ld", (long)px.width, (long)px.height];
    NSString *title = [NSString stringWithFormat:@"%@ (%@)", name, res];
    if (screen == [NSScreen mainScreen]) {
        title = [title stringByAppendingString:[MLStrings t:@"prefs.overlay_screen.main_suffix"]];
    }
    return title;
}

- (void)rebuildOverlayScreenPopupPreservingSelection:(BOOL)preserve {
    if (!self.overlayScreenPopup) {
        return;
    }
    MLOverlayScreenMode mode = self.config.overlayScreenMode;
    uint32_t sid = self.config.overlayScreenID;
    if (preserve && self.overlayScreenPopup.numberOfItems > 0) {
        NSDictionary *sel = self.overlayScreenPopup.selectedItem.representedObject;
        if ([sel isKindOfClass:[NSDictionary class]]) {
            mode = (MLOverlayScreenMode)[sel[@"mode"] integerValue];
            sid = (uint32_t)[sel[@"id"] unsignedIntValue];
        }
    }

    [self.overlayScreenPopup removeAllItems];

    NSMenuItem *mouseItem = [[NSMenuItem alloc] initWithTitle:[MLStrings t:@"prefs.overlay_screen.mouse"]
                                                       action:NULL
                                                keyEquivalent:@""];
    mouseItem.representedObject = @{ @"mode" : @(MLOverlayScreenModeMouse) };
    [self.overlayScreenPopup.menu addItem:mouseItem];

    NSMenuItem *mainItem = [[NSMenuItem alloc] initWithTitle:[MLStrings t:@"prefs.overlay_screen.main"]
                                                      action:NULL
                                               keyEquivalent:@""];
    mainItem.representedObject = @{ @"mode" : @(MLOverlayScreenModeMain) };
    [self.overlayScreenPopup.menu addItem:mainItem];

    [self.overlayScreenPopup.menu addItem:[NSMenuItem separatorItem]];

    NSInteger selectIdx = 0;
    if (mode == MLOverlayScreenModeMain) {
        selectIdx = 1;
    }
    NSArray<NSScreen *> *screens = [NSScreen screens];
    for (NSScreen *screen in screens) {
        NSNumber *num = [MLScreenGeometry screenIDForScreen:screen];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[self titleForScreen:screen]
                                                      action:NULL
                                               keyEquivalent:@""];
        item.representedObject = @{
            @"mode" : @(MLOverlayScreenModeFixed),
            @"id" : num ?: @0,
        };
        [self.overlayScreenPopup.menu addItem:item];
        if (mode == MLOverlayScreenModeFixed && num.unsignedIntValue == sid) {
            selectIdx = self.overlayScreenPopup.numberOfItems - 1;
        }
    }

    if (mode == MLOverlayScreenModeFixed && selectIdx == 0) {
        selectIdx = 1;
    }
    if (selectIdx >= 0 && selectIdx < self.overlayScreenPopup.numberOfItems) {
        [self.overlayScreenPopup selectItemAtIndex:selectIdx];
    }
}

- (void)overlayScreenChanged:(id)sender {
    (void)sender;
    if (self.suppressApply) {
        return;
    }
    NSDictionary *info = self.overlayScreenPopup.selectedItem.representedObject;
    if (![info isKindOfClass:[NSDictionary class]]) {
        return;
    }
    MLOverlayScreenMode mode = (MLOverlayScreenMode)[info[@"mode"] integerValue];
    uint32_t sid = (uint32_t)[info[@"id"] unsignedIntValue];
    [self.config updateOverlayScreenMode:mode screenID:sid];
}

- (NSTimeInterval)pollSecondsFromSlider {
    return self.pollSlider.doubleValue / 10.0;
}

- (void)updatePollValueLabel {
    self.pollValueLabel.stringValue =
        [NSString stringWithFormat:@"%.1fs", [self pollSecondsFromSlider]];
}

- (void)pollChanged:(id)sender {
    (void)sender;
    [self updatePollValueLabel];
    [self applyLive];
}

- (void)iconCacheChanged:(id)sender {
    (void)sender;
    self.iconCacheValueLabel.stringValue =
        [NSString stringWithFormat:@"%.0f", self.iconCacheSlider.doubleValue];
    [self applyLive];
}

- (void)prefsChanged:(id)sender {
    (void)sender;
    [self updateDependentControlsEnabled];
    [self applyLive];
}

- (void)launchAtLoginChanged:(id)sender {
    (void)sender;
    if (self.suppressApply) {
        return;
    }
    BOOL want = (self.launchAtLoginCheckbox.state == NSControlStateValueOn);
    NSError *err = nil;
    if (![MLLaunchAtLogin setEnabled:want error:&err]) {
        self.suppressApply = YES;
        self.launchAtLoginCheckbox.state =
            [MLLaunchAtLogin isEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
        self.suppressApply = NO;
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [MLStrings t:@"prefs.launch_at_login_failed"];
        alert.informativeText = err.localizedDescription.length > 0
                                    ? err.localizedDescription
                                    : [MLStrings t:@"prefs.launch_at_login_failed_info"];
        [alert addButtonWithTitle:[MLStrings t:@"prefs.ok"]];
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    self.suppressApply = YES;
    self.launchAtLoginCheckbox.state =
        [MLLaunchAtLogin isEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    self.suppressApply = NO;
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

- (void)reloadExtraRootsTable {
    self.extraRootsCache = [self.config scanExtraRoots] ?: @[];
    [self.extraRootsTable reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.extraRootsCache.count;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                   row:(NSInteger)row {
    (void)tableColumn;
    NSString *ident = @"pathCell";
    NSTextField *cell = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cell) {
        cell = [NSTextField labelWithString:@""];
        cell.identifier = ident;
        cell.editable = NO;
        cell.bordered = NO;
        cell.drawsBackground = NO;
        cell.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    }
    if (row < 0 || row >= (NSInteger)self.extraRootsCache.count) {
        cell.stringValue = @"";
        return cell;
    }
    NSString *path = self.extraRootsCache[(NSUInteger)row];
    NSString *expanded = [path stringByExpandingTildeInPath];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:expanded];
    if (exists) {
        cell.stringValue = path;
        cell.textColor = [NSColor labelColor];
    } else {
        cell.stringValue =
            [NSString stringWithFormat:[MLStrings t:@"prefs.unmounted"], path];
        cell.textColor = [NSColor secondaryLabelColor];
    }
    return cell;
}

- (void)addExtraRoot:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = NO;
    panel.prompt = [MLStrings t:@"prefs.add_prompt"];
    panel.message = [MLStrings t:@"prefs.add_message"];
    panel.directoryURL = [NSURL fileURLWithPath:@"/Volumes"];
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse result) {
                      if (result != NSModalResponseOK || !panel.URL) {
                          return;
                      }
                      NSString *path = panel.URL.path;
                      if (![self.config addScanExtraRoot:path]) {
                          NSAlert *alert = [[NSAlert alloc] init];
                          alert.messageText = [MLStrings t:@"prefs.add_failed_title"];
                          alert.informativeText = [MLStrings t:@"prefs.add_failed_info"];
                          [alert addButtonWithTitle:[MLStrings t:@"prefs.ok"]];
                          [alert beginSheetModalForWindow:self.window completionHandler:nil];
                          return;
                      }
                      [self reloadExtraRootsTable];
                  }];
}

- (void)removeExtraRoot:(id)sender {
    (void)sender;
    NSInteger row = self.extraRootsTable.selectedRow;
    if (row < 0) {
        return;
    }
    [self.config removeScanExtraRootAtIndex:row];
    [self reloadExtraRootsTable];
}

- (void)rescanApps:(id)sender {
    (void)sender;
    [self.config requestAppRescan];
}

- (void)reloadFields {
    self.suppressApply = YES;
    [self.languagePopup selectItemAtIndex:(self.config.language == MLLanguageChinese) ? 0 : 1];
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
    [self rebuildOverlayScreenPopupPreservingSelection:NO];
    self.launchAtLoginCheckbox.state =
        [MLLaunchAtLogin isEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
    self.hotCornerEnabled.state = self.config.hotCornerEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self selectPopupForPosition:self.config.hotCornerPosition];
    self.sizeField.stringValue = [NSString stringWithFormat:@"%.0f", self.config.hotCornerSizePt];
    self.hotkeyEnabled.state = self.config.hotkeyEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self.hotkeyRecorder setKeyCode:self.config.hotkeyKeyCode
                            command:self.config.hotkeyCommand
                             option:self.config.hotkeyOption
                            control:self.config.hotkeyControl
                              shift:self.config.hotkeyShift];
    self.taskbarEnabled.state = self.config.taskbarEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.memoryFreeEnabled.state = self.config.memoryFreeEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    NSTimeInterval poll = self.config.taskbarWindowPollSeconds;
    if (poll < 0.5) poll = 0.5;
    if (poll > 5.0) poll = 5.0;
    self.pollSlider.doubleValue = poll * 10.0;
    [self updatePollValueLabel];
    NSUInteger iconMax = self.config.overlayIconCacheMax;
    if (iconMax < 32) iconMax = 32;
    if (iconMax > 256) iconMax = 256;
    self.iconCacheSlider.doubleValue = (double)iconMax;
    self.iconCacheValueLabel.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)iconMax];
    self.pathLabel.stringValue =
        [NSString stringWithFormat:[MLStrings t:@"prefs.config_path"],
                                   [MLConfigStore configFileURL].path];
    [self reloadExtraRootsTable];
    [self updateDependentControlsEnabled];
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

    [self.config updateHotkeyEnabled:(self.hotkeyEnabled.state == NSControlStateValueOn)
                             keyCode:self.hotkeyRecorder.capturedKeyCode
                              option:self.hotkeyRecorder.capturedOption
                             command:self.hotkeyRecorder.capturedCommand
                             control:self.hotkeyRecorder.capturedControl
                               shift:self.hotkeyRecorder.capturedShift];

    [self.config updateTaskbarEnabled:(self.taskbarEnabled.state == NSControlStateValueOn)];
    [self.config updateMemoryFreeEnabled:(self.memoryFreeEnabled.state == NSControlStateValueOn)];
    [self.config updateTaskbarWindowPollSeconds:[self pollSecondsFromSlider]];
    [self.config updateOverlayIconCacheMax:(NSUInteger)lround(self.iconCacheSlider.doubleValue)];
}

- (void)hotkeyRecorderChanged {
    [self applyLive];
}

- (void)show {
    [self ensureWindow];
    [self applyLocalizedStrings];
    [self reloadFields];
    [self.window center];
    [self.window orderFrontRegardless];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

@end
