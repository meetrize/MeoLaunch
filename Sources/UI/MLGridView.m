#import "MLGridView.h"

#import "MLIconCache.h"

#include <string.h>

@implementation MLGridView {
    CGFloat _wheelAccum;
    NSTimeInterval _lastPageFlipAt;
    BOOL _dragTracking;
    BOOL _dragActive;
    NSInteger _dragSourceVis;
    NSPoint _dragStartPoint;
    NSPoint _dragOffset; /* mouse relative to icon origin */
    NSImageView *_dragImageView;
    NSInteger _dropInsertIndex; /* -1 none; destination index after drop */
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _gridConfig = (MLGridConfig){.cols = 7, .rows = 5, .padding = 48.f, .spacing = 28.f, .icon_size = 0.f};
        _currentPage = 0;
        _appIndex = NULL;
        _visibleIndices = NULL;
        _visibleCount = 0;
        _layout = NULL;
        _wheelThreshold = 0.15;
        _wheelAccum = 0;
        _lastPageFlipAt = 0;
        _selectedVisibleIndex = -1;
        _dragTracking = NO;
        _dragActive = NO;
        _dragSourceVis = -1;
        _dropInsertIndex = -1;
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

#pragma mark - Layout helpers

- (BOOL)usesLayoutRoot {
    return self.layout != NULL;
}

- (const MLLayoutNode *)nodeAtVisible:(size_t)vis {
    if (![self usesLayoutRoot] || !self.layout || !self.layout->root) {
        return NULL;
    }
    if (vis >= self.layout->count) {
        return NULL;
    }
    return &self.layout->root[vis];
}

- (BOOL)isFolderAtVisibleIndex:(NSInteger)vis {
    if (vis < 0) {
        return NO;
    }
    const MLLayoutNode *node = [self nodeAtVisible:(size_t)vis];
    return node && node->kind == ML_LAYOUT_FOLDER && node->u.folder != NULL;
}

- (NSString *)folderIdAtVisibleIndex:(NSInteger)vis {
    if (![self isFolderAtVisibleIndex:vis]) {
        return nil;
    }
    const MLLayoutNode *node = [self nodeAtVisible:(size_t)vis];
    const char *fid = node->u.folder->id;
    if (!fid || fid[0] == '\0') {
        return nil;
    }
    return [NSString stringWithUTF8String:fid];
}

- (uint32_t)appIndexForPathC:(const char *)path {
    if (!path || !self.appIndex) {
        return UINT32_MAX;
    }
    for (size_t i = 0; i < self.appIndex->count; i++) {
        const char *ip = self.appIndex->items[i].path;
        if (ip && strcmp(ip, path) == 0) {
            return (uint32_t)i;
        }
    }
    return UINT32_MAX;
}

- (NSString *)appPathAtVisible:(size_t)vis {
    if ([self usesLayoutRoot]) {
        const MLLayoutNode *node = [self nodeAtVisible:vis];
        if (!node || node->kind != ML_LAYOUT_APP || !node->u.app.path) {
            return nil;
        }
        return [NSString stringWithUTF8String:node->u.app.path];
    }
    uint32_t appIdx = [self appIndexAtVisible:vis];
    if (!self.appIndex || appIdx == UINT32_MAX || appIdx >= self.appIndex->count) {
        return nil;
    }
    const char *cpath = self.appIndex->items[appIdx].path;
    if (!cpath) {
        return nil;
    }
    return [NSString stringWithUTF8String:cpath];
}

- (uint32_t)appIndexAtVisible:(size_t)vis {
    if ([self usesLayoutRoot]) {
        const MLLayoutNode *node = [self nodeAtVisible:vis];
        if (!node || node->kind != ML_LAYOUT_APP || !node->u.app.path) {
            return UINT32_MAX;
        }
        return [self appIndexForPathC:node->u.app.path];
    }
    if (self.visibleIndices) {
        if (vis >= self.visibleCount) {
            return UINT32_MAX;
        }
        return self.visibleIndices[vis];
    }
    return (uint32_t)vis;
}

- (NSString *)displayNameForAppPath:(NSString *)path {
    if (path.length == 0) {
        return @"";
    }
    uint32_t appIdx = [self appIndexForPathC:path.UTF8String];
    if (appIdx != UINT32_MAX && self.appIndex) {
        const char *name = self.appIndex->items[appIdx].display_name;
        if (name && name[0] != '\0') {
            return [NSString stringWithUTF8String:name];
        }
    }
    return path.lastPathComponent.stringByDeletingPathExtension;
}

- (size_t)visibleItemCount {
    if (self.layout != NULL) {
        return self.layout->count;
    }
    if (self.visibleIndices) {
        return self.visibleCount;
    }
    return self.appIndex ? self.appIndex->count : 0;
}

#pragma mark - Public API

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
    if (self.selectedVisibleIndex < 0) {
        return NO;
    }
    size_t total = [self visibleItemCount];
    if ((size_t)self.selectedVisibleIndex >= total) {
        return NO;
    }
    NSInteger vis = self.selectedVisibleIndex;
    if ([self isFolderAtVisibleIndex:vis]) {
        NSString *fid = [self folderIdAtVisibleIndex:vis];
        if (!fid.length) {
            return NO;
        }
        if ([self.delegate respondsToSelector:@selector(gridView:didActivateFolderId:)]) {
            [self.delegate gridView:self didActivateFolderId:fid];
            return YES;
        }
        return NO;
    }
    NSString *path = [self appPathAtVisible:(size_t)vis];
    if (!path.length) {
        return NO;
    }
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

- (NSImage *)folderCompositeImageAtVisible:(NSInteger)vis size:(NSSize)size {
    const MLLayoutNode *node = [self nodeAtVisible:(size_t)vis];
    if (!node || node->kind != ML_LAYOUT_FOLDER || !node->u.folder) {
        return nil;
    }
    const MLLayoutFolder *folder = node->u.folder;
    if (size.width < 1.0 || size.height < 1.0) {
        return nil;
    }

    NSImage *img = [[NSImage alloc] initWithSize:size];
    [img lockFocus];

    NSRect plate = NSMakeRect(0, 0, size.width, size.height);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:plate xRadius:size.width * 0.18 yRadius:size.height * 0.18];
    [[[NSColor whiteColor] colorWithAlphaComponent:0.12] setFill];
    [path fill];

    CGFloat pad = size.width * 0.12;
    CGFloat gap = size.width * 0.06;
    CGFloat cell = (size.width - pad * 2.0 - gap) * 0.5;
    size_t n = folder->count < 4 ? folder->count : 4;
    for (size_t i = 0; i < n; i++) {
        const char *cpath = folder->items[i].path;
        if (!cpath) {
            continue;
        }
        NSString *pathStr = [NSString stringWithUTF8String:cpath];
        NSImage *icon = [self.iconCache cachedIconForPath:pathStr];
        if (!icon) {
            icon = [[NSWorkspace sharedWorkspace] iconForFile:pathStr];
        }
        if (!icon) {
            continue;
        }
        int col = (int)(i % 2);
        int row = (int)(i / 2);
        NSRect mini = NSMakeRect(pad + col * (cell + gap),
                                 pad + row * (cell + gap),
                                 cell,
                                 cell);
        [icon drawInRect:mini
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:1.0
          respectFlipped:YES
                   hints:nil];
    }

    [img unlockFocus];
    return img;
}

- (NSImage *)iconImageForVisibleIndex:(NSInteger)vis {
    if (vis < 0) {
        return nil;
    }
    size_t total = [self visibleItemCount];
    if ((size_t)vis >= total) {
        return nil;
    }
    if ([self isFolderAtVisibleIndex:vis]) {
        NSRect iconRect = [self iconRectForVisibleIndex:vis];
        NSSize size = NSIsEmptyRect(iconRect) ? NSMakeSize(64, 64) : iconRect.size;
        NSImage *composite = [self folderCompositeImageAtVisible:vis size:size];
        if (composite) {
            return composite;
        }
        const MLLayoutNode *node = [self nodeAtVisible:(size_t)vis];
        if (node && node->u.folder && node->u.folder->count > 0 && node->u.folder->items[0].path) {
            NSString *path = [NSString stringWithUTF8String:node->u.folder->items[0].path];
            NSImage *cached = [self.iconCache cachedIconForPath:path];
            return cached ?: [[NSWorkspace sharedWorkspace] iconForFile:path];
        }
        return nil;
    }
    NSString *path = [self appPathAtVisible:(size_t)vis];
    if (!path.length) {
        return nil;
    }
    return [self.iconCache cachedIconForPath:path];
}

#pragma mark - Input

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
    if (_dragActive) {
        return;
    }
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

#pragma mark - Prefetch

- (void)requestIconForPath:(NSString *)path {
    if (!path.length || !self.iconCache) {
        return;
    }
    if ([self.iconCache cachedIconForPath:path]) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    [self.iconCache loadIconForPath:path onLoaded:^(NSString *loadedPath, NSImage *image) {
        (void)loadedPath;
        (void)image;
        [weakSelf setNeedsDisplay:YES];
    }];
}

- (void)prefetchIconsForPage:(NSInteger)page {
    if (!self.iconCache || page < 0) {
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

    for (size_t i = start; i < end; i++) {
        if ([self isFolderAtVisibleIndex:(NSInteger)i]) {
            const MLLayoutNode *node = [self nodeAtVisible:i];
            if (!node || !node->u.folder) {
                continue;
            }
            size_t n = node->u.folder->count < 4 ? node->u.folder->count : 4;
            for (size_t j = 0; j < n; j++) {
                const char *cpath = node->u.folder->items[j].path;
                if (!cpath) {
                    continue;
                }
                [self requestIconForPath:[NSString stringWithUTF8String:cpath]];
            }
            continue;
        }
        uint32_t appIdx = [self appIndexAtVisible:i];
        if (appIdx == UINT32_MAX) {
            NSString *path = [self appPathAtVisible:i];
            [self requestIconForPath:path];
            continue;
        }
        if (!self.appIndex || appIdx >= self.appIndex->count) {
            continue;
        }
        NSString *path = [NSString stringWithUTF8String:self.appIndex->items[appIdx].path ?: ""];
        [self requestIconForPath:path];
    }
}

- (void)prefetchVisibleIcons {
    [self prefetchIconsForPage:self.currentPage];
    [self prefetchIconsForPage:self.currentPage - 1];
    [self prefetchIconsForPage:self.currentPage + 1];
}

#pragma mark - Drawing

- (void)drawSelectionHaloInIconRect:(NSRect)iconRect {
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

- (void)drawFolderAtVisible:(size_t)vis cell:(const MLCellFrame *)cell isDragSource:(BOOL)isDragSource {
    const MLLayoutNode *node = [self nodeAtVisible:vis];
    if (!node || node->kind != ML_LAYOUT_FOLDER || !node->u.folder) {
        return;
    }
    const MLLayoutFolder *folder = node->u.folder;
    NSRect iconRect = NSMakeRect(cell->icon_x, cell->icon_y, cell->icon_s, cell->icon_s);

    if ((NSInteger)vis == self.selectedVisibleIndex && !isDragSource) {
        [self drawSelectionHaloInIconRect:iconRect];
    }

    CGFloat radius = cell->icon_s * 0.18f;
    NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:iconRect xRadius:radius yRadius:radius];
    [[[NSColor whiteColor] colorWithAlphaComponent:isDragSource ? 0.05 : 0.12] setFill];
    [plate fill];

    if (!isDragSource) {
        CGFloat pad = cell->icon_s * 0.12f;
        CGFloat gap = cell->icon_s * 0.06f;
        CGFloat mini = (cell->icon_s - pad * 2.f - gap) * 0.5f;
        size_t n = folder->count < 4 ? folder->count : 4;
        for (size_t i = 0; i < n; i++) {
            const char *cpath = folder->items[i].path;
            if (!cpath) {
                continue;
            }
            NSString *path = [NSString stringWithUTF8String:cpath];
            NSImage *icon = [self.iconCache cachedIconForPath:path];
            if (!icon) {
                icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
                [self requestIconForPath:path];
            }
            if (!icon) {
                continue;
            }
            int col = (int)(i % 2);
            int row = (int)(i / 2);
            NSRect miniRect = NSMakeRect(cell->icon_x + pad + col * (mini + gap),
                                         cell->icon_y + pad + row * (mini + gap),
                                         mini,
                                         mini);
            [icon drawInRect:miniRect
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0
              respectFlipped:YES
                       hints:nil];
        }
    }

    NSString *name = nil;
    if (folder->name && folder->name[0] != '\0') {
        name = [NSString stringWithUTF8String:folder->name];
    }
    if (!name.length) {
        name = @"文件夹";
    }

    if (!isDragSource) {
        NSFont *labelFont = [NSFont systemFontOfSize:11];
        NSDictionary *labelAttrs = @{
            NSForegroundColorAttributeName : [NSColor whiteColor],
            NSFontAttributeName : labelFont
        };
        NSSize textSize = [name sizeWithAttributes:labelAttrs];
        CGFloat maxW = cell->w - 4.f;
        NSString *drawName = name;
        if (textSize.width > maxW) {
            drawName = [self truncatedString:name maxWidth:maxW attributes:labelAttrs];
            textSize = [drawName sizeWithAttributes:labelAttrs];
        }
        NSPoint tp = NSMakePoint(cell->x + (cell->w - textSize.width) * 0.5f, cell->label_y);
        [drawName drawAtPoint:tp withAttributes:labelAttrs];
    }
}

- (void)drawAppAtVisible:(size_t)vis
                    path:(NSString *)path
                    name:(NSString *)name
                    cell:(const MLCellFrame *)cell
            isDragSource:(BOOL)isDragSource {
    NSRect iconRect = NSMakeRect(cell->icon_x, cell->icon_y, cell->icon_s, cell->icon_s);

    if ((NSInteger)vis == self.selectedVisibleIndex && !isDragSource) {
        [self drawSelectionHaloInIconRect:iconRect];
    }

    NSImage *icon = path.length ? [self.iconCache cachedIconForPath:path] : nil;
    if (icon) {
        [icon drawInRect:iconRect
                fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver
                fraction:isDragSource ? 0.25 : 1.0
          respectFlipped:YES
                   hints:nil];
    } else if (!isDragSource) {
        [[[NSColor whiteColor] colorWithAlphaComponent:0.15] setFill];
        NSRectFill(iconRect);
        [self requestIconForPath:path];
    }

    if (name.length && !isDragSource) {
        NSFont *labelFont = [NSFont systemFontOfSize:11];
        NSDictionary *labelAttrs = @{
            NSForegroundColorAttributeName : [NSColor whiteColor],
            NSFontAttributeName : labelFont
        };
        NSSize textSize = [name sizeWithAttributes:labelAttrs];
        CGFloat maxW = cell->w - 4.f;
        NSString *drawName = name;
        if (textSize.width > maxW) {
            drawName = [self truncatedString:name maxWidth:maxW attributes:labelAttrs];
            textSize = [drawName sizeWithAttributes:labelAttrs];
        }
        NSPoint tp = NSMakePoint(cell->x + (cell->w - textSize.width) * 0.5f, cell->label_y);
        [drawName drawAtPoint:tp withAttributes:labelAttrs];
    }
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor clearColor] setFill];
    NSRectFill(self.bounds);

    size_t total = [self visibleItemCount];
    BOOL hasApps = self.appIndex && self.appIndex->count > 0;
    BOOL hasLayout = [self usesLayoutRoot] && self.layout->count > 0;
    if (total == 0) {
        NSString *text = (hasApps || hasLayout) ? @"无匹配应用" : @"No apps found";
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

    if (![self usesLayoutRoot] && !self.appIndex) {
        return;
    }

    int cap = [self pageCapacity];
    size_t start = (size_t)self.currentPage * (size_t)cap;

    float vw = (float)NSWidth(self.bounds);
    float vh = (float)NSHeight(self.bounds);

    for (int slot = 0; slot < cap; slot++) {
        size_t vis = start + (size_t)slot;
        if (vis >= total) {
            break;
        }

        MLCellFrame cell;
        ml_grid_cell_frame(&self->_gridConfig, vw, vh, slot, &cell);

        BOOL isDragSource = _dragActive && (NSInteger)vis == _dragSourceVis;

        if ([self isFolderAtVisibleIndex:(NSInteger)vis]) {
            [self drawFolderAtVisible:vis cell:&cell isDragSource:isDragSource];
            continue;
        }

        NSString *path = [self appPathAtVisible:vis];
        if (!path.length) {
            continue;
        }
        NSString *name = [self displayNameForAppPath:path];
        [self drawAppAtVisible:vis path:path name:name cell:&cell isDragSource:isDragSource];
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

#pragma mark - Hit testing

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

#pragma mark - Drag

- (BOOL)allowsReorderNow {
    if (![self.delegate respondsToSelector:@selector(gridViewAllowsReorder:)]) {
        return NO;
    }
    return [self.delegate gridViewAllowsReorder:self];
}

- (void)endDragVisuals {
    [_dragImageView removeFromSuperview];
    _dragImageView = nil;
    BOOL wasActive = _dragActive;
    _dragActive = NO;
    _dragTracking = NO;
    _dragSourceVis = -1;
    _dropInsertIndex = -1;
    [self setNeedsDisplay:YES];
    if (wasActive && [self.delegate respondsToSelector:@selector(gridViewDidEndDragging:)]) {
        [self.delegate gridViewDidEndDragging:self];
    }
}

- (void)beginDragAtPoint:(NSPoint)p {
    if (_dragSourceVis < 0) {
        return;
    }
    NSRect iconRect = [self iconRectForVisibleIndex:_dragSourceVis];
    if (NSIsEmptyRect(iconRect)) {
        return;
    }

    NSImage *icon = nil;
    if ([self isFolderAtVisibleIndex:_dragSourceVis]) {
        icon = [self folderCompositeImageAtVisible:_dragSourceVis size:iconRect.size];
        if (!icon) {
            const MLLayoutNode *node = [self nodeAtVisible:(size_t)_dragSourceVis];
            if (node && node->u.folder && node->u.folder->count > 0 && node->u.folder->items[0].path) {
                NSString *path = [NSString stringWithUTF8String:node->u.folder->items[0].path];
                icon = [self.iconCache cachedIconForPath:path];
                if (!icon) {
                    icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
                    icon = [icon copy];
                    icon.size = iconRect.size;
                }
            }
        }
    } else {
        icon = [self iconImageForVisibleIndex:_dragSourceVis];
        if (!icon) {
            NSString *path = [self appPathAtVisible:(size_t)_dragSourceVis];
            if (path.length) {
                icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
                icon = [icon copy];
                icon.size = iconRect.size;
            }
        }
    }
    if (!icon) {
        return;
    }

    NSView *content = self.window.contentView;
    NSRect startRect = [self convertRect:iconRect toView:content];
    _dragOffset = NSMakePoint(p.x - iconRect.origin.x, p.y - iconRect.origin.y);

    _dragImageView = [[NSImageView alloc] initWithFrame:startRect];
    _dragImageView.image = icon;
    _dragImageView.imageScaling = NSImageScaleAxesIndependently;
    _dragImageView.wantsLayer = YES;
    _dragImageView.alphaValue = 0.92;
    _dragImageView.layer.shadowOpacity = 0.35;
    _dragImageView.layer.shadowRadius = 8.0;
    _dragImageView.layer.shadowOffset = CGSizeMake(0, -2);
    [content addSubview:_dragImageView positioned:NSWindowAbove relativeTo:nil];

    _dragActive = YES;
    self.selectedVisibleIndex = _dragSourceVis;
    [self setNeedsDisplay:YES];
    if ([self.delegate respondsToSelector:@selector(gridViewDidBeginDragging:)]) {
        [self.delegate gridViewDidBeginDragging:self];
    }
}

- (void)updateDragImageAtPoint:(NSPoint)p {
    if (!_dragImageView) {
        return;
    }
    NSView *content = self.window.contentView;
    NSSize size = _dragImageView.frame.size;
    NSRect iconLocal = NSMakeRect(p.x - _dragOffset.x, p.y - _dragOffset.y, size.width, size.height);
    NSRect inContentRect = [self convertRect:iconLocal toView:content];
    _dragImageView.frame = inContentRect;
}

/* Center 50% of icon rect — merge / add-to-folder hotzone. Folders as source never merge. */
- (NSInteger)mergeTargetAtPoint:(NSPoint)p {
    if (_dragSourceVis < 0 || [self isFolderAtVisibleIndex:_dragSourceVis]) {
        return -1;
    }
    NSInteger target = [self visibleSlotAtPoint:p];
    if (target < 0 || target == _dragSourceVis) {
        return -1;
    }
    NSRect icon = [self iconRectForVisibleIndex:target];
    if (NSIsEmptyRect(icon)) {
        return -1;
    }
    CGFloat insetX = NSWidth(icon) * 0.25;
    CGFloat insetY = NSHeight(icon) * 0.25;
    NSRect hot = NSInsetRect(icon, insetX, insetY);
    if (!NSPointInRect(p, hot)) {
        return -1;
    }
    return target;
}

- (NSInteger)destinationIndexForDropAtPoint:(NSPoint)p {
    size_t total = [self visibleItemCount];
    if (total == 0 || _dragSourceVis < 0) {
        return -1;
    }

    NSInteger target = [self visibleSlotAtPoint:p];
    if (target < 0) {
        /* Closest cell center on current page (including empty trailing slots). */
        int cap = [self pageCapacity];
        float vw = (float)NSWidth(self.bounds);
        float vh = (float)NSHeight(self.bounds);
        size_t start = (size_t)self.currentPage * (size_t)cap;
        CGFloat best = CGFLOAT_MAX;
        NSInteger bestSlot = -1;
        for (int slot = 0; slot < cap; slot++) {
            MLCellFrame cell;
            ml_grid_cell_frame(&self->_gridConfig, vw, vh, slot, &cell);
            CGFloat cx = cell.icon_x + cell.icon_s * 0.5f;
            CGFloat cy = cell.icon_y + cell.icon_s * 0.5f;
            CGFloat d = (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy);
            if (d < best) {
                best = d;
                bestSlot = slot;
            }
        }
        if (bestSlot < 0) {
            return -1;
        }
        target = (NSInteger)start + bestSlot;
        if (target > (NSInteger)total) {
            target = (NSInteger)total;
        }
        if (target >= (NSInteger)total) {
            NSInteger dest = (NSInteger)total - 1;
            if (_dragSourceVis == dest) {
                return _dragSourceVis;
            }
            return (NSInteger)total - 1;
        }
    }

    NSRect icon = [self iconRectForVisibleIndex:target];
    NSInteger insertAt = target;
    if (!NSIsEmptyRect(icon) && p.x > NSMidX(icon)) {
        insertAt = target + 1;
    }
    if (insertAt > (NSInteger)total) {
        insertAt = (NSInteger)total;
    }

    NSInteger dest = insertAt;
    if (_dragSourceVis < insertAt) {
        dest = insertAt - 1;
    }
    if (dest < 0) {
        dest = 0;
    }
    if (dest >= (NSInteger)total) {
        dest = (NSInteger)total - 1;
    }
    return dest;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger vis = [self visibleSlotAtPoint:p];
    if (vis < 0) {
        [self endDragVisuals];
        [self.delegate gridViewDidClickBackground:self];
        return;
    }
    if (![self usesLayoutRoot] && !self.appIndex) {
        [self endDragVisuals];
        [self.delegate gridViewDidClickBackground:self];
        return;
    }

    self.selectedVisibleIndex = vis;
    _dragTracking = [self allowsReorderNow];
    _dragActive = NO;
    _dragSourceVis = vis;
    _dragStartPoint = p;
    _dropInsertIndex = -1;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragTracking || _dragSourceVis < 0) {
        return;
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!_dragActive) {
        CGFloat dx = p.x - _dragStartPoint.x;
        CGFloat dy = p.y - _dragStartPoint.y;
        if ((dx * dx + dy * dy) < 16.0) { /* ~4pt */
            return;
        }
        if (![self allowsReorderNow]) {
            _dragTracking = NO;
            return;
        }
        [self beginDragAtPoint:p];
        if (!_dragActive) {
            _dragTracking = NO;
            return;
        }
    }
    [self updateDragImageAtPoint:p];
    _dropInsertIndex = [self destinationIndexForDropAtPoint:p];
    if ([self.delegate respondsToSelector:@selector(gridView:dragMovedToWindowPoint:)]) {
        [self.delegate gridView:self dragMovedToWindowPoint:event.locationInWindow];
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];

    if (_dragActive) {
        NSInteger src = _dragSourceVis;

        /* Folder: drop on extract zone, or outside grid → extract to root */
        BOOL extract = NO;
        if (self.allowsExtractOnDragOutside && src >= 0) {
            if ([self.delegate respondsToSelector:@selector(gridView:isExtractDropAtWindowPoint:)] &&
                [self.delegate gridView:self isExtractDropAtWindowPoint:event.locationInWindow]) {
                extract = YES;
            } else if (!NSMouseInRect(p, self.bounds, self.isFlipped)) {
                extract = YES;
            }
        }
        if (extract) {
            [self endDragVisuals];
            if ([self.delegate respondsToSelector:@selector(gridView:didExtractItemAt:)]) {
                [self.delegate gridView:self didExtractItemAt:src];
            }
            return;
        }

        NSInteger mergeTarget = [self mergeTargetAtPoint:p];
        NSInteger dest = [self destinationIndexForDropAtPoint:p];
        [self endDragVisuals];

        /* Merge only on root layout browse (not inside folder). */
        if (self.layout && src >= 0 && mergeTarget >= 0 && ![self isFolderAtVisibleIndex:src]) {
            if ([self isFolderAtVisibleIndex:mergeTarget]) {
                if ([self.delegate respondsToSelector:@selector(gridView:didAddItem:toFolderAt:)]) {
                    [self.delegate gridView:self didAddItem:src toFolderAt:mergeTarget];
                    self.selectedVisibleIndex = mergeTarget;
                    return;
                }
            } else if ([self.delegate respondsToSelector:@selector(gridView:didMergeItem:ontoItem:)]) {
                [self.delegate gridView:self didMergeItem:src ontoItem:mergeTarget];
                self.selectedVisibleIndex = mergeTarget;
                return;
            }
        }

        if (dest >= 0 && src >= 0 && dest != src &&
            [self.delegate respondsToSelector:@selector(gridView:didReorderFrom:to:)]) {
            [self.delegate gridView:self didReorderFrom:src to:dest];
            self.selectedVisibleIndex = dest;
        }
        return;
    }

    BOOL wasTracking = _dragTracking;
    NSInteger src = _dragSourceVis;
    [self endDragVisuals];

    if (!wasTracking && src < 0) {
        return;
    }
    /* Click activate */
    NSInteger vis = [self visibleSlotAtPoint:p];
    if (vis < 0) {
        vis = src;
    }
    if (vis < 0) {
        return;
    }
    self.selectedVisibleIndex = vis;

    if ([self isFolderAtVisibleIndex:vis]) {
        NSString *fid = [self folderIdAtVisibleIndex:vis];
        if (fid.length && [self.delegate respondsToSelector:@selector(gridView:didActivateFolderId:)]) {
            [self.delegate gridView:self didActivateFolderId:fid];
        }
        return;
    }

    NSString *path = [self appPathAtVisible:(size_t)vis];
    if (!path.length) {
        return;
    }
    [self.delegate gridView:self didActivateAppAtPath:path];
}

@end
