#import "MLGridView.h"

#import "MLIconCache.h"

#import <QuartzCore/QuartzCore.h>

#include <string.h>

@implementation MLGridView {
    CGFloat _wheelAccum;
    NSTimeInterval _lastPageFlipAt;
    BOOL _dragTracking;
    BOOL _dragActive;
    BOOL _dropAnimating;
    NSInteger _dragSourceVis;
    NSPoint _dragStartPoint;
    NSPoint _dragOffset; /* mouse relative to icon origin (base size) */
    NSSize _dragIconBaseSize;
    NSImageView *_dragImageView;
    NSInteger _dropInsertIndex; /* -1 none; destination index after drop */
    NSInteger _mergeHoverVis;   /* -1 none; merge / add-to-folder target */
    NSInteger _gapAnimFromDest; /* previous insert index for lerp */
    NSTimeInterval _gapAnimStart;
    NSInteger _edgeFlipSide; /* -1 left, 0 none, +1 right */
    NSTimeInterval _edgeEnterTime;
    NSMutableDictionary<NSString *, NSImage *> *_folderCompositeCache;
    NSMutableArray<NSString *> *_folderCompositeLRU;
}

enum { MLFolderCompositeMaxEntries = 16 };

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
        _dropAnimating = NO;
        _dragSourceVis = -1;
        _dropInsertIndex = -1;
        _mergeHoverVis = -1;
        _gapAnimFromDest = -1;
        _gapAnimStart = 0;
        _edgeFlipSide = 0;
        _edgeEnterTime = 0;
        _dragIconBaseSize = NSZeroSize;
        _folderCompositeCache = [NSMutableDictionary dictionary];
        _folderCompositeLRU = [NSMutableArray array];
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

- (void)clearFolderCompositeCache {
    [_folderCompositeCache removeAllObjects];
    [_folderCompositeLRU removeAllObjects];
}

- (void)setLayout:(const MLLayout *)layout {
    if (_layout == layout) {
        return;
    }
    _layout = layout;
    [self clearFolderCompositeCache];
}

- (void)reloadData {
    size_t total = [self visibleItemCount];
    if (self.selectedVisibleIndex >= (NSInteger)total) {
        self.selectedVisibleIndex = total > 0 ? (NSInteger)total - 1 : -1;
    }
    [self clearFolderCompositeCache];
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
    MLCellFrame cell;
    if (![self cellFrameForVisibleIndex:vis out:&cell]) {
        return NSZeroRect;
    }
    return NSMakeRect(cell.icon_x, cell.icon_y, cell.icon_s, cell.icon_s);
}

- (BOOL)cellFrameForVisibleIndex:(NSInteger)vis out:(MLCellFrame *)out {
    if (!out || vis < 0) {
        return NO;
    }
    int cap = [self pageCapacity];
    if (cap <= 0) {
        return NO;
    }
    size_t start = (size_t)self.currentPage * (size_t)cap;
    if ((size_t)vis < start || (size_t)vis >= start + (size_t)cap) {
        return NO;
    }
    int slot = (int)((size_t)vis - start);
    ml_grid_cell_frame(&self->_gridConfig,
                       (float)NSWidth(self.bounds),
                       (float)NSHeight(self.bounds),
                       slot,
                       out);
    return YES;
}

/** Where `vis` would sit after moving `src` → `dest`. Returns -1 for the drag source. */
- (NSInteger)shiftedVisibleIndex:(NSInteger)vis source:(NSInteger)src dest:(NSInteger)dest {
    if (vis == src) {
        return -1;
    }
    if (src < 0 || dest < 0 || src == dest) {
        return vis;
    }
    if (src < dest) {
        if (vis > src && vis <= dest) {
            return vis - 1;
        }
    } else if (dest < src) {
        if (vis >= dest && vis < src) {
            return vis + 1;
        }
    }
    return vis;
}

- (BOOL)reorderGapActive {
    return _dragActive && _dropInsertIndex >= 0 && _mergeHoverVis < 0 && _dragSourceVis >= 0;
}

- (CGFloat)gapAnimProgress {
    if (_gapAnimStart <= 0) {
        return 1.0;
    }
    const NSTimeInterval dur = 0.14;
    CGFloat t = (CGFloat)((CACurrentMediaTime() - _gapAnimStart) / dur);
    if (t >= 1.0) {
        return 1.0;
    }
    if (t <= 0.0) {
        return 0.0;
    }
    /* ease-out */
    return 1.0 - (1.0 - t) * (1.0 - t);
}

- (void)gapAnimTick {
    [self setNeedsDisplay:YES];
    if ([self gapAnimProgress] < 1.0) {
        [self performSelector:@selector(gapAnimTick) withObject:nil afterDelay:1.0 / 60.0];
    }
}

- (void)setDropInsertIndexAnimated:(NSInteger)dest {
    if (dest == _dropInsertIndex) {
        return;
    }
    if (_dropInsertIndex >= 0) {
        _gapAnimFromDest = _dropInsertIndex;
    } else if (_dragSourceVis >= 0) {
        _gapAnimFromDest = _dragSourceVis;
    } else {
        _gapAnimFromDest = dest;
    }
    _dropInsertIndex = dest;
    _gapAnimStart = CACurrentMediaTime();
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(gapAnimTick) object:nil];
    [self setNeedsDisplay:YES];
    [self performSelector:@selector(gapAnimTick) withObject:nil afterDelay:1.0 / 60.0];
}

- (MLCellFrame)lerpedCellFrom:(const MLCellFrame *)a to:(const MLCellFrame *)b progress:(CGFloat)p {
    MLCellFrame c = *a;
    if (!a || !b) {
        return c;
    }
    if (p <= 0) {
        return *a;
    }
    if (p >= 1) {
        return *b;
    }
    c.x = a->x + (b->x - a->x) * p;
    c.y = a->y + (b->y - a->y) * p;
    c.w = a->w + (b->w - a->w) * p;
    c.h = a->h + (b->h - a->h) * p;
    c.icon_x = a->icon_x + (b->icon_x - a->icon_x) * p;
    c.icon_y = a->icon_y + (b->icon_y - a->icon_y) * p;
    c.icon_s = a->icon_s + (b->icon_s - a->icon_s) * p;
    c.label_y = a->label_y + (b->label_y - a->label_y) * p;
    return c;
}

- (BOOL)drawCellForVisibleIndex:(NSInteger)vis out:(MLCellFrame *)out {
    if (!out) {
        return NO;
    }
    if (![self reorderGapActive]) {
        return [self cellFrameForVisibleIndex:vis out:out];
    }
    NSInteger src = _dragSourceVis;
    NSInteger toDest = _dropInsertIndex;
    NSInteger fromDest = _gapAnimFromDest >= 0 ? _gapAnimFromDest : src;
    NSInteger fromVis = [self shiftedVisibleIndex:vis source:src dest:fromDest];
    NSInteger toVis = [self shiftedVisibleIndex:vis source:src dest:toDest];
    if (toVis < 0) {
        return NO;
    }
    MLCellFrame toCell;
    if (![self cellFrameForVisibleIndex:toVis out:&toCell]) {
        return NO;
    }
    CGFloat p = [self gapAnimProgress];
    if (p >= 1.0 || fromVis < 0) {
        *out = toCell;
        return YES;
    }
    MLCellFrame fromCell;
    if (![self cellFrameForVisibleIndex:fromVis out:&fromCell]) {
        *out = toCell;
        return YES;
    }
    *out = [self lerpedCellFrom:&fromCell to:&toCell progress:p];
    return YES;
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

    NSString *fid = folder->id ? [NSString stringWithUTF8String:folder->id] : nil;
    NSString *cacheKey = nil;
    if (fid.length > 0) {
        cacheKey = [NSString stringWithFormat:@"%@|%.0fx%.0f", fid, size.width, size.height];
        NSImage *hit = _folderCompositeCache[cacheKey];
        if (hit) {
            [_folderCompositeLRU removeObject:cacheKey];
            [_folderCompositeLRU addObject:cacheKey];
            return hit;
        }
    }

    NSImage *img = [[NSImage alloc] initWithSize:size];
    [img lockFocus];

    NSRect plate = NSMakeRect(0, 0, size.width, size.height);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:plate xRadius:size.width * 0.22 yRadius:size.height * 0.22];
    [[[NSColor whiteColor] colorWithAlphaComponent:0.12] setFill];
    [path fill];

    CGFloat pad = size.width * 0.12;
    CGFloat gap = size.width * 0.06;
    CGFloat cell = (size.width - pad * 2.0 - gap) * 0.5;
    size_t n = folder->count < 4 ? folder->count : 4;
    BOOL complete = YES;
    for (size_t i = 0; i < n; i++) {
        const char *cpath = folder->items[i].path;
        if (!cpath) {
            continue;
        }
        NSString *pathStr = [NSString stringWithUTF8String:cpath];
        NSImage *icon = [self.iconCache cachedIconForPath:pathStr];
        if (!icon) {
            complete = NO;
            [self requestIconForPath:pathStr];
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

    /* Only cache complete composites so missing icons can still appear after load. */
    if (complete && cacheKey.length > 0 && img) {
        _folderCompositeCache[cacheKey] = img;
        [_folderCompositeLRU removeObject:cacheKey];
        [_folderCompositeLRU addObject:cacheKey];
        while (_folderCompositeLRU.count > (NSUInteger)MLFolderCompositeMaxEntries) {
            NSString *oldest = _folderCompositeLRU.firstObject;
            [_folderCompositeLRU removeObjectAtIndex:0];
            if (oldest) {
                [_folderCompositeCache removeObjectForKey:oldest];
            }
        }
    }
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
            if (!cached) {
                [self requestIconForPath:path];
            }
            return cached;
        }
        return nil;
    }
    NSString *path = [self appPathAtVisible:(size_t)vis];
    if (!path.length) {
        return nil;
    }
    NSImage *cached = [self.iconCache cachedIconForPath:path];
    if (!cached) {
        [self requestIconForPath:path];
    }
    return cached;
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
    /* P1: current page only — neighbor pages load on flip (lower Active peak). */
    [self prefetchIconsForPage:self.currentPage];
}

#pragma mark - Drawing

- (void)drawSelectionHaloInIconRect:(NSRect)iconRect {
    /* Same corner language as folder plates: radius = side * 0.22, proportional pad. */
    CGFloat pad = NSWidth(iconRect) * 0.08;
    NSRect halo = NSInsetRect(iconRect, -pad, -pad);
    [self drawFolderPlateInRect:halo fillAlpha:0.16 showStroke:YES softGlow:NO];
}

/** Single-surface folder plate: proportional corners, at most one stroke, optional soft glow (fill only). */
- (void)drawFolderPlateInRect:(NSRect)plateRect
                    fillAlpha:(CGFloat)fillAlpha
                   showStroke:(BOOL)showStroke
                     softGlow:(BOOL)softGlow {
    CGFloat radius = NSWidth(plateRect) * 0.22;
    if (softGlow) {
        CGFloat glowPad = NSWidth(plateRect) * 0.08;
        NSRect glowRect = NSInsetRect(plateRect, -glowPad, -glowPad);
        CGFloat glowRadius = NSWidth(glowRect) * 0.22;
        NSBezierPath *glow = [NSBezierPath bezierPathWithRoundedRect:glowRect
                                                             xRadius:glowRadius
                                                             yRadius:glowRadius];
        [[[NSColor whiteColor] colorWithAlphaComponent:0.10] setFill];
        [glow fill];
    }
    NSBezierPath *plate = [NSBezierPath bezierPathWithRoundedRect:plateRect xRadius:radius yRadius:radius];
    [[[NSColor whiteColor] colorWithAlphaComponent:fillAlpha] setFill];
    [plate fill];
    if (showStroke) {
        NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(plateRect, 0.5, 0.5)
                                                              xRadius:radius
                                                              yRadius:radius];
        border.lineWidth = 1.5;
        [[[NSColor whiteColor] colorWithAlphaComponent:0.55] setStroke];
        [border stroke];
    }
}

- (void)drawFolderAtVisible:(size_t)vis
                       cell:(const MLCellFrame *)cell
               isDragSource:(BOOL)isDragSource
               isMergeHover:(BOOL)isMergeHover {
    const MLLayoutNode *node = [self nodeAtVisible:vis];
    if (!node || node->kind != ML_LAYOUT_FOLDER || !node->u.folder) {
        return;
    }
    const MLLayoutFolder *folder = node->u.folder;
    NSRect iconRect = NSMakeRect(cell->icon_x, cell->icon_y, cell->icon_s, cell->icon_s);
    BOOL hover = isMergeHover && !isDragSource;

    if (!hover && (NSInteger)vis == self.selectedVisibleIndex && !isDragSource) {
        [self drawSelectionHaloInIconRect:iconRect];
    }

    CGFloat scale = hover ? 1.10 : 1.0;
    CGFloat grow = cell->icon_s * (scale - 1.0) * 0.5;
    NSRect plateRect = NSInsetRect(iconRect, -grow, -grow);
    CGFloat plateAlpha = isDragSource ? 0.05 : (hover ? 0.24 : 0.12);
    [self drawFolderPlateInRect:plateRect
                      fillAlpha:plateAlpha
                     showStroke:hover
                       softGlow:hover];

    if (!isDragSource) {
        CGFloat padScale = hover ? 0.11f : 0.12f;
        CGFloat pad = NSWidth(plateRect) * padScale;
        CGFloat gap = NSWidth(plateRect) * (hover ? 0.05f : 0.06f);
        CGFloat mini = (NSWidth(plateRect) - pad * 2.f - gap) * 0.5f;
        CGFloat originX = NSMinX(plateRect);
        CGFloat originY = NSMinY(plateRect);
        size_t n = folder->count < 4 ? folder->count : 4;
        for (size_t i = 0; i < n; i++) {
            const char *cpath = folder->items[i].path;
            if (!cpath) {
                continue;
            }
            NSString *path = [NSString stringWithUTF8String:cpath];
            NSImage *icon = [self.iconCache cachedIconForPath:path];
            if (!icon) {
                [self requestIconForPath:path];
                continue;
            }
            int col = (int)(i % 2);
            int row = (int)(i / 2);
            NSRect miniRect = NSMakeRect(originX + pad + col * (mini + gap),
                                         originY + pad + row * (mini + gap),
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
        NSFont *labelFont = [NSFont systemFontOfSize:11
                                              weight:hover ? NSFontWeightSemibold : NSFontWeightRegular];
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
            isDragSource:(BOOL)isDragSource
            isMergeHover:(BOOL)isMergeHover {
    NSRect iconRect = NSMakeRect(cell->icon_x, cell->icon_y, cell->icon_s, cell->icon_s);
    BOOL hover = isMergeHover && !isDragSource;

    if (hover) {
        /* Same container language as folders: one plate, icon sits inside. */
        [self drawFolderPlateInRect:iconRect
                          fillAlpha:0.20
                         showStroke:YES
                           softGlow:YES];
    } else if ((NSInteger)vis == self.selectedVisibleIndex && !isDragSource) {
        [self drawSelectionHaloInIconRect:iconRect];
    }

    NSImage *icon = path.length ? [self.iconCache cachedIconForPath:path] : nil;
    if (icon) {
        if (hover) {
            CGFloat inset = NSWidth(iconRect) * (1.0 - 0.86) * 0.5;
            NSRect inner = NSInsetRect(iconRect, inset, inset);
            [icon drawInRect:inner
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0
              respectFlipped:YES
                       hints:nil];
        } else {
            [icon drawInRect:iconRect
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:isDragSource ? 0.25 : 1.0
              respectFlipped:YES
                       hints:nil];
        }
    } else if (!isDragSource) {
        if (!hover) {
            [[[NSColor whiteColor] colorWithAlphaComponent:0.15] setFill];
            NSRectFill(iconRect);
        }
        [self requestIconForPath:path];
    }

    NSString *label = hover ? @"新建文件夹" : name;
    if (label.length && !isDragSource) {
        NSFont *labelFont = [NSFont systemFontOfSize:11
                                              weight:hover ? NSFontWeightSemibold : NSFontWeightRegular];
        NSDictionary *labelAttrs = @{
            NSForegroundColorAttributeName : [NSColor whiteColor],
            NSFontAttributeName : labelFont
        };
        NSSize textSize = [label sizeWithAttributes:labelAttrs];
        CGFloat maxW = cell->w - 4.f;
        NSString *drawName = label;
        if (textSize.width > maxW) {
            drawName = [self truncatedString:label maxWidth:maxW attributes:labelAttrs];
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
    BOOL gapActive = [self reorderGapActive];

    /* Placeholder for the open slot (under icons). */
    if (gapActive) {
        NSInteger dest = _dropInsertIndex;
        NSInteger fromDest = _gapAnimFromDest >= 0 ? _gapAnimFromDest : _dragSourceVis;
        CGFloat p = [self gapAnimProgress];
        MLCellFrame fromCell, toCell;
        BOOL haveTo = [self cellFrameForVisibleIndex:dest out:&toCell];
        BOOL haveFrom = [self cellFrameForVisibleIndex:fromDest out:&fromCell];
        if (haveTo) {
            MLCellFrame hole = toCell;
            if (haveFrom && p < 1.0) {
                hole = [self lerpedCellFrom:&fromCell to:&toCell progress:p];
            }
            NSRect plate = NSMakeRect(hole.icon_x, hole.icon_y, hole.icon_s, hole.icon_s);
            [self drawFolderPlateInRect:plate fillAlpha:0.14 showStroke:NO softGlow:YES];
        }
    }

    for (int slot = 0; slot < cap; slot++) {
        size_t vis = start + (size_t)slot;
        if (vis >= total) {
            break;
        }

        /* Source leaves a hole; only the drag ghost shows it. */
        if (gapActive && (NSInteger)vis == _dragSourceVis) {
            continue;
        }

        MLCellFrame cell;
        if (gapActive) {
            if (![self drawCellForVisibleIndex:(NSInteger)vis out:&cell]) {
                continue;
            }
        } else {
            ml_grid_cell_frame(&self->_gridConfig, vw, vh, slot, &cell);
        }

        BOOL isDragSource = _dragActive && (NSInteger)vis == _dragSourceVis;
        BOOL isMergeHover = _dragActive && (NSInteger)vis == _mergeHoverVis;

        if ([self isFolderAtVisibleIndex:(NSInteger)vis]) {
            [self drawFolderAtVisible:vis cell:&cell isDragSource:isDragSource isMergeHover:isMergeHover];
            continue;
        }

        NSString *path = [self appPathAtVisible:vis];
        if (!path.length) {
            continue;
        }
        NSString *name = [self displayNameForAppPath:path];
        [self drawAppAtVisible:vis path:path name:name cell:&cell isDragSource:isDragSource isMergeHover:isMergeHover];
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
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(gapAnimTick) object:nil];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(edgeFlipTick) object:nil];
    [_dragImageView removeFromSuperview];
    _dragImageView = nil;
    _dragActive = NO;
    _dragTracking = NO;
    _dropAnimating = NO;
    _dragSourceVis = -1;
    _dropInsertIndex = -1;
    _mergeHoverVis = -1;
    _gapAnimFromDest = -1;
    _gapAnimStart = 0;
    _edgeFlipSide = 0;
    _edgeEnterTime = 0;
    _dragIconBaseSize = NSZeroSize;
    [self setNeedsDisplay:YES];
}

- (void)cancelActiveDrag {
    [self endDragVisuals];
}

- (CGFloat)edgePageFlipBandWidth {
    CGFloat w = NSWidth(self.bounds);
    return MAX(48.0, MIN(56.0, w * 0.06));
}

/** -1 left edge, +1 right edge, 0 none. Respects first/last page. */
- (NSInteger)edgeFlipSideAtPoint:(NSPoint)p {
    if (!_dragActive || [self pageCount] <= 1) {
        return 0;
    }
    if (!NSMouseInRect(p, self.bounds, self.isFlipped)) {
        return 0;
    }
    CGFloat band = [self edgePageFlipBandWidth];
    NSInteger pages = [self pageCount];
    if (p.x <= band && self.currentPage > 0) {
        return -1;
    }
    if (p.x >= NSWidth(self.bounds) - band && self.currentPage < pages - 1) {
        return 1;
    }
    return 0;
}

- (void)clearEdgePageFlip {
    _edgeFlipSide = 0;
    _edgeEnterTime = 0;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(edgeFlipTick) object:nil];
}

- (void)scheduleEdgeFlipAfterDelay:(NSTimeInterval)delay {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(edgeFlipTick) object:nil];
    if (delay <= 0) {
        [self edgeFlipTick];
        return;
    }
    [self performSelector:@selector(edgeFlipTick) withObject:nil afterDelay:delay];
}

- (void)updateEdgePageFlipAtPoint:(NSPoint)p {
    NSInteger side = [self edgeFlipSideAtPoint:p];
    if (side == 0) {
        [self clearEdgePageFlip];
        return;
    }
    if (side != _edgeFlipSide) {
        _edgeFlipSide = side;
        _edgeEnterTime = CACurrentMediaTime();
        [self scheduleEdgeFlipAfterDelay:0.45];
    }
}

- (void)edgeFlipTick {
    if (!_dragActive || _edgeFlipSide == 0 || !self.window) {
        [self clearEdgePageFlip];
        return;
    }
    NSPoint win = [self.window mouseLocationOutsideOfEventStream];
    NSPoint p = [self convertPoint:win fromView:nil];
    if ([self edgeFlipSideAtPoint:p] != _edgeFlipSide) {
        [self clearEdgePageFlip];
        return;
    }

    NSInteger before = self.currentPage;
    [self nudgePage:_edgeFlipSide];
    if (self.currentPage == before) {
        [self clearEdgePageFlip];
        return;
    }

    /* Keep drag ghost; suppress merge in edge band; refresh insert on new page. */
    _mergeHoverVis = -1;
    _lastPageFlipAt = [NSDate timeIntervalSinceReferenceDate];
    NSInteger dest = [self destinationIndexForDropAtPoint:p];
    if (dest >= 0) {
        [self setDropInsertIndexAnimated:dest];
    } else {
        /* Empty-ish page: park at end of visible range on this page. */
        int cap = [self pageCapacity];
        size_t start = (size_t)self.currentPage * (size_t)cap;
        size_t total = [self visibleItemCount];
        NSInteger fallback = (NSInteger)MIN(total > 0 ? total - 1 : 0, start + (size_t)MAX(cap - 1, 0));
        if (_dragSourceVis >= 0 && fallback == _dragSourceVis && total > 0) {
            fallback = (NSInteger)total - 1;
        }
        [self setDropInsertIndexAnimated:fallback];
    }
    [self updateDragImageAtPoint:p];
    [self setNeedsDisplay:YES];

    /* Continuous flip while still dwelling in the band. */
    _edgeEnterTime = CACurrentMediaTime();
    [self scheduleEdgeFlipAfterDelay:0.50];
}

- (CGFloat)dragGhostScaleForMergeHover {
    if (_mergeHoverVis < 0) {
        return 1.0;
    }
    if ([self isFolderAtVisibleIndex:_mergeHoverVis]) {
        return 0.72;
    }
    return 0.82;
}

- (CGFloat)dragGhostAlphaForMergeHover {
    if (_mergeHoverVis < 0) {
        return 0.92;
    }
    if ([self isFolderAtVisibleIndex:_mergeHoverVis]) {
        return 0.78;
    }
    return 0.85;
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
                    [self requestIconForPath:path];
                }
            }
        }
    } else {
        icon = [self iconImageForVisibleIndex:_dragSourceVis];
        if (!icon) {
            NSString *path = [self appPathAtVisible:(size_t)_dragSourceVis];
            if (path.length) {
                [self requestIconForPath:path];
                icon = [self.iconCache cachedIconForPath:path];
            }
        }
    }
    if (!icon) {
        return;
    }

    NSView *content = self.window.contentView;
    NSRect startRect = [self convertRect:iconRect toView:content];
    _dragIconBaseSize = iconRect.size;
    _dragOffset = NSMakePoint(p.x - iconRect.origin.x, p.y - iconRect.origin.y);
    _mergeHoverVis = -1;

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
    /* Open a hole under the source immediately. */
    _dropInsertIndex = _dragSourceVis;
    _gapAnimFromDest = _dragSourceVis;
    _gapAnimStart = 0;
    [self setNeedsDisplay:YES];
}

- (void)updateDragImageAtPoint:(NSPoint)p {
    if (!_dragImageView || _dragIconBaseSize.width <= 0) {
        return;
    }
    NSView *content = self.window.contentView;
    CGFloat scale = [self dragGhostScaleForMergeHover];
    NSSize size = NSMakeSize(_dragIconBaseSize.width * scale, _dragIconBaseSize.height * scale);
    NSPoint baseOrigin = NSMakePoint(p.x - _dragOffset.x, p.y - _dragOffset.y);
    NSPoint center = NSMakePoint(baseOrigin.x + _dragIconBaseSize.width * 0.5,
                                 baseOrigin.y + _dragIconBaseSize.height * 0.5);
    NSRect iconLocal = NSMakeRect(center.x - size.width * 0.5,
                                  center.y - size.height * 0.5,
                                  size.width,
                                  size.height);
    NSRect inContentRect = [self convertRect:iconLocal toView:content];
    _dragImageView.frame = inContentRect;
    _dragImageView.alphaValue = [self dragGhostAlphaForMergeHover];
}

- (void)setMergeHoverVis:(NSInteger)vis {
    if (_mergeHoverVis == vis) {
        return;
    }
    _mergeHoverVis = vis;
    /* Entering merge clears gap; leaving merge restores insert from last drag point via mouseDragged. */
    if (vis >= 0 && _dropInsertIndex >= 0) {
        _gapAnimFromDest = _dropInsertIndex;
        _dropInsertIndex = -1;
        _gapAnimStart = 0;
    }
    [self setNeedsDisplay:YES];
}

/* Center 50% of icon rect — merge / add-to-folder hotzone. Folders as source never merge. */
- (NSInteger)mergeTargetAtPoint:(NSPoint)p {
    if (_dragSourceVis < 0 || [self isFolderAtVisibleIndex:_dragSourceVis]) {
        return -1;
    }
    /* Merge / add only on root layout browse. */
    if (!self.layout) {
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

- (void)animateSuckIntoVisible:(NSInteger)target completion:(void (^)(void))completion {
    if (!_dragImageView) {
        if (completion) {
            completion();
        }
        return;
    }
    NSRect targetIcon = [self iconRectForVisibleIndex:target];
    NSView *content = self.window.contentView;
    if (NSIsEmptyRect(targetIcon) || !content) {
        [self endDragVisuals];
        if (completion) {
            completion();
        }
        return;
    }
    NSRect dest = [self convertRect:targetIcon toView:content];
    CGFloat inset = MIN(NSWidth(dest), NSHeight(dest)) * 0.38;
    NSRect endRect = NSInsetRect(dest, inset, inset);
    _dropAnimating = YES;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.20;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        self->_dragImageView.animator.frame = endRect;
        self->_dragImageView.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self endDragVisuals];
        if (completion) {
            completion();
        }
    }];
}

- (void)pulseVisibleIndex:(NSInteger)vis {
    NSRect iconRect = [self iconRectForVisibleIndex:vis];
    if (NSIsEmptyRect(iconRect)) {
        return;
    }
    NSView *content = self.window.contentView;
    if (!content) {
        return;
    }
    /* Prefer overlay animation host — avoids contentView.wantsLayer which can
     * glitch NSVisualEffectView + field-editor chrome (ghost panel under search). */
    NSView *host = nil;
    for (NSView *sub in content.subviews) {
        if ([sub.identifier isEqualToString:@"ml.animationHost"]) {
            host = sub;
            break;
        }
    }
    if (!host) {
        host = content;
    }
    host.wantsLayer = YES;
    if (!host.layer) {
        return;
    }
    NSRect dest = [self convertRect:iconRect toView:host];
    /* contentView is typically non-flipped; convertRect already maps correctly. */
    CALayer *pulse = [CALayer layer];
    pulse.frame = NSRectToCGRect(dest);
    pulse.cornerRadius = NSWidth(dest) * 0.22;
    pulse.backgroundColor = [[NSColor whiteColor] colorWithAlphaComponent:0.32].CGColor;
    pulse.borderWidth = 2.0;
    pulse.borderColor = [[NSColor whiteColor] colorWithAlphaComponent:0.75].CGColor;
    pulse.opacity = 0.0;
    [host.layer addSublayer:pulse];

    CABasicAnimation *fadeIn = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fadeIn.fromValue = @0.0;
    fadeIn.toValue = @1.0;
    fadeIn.duration = 0.08;

    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @0.94;
    scale.toValue = @1.08;
    scale.duration = 0.28;
    scale.autoreverses = YES;
    scale.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];

    CABasicAnimation *fadeOut = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fadeOut.fromValue = @1.0;
    fadeOut.toValue = @0.0;
    fadeOut.beginTime = 0.14;
    fadeOut.duration = 0.22;
    fadeOut.fillMode = kCAFillModeForwards;

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[ fadeIn, scale, fadeOut ];
    group.duration = 0.36;
    group.fillMode = kCAFillModeForwards;
    group.removedOnCompletion = NO;

    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [pulse removeFromSuperlayer];
    }];
    [pulse addAnimation:group forKey:@"ml.cellPulse"];
    [CATransaction commit];
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
    if (_dropAnimating) {
        return;
    }
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
    _mergeHoverVis = -1;
    [self clearEdgePageFlip];
}

- (void)mouseDragged:(NSEvent *)event {
    if (_dropAnimating || !_dragTracking || _dragSourceVis < 0) {
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

    [self updateEdgePageFlipAtPoint:p];
    BOOL inEdgeBand = (_edgeFlipSide != 0);

    /* Edge band: page-flip only — no merge hotzone. */
    NSInteger hover = inEdgeBand ? -1 : [self mergeTargetAtPoint:p];
    [self setMergeHoverVis:hover];
    if (_mergeHoverVis >= 0) {
        if (_dropInsertIndex >= 0) {
            _dropInsertIndex = -1;
            [self setNeedsDisplay:YES];
        }
    } else if (!inEdgeBand) {
        [self setDropInsertIndexAnimated:[self destinationIndexForDropAtPoint:p]];
    }
    [self updateDragImageAtPoint:p];
}

- (void)mouseUp:(NSEvent *)event {
    if (_dropAnimating) {
        return;
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];

    if (_dragActive) {
        NSInteger src = _dragSourceVis;

        /* Folder: drop outside grid → extract to root */
        BOOL extract = NO;
        if (self.allowsExtractOnDragOutside && src >= 0) {
            if (!NSMouseInRect(p, self.bounds, self.isFlipped)) {
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

        /* Merge only on root layout browse (not inside folder). */
        if (self.layout && src >= 0 && mergeTarget >= 0 && ![self isFolderAtVisibleIndex:src]) {
            BOOL addToFolder = [self isFolderAtVisibleIndex:mergeTarget];
            BOOL canAdd = addToFolder &&
                [self.delegate respondsToSelector:@selector(gridView:didAddItem:toFolderAt:)];
            BOOL canMerge = !addToFolder &&
                [self.delegate respondsToSelector:@selector(gridView:didMergeItem:ontoItem:)];
            if (canAdd || canMerge) {
                __weak typeof(self) weakSelf = self;
                [self animateSuckIntoVisible:mergeTarget completion:^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (!self) {
                        return;
                    }
                    if (addToFolder) {
                        [self.delegate gridView:self didAddItem:src toFolderAt:mergeTarget];
                    } else {
                        [self.delegate gridView:self didMergeItem:src ontoItem:mergeTarget];
                    }
                    self.selectedVisibleIndex = mergeTarget;
                }];
                return;
            }
        }

        [self endDragVisuals];

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
