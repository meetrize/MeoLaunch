#import "MLChipLocatorPanel.h"

#import "MLIconCache.h"
#import "MLStrings.h"

static const CGFloat kMLLocatorPanelWidth = 460.0;
static const CGFloat kMLLocatorRowHeight = 38.0;
static const CGFloat kMLLocatorHeaderHeight = 26.0;
static const CGFloat kMLLocatorSearchHeight = 36.0;
static const CGFloat kMLLocatorCorner = 13.0;
static const CGFloat kMLLocatorPad = 12.0;
static const CGFloat kMLLocatorSearchCorner = 10.0;
static const CGFloat kMLLocatorSearchHInset = 12.0;

@implementation MLChipLocatorRow
@end

/** Vertically centered text for the locator search field. */
@interface MLLocatorSearchFieldCell : NSTextFieldCell
@end

@implementation MLLocatorSearchFieldCell

- (NSRect)titleRectForBounds:(NSRect)rect {
    NSRect r = NSInsetRect(rect, kMLLocatorSearchHInset, 0);
    CGFloat textH = self.font ? ceil(self.font.boundingRectForFont.size.height) : 16.0;
    CGFloat h = MIN(textH + 2.0, NSHeight(r));
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

- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
    NSText *editor = [super setUpFieldEditorAttributes:textObj];
    if ([editor isKindOfClass:[NSTextView class]]) {
        NSTextView *tv = (NSTextView *)editor;
        tv.focusRingType = NSFocusRingTypeNone;
        tv.drawsBackground = NO;
        tv.backgroundColor = [NSColor clearColor];
    }
    return editor;
}

@end

/** Chrome that drags the panel when clicking non-interactive areas. */
@interface MLChipLocatorChromeView : NSView
@property (nonatomic, weak) NSView *searchField;
@property (nonatomic, weak) NSView *scrollView;
@end

@implementation MLChipLocatorChromeView
- (void)mouseDown:(NSEvent *)event {
    NSView *content = self.window.contentView;
    NSPoint inContent = [content convertPoint:event.locationInWindow fromView:nil];
    NSView *hit = [content hitTest:inContent];
    BOOL onSearch = (hit == self.searchField || [hit isDescendantOf:self.searchField]);
    BOOL onList = (hit == self.scrollView || [hit isDescendantOf:self.scrollView]);
    if (onSearch || onList) {
        [super mouseDown:event];
        return;
    }
    [self.window performWindowDragWithEvent:event];
}
@end

@class MLChipLocatorPanel;

@interface MLChipLocatorTableView : NSTableView
@property (nonatomic, weak) MLChipLocatorPanel *locatorPanel;
@end

@interface MLChipLocatorPanel ()
@property (nonatomic, strong) NSVisualEffectView *effectView;
@property (nonatomic, strong) MLChipLocatorChromeView *chrome;
@property (nonatomic, strong) NSView *searchShell;
@property (nonatomic, strong) NSTextField *searchField;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) MLChipLocatorTableView *tableView;
@property (nonatomic, strong) NSTextField *emptyLabel;
@property (nonatomic, assign, readwrite) BOOL showingAll;
- (void)handleHoverAtTableRow:(NSInteger)tableRow;
@end

@implementation MLChipLocatorTableView
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in [self.trackingAreas copy]) {
        [self removeTrackingArea:area];
    }
    NSTrackingAreaOptions opts = NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                 NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect |
                                 NSTrackingEnabledDuringMouseDrag;
    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                        options:opts
                                                          owner:self
                                                       userInfo:nil];
    [self addTrackingArea:area];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    [self.locatorPanel handleHoverAtTableRow:row];
}

- (void)mouseEntered:(NSEvent *)event {
    [self mouseMoved:event];
}
@end

@implementation MLChipLocatorPanel

- (instancetype)initPanel {
    NSRect content = NSMakeRect(0, 0, kMLLocatorPanelWidth, 320);
    /* Do NOT use NonactivatingPanel — search field must be able to become key. */
    self = [super initWithContentRect:content
                            styleMask:NSWindowStyleMaskBorderless
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (!self) {
        return nil;
    }
    self.opaque = NO;
    self.backgroundColor = [NSColor clearColor];
    self.hasShadow = YES;
    /* Stay above preview-raised app windows without fighting focus. */
    self.level = NSStatusWindowLevel + 1;
    self.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
                              NSWindowCollectionBehaviorFullScreenAuxiliary |
                              NSWindowCollectionBehaviorTransient;
    self.releasedWhenClosed = NO;
    self.hidesOnDeactivate = NO;
    self.becomesKeyOnlyIfNeeded = NO;
    self.animationBehavior = NSWindowAnimationBehaviorUtilityWindow;
    self.movableByWindowBackground = YES;
    self.title = @"Chip Locator";
    self.accessibilityRole = NSAccessibilityWindowRole;
    self.accessibilityLabel = @"Chip Locator";

    _rows = @[];
    _highlightedCandidateIndex = 0;
    _query = @"";
    _showingAll = NO;

    _effectView = [[NSVisualEffectView alloc] initWithFrame:content];
    _effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _effectView.material = NSVisualEffectMaterialSidebar;
    _effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    _effectView.state = NSVisualEffectStateActive;
    _effectView.wantsLayer = YES;
    _effectView.layer.cornerRadius = kMLLocatorCorner;
    _effectView.layer.masksToBounds = YES;

    NSView *border = [[NSView alloc] initWithFrame:_effectView.bounds];
    border.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    border.wantsLayer = YES;
    border.layer.cornerRadius = kMLLocatorCorner;
    border.layer.borderWidth = 1.0;
    border.layer.borderColor = [[NSColor colorWithWhite:1.0 alpha:0.35] CGColor];
    border.layer.masksToBounds = YES;
    [_effectView addSubview:border];

    _chrome = [[MLChipLocatorChromeView alloc] initWithFrame:content];
    _chrome.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat contentInnerW = kMLLocatorPanelWidth - kMLLocatorPad * 2;
    CGFloat searchY = content.size.height - kMLLocatorPad - kMLLocatorSearchHeight;
    _searchShell = [[NSView alloc] initWithFrame:NSMakeRect(kMLLocatorPad, searchY,
                                                            contentInnerW, kMLLocatorSearchHeight)];
    _searchShell.wantsLayer = YES;
    _searchShell.layer.cornerRadius = kMLLocatorSearchCorner;
    _searchShell.layer.masksToBounds = YES;
    _searchShell.layer.backgroundColor =
        [[[NSColor labelColor] colorWithAlphaComponent:0.08] CGColor];

    _searchField = [[NSTextField alloc] initWithFrame:_searchShell.bounds];
    _searchField.cell = [[MLLocatorSearchFieldCell alloc] init];
    _searchField.placeholderString = [MLStrings t:@"locator.search_placeholder"];
    _searchField.font = [NSFont systemFontOfSize:14 weight:NSFontWeightRegular];
    _searchField.editable = YES;
    _searchField.selectable = YES;
    /* Transparent field over rounded shell — no system blue focus ring. */
    _searchField.bezeled = NO;
    _searchField.bordered = NO;
    _searchField.drawsBackground = NO;
    _searchField.backgroundColor = [NSColor clearColor];
    _searchField.focusRingType = NSFocusRingTypeNone;
    _searchField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _searchField.delegate = self;
    [_searchShell addSubview:_searchField];
    [_chrome addSubview:_searchShell];

    _tableView = [[MLChipLocatorTableView alloc] initWithFrame:NSZeroRect];
    _tableView.locatorPanel = self;
    _tableView.headerView = nil;
    _tableView.rowHeight = kMLLocatorRowHeight;
    _tableView.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    _tableView.allowsEmptySelection = YES;
    _tableView.allowsMultipleSelection = NO;
    _tableView.backgroundColor = [NSColor clearColor];
    _tableView.intercellSpacing = NSMakeSize(0, 2);
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.target = self;
    _tableView.action = @selector(tableClicked:);
    _tableView.doubleAction = @selector(tableDoubleClicked:);
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"row"];
    col.width = contentInnerW;
    [_tableView addTableColumn:col];

    _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    _scrollView.documentView = _tableView;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.borderType = NSNoBorder;
    _scrollView.drawsBackground = NO;
    _scrollView.backgroundColor = [NSColor clearColor];
    [_chrome addSubview:_scrollView];

    _emptyLabel = [[NSTextField alloc] initWithFrame:NSZeroRect];
    _emptyLabel.editable = NO;
    _emptyLabel.bordered = NO;
    _emptyLabel.drawsBackground = NO;
    _emptyLabel.alignment = NSTextAlignmentCenter;
    _emptyLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
    _emptyLabel.textColor = [NSColor secondaryLabelColor];
    _emptyLabel.hidden = YES;
    [_chrome addSubview:_emptyLabel];

    _chrome.searchField = _searchShell; /* whole rounded shell is interactive / non-drag */
    _chrome.scrollView = _scrollView;

    [_effectView addSubview:_chrome];
    self.contentView = _effectView;
    [self layoutSubviewsForHeight:320];
    return self;
}

- (BOOL)canBecomeKeyWindow {
    return YES;
}

- (BOOL)canBecomeMainWindow {
    return NO;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)setShowingAll:(BOOL)showingAll {
    _showingAll = showingAll;
}

- (void)setQuery:(NSString *)query {
    _query = [query copy] ?: @"";
    if (![self.searchField.stringValue isEqualToString:_query]) {
        self.searchField.stringValue = _query;
    }
}

- (void)setRows:(NSArray<MLChipLocatorRow *> *)rows {
    _rows = [rows copy] ?: @[];
    [self.tableView reloadData];
    [self scrollHighlightVisible];
}

- (void)updateEmptyMessage:(NSString *)message {
    if (message.length == 0) {
        self.emptyLabel.hidden = YES;
        self.emptyLabel.stringValue = @"";
        return;
    }
    self.emptyLabel.stringValue = message;
    self.emptyLabel.hidden = NO;
}

- (void)layoutForScreen:(NSScreen *)screen {
    if (!screen) {
        screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    }
    if (!screen) {
        return;
    }
    NSRect vis = screen.visibleFrame;
    CGFloat maxH = floor(vis.size.height * 0.65);
    CGFloat contentH = [self preferredContentHeightCappedAt:maxH];
    CGFloat x = NSMinX(vis) + floor((NSWidth(vis) - kMLLocatorPanelWidth) * 0.5);
    CGFloat y = NSMinY(vis) + floor(NSHeight(vis) * 0.72) - contentH;
    if (y < NSMinY(vis) + 20) {
        y = NSMinY(vis) + 20;
    }
    [self setFrame:NSMakeRect(x, y, kMLLocatorPanelWidth, contentH) display:YES];
    [self layoutSubviewsForHeight:contentH];
}

- (CGFloat)preferredContentHeightCappedAt:(CGFloat)maxH {
    CGFloat listH = 0;
    for (MLChipLocatorRow *row in self.rows) {
        listH += row.isSectionHeader ? kMLLocatorHeaderHeight : kMLLocatorRowHeight;
        listH += 2;
    }
    if (listH < kMLLocatorRowHeight * 3) {
        listH = kMLLocatorRowHeight * 3;
    }
    CGFloat h = kMLLocatorPad + kMLLocatorSearchHeight + 8 + listH + kMLLocatorPad;
    return MIN(MAX(h, 160), maxH);
}

- (void)layoutSubviewsForHeight:(CGFloat)height {
    NSRect bounds = NSMakeRect(0, 0, kMLLocatorPanelWidth, height);
    self.effectView.frame = bounds;
    self.chrome.frame = bounds;
    CGFloat innerW = kMLLocatorPanelWidth - kMLLocatorPad * 2;
    CGFloat searchY = height - kMLLocatorPad - kMLLocatorSearchHeight;
    /* Search + list share the same horizontal inset (full width). */
    self.searchShell.frame = NSMakeRect(kMLLocatorPad, searchY, innerW, kMLLocatorSearchHeight);
    self.searchField.frame = self.searchShell.bounds;
    self.searchShell.layer.backgroundColor =
        [[[NSColor labelColor] colorWithAlphaComponent:0.08] CGColor];
    CGFloat listTop = searchY - 8;
    CGFloat listH = listTop - kMLLocatorPad;
    self.scrollView.frame = NSMakeRect(kMLLocatorPad, kMLLocatorPad, innerW, listH);
    self.emptyLabel.frame = NSInsetRect(self.scrollView.frame, 8, 8);
    NSTableColumn *col = self.tableView.tableColumns.firstObject;
    col.width = innerW;
}

- (void)reloadListKeepingHighlight:(BOOL)keep {
    (void)keep;
    CGFloat maxH = self.screen.visibleFrame.size.height * 0.65;
    CGFloat contentH = [self preferredContentHeightCappedAt:maxH];
    NSRect f = self.frame;
    /* Keep top edge stable when height changes (resize downward). */
    CGFloat top = NSMaxY(f);
    f.size.height = contentH;
    f.origin.y = top - contentH;
    [self setFrame:f display:YES];
    [self layoutSubviewsForHeight:contentH];
    [self.tableView reloadData];
    [self scrollHighlightVisible];
}

- (void)focusSearchField {
    [NSApp activateIgnoringOtherApps:YES];
    [self makeKeyAndOrderFront:nil];
    /* Field editor needs a runloop turn after becoming key. */
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        [self makeKeyAndOrderFront:nil];
        [self makeFirstResponder:self.searchField];
        NSText *editor = [self fieldEditor:YES forObject:self.searchField];
        if ([editor isKindOfClass:[NSTextView class]]) {
            NSTextView *tv = (NSTextView *)editor;
            tv.focusRingType = NSFocusRingTypeNone;
            NSUInteger len = tv.string.length;
            tv.selectedRange = NSMakeRange(len, 0);
        }
    });
}

- (void)handleHoverAtTableRow:(NSInteger)tableRow {
    if (tableRow < 0 || tableRow >= (NSInteger)self.rows.count) {
        return;
    }
    MLChipLocatorRow *r = self.rows[(NSUInteger)tableRow];
    if (r.isSectionHeader || r.isShowAllFooter || r.isEmptyPlaceholder) {
        return;
    }
    if (r.candidateIndex < 0) {
        return;
    }
    if (r.candidateIndex == self.highlightedCandidateIndex) {
        return;
    }
    self.highlightedCandidateIndex = r.candidateIndex;
    [self.tableView reloadData];
    [self.locatorDelegate chipLocatorPanel:self didHoverCandidateIndex:r.candidateIndex];
}

- (void)scrollHighlightVisible {
    NSInteger tableRow = [self tableRowForCandidateIndex:self.highlightedCandidateIndex];
    if (tableRow >= 0 && tableRow < (NSInteger)self.rows.count) {
        [self.tableView scrollRowToVisible:tableRow];
        [self.tableView reloadData];
    }
}

- (NSInteger)tableRowForCandidateIndex:(NSInteger)candIdx {
    if (candIdx < 0) {
        return -1;
    }
    for (NSInteger i = 0; i < (NSInteger)self.rows.count; i++) {
        MLChipLocatorRow *r = self.rows[(NSUInteger)i];
        if (!r.isSectionHeader && !r.isShowAllFooter && !r.isEmptyPlaceholder &&
            r.candidateIndex == candIdx) {
            return i;
        }
    }
    return -1;
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.rows.count;
}

- (CGFloat)tableView:(NSTableView *)tableView heightOfRow:(NSInteger)row {
    (void)tableView;
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return kMLLocatorRowHeight;
    }
    MLChipLocatorRow *r = self.rows[(NSUInteger)row];
    if (r.isSectionHeader) {
        return kMLLocatorHeaderHeight;
    }
    return kMLLocatorRowHeight;
}

- (BOOL)tableView:(NSTableView *)tableView shouldSelectRow:(NSInteger)row {
    (void)tableView;
    (void)row;
    return NO;
}

- (NSView *)tableView:(NSTableView *)tableView
    viewForTableColumn:(NSTableColumn *)tableColumn
                  row:(NSInteger)row {
    (void)tableColumn;
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return nil;
    }
    MLChipLocatorRow *r = self.rows[(NSUInteger)row];
    if (r.isSectionHeader) {
        NSTextField *lab = [tableView makeViewWithIdentifier:@"hdr" owner:self];
        if (!lab) {
            lab = [[NSTextField alloc] initWithFrame:NSZeroRect];
            lab.identifier = @"hdr";
            lab.editable = NO;
            lab.bordered = NO;
            lab.drawsBackground = NO;
            lab.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
            lab.textColor = [NSColor secondaryLabelColor];
        }
        lab.stringValue = r.headerTitle ?: @"";
        return lab;
    }
    if (r.isShowAllFooter) {
        NSButton *btn = [tableView makeViewWithIdentifier:@"all" owner:self];
        if (!btn) {
            btn = [[NSButton alloc] initWithFrame:NSZeroRect];
            btn.identifier = @"all";
            btn.bezelStyle = NSBezelStyleInline;
            btn.bordered = NO;
            btn.target = self;
            btn.action = @selector(showAllClicked:);
            btn.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        }
        if (self.showingAll) {
            btn.title = [MLStrings t:@"locator.show_less"];
        } else if (r.remainingHiddenCount > 0) {
            btn.title = [NSString stringWithFormat:[MLStrings t:@"locator.show_all_fmt"],
                                                   (unsigned long)r.remainingHiddenCount];
        } else {
            btn.title = [MLStrings t:@"locator.show_all"];
        }
        return btn;
    }
    if (r.isEmptyPlaceholder) {
        NSTextField *lab = [tableView makeViewWithIdentifier:@"empty" owner:self];
        if (!lab) {
            lab = [[NSTextField alloc] initWithFrame:NSZeroRect];
            lab.identifier = @"empty";
            lab.editable = NO;
            lab.bordered = NO;
            lab.drawsBackground = NO;
            lab.alignment = NSTextAlignmentCenter;
            lab.font = [NSFont systemFontOfSize:13];
            lab.textColor = [NSColor secondaryLabelColor];
        }
        lab.stringValue = r.title ?: @"";
        return lab;
    }

    NSView *cell = [tableView makeViewWithIdentifier:@"cand" owner:self];
    NSImageView *iconView = nil;
    NSTextField *titleField = nil;
    NSTextField *subField = nil;
    NSView *hl = nil;
    if (!cell) {
        cell = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, kMLLocatorRowHeight)];
        cell.identifier = @"cand";
        cell.wantsLayer = YES;

        hl = [[NSView alloc] initWithFrame:NSZeroRect];
        hl.identifier = @"hl";
        hl.wantsLayer = YES;
        hl.layer.cornerRadius = 8.0;
        hl.layer.backgroundColor =
            [[NSColor colorWithCalibratedRed:0.847 green:0.902 blue:0.980 alpha:1.0] CGColor];
        hl.hidden = YES;
        [cell addSubview:hl];

        iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
        iconView.identifier = @"icon";
        iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        [cell addSubview:iconView];

        titleField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        titleField.identifier = @"title";
        titleField.editable = NO;
        titleField.bordered = NO;
        titleField.drawsBackground = NO;
        titleField.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
        titleField.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:titleField];

        subField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        subField.identifier = @"sub";
        subField.editable = NO;
        subField.bordered = NO;
        subField.drawsBackground = NO;
        subField.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
        subField.textColor = [NSColor secondaryLabelColor];
        subField.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:subField];
    } else {
        for (NSView *v in cell.subviews) {
            if ([v.identifier isEqualToString:@"hl"]) {
                hl = v;
            } else if ([v.identifier isEqualToString:@"icon"]) {
                iconView = (NSImageView *)v;
            } else if ([v.identifier isEqualToString:@"title"]) {
                titleField = (NSTextField *)v;
            } else if ([v.identifier isEqualToString:@"sub"]) {
                subField = (NSTextField *)v;
            }
        }
    }

    NSRect b = cell.bounds;
    if (NSWidth(b) < 10) {
        b = NSMakeRect(0, 0, NSWidth(tableView.bounds), kMLLocatorRowHeight);
    }
    hl.frame = NSInsetRect(b, 2, 1);
    BOOL highlighted = (r.candidateIndex == self.highlightedCandidateIndex);
    hl.hidden = !highlighted;
    if (highlighted) {
        NSAppearance *app = self.effectiveAppearance;
        BOOL dark = NO;
        if (@available(macOS 10.14, *)) {
            NSAppearanceName name =
                [app bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua,
                                                          NSAppearanceNameDarkAqua ]];
            dark = [name isEqualToString:NSAppearanceNameDarkAqua];
        }
        if (dark) {
            hl.layer.backgroundColor =
                [[NSColor colorWithCalibratedRed:0.30 green:0.40 blue:0.55 alpha:0.85] CGColor];
        } else {
            hl.layer.backgroundColor =
                [[NSColor colorWithCalibratedRed:0.847 green:0.902 blue:0.980 alpha:1.0] CGColor];
        }
    }

    iconView.frame = NSMakeRect(10, floor((kMLLocatorRowHeight - 28) * 0.5), 28, 28);
    titleField.frame = NSMakeRect(46, 17, NSWidth(b) - 56, 16);
    subField.frame = NSMakeRect(46, 3, NSWidth(b) - 56, 14);
    titleField.stringValue = r.title ?: @"";
    subField.stringValue = r.subtitle ?: @"";

    NSImage *img = nil;
    if (r.iconPath.length > 0 && self.iconCache) {
        img = [self.iconCache cachedIconForPath:r.iconPath];
        if (!img) {
            img = [self.iconCache slimIconForPath:r.iconPath pointSize:32.0];
        }
    }
    iconView.image = img;
    return cell;
}

- (void)tableClicked:(id)sender {
    (void)sender;
    NSInteger row = self.tableView.clickedRow;
    if (row < 0 || row >= (NSInteger)self.rows.count) {
        return;
    }
    MLChipLocatorRow *r = self.rows[(NSUInteger)row];
    if (r.isShowAllFooter) {
        [self.locatorDelegate chipLocatorPanelDidClickShowAll:self];
        return;
    }
    if (r.isSectionHeader || r.isEmptyPlaceholder) {
        return;
    }
    [self.locatorDelegate chipLocatorPanel:self didClickRow:r.candidateIndex];
}

- (void)tableDoubleClicked:(id)sender {
    [self tableClicked:sender];
}

- (void)showAllClicked:(id)sender {
    (void)sender;
    [self.locatorDelegate chipLocatorPanelDidClickShowAll:self];
}

#pragma mark - Search + keys

- (void)controlTextDidChange:(NSNotification *)obj {
    (void)obj;
    self.query = self.searchField.stringValue ?: @"";
    [self.locatorDelegate chipLocatorPanelQueryDidChange:self];
}

- (BOOL)control:(NSControl *)control
       textView:(NSTextView *)textView
doCommandBySelector:(SEL)commandSelector {
    (void)control;
    if (textView.markedRange.length > 0) {
        return NO;
    }
    if (commandSelector == @selector(moveDown:) ||
        commandSelector == @selector(moveDownAndModifySelection:)) {
        [self.locatorDelegate chipLocatorPanel:self didMoveHighlightBy:1];
        return YES;
    }
    if (commandSelector == @selector(moveUp:) ||
        commandSelector == @selector(moveUpAndModifySelection:)) {
        [self.locatorDelegate chipLocatorPanel:self didMoveHighlightBy:-1];
        return YES;
    }
    if (commandSelector == @selector(insertNewline:) ||
        commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
        [self.locatorDelegate chipLocatorPanelDidConfirm:self];
        return YES;
    }
    if (commandSelector == @selector(cancelOperation:)) {
        [self.locatorDelegate chipLocatorPanelDidCancel:self];
        return YES;
    }
    return NO;
}

- (void)keyDown:(NSEvent *)event {
    NSString *chars = event.charactersIgnoringModifiers;
    if (chars.length == 1) {
        unichar c = [chars characterAtIndex:0];
        if (c == 27) { /* Esc */
            [self.locatorDelegate chipLocatorPanelDidCancel:self];
            return;
        }
        if (c == NSUpArrowFunctionKey) {
            [self.locatorDelegate chipLocatorPanel:self didMoveHighlightBy:-1];
            return;
        }
        if (c == NSDownArrowFunctionKey) {
            [self.locatorDelegate chipLocatorPanel:self didMoveHighlightBy:1];
            return;
        }
        if (c == NSCarriageReturnCharacter || c == NSEnterCharacter) {
            [self.locatorDelegate chipLocatorPanelDidConfirm:self];
            return;
        }
    }
    [super keyDown:event];
}

@end
