#import "MLGridView.h"

#import "MLIconCache.h"

@implementation MLGridView {
    CGFloat _wheelAccum;
    NSTimeInterval _lastPageFlipAt;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _gridConfig = (MLGridConfig){.cols = 7, .rows = 5, .padding = 48.f, .spacing = 28.f, .icon_size = 0.f};
        _currentPage = 0;
        _appIndex = NULL;
        _visibleIndices = NULL;
        _visibleCount = 0;
        _wheelThreshold = 0.15;
        _wheelAccum = 0;
        _lastPageFlipAt = 0;
        _selectedVisibleIndex = -1;
        self.wantsLayer = NO;
    }
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    [self setNeedsDisplay:YES];
    return [super becomeFirstResponder];
}

- (BOOL)resignFirstResponder {
    [self setNeedsDisplay:YES];
    return [super resignFirstResponder];
}

- (size_t)visibleItemCount {
    if (self.visibleIndices) {
        return self.visibleCount;
    }
    return self.appIndex ? self.appIndex->count : 0;
}

- (uint32_t)appIndexAtVisible:(size_t)vis {
    if (self.visibleIndices) {
        return self.visibleIndices[vis];
    }
    return (uint32_t)vis;
}

- (void)reloadData {
    size_t total = [self visibleItemCount];
    if (self.selectedVisibleIndex >= (NSInteger)total) {
        self.selectedVisibleIndex = total > 0 ? (NSInteger)total - 1 : -1;
    }
    [self ensureSelectionPageVisible];
    [self setNeedsDisplay:YES];
    [self prefetchVisibleIcons];
    [self notifyPageChanged];
}

- (int)pageCapacity {
    return ml_grid_page_capacity(&self->_gridConfig);
}

- (NSInteger)pageCount {
    int cap = [self pageCapacity];
    size_t total = [self visibleItemCount];
    if (cap <= 0 || total == 0) {
        return 1;
    }
    return (NSInteger)((total + (size_t)cap - 1) / (size_t)cap);
}

- (void)notifyPageChanged {
    if ([self.delegate respondsToSelector:@selector(gridView:didChangePage:pageCount:)]) {
        [self.delegate gridView:self didChangePage:self.currentPage pageCount:[self pageCount]];
    }
}

- (void)goToPage:(NSInteger)page {
    NSInteger count = [self pageCount];
    if (page < 0) {
        page = 0;
    }
    if (page >= count) {
        page = count - 1;
    }
    if (page == self.currentPage) {
        return;
    }
    self.currentPage = page;
    _wheelAccum = 0;
    [self setNeedsDisplay:YES];
    [self prefetchVisibleIcons];
    [self notifyPageChanged];
}

- (void)nudgePage:(NSInteger)delta {
    if (delta == 0) {
        return;
    }
    [self goToPage:self.currentPage + delta];
}

- (void)ensureSelectionPageVisible {
    if (self.selectedVisibleIndex < 0) {
        return;
    }
    int cap = [self pageCapacity];
    if (cap <= 0) {
        return;
    }
    NSInteger page = self.selectedVisibleIndex / cap;
    if (page != self.currentPage) {
        [self goToPage:page];
    }
}

- (void)selectFirstVisibleItem {
    if ([self visibleItemCount] == 0) {
        self.selectedVisibleIndex = -1;
        [self setNeedsDisplay:YES];
        return;
    }
    self.selectedVisibleIndex = 0;
    [self goToPage:0];
    [self setNeedsDisplay:YES];
}

- (void)clearSelection {
    if (self.selectedVisibleIndex < 0) {
        return;
    }
    self.selectedVisibleIndex = -1;
    [self setNeedsDisplay:YES];
}

- (void)setSelectedVisibleIndex:(NSInteger)selectedVisibleIndex {
    size_t total = [self visibleItemCount];
    NSInteger next = selectedVisibleIndex;
    if (total == 0) {
        next = -1;
    } else if (next < -1) {
        next = -1;
    } else if (next >= (NSInteger)total) {
        next = (NSInteger)total - 1;
    }
    if (_selectedVisibleIndex == next) {
        return;
    }
    _selectedVisibleIndex = next;
    [self ensureSelectionPageVisible];
    [self setNeedsDisplay:YES];
}

- (void)moveSelectionByColumns:(NSInteger)dCol rows:(NSInteger)dRow {
    size_t total = [self visibleItemCount];
    if (total == 0) {
        return;
    }
    int cols = self.gridConfig.cols > 0 ? self.gridConfig.cols : 7;
    NSInteger sel = self.selectedVisibleIndex;
    if (sel < 0) {
        [self selectFirstVisibleItem];
        return;
    }

    NSInteger next = sel + dCol + dRow * cols;
    if (next < 0) {
        next = 0;
    }
    if (next >= (NSInteger)total) {
        next = (NSInteger)total - 1;
    }
    self.selectedVisibleIndex = next;
}

- (BOOL)activateSelection {
    if (self.selectedVisibleIndex < 0 || !self.appIndex) {
        return NO;
    }
    size_t total = [self visibleItemCount];
    if ((size_t)self.selectedVisibleIndex >= total) {
        return NO;
    }
    uint32_t appIdx = [self appIndexAtVisible:(size_t)self.selectedVisibleIndex];
    if (appIdx >= self.appIndex->count) {
        return NO;
    }
    const char *cpath = self.appIndex->items[appIdx].path;
    if (!cpath) {
        return NO;
    }
    NSString *path = [NSString stringWithUTF8String:cpath];
    [self.delegate gridView:self didActivateAppAtPath:path];
    return YES;
}

- (NSRect)iconRectForVisibleIndex:(NSInteger)vis {
    if (vis < 0) {
        return NSZeroRect;
    }
    int cap = [self pageCapacity];
    if (cap <= 0) {
        return NSZeroRect;
    }
    size_t start = (size_t)self.currentPage * (size_t)cap;
    if ((size_t)vis < start || (size_t)vis >= start + (size_t)cap) {
        return NSZeroRect;
    }
    int slot = (int)((size_t)vis - start);
    MLCellFrame cell;
    ml_grid_cell_frame(&self->_gridConfig,
                       (float)NSWidth(self.bounds),
                       (float)NSHeight(self.bounds),
                       slot,
                       &cell);
    return NSMakeRect(cell.icon_x, cell.icon_y, cell.icon_s, cell.icon_s);
}

- (NSImage *)iconImageForVisibleIndex:(NSInteger)vis {
    if (vis < 0 || !self.appIndex) {
        return nil;
    }
    size_t total = [self visibleItemCount];
    if ((size_t)vis >= total) {
        return nil;
    }
    uint32_t appIdx = [self appIndexAtVisible:(size_t)vis];
    if (appIdx >= self.appIndex->count) {
        return nil;
    }
    NSString *path = [NSString stringWithUTF8String:self.appIndex->items[appIdx].path ?: ""];
    return path.length ? [self.iconCache cachedIconForPath:path] : nil;
}

- (void)scrollWheel:(NSEvent *)event {
    NSInteger pages = [self pageCount];
    if (pages <= 1) {
        return;
    }

    CGFloat dx = event.scrollingDeltaX;
    CGFloat dy = event.scrollingDeltaY;
    CGFloat primary = (fabs(dx) > fabs(dy)) ? dx : -dy;
    if (fabs(primary) < 0.01) {
        return;
    }

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastPageFlipAt < 0.10) {
        return;
    }

    _lastPageFlipAt = now;
    _wheelAccum = 0;
    [self nudgePage:(primary > 0 ? 1 : -1)];
}

- (void)keyDown:(NSEvent *)event {
    switch (event.keyCode) {
        case 123: /* left */
            [self moveSelectionByColumns:-1 rows:0];
            return;
        case 124: /* right */
            [self moveSelectionByColumns:1 rows:0];
            return;
        case 125: /* down */
            [self moveSelectionByColumns:0 rows:1];
            return;
        case 126: /* up */
            [self moveSelectionByColumns:0 rows:-1];
            return;
        case 36:  /* return */
        case 76:  /* keypad enter */
            [self activateSelection];
            return;
        default:
            break;
    }
    [super keyDown:event];
}

- (void)prefetchIconsForPage:(NSInteger)page {
    if (!self.appIndex || !self.iconCache || page < 0) {
        return;
    }
    NSInteger pages = [self pageCount];
    if (page >= pages) {
        return;
    }
    int cap = [self pageCapacity];
    if (cap <= 0) {
        return;
    }
    size_t total = [self visibleItemCount];
    size_t start = (size_t)page * (size_t)cap;
    size_t end = start + (size_t)cap;
    if (end > total) {
        end = total;
    }

    __weak typeof(self) weakSelf = self;
    for (size_t i = start; i < end; i++) {
        uint32_t appIdx = [self appIndexAtVisible:i];
        if (appIdx >= self.appIndex->count) {
            continue;
        }
        NSString *path = [NSString stringWithUTF8String:self.appIndex->items[appIdx].path];
        if (!path || [self.iconCache cachedIconForPath:path]) {
            continue;
        }
        [self.iconCache loadIconForPath:path onLoaded:^(NSString *loadedPath, NSImage *image) {
            (void)loadedPath;
            (void)image;
            [weakSelf setNeedsDisplay:YES];
        }];
    }
}

- (void)prefetchVisibleIcons {
    [self prefetchIconsForPage:self.currentPage];
    [self prefetchIconsForPage:self.currentPage - 1];
    [self prefetchIconsForPage:self.currentPage + 1];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor clearColor] setFill];
    NSRectFill(self.bounds);

    size_t total = [self visibleItemCount];
    if (!self.appIndex || total == 0) {
        NSString *text = self.appIndex && self.appIndex->count > 0 ? @"无匹配应用" : @"No apps found";
        NSDictionary *attrs = @{
            NSForegroundColorAttributeName : [NSColor whiteColor],
            NSFontAttributeName : [NSFont systemFontOfSize:18]
        };
        NSSize size = [text sizeWithAttributes:attrs];
        NSPoint p = NSMakePoint(NSMidX(self.bounds) - size.width * 0.5,
                                NSMidY(self.bounds) - size.height * 0.5);
        [text drawAtPoint:p withAttributes:attrs];
        return;
    }

    int cap = [self pageCapacity];
    size_t start = (size_t)self.currentPage * (size_t)cap;
    NSFont *labelFont = [NSFont systemFontOfSize:11];
    NSDictionary *labelAttrs = @{
        NSForegroundColorAttributeName : [NSColor whiteColor],
        NSFontAttributeName : labelFont
    };

    float vw = (float)NSWidth(self.bounds);
    float vh = (float)NSHeight(self.bounds);

    for (int slot = 0; slot < cap; slot++) {
        size_t vis = start + (size_t)slot;
        if (vis >= total) {
            break;
        }

        uint32_t appIdx = [self appIndexAtVisible:vis];
        if (appIdx >= self.appIndex->count) {
            continue;
        }

        MLCellFrame cell;
        ml_grid_cell_frame(&self->_gridConfig, vw, vh, slot, &cell);

        const MLAppEntry *entry = &self.appIndex->items[appIdx];
        NSString *path = [NSString stringWithUTF8String:entry->path ?: ""];
        NSString *name = [NSString stringWithUTF8String:entry->display_name ?: ""];

        NSRect iconRect = NSMakeRect(cell.icon_x, cell.icon_y, cell.icon_s, cell.icon_s);

        if ((NSInteger)vis == self.selectedVisibleIndex) {
            NSRect halo = NSInsetRect(iconRect, -10.0, -10.0);
            NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:halo xRadius:16 yRadius:16];
            [[[NSColor whiteColor] colorWithAlphaComponent:0.18] setFill];
            [fill fill];
            NSBezierPath *stroke = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(halo, 0.5, 0.5)
                                                                  xRadius:16
                                                                  yRadius:16];
            stroke.lineWidth = 1.5;
            [[[NSColor whiteColor] colorWithAlphaComponent:0.55] setStroke];
            [stroke stroke];
        }

        NSImage *icon = [self.iconCache cachedIconForPath:path];
        if (icon) {
            [icon drawInRect:iconRect
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0
              respectFlipped:YES
                       hints:nil];
        } else {
            [[[NSColor whiteColor] colorWithAlphaComponent:0.15] setFill];
            NSRectFill(iconRect);
            if (path.length) {
                __weak typeof(self) weakSelf = self;
                [self.iconCache loadIconForPath:path onLoaded:^(NSString *loadedPath, NSImage *image) {
                    (void)loadedPath;
                    (void)image;
                    [weakSelf setNeedsDisplay:YES];
                }];
            }
        }

        if (name.length) {
            NSSize textSize = [name sizeWithAttributes:labelAttrs];
            CGFloat maxW = cell.w - 4.f;
            NSString *drawName = name;
            if (textSize.width > maxW) {
                drawName = [self truncatedString:name maxWidth:maxW attributes:labelAttrs];
                textSize = [drawName sizeWithAttributes:labelAttrs];
            }
            NSPoint tp = NSMakePoint(cell.x + (cell.w - textSize.width) * 0.5f, cell.label_y);
            [drawName drawAtPoint:tp withAttributes:labelAttrs];
        }
    }
}

- (NSString *)truncatedString:(NSString *)s maxWidth:(CGFloat)maxW attributes:(NSDictionary *)attrs {
    if (s.length <= 1) {
        return s;
    }
    NSString *ellipsis = @"…";
    for (NSUInteger len = s.length; len > 0; len--) {
        NSString *candidate = [[s substringToIndex:len] stringByAppendingString:ellipsis];
        if ([candidate sizeWithAttributes:attrs].width <= maxW) {
            return candidate;
        }
    }
    return ellipsis;
}

- (NSInteger)visibleSlotAtPoint:(NSPoint)p {
    int cap = [self pageCapacity];
    float vw = (float)NSWidth(self.bounds);
    float vh = (float)NSHeight(self.bounds);
    size_t start = (size_t)self.currentPage * (size_t)cap;
    size_t total = [self visibleItemCount];

    const CGFloat pad = 4.0;
    const CGFloat labelH = 16.0;

    for (int slot = 0; slot < cap; slot++) {
        size_t vis = start + (size_t)slot;
        if (vis >= total) {
            break;
        }
        MLCellFrame cell;
        ml_grid_cell_frame(&self->_gridConfig, vw, vh, slot, &cell);

        NSRect iconHit = NSInsetRect(
            NSMakeRect(cell.icon_x, cell.icon_y, cell.icon_s, cell.icon_s),
            -pad,
            -pad);
        NSRect labelHit = NSMakeRect(cell.icon_x - pad,
                                     cell.label_y - 2.0,
                                     cell.icon_s + pad * 2.0,
                                     labelH);
        if (NSPointInRect(p, iconHit) || NSPointInRect(p, labelHit)) {
            return (NSInteger)vis;
        }
    }
    return -1;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger vis = [self visibleSlotAtPoint:p];
    if (vis < 0 || !self.appIndex) {
        [self.delegate gridViewDidClickBackground:self];
        return;
    }
    self.selectedVisibleIndex = vis;
    uint32_t appIdx = [self appIndexAtVisible:(size_t)vis];
    if (appIdx >= self.appIndex->count) {
        return;
    }
    const char *cpath = self.appIndex->items[appIdx].path;
    if (!cpath) {
        return;
    }
    NSString *path = [NSString stringWithUTF8String:cpath];
    [self.delegate gridView:self didActivateAppAtPath:path];
}

@end
