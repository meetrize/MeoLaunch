#import "MLPrefsWindow.h"

#import "MLConfigStore.h"
#import "MLLaunchAtLogin.h"
#import "MLScreenGeometry.h"
#import "MLStrings.h"

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
@property (nonatomic, strong) NSTextField *pathLabel;
@property (nonatomic, strong) NSTableView *extraRootsTable;
@property (nonatomic, strong) NSArray<NSString *> *extraRootsCache;
@property (nonatomic, assign) BOOL suppressApply;
@end

@implementation MLPrefsWindow

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

    NSRect rect = NSMakeRect(0, 0, 520, 820);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:rect
                                              styleMask:NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.releasedWhenClosed = NO;
    w.minSize = NSMakeSize(480, 680);
    w.level = NSStatusWindowLevel + 1;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                           NSWindowCollectionBehaviorFullScreenAuxiliary;

    NSScrollView *outerScroll = [[NSScrollView alloc] initWithFrame:w.contentView.bounds];
    outerScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    outerScroll.hasVerticalScroller = YES;
    outerScroll.hasHorizontalScroller = NO;
    outerScroll.autohidesScrollers = YES;
    outerScroll.borderType = NSNoBorder;
    outerScroll.drawsBackground = NO;

    const CGFloat contentW = 500;
    const CGFloat pad = 16;
    CGFloat y = pad;

    MLPrefsFormView *c = [[MLPrefsFormView alloc] initWithFrame:NSMakeRect(0, 0, contentW, 10)];

    self.languageLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.languageLabel];
    self.languagePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(140, y - 1, 180, 26) pullsDown:NO];
    [self.languagePopup addItemsWithTitles:@[ @"", @"" ]];
    self.languagePopup.target = self;
    self.languagePopup.action = @selector(languageChanged:);
    [c addSubview:self.languagePopup];
    y += 40;

    self.colsLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.colsLabel];
    self.colsSlider = [self makeIntSliderMin:4 max:10 action:@selector(colsChanged:)];
    self.colsSlider.frame = NSMakeRect(136, y - 2, 280, 28);
    [c addSubview:self.colsSlider];
    self.colsValueLabel = [self makeLabel:@"7" frame:NSMakeRect(430, y, 40, 22)];
    self.colsValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.colsValueLabel];
    y += 40;

    self.rowsLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.rowsLabel];
    self.rowsSlider = [self makeIntSliderMin:3 max:8 action:@selector(rowsChanged:)];
    self.rowsSlider.frame = NSMakeRect(136, y - 2, 280, 28);
    [c addSubview:self.rowsSlider];
    self.rowsValueLabel = [self makeLabel:@"5" frame:NSMakeRect(430, y, 40, 22)];
    self.rowsValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.rowsValueLabel];
    y += 40;

    self.iconSizeLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.iconSizeLabel];
    self.iconSizeSlider = [NSSlider sliderWithValue:0
                                           minValue:0
                                           maxValue:160
                                             target:self
                                             action:@selector(iconSizeChanged:)];
    self.iconSizeSlider.numberOfTickMarks = 11;
    self.iconSizeSlider.allowsTickMarkValuesOnly = NO;
    self.iconSizeSlider.tickMarkPosition = NSTickMarkPositionBelow;
    self.iconSizeSlider.frame = NSMakeRect(136, y - 2, 280, 28);
    [c addSubview:self.iconSizeSlider];
    self.iconSizeValueLabel = [self makeLabel:@"" frame:NSMakeRect(420, y, 50, 22)];
    self.iconSizeValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.iconSizeValueLabel];
    y += 40;

    self.opacityLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.opacityLabel];
    self.opacitySlider = [NSSlider sliderWithValue:55
                                          minValue:0
                                          maxValue:100
                                            target:self
                                            action:@selector(opacityChanged:)];
    self.opacitySlider.numberOfTickMarks = 11;
    self.opacitySlider.allowsTickMarkValuesOnly = NO;
    self.opacitySlider.tickMarkPosition = NSTickMarkPositionBelow;
    self.opacitySlider.frame = NSMakeRect(136, y - 2, 280, 28);
    [c addSubview:self.opacitySlider];
    self.opacityValueLabel = [self makeLabel:@"55%" frame:NSMakeRect(420, y, 50, 22)];
    self.opacityValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.opacityValueLabel];
    y += 40;

    self.overlayScreenLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.overlayScreenLabel];
    self.overlayScreenPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(140, y - 1, 320, 26)
                                                         pullsDown:NO];
    self.overlayScreenPopup.target = self;
    self.overlayScreenPopup.action = @selector(overlayScreenChanged:);
    [c addSubview:self.overlayScreenPopup];
    y += 40;

    self.launchAtLoginCheckbox = [NSButton checkboxWithTitle:@""
                                                      target:self
                                                      action:@selector(launchAtLoginChanged:)];
    self.launchAtLoginCheckbox.frame = NSMakeRect(pad, y, 320, 24);
    [c addSubview:self.launchAtLoginCheckbox];
    y += 32;

    self.hotCornerEnabled = [NSButton checkboxWithTitle:@""
                                                 target:self
                                                 action:@selector(prefsChanged:)];
    self.hotCornerEnabled.frame = NSMakeRect(pad, y, 280, 24);
    [c addSubview:self.hotCornerEnabled];
    y += 32;

    self.hotCornerLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.hotCornerLabel];
    self.cornerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(140, y - 1, 180, 26) pullsDown:NO];
    [self.cornerPopup addItemsWithTitles:@[ @"", @"", @"", @"", @"" ]];
    self.cornerPopup.target = self;
    self.cornerPopup.action = @selector(prefsChanged:);
    [c addSubview:self.cornerPopup];
    y += 32;

    self.sizeLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.sizeLabel];
    self.sizeField = [self makeField:NSMakeRect(140, y, 60, 24)];
    self.sizeField.delegate = self;
    self.sizeField.target = self;
    self.sizeField.action = @selector(prefsChanged:);
    [c addSubview:self.sizeField];
    y += 36;

    self.taskbarEnabled = [NSButton checkboxWithTitle:@""
                                               target:self
                                               action:@selector(prefsChanged:)];
    self.taskbarEnabled.frame = NSMakeRect(pad, y, 320, 24);
    [c addSubview:self.taskbarEnabled];
    y += 32;

    self.memoryFreeEnabled = [NSButton checkboxWithTitle:@""
                                                  target:self
                                                  action:@selector(prefsChanged:)];
    self.memoryFreeEnabled.frame = NSMakeRect(pad, y, 360, 24);
    [c addSubview:self.memoryFreeEnabled];
    y += 32;

    self.pollLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.pollLabel];
    self.pollSlider = [NSSlider sliderWithValue:10
                                       minValue:5
                                       maxValue:50
                                         target:self
                                         action:@selector(pollChanged:)];
    self.pollSlider.numberOfTickMarks = 10;
    self.pollSlider.allowsTickMarkValuesOnly = NO;
    self.pollSlider.tickMarkPosition = NSTickMarkPositionBelow;
    self.pollSlider.frame = NSMakeRect(136, y - 2, 280, 28);
    [c addSubview:self.pollSlider];
    self.pollValueLabel = [self makeLabel:@"1.0s" frame:NSMakeRect(420, y, 50, 22)];
    self.pollValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.pollValueLabel];
    y += 40;

    self.iconCacheLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 120, 22)];
    [c addSubview:self.iconCacheLabel];
    self.iconCacheSlider = [self makeIntSliderMin:32 max:256 action:@selector(iconCacheChanged:)];
    self.iconCacheSlider.numberOfTickMarks = 8;
    self.iconCacheSlider.allowsTickMarkValuesOnly = YES;
    self.iconCacheSlider.frame = NSMakeRect(136, y - 2, 280, 28);
    [c addSubview:self.iconCacheSlider];
    self.iconCacheValueLabel = [self makeLabel:@"128" frame:NSMakeRect(420, y, 50, 22)];
    self.iconCacheValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.iconCacheValueLabel];
    y += 40;

    self.scanTitle = [self makeLabel:@"" frame:NSMakeRect(pad, y, 200, 20)];
    self.scanTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [c addSubview:self.scanTitle];
    y += 22;

    self.scanHint = [self makeLabel:@"" frame:NSMakeRect(pad, y, 468, 32)];
    self.scanHint.font = [NSFont systemFontOfSize:11];
    self.scanHint.textColor = [NSColor secondaryLabelColor];
    self.scanHint.maximumNumberOfLines = 2;
    self.scanHint.lineBreakMode = NSLineBreakByWordWrapping;
    [c addSubview:self.scanHint];
    y += 36;

    self.sysLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 200, 16)];
    self.sysLabel.font = [NSFont systemFontOfSize:11];
    self.sysLabel.textColor = [NSColor secondaryLabelColor];
    [c addSubview:self.sysLabel];
    y += 16;

    for (NSString *root in [MLConfigStore builtInScanRoots]) {
        NSTextField *row = [self makeLabel:root frame:NSMakeRect(pad + 8, y, 456, 14)];
        row.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
        row.textColor = [NSColor tertiaryLabelColor];
        [c addSubview:row];
        y += 14;
    }
    y += 6;

    self.extraLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 200, 16)];
    self.extraLabel.font = [NSFont systemFontOfSize:11];
    self.extraLabel.textColor = [NSColor secondaryLabelColor];
    [c addSubview:self.extraLabel];
    y += 18;

    CGFloat tableH = 72;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(pad, y, 468, tableH)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;

    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    col.title = @"";
    col.width = 440;
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
    y += tableH + 10;

    self.addBtn = [NSButton buttonWithTitle:@""
                                     target:self
                                     action:@selector(addExtraRoot:)];
    self.addBtn.frame = NSMakeRect(pad, y, 130, 28);
    [c addSubview:self.addBtn];

    self.removeBtn = [NSButton buttonWithTitle:@""
                                        target:self
                                        action:@selector(removeExtraRoot:)];
    self.removeBtn.frame = NSMakeRect(pad + 138, y, 80, 28);
    [c addSubview:self.removeBtn];

    self.rescanBtn = [NSButton buttonWithTitle:@""
                                        target:self
                                        action:@selector(rescanApps:)];
    self.rescanBtn.frame = NSMakeRect(pad + 226, y, 110, 28);
    [c addSubview:self.rescanBtn];
    y += 34;

    self.pathLabel = [self makeLabel:@"" frame:NSMakeRect(pad, y, 468, 16)];
    self.pathLabel.font = [NSFont systemFontOfSize:10];
    self.pathLabel.textColor = [NSColor secondaryLabelColor];
    self.pathLabel.maximumNumberOfLines = 1;
    self.pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [c addSubview:self.pathLabel];
    y += 24;

    c.frame = NSMakeRect(0, 0, contentW, y);
    outerScroll.documentView = c;
    [w.contentView addSubview:outerScroll];
    self.window = w;

    [self applyLocalizedStrings];
}

- (void)applyLocalizedStrings {
    if (!self.window) {
        return;
    }
    self.window.title = [MLStrings t:@"prefs.title"];
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

    self.sizeLabel.stringValue = [MLStrings t:@"prefs.hot_size"];
    self.taskbarEnabled.title = [MLStrings t:@"prefs.taskbar_enabled"];
    self.memoryFreeEnabled.title = [MLStrings t:@"prefs.memory_free_enabled"];
    self.pollLabel.stringValue = [MLStrings t:@"prefs.window_poll"];
    self.iconCacheLabel.stringValue = [MLStrings t:@"prefs.overlay_icon_cache"];
    self.scanTitle.stringValue = [MLStrings t:@"prefs.scan_title"];
    self.scanHint.stringValue = [MLStrings t:@"prefs.scan_hint"];
    self.sysLabel.stringValue = [MLStrings t:@"prefs.system_dirs"];
    self.extraLabel.stringValue = [MLStrings t:@"prefs.extra_dirs"];
    self.addBtn.title = [MLStrings t:@"prefs.add_folder"];
    self.removeBtn.title = [MLStrings t:@"prefs.remove"];
    self.rescanBtn.title = [MLStrings t:@"prefs.rescan"];
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
        self.iconSizeSlider.doubleValue = v;
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
        /* Saved display missing: keep fixed intent visible via main fallback label. */
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
    /* Slider is tenths of a second: 5…50 → 0.5…5.0 */
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

    [self.config updateTaskbarEnabled:(self.taskbarEnabled.state == NSControlStateValueOn)];
    [self.config updateMemoryFreeEnabled:(self.memoryFreeEnabled.state == NSControlStateValueOn)];
    [self.config updateTaskbarWindowPollSeconds:[self pollSecondsFromSlider]];
    [self.config updateOverlayIconCacheMax:(NSUInteger)lround(self.iconCacheSlider.doubleValue)];
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
