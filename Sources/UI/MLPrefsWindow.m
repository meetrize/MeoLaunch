#import "MLPrefsWindow.h"

#import "MLConfigStore.h"

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

    NSRect rect = NSMakeRect(0, 0, 520, 620);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:rect
                                              styleMask:NSWindowStyleMaskTitled |
                                                        NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.title = @"MeoLaunch Preferences";
    w.releasedWhenClosed = NO;
    w.minSize = NSMakeSize(480, 520);
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

    [c addSubview:[self makeLabel:@"Grid columns" frame:NSMakeRect(pad, y, 120, 22)]];
    self.colsSlider = [self makeIntSliderMin:4 max:10 action:@selector(colsChanged:)];
    self.colsSlider.frame = NSMakeRect(136, y - 2, 280, 28);
    [c addSubview:self.colsSlider];
    self.colsValueLabel = [self makeLabel:@"7" frame:NSMakeRect(430, y, 40, 22)];
    self.colsValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.colsValueLabel];
    y += 40;

    [c addSubview:[self makeLabel:@"Grid rows" frame:NSMakeRect(pad, y, 120, 22)]];
    self.rowsSlider = [self makeIntSliderMin:3 max:8 action:@selector(rowsChanged:)];
    self.rowsSlider.frame = NSMakeRect(136, y - 2, 280, 28);
    [c addSubview:self.rowsSlider];
    self.rowsValueLabel = [self makeLabel:@"5" frame:NSMakeRect(430, y, 40, 22)];
    self.rowsValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.rowsValueLabel];
    y += 40;

    [c addSubview:[self makeLabel:@"Icon size" frame:NSMakeRect(pad, y, 120, 22)]];
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
    self.iconSizeValueLabel = [self makeLabel:@"Auto" frame:NSMakeRect(420, y, 50, 22)];
    self.iconSizeValueLabel.alignment = NSTextAlignmentRight;
    [c addSubview:self.iconSizeValueLabel];
    y += 40;

    [c addSubview:[self makeLabel:@"Overlay opacity" frame:NSMakeRect(pad, y, 120, 22)]];
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

    self.hotCornerEnabled = [NSButton checkboxWithTitle:@"Hot corner enabled"
                                                 target:self
                                                 action:@selector(prefsChanged:)];
    self.hotCornerEnabled.frame = NSMakeRect(pad, y, 220, 24);
    [c addSubview:self.hotCornerEnabled];
    y += 32;

    [c addSubview:[self makeLabel:@"Hot corner" frame:NSMakeRect(pad, y, 120, 22)]];
    self.cornerPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(140, y - 1, 180, 26) pullsDown:NO];
    [self.cornerPopup addItemsWithTitles:@[
        @"Top Left", @"Top Right", @"Bottom Left", @"Bottom Right", @"Off"
    ]];
    self.cornerPopup.target = self;
    self.cornerPopup.action = @selector(prefsChanged:);
    [c addSubview:self.cornerPopup];
    y += 32;

    [c addSubview:[self makeLabel:@"Hot size (pt)" frame:NSMakeRect(pad, y, 120, 22)]];
    self.sizeField = [self makeField:NSMakeRect(140, y, 60, 24)];
    self.sizeField.delegate = self;
    self.sizeField.target = self;
    self.sizeField.action = @selector(prefsChanged:);
    [c addSubview:self.sizeField];
    y += 36;

    NSTextField *scanTitle = [self makeLabel:@"应用目录" frame:NSMakeRect(pad, y, 200, 20)];
    scanTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    [c addSubview:scanTitle];
    y += 22;

    NSTextField *scanHint = [self makeLabel:@"外接硬盘上的 .app 可加在这里；仅扫描该文件夹及一层子文件夹。"
                                      frame:NSMakeRect(pad, y, 468, 16)];
    scanHint.font = [NSFont systemFontOfSize:11];
    scanHint.textColor = [NSColor secondaryLabelColor];
    scanHint.maximumNumberOfLines = 1;
    scanHint.lineBreakMode = NSLineBreakByTruncatingTail;
    [c addSubview:scanHint];
    y += 20;

    NSTextField *sysLabel = [self makeLabel:@"系统目录（只读）" frame:NSMakeRect(pad, y, 200, 16)];
    sysLabel.font = [NSFont systemFontOfSize:11];
    sysLabel.textColor = [NSColor secondaryLabelColor];
    [c addSubview:sysLabel];
    y += 16;

    for (NSString *root in [MLConfigStore builtInScanRoots]) {
        NSTextField *row = [self makeLabel:root frame:NSMakeRect(pad + 8, y, 456, 14)];
        row.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
        row.textColor = [NSColor tertiaryLabelColor];
        [c addSubview:row];
        y += 14;
    }
    y += 6;

    NSTextField *extraLabel = [self makeLabel:@"额外目录" frame:NSMakeRect(pad, y, 200, 16)];
    extraLabel.font = [NSFont systemFontOfSize:11];
    extraLabel.textColor = [NSColor secondaryLabelColor];
    [c addSubview:extraLabel];
    y += 18;

    CGFloat tableH = 72;
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(pad, y, 468, tableH)];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSBezelBorder;

    NSTableView *table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"path"];
    col.title = @"路径";
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

    NSButton *addBtn = [NSButton buttonWithTitle:@"添加文件夹…"
                                          target:self
                                          action:@selector(addExtraRoot:)];
    addBtn.frame = NSMakeRect(pad, y, 120, 28);
    [c addSubview:addBtn];

    NSButton *removeBtn = [NSButton buttonWithTitle:@"移除"
                                             target:self
                                             action:@selector(removeExtraRoot:)];
    removeBtn.frame = NSMakeRect(pad + 128, y, 72, 28);
    [c addSubview:removeBtn];

    NSButton *rescanBtn = [NSButton buttonWithTitle:@"重新扫描"
                                             target:self
                                             action:@selector(rescanApps:)];
    rescanBtn.frame = NSMakeRect(pad + 208, y, 100, 28);
    [c addSubview:rescanBtn];
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
        cell.stringValue = [NSString stringWithFormat:@"%@（未挂载）", path];
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
    panel.prompt = @"添加";
    panel.message = @"选择包含 .app 的文件夹（例如外接硬盘上的 Apps）";
    panel.directoryURL = [NSURL fileURLWithPath:@"/Volumes"];
    [panel beginSheetModalForWindow:self.window
                  completionHandler:^(NSModalResponse result) {
                      if (result != NSModalResponseOK || !panel.URL) {
                          return;
                      }
                      NSString *path = panel.URL.path;
                      if (![self.config addScanExtraRoot:path]) {
                          NSAlert *alert = [[NSAlert alloc] init];
                          alert.messageText = @"未能添加目录";
                          alert.informativeText = @"路径无效，或已在列表中。";
                          [alert addButtonWithTitle:@"好"];
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
