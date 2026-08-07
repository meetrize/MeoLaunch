#import "MLTaskbarView.h"

#import "MLStrings.h"
#import "MLIconCache.h"

#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>

@implementation MLTaskbarItem
@end

@implementation MLTaskbarMenuFlags
@end

@interface MLTaskbarView ()
@property (nonatomic, assign) NSInteger menuIndex;
@property (nonatomic, assign) BOOL dragTracking;
@property (nonatomic, assign, readwrite) BOOL dragActive;
@property (nonatomic, assign) NSInteger dragSourceIndex;
@property (nonatomic, assign) NSPoint dragStartPoint;
@property (nonatomic, assign) NSPoint dragOffsetInCell;
@property (nonatomic, assign) NSInteger dropInsertIndex;
@property (nonatomic, assign) NSInteger gapAnimFromDest;
@property (nonatomic, assign) NSTimeInterval gapAnimStart;
@property (nonatomic, assign) MLTaskbarChipZone localDragZone;
@property (nonatomic, assign) BOOL externalPreviewActive;
@property (nonatomic, assign) MLTaskbarChipZone externalPreviewZone;
@property (nonatomic, assign) NSInteger externalInsertIndex;
@property (nonatomic, assign) CGFloat externalPlaceholderWidth;
@property (nonatomic, strong) NSWindow *ghostWindow;
@property (nonatomic, strong) NSImageView *ghostImageView;
@end

@implementation MLTaskbarView

/*
 * Light "mist" taskbar palette
 *   bar fill:     #E8ECF2 @ 0.94
 *   chip idle:    #FFFFFF @ 0.96 + stroke #C9D0DB
 *   chip min:     #F1F3F7 + stroke #D3D8E2
 *   chip active:  #D8E6FA + stroke #4F7FE8
 *   pinned only:  bare full-color icon (no chip / no title), left-packed
 *   title:        #1F2937 / active #14305C
 */

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _iconSize = 32.0;
        _spacing = 2.0;
        _barHeight = 40.0;
        _itemMaxWidth = 160.0;
        _itemMinWidth = 72.0;
        _items = @[];
        _menuIndex = -1;
        _dragSourceIndex = -1;
        _dropInsertIndex = -1;
        _gapAnimFromDest = -1;
        _localDragZone = MLTaskbarChipZoneNone;
        _externalPreviewZone = MLTaskbarChipZoneNone;
        _externalInsertIndex = -1;
        self.wantsLayer = YES;
    }
    return self;
}

- (void)dealloc {
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self destroyGhostWindow];
}

- (BOOL)isFlipped {
    return YES;
}

- (void)setItems:(NSArray<MLTaskbarItem *> *)items {
    _items = [items copy] ?: @[];
    [self setNeedsDisplay:YES];
    for (MLTaskbarItem *item in _items) {
        if (item.path.length == 0) {
            continue;
        }
        if ([self.iconCache cachedIconForPath:item.path]) {
            continue;
        }
        __weak typeof(self) weakSelf = self;
        NSString *path = item.path;
        [self.iconCache loadIconForPath:path
                               onLoaded:^(NSString *loadedPath, NSImage *image) {
                                   (void)image;
                                   __strong typeof(weakSelf) self = weakSelf;
                                   if (!self) {
                                       return;
                                   }
                                   for (MLTaskbarItem *it in self.items) {
                                       if ([it.path isEqualToString:loadedPath]) {
                                           [self setNeedsDisplay:YES];
                                           break;
                                       }
                                   }
                               }];
    }
}

- (CGFloat)edgeInset {
    return 3.0;
}

/** Bare icon slot for pinned-not-running launchers. */
- (CGFloat)pinnedSlotWidth {
    return self.iconSize + 4.0;
}

- (BOOL)isPinnedIconOnly:(MLTaskbarItem *)item {
    return item && item.kind == MLTaskbarItemPinnedOnly;
}

- (NSInteger)pinZoneCount {
    NSInteger n = 0;
    for (MLTaskbarItem *item in self.items) {
        if (![self isPinnedIconOnly:item]) {
            break;
        }
        n++;
    }
    return n;
}

- (MLTaskbarChipZone)zoneForIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.items.count) {
        return MLTaskbarChipZoneNone;
    }
    if ([self isPinnedIconOnly:self.items[(NSUInteger)index]]) {
        return MLTaskbarChipZonePin;
    }
    return MLTaskbarChipZoneWindow;
}

- (NSInteger)zoneStartIndex:(MLTaskbarChipZone)zone {
    if (zone == MLTaskbarChipZonePin) {
        return 0;
    }
    if (zone == MLTaskbarChipZoneWindow) {
        return [self pinZoneCount];
    }
    return 0;
}

- (NSInteger)zoneCount:(MLTaskbarChipZone)zone {
    NSInteger pins = [self pinZoneCount];
    if (zone == MLTaskbarChipZonePin) {
        return pins;
    }
    if (zone == MLTaskbarChipZoneWindow) {
        return (NSInteger)self.items.count - pins;
    }
    return 0;
}

- (CGFloat)windowChipWidth {
    NSUInteger pinnedN = 0;
    NSUInteger windowN = 0;
    for (MLTaskbarItem *item in self.items) {
        if ([self isPinnedIconOnly:item]) {
            pinnedN++;
        } else {
            windowN++;
        }
    }
    if (windowN == 0) {
        return self.itemMaxWidth;
    }
    CGFloat inset = [self edgeInset];
    CGFloat avail = NSWidth(self.bounds) - inset * 2.0;
    CGFloat spacing = self.spacing;
    CGFloat pinnedW = [self pinnedSlotWidth];
    CGFloat pinnedSpan = pinnedN * pinnedW + (pinnedN > 0 ? (pinnedN - 1) * spacing : 0);
    if (pinnedN > 0 && windowN > 0) {
        pinnedSpan += spacing;
    }
    CGFloat remain = avail - pinnedSpan;
    if (remain < 0) {
        remain = 0;
    }
    CGFloat maxW = self.itemMaxWidth;
    CGFloat minW = self.itemMinWidth;
    CGFloat need = windowN * maxW + (windowN > 1 ? (windowN - 1) * spacing : 0);
    if (need <= remain) {
        return maxW;
    }
    CGFloat w = (remain - (windowN > 1 ? (windowN - 1) * spacing : 0)) / (CGFloat)windowN;
    if (w < minW) {
        w = minW;
    }
    if (w > maxW) {
        w = maxW;
    }
    return w;
}

- (CGFloat)widthForItem:(MLTaskbarItem *)item chipWidth:(CGFloat)chipW {
    if ([self isPinnedIconOnly:item]) {
        return [self pinnedSlotWidth];
    }
    return chipW;
}

- (CGFloat)widthForItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.items.count) {
        return 0;
    }
    return [self widthForItem:self.items[(NSUInteger)index] chipWidth:[self windowChipWidth]];
}

- (NSRect)rectForItemAtIndex:(NSInteger)index chipWidth:(CGFloat)chipW {
    if (index < 0 || index >= (NSInteger)self.items.count) {
        return NSZeroRect;
    }
    CGFloat x = [self edgeInset];
    for (NSInteger i = 0; i < index; i++) {
        MLTaskbarItem *prev = self.items[(NSUInteger)i];
        x += [self widthForItem:prev chipWidth:chipW] + self.spacing;
    }
    CGFloat w = [self widthForItem:self.items[(NSUInteger)index] chipWidth:chipW];
    CGFloat y = (NSHeight(self.bounds) - self.barHeight) * 0.5;
    if (y < 0) {
        y = 0;
    }
    return NSMakeRect(x, y, w, self.barHeight);
}

- (NSInteger)indexAtPoint:(NSPoint)p {
    CGFloat chipW = [self windowChipWidth];
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        NSRect r = [self rectForItemAtIndex:i chipWidth:chipW];
        if (NSPointInRect(p, r)) {
            return i;
        }
    }
    return -1;
}

- (NSRect)rectForItemAtIndex:(NSInteger)index {
    return [self rectForItemAtIndex:index chipWidth:[self windowChipWidth]];
}

- (NSInteger)destinationIndexAtPoint:(NSPoint)p
                              inZone:(MLTaskbarChipZone)zone
                        sourceIndex:(NSInteger)sourceIndex {
    NSInteger start = [self zoneStartIndex:zone];
    NSInteger count = [self zoneCount:zone];
    if (count <= 0 || zone == MLTaskbarChipZoneNone) {
        return -1;
    }
    if (sourceIndex < start || sourceIndex >= start + count) {
        return -1;
    }

    CGFloat chipW = [self windowChipWidth];
    NSInteger hit = -1;
    for (NSInteger i = 0; i < count; i++) {
        NSInteger abs = start + i;
        NSRect r = [self rectForItemAtIndex:abs chipWidth:chipW];
        if (p.x < NSMaxX(r)) {
            hit = abs;
            break;
        }
    }
    NSInteger insertAt;
    if (hit < 0) {
        insertAt = start + count;
    } else {
        NSRect icon = [self rectForItemAtIndex:hit chipWidth:chipW];
        insertAt = hit;
        if (!NSIsEmptyRect(icon) && p.x > NSMidX(icon)) {
            insertAt = hit + 1;
        }
    }
    if (insertAt > start + count) {
        insertAt = start + count;
    }

    NSInteger dest = insertAt;
    if (sourceIndex < insertAt) {
        dest = insertAt - 1;
    }
    if (dest < start) {
        dest = start;
    }
    if (dest >= start + count) {
        dest = start + count - 1;
    }
    return dest;
}

- (NSInteger)externalInsertIndexAtPoint:(NSPoint)p inZone:(MLTaskbarChipZone)zone {
    NSInteger start = [self zoneStartIndex:zone];
    NSInteger count = [self zoneCount:zone];
    if (zone == MLTaskbarChipZoneNone) {
        return -1;
    }
    /* Empty zone: still allow drop at start. */
    if (count == 0) {
        CGFloat chipW = [self windowChipWidth];
        CGFloat x = [self edgeInset];
        for (NSInteger i = 0; i < start; i++) {
            x += [self widthForItem:self.items[(NSUInteger)i] chipWidth:chipW] + self.spacing;
        }
        /* Anywhere on the bar maps to the empty zone insert. */
        (void)x;
        return start;
    }

    CGFloat chipW = [self windowChipWidth];
    NSInteger hit = -1;
    for (NSInteger i = 0; i < count; i++) {
        NSInteger abs = start + i;
        NSRect r = [self rectForItemAtIndex:abs chipWidth:chipW];
        if (p.x < NSMaxX(r)) {
            hit = abs;
            break;
        }
    }
    if (hit < 0) {
        return start + count;
    }
    NSRect icon = [self rectForItemAtIndex:hit chipWidth:chipW];
    if (!NSIsEmptyRect(icon) && p.x > NSMidX(icon)) {
        return hit + 1;
    }
    return hit;
}

- (NSInteger)shiftedIndex:(NSInteger)index source:(NSInteger)src dest:(NSInteger)dest {
    if (index == src) {
        return -1;
    }
    if (src < 0 || dest < 0 || src == dest) {
        return index;
    }
    if (src < dest) {
        if (index > src && index <= dest) {
            return index - 1;
        }
    } else if (dest < src) {
        if (index >= dest && index < src) {
            return index + 1;
        }
    }
    return index;
}

- (BOOL)reorderGapActive {
    return self.dragActive && self.dropInsertIndex >= 0 && self.dragSourceIndex >= 0 &&
           !self.externalPreviewActive;
}

- (BOOL)externalGapActive {
    return self.externalPreviewActive && self.externalInsertIndex >= 0 &&
           self.externalPreviewZone != MLTaskbarChipZoneNone;
}

- (CGFloat)gapAnimProgress {
    if (self.gapAnimStart <= 0) {
        return 1.0;
    }
    const NSTimeInterval dur = 0.14;
    CGFloat t = (CGFloat)((CACurrentMediaTime() - self.gapAnimStart) / dur);
    if (t >= 1.0) {
        return 1.0;
    }
    if (t <= 0.0) {
        return 0.0;
    }
    return 1.0 - (1.0 - t) * (1.0 - t);
}

- (void)gapAnimTick {
    [self setNeedsDisplay:YES];
    if ([self gapAnimProgress] < 1.0) {
        [self performSelector:@selector(gapAnimTick) withObject:nil afterDelay:1.0 / 60.0];
    }
}

- (void)setDropInsertIndexAnimated:(NSInteger)dest {
    if (dest == self.dropInsertIndex) {
        return;
    }
    if (self.dropInsertIndex >= 0) {
        self.gapAnimFromDest = self.dropInsertIndex;
    } else if (self.dragSourceIndex >= 0) {
        self.gapAnimFromDest = self.dragSourceIndex;
    } else {
        self.gapAnimFromDest = dest;
    }
    self.dropInsertIndex = dest;
    self.gapAnimStart = CACurrentMediaTime();
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(gapAnimTick) object:nil];
    [self setNeedsDisplay:YES];
    [self performSelector:@selector(gapAnimTick) withObject:nil afterDelay:1.0 / 60.0];
}

- (void)setLocalDragPreviewSourceIndex:(NSInteger)sourceIndex insertIndex:(NSInteger)insertIndex {
    self.externalPreviewActive = NO;
    self.externalInsertIndex = -1;
    self.dragSourceIndex = sourceIndex;
    self.localDragZone = [self zoneForIndex:sourceIndex];
    [self setDropInsertIndexAnimated:insertIndex];
}

- (void)setExternalDragPreviewInZone:(MLTaskbarChipZone)zone
                         insertIndex:(NSInteger)insertIndex
                    placeholderWidth:(CGFloat)width {
    BOOL same = self.externalPreviewActive && self.externalPreviewZone == zone &&
                self.externalInsertIndex == insertIndex;
    self.externalPreviewActive = YES;
    self.externalPreviewZone = zone;
    self.externalPlaceholderWidth = MAX(width, 8.0);
    if (self.dropInsertIndex >= 0 || self.dragActive) {
        self.dropInsertIndex = -1;
        self.dragSourceIndex = -1;
    }
    if (!same) {
        if (self.externalInsertIndex >= 0) {
            self.gapAnimFromDest = self.externalInsertIndex;
        } else {
            self.gapAnimFromDest = insertIndex;
        }
        self.externalInsertIndex = insertIndex;
        self.gapAnimStart = CACurrentMediaTime();
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(gapAnimTick) object:nil];
        [self performSelector:@selector(gapAnimTick) withObject:nil afterDelay:1.0 / 60.0];
    } else {
        self.externalInsertIndex = insertIndex;
    }
    [self setNeedsDisplay:YES];
}

- (void)clearDragPreview {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(gapAnimTick) object:nil];
    self.dropInsertIndex = -1;
    self.gapAnimFromDest = -1;
    self.gapAnimStart = 0;
    self.localDragZone = MLTaskbarChipZoneNone;
    self.externalPreviewActive = NO;
    self.externalPreviewZone = MLTaskbarChipZoneNone;
    self.externalInsertIndex = -1;
    self.externalPlaceholderWidth = 0;
    [self setNeedsDisplay:YES];
}

- (NSRect)layoutRectForIndex:(NSInteger)index chipWidth:(CGFloat)chipW {
    if ([self reorderGapActive] || [self externalGapActive]) {
        return [self visualRectForModelIndex:index chipWidth:chipW];
    }
    return [self rectForItemAtIndex:index chipWidth:chipW];
}

/**
 * Pack chips left-to-right. Local drag: leave a hole at `dest` (placeholder) and
 * omit the source chip (shown by the ghost). External drag: insert placeholder width.
 */
- (NSRect)visualRectForModelIndex:(NSInteger)modelIndex chipWidth:(CGFloat)chipW {
    CGFloat y = (NSHeight(self.bounds) - self.barHeight) * 0.5;
    if (y < 0) {
        y = 0;
    }

    if ([self reorderGapActive]) {
        NSInteger src = self.dragSourceIndex;
        NSInteger dest = self.dropInsertIndex;
        if (modelIndex == src || src < 0 || dest < 0) {
            return NSZeroRect;
        }
        CGFloat holeW = [self widthForItem:self.items[(NSUInteger)src] chipWidth:chipW];
        NSMutableArray<NSNumber *> *order = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
            if (i == src) {
                continue;
            }
            [order addObject:@(i)];
        }
        [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            NSInteger va = [self shiftedIndex:a.integerValue source:src dest:dest];
            NSInteger vb = [self shiftedIndex:b.integerValue source:src dest:dest];
            if (va < vb) {
                return NSOrderedAscending;
            }
            if (va > vb) {
                return NSOrderedDescending;
            }
            return NSOrderedSame;
        }];

        CGFloat x = [self edgeInset];
        BOOL holePlaced = NO;
        for (NSNumber *num in order) {
            NSInteger mi = num.integerValue;
            NSInteger vis = [self shiftedIndex:mi source:src dest:dest];
            if (!holePlaced && vis >= dest) {
                x += holeW + self.spacing;
                holePlaced = YES;
            }
            CGFloat w = [self widthForItem:self.items[(NSUInteger)mi] chipWidth:chipW];
            if (mi == modelIndex) {
                return NSMakeRect(x, y, w, self.barHeight);
            }
            x += w + self.spacing;
        }
        return NSZeroRect;
    }

    if ([self externalGapActive]) {
        NSInteger insert = self.externalInsertIndex;
        CGFloat ph = self.externalPlaceholderWidth;
        CGFloat x = [self edgeInset];
        for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
            if (i == insert) {
                x += ph + self.spacing;
            }
            CGFloat w = [self widthForItem:self.items[(NSUInteger)i] chipWidth:chipW];
            if (i == modelIndex) {
                return NSMakeRect(x, y, w, self.barHeight);
            }
            x += w + self.spacing;
        }
        return NSZeroRect;
    }

    return [self rectForItemAtIndex:modelIndex chipWidth:chipW];
}

- (NSRect)placeholderRectChipWidth:(CGFloat)chipW {
    CGFloat y = (NSHeight(self.bounds) - self.barHeight) * 0.5;
    if (y < 0) {
        y = 0;
    }
    if ([self reorderGapActive]) {
        NSInteger src = self.dragSourceIndex;
        NSInteger dest = self.dropInsertIndex;
        if (src < 0 || dest < 0 || src >= (NSInteger)self.items.count) {
            return NSZeroRect;
        }
        CGFloat holeW = [self widthForItem:self.items[(NSUInteger)src] chipWidth:chipW];
        NSMutableArray<NSNumber *> *order = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
            if (i == src) {
                continue;
            }
            [order addObject:@(i)];
        }
        [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
            NSInteger va = [self shiftedIndex:a.integerValue source:src dest:dest];
            NSInteger vb = [self shiftedIndex:b.integerValue source:src dest:dest];
            if (va < vb) {
                return NSOrderedAscending;
            }
            if (va > vb) {
                return NSOrderedDescending;
            }
            return NSOrderedSame;
        }];

        CGFloat x = [self edgeInset];
        for (NSNumber *num in order) {
            NSInteger mi = num.integerValue;
            NSInteger vis = [self shiftedIndex:mi source:src dest:dest];
            if (vis >= dest) {
                return NSMakeRect(x, y, holeW, self.barHeight);
            }
            x += [self widthForItem:self.items[(NSUInteger)mi] chipWidth:chipW] + self.spacing;
        }
        return NSMakeRect(x, y, holeW, self.barHeight);
    }
    if ([self externalGapActive]) {
        NSInteger insert = self.externalInsertIndex;
        CGFloat ph = self.externalPlaceholderWidth;
        CGFloat x = [self edgeInset];
        for (NSInteger i = 0; i < insert && i < (NSInteger)self.items.count; i++) {
            x += [self widthForItem:self.items[(NSUInteger)i] chipWidth:chipW] + self.spacing;
        }
        return NSMakeRect(x, y, ph, self.barHeight);
    }
    return NSZeroRect;
}

- (void)drawRoundedChip:(NSRect)rect
                   fill:(NSColor *)fill
                 stroke:(NSColor *)stroke
            strokeWidth:(CGFloat)strokeWidth {
    CGFloat radius = 8.0;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
    [fill setFill];
    [path fill];
    if (stroke && strokeWidth > 0.0) {
        [stroke setStroke];
        path.lineWidth = strokeWidth;
        [path stroke];
    }
}

- (void)drawPlaceholderInRect:(NSRect)cell {
    if (NSIsEmptyRect(cell)) {
        return;
    }
    NSRect slot = NSInsetRect(cell, 1.0, 4.0);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:slot xRadius:8.0 yRadius:8.0];
    [[NSColor colorWithCalibratedRed:0.55 green:0.62 blue:0.75 alpha:0.22] setFill];
    [path fill];
    [[NSColor colorWithCalibratedRed:0.40 green:0.50 blue:0.70 alpha:0.55] setStroke];
    path.lineWidth = 1.5;
    CGFloat pattern[] = {4.0, 3.0};
    [path setLineDash:pattern count:2 phase:0];
    [path stroke];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;

    /* Light bar backdrop */
    [[NSColor colorWithCalibratedRed:0.910 green:0.925 blue:0.949 alpha:0.94] setFill];
    NSRectFill(self.bounds);

    /* Soft top hairline for separation from desktop */
    [[NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:0.55] setFill];
    NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 1.0));
    [[NSColor colorWithCalibratedRed:0.72 green:0.76 blue:0.82 alpha:0.35] setFill];
    NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 1.0, NSWidth(self.bounds), 1.0));

    CGFloat chipW = [self windowChipWidth];

    NSColor *titleIdle = [NSColor colorWithCalibratedRed:0.122 green:0.161 blue:0.216 alpha:1.0];
    NSColor *titleActive = [NSColor colorWithCalibratedRed:0.078 green:0.188 blue:0.361 alpha:1.0];

    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    ps.alignment = NSTextAlignmentLeft;

    NSDictionary *titleAttrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : titleIdle,
        NSParagraphStyleAttributeName : ps,
    };
    NSDictionary *activeTitleAttrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName : titleActive,
        NSParagraphStyleAttributeName : ps,
    };

    NSColor *chipIdleFill = [NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:0.96];
    NSColor *chipIdleStroke = [NSColor colorWithCalibratedRed:0.788 green:0.816 blue:0.859 alpha:1.0];
    NSColor *chipMinFill = [NSColor colorWithCalibratedRed:0.945 green:0.953 blue:0.969 alpha:1.0];
    NSColor *chipMinStroke = [NSColor colorWithCalibratedRed:0.827 green:0.847 blue:0.886 alpha:1.0];
    NSColor *chipActiveFill = [NSColor colorWithCalibratedRed:0.847 green:0.902 blue:0.980 alpha:1.0];
    NSColor *chipActiveStroke = [NSColor colorWithCalibratedRed:0.310 green:0.498 blue:0.910 alpha:1.0];

    if ([self reorderGapActive] || [self externalGapActive]) {
        [self drawPlaceholderInRect:[self placeholderRectChipWidth:chipW]];
    }

    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        MLTaskbarItem *item = self.items[(NSUInteger)i];
        NSRect cell = [self layoutRectForIndex:i chipWidth:chipW];
        if (NSIsEmptyRect(cell)) {
            continue;
        }

        BOOL pinnedOnly = [self isPinnedIconOnly:item];
        BOOL isActive = item.active && !pinnedOnly;
        BOOL dimmed = self.dragActive && i == self.dragSourceIndex;

        if (pinnedOnly) {
            NSRect iconRect = NSMakeRect(NSMinX(cell) + (NSWidth(cell) - self.iconSize) * 0.5,
                                         NSMinY(cell) + (NSHeight(cell) - self.iconSize) * 0.5,
                                         self.iconSize,
                                         self.iconSize);
            NSImage *icon = [self.iconCache cachedIconForPath:item.path];
            CGFloat frac = dimmed ? 0.25 : 1.0;
            if (icon) {
                [icon drawInRect:iconRect
                        fromRect:NSZeroRect
                       operation:NSCompositingOperationSourceOver
                        fraction:frac
                  respectFlipped:YES
                           hints:nil];
            } else {
                [[NSColor colorWithCalibratedRed:0.82 green:0.85 blue:0.90 alpha:frac] setFill];
                NSRectFill(iconRect);
            }
            continue;
        }

        NSRect chip = NSInsetRect(cell, 0.0, 3.0);
        if (dimmed) {
            [[NSColor colorWithCalibratedRed:0.90 green:0.92 blue:0.95 alpha:0.45] setFill];
            NSBezierPath *ph = [NSBezierPath bezierPathWithRoundedRect:chip xRadius:8.0 yRadius:8.0];
            [ph fill];
            continue;
        }
        if (isActive) {
            [self drawRoundedChip:chip
                             fill:chipActiveFill
                           stroke:chipActiveStroke
                      strokeWidth:1.5];
        } else if (item.minimized) {
            [self drawRoundedChip:chip
                             fill:chipMinFill
                           stroke:chipMinStroke
                      strokeWidth:1.0];
        } else {
            [self drawRoundedChip:chip
                             fill:chipIdleFill
                           stroke:chipIdleStroke
                      strokeWidth:1.0];
        }

        NSRect iconRect = NSMakeRect(NSMinX(chip) + 6.0,
                                     NSMinY(chip) + (NSHeight(chip) - self.iconSize) * 0.5,
                                     self.iconSize,
                                     self.iconSize);
        NSImage *icon = [self.iconCache cachedIconForPath:item.path];
        if (icon) {
            [icon drawInRect:iconRect
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:1.0
              respectFlipped:YES
                       hints:nil];
        } else {
            [[NSColor colorWithCalibratedRed:0.82 green:0.85 blue:0.90 alpha:1.0] setFill];
            NSBezierPath *ph = [NSBezierPath bezierPathWithRoundedRect:iconRect xRadius:6.0 yRadius:6.0];
            [ph fill];
        }

        NSRect titleRect = NSMakeRect(NSMaxX(iconRect) + 6.0,
                                      NSMinY(chip) + (NSHeight(chip) - 14.0) * 0.5,
                                      NSMaxX(chip) - (NSMaxX(iconRect) + 6.0) - 8.0,
                                      14.0);
        if (titleRect.size.width > 8.0 && item.title.length > 0) {
            NSDictionary *attrs = isActive ? activeTitleAttrs : titleAttrs;
            [item.title drawInRect:titleRect withAttributes:attrs];
        }
    }
}

#pragma mark - Ghost

- (NSImage *)snapshotImageForItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.items.count) {
        return nil;
    }
    NSRect cell = [self rectForItemAtIndex:index];
    if (NSIsEmptyRect(cell)) {
        return nil;
    }
    MLTaskbarItem *item = self.items[(NSUInteger)index];
    NSImage *icon = [self.iconCache cachedIconForPath:item.path];
    NSImage *img = [[NSImage alloc] initWithSize:cell.size];
    [img lockFocus];
    if ([self isPinnedIconOnly:item]) {
        NSRect iconRect = NSMakeRect((cell.size.width - self.iconSize) * 0.5,
                                     (cell.size.height - self.iconSize) * 0.5,
                                     self.iconSize,
                                     self.iconSize);
        if (icon) {
            [icon drawInRect:iconRect
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:0.92
              respectFlipped:YES
                       hints:nil];
        }
    } else {
        NSRect chip = NSMakeRect(0, 3.0, cell.size.width, cell.size.height - 6.0);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:chip xRadius:8.0 yRadius:8.0];
        [[NSColor colorWithCalibratedRed:1.0 green:1.0 blue:1.0 alpha:0.92] setFill];
        [path fill];
        NSRect iconRect = NSMakeRect(6.0, (cell.size.height - self.iconSize) * 0.5, self.iconSize, self.iconSize);
        if (icon) {
            [icon drawInRect:iconRect
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:0.92
              respectFlipped:YES
                       hints:nil];
        }
        if (item.title.length > 0) {
            NSRect titleRect = NSMakeRect(NSMaxX(iconRect) + 6.0,
                                          (cell.size.height - 14.0) * 0.5,
                                          cell.size.width - NSMaxX(iconRect) - 14.0,
                                          14.0);
            NSDictionary *attrs = @{
                NSFontAttributeName : [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium],
                NSForegroundColorAttributeName :
                    [NSColor colorWithCalibratedRed:0.122 green:0.161 blue:0.216 alpha:0.9],
            };
            [item.title drawInRect:titleRect withAttributes:attrs];
        }
    }
    [img unlockFocus];
    return img;
}

- (void)destroyGhostWindow {
    if (self.ghostWindow) {
        [self.ghostWindow orderOut:nil];
        self.ghostWindow = nil;
    }
    self.ghostImageView = nil;
}

- (void)beginGhostForIndex:(NSInteger)index atViewPoint:(NSPoint)p {
    [self destroyGhostWindow];
    NSRect cell = [self rectForItemAtIndex:index];
    NSImage *img = [self snapshotImageForItemAtIndex:index];
    if (!img || NSIsEmptyRect(cell)) {
        return;
    }
    self.dragOffsetInCell = NSMakePoint(p.x - NSMinX(cell), p.y - NSMinY(cell));

    NSRect screenCell = [self convertRect:cell toView:nil];
    screenCell = [self.window convertRectToScreen:screenCell];

    NSWindow *gw = [[NSWindow alloc] initWithContentRect:screenCell
                                               styleMask:NSWindowStyleMaskBorderless
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    gw.opaque = NO;
    gw.backgroundColor = [NSColor clearColor];
    gw.hasShadow = YES;
    gw.level = NSFloatingWindowLevel + 2;
    gw.ignoresMouseEvents = YES;
    gw.releasedWhenClosed = NO;

    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, screenCell.size.width, screenCell.size.height)];
    iv.image = img;
    iv.imageScaling = NSImageScaleAxesIndependently;
    iv.wantsLayer = YES;
    iv.alphaValue = 0.92;
    gw.contentView = iv;

    self.ghostWindow = gw;
    self.ghostImageView = iv;
    [gw orderFront:nil];
}

- (void)moveGhostToScreenPoint:(NSPoint)screenPoint {
    if (!self.ghostWindow) {
        return;
    }
    NSSize sz = self.ghostWindow.frame.size;
    /* screenPoint is cursor; offset was in flipped view coords — approximate with x only + center y */
    CGFloat x = screenPoint.x - self.dragOffsetInCell.x;
    CGFloat y = screenPoint.y - (sz.height - self.dragOffsetInCell.y);
    [self.ghostWindow setFrameOrigin:NSMakePoint(x, y)];
}

#pragma mark - Mouse

- (BOOL)allowsDragNow {
    if (self.menuIndex >= 0) {
        return NO;
    }
    if ([self.delegate respondsToSelector:@selector(taskbarViewShouldBeginDrag:)]) {
        return [self.delegate taskbarViewShouldBeginDrag:self];
    }
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    if (event.type == NSEventTypeRightMouseDown || (event.modifierFlags & NSEventModifierFlagControl)) {
        return;
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:p];
    if (idx < 0) {
        self.dragTracking = NO;
        self.dragActive = NO;
        self.dragSourceIndex = -1;
        return;
    }
    self.dragTracking = [self allowsDragNow];
    self.dragActive = NO;
    self.dragSourceIndex = idx;
    self.dragStartPoint = p;
    self.dropInsertIndex = -1;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!self.dragTracking || self.dragSourceIndex < 0) {
        return;
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!self.dragActive) {
        CGFloat dx = p.x - self.dragStartPoint.x;
        CGFloat dy = p.y - self.dragStartPoint.y;
        if ((dx * dx + dy * dy) < 16.0) {
            return;
        }
        if (![self allowsDragNow]) {
            self.dragTracking = NO;
            return;
        }
        self.dragActive = YES;
        self.localDragZone = [self zoneForIndex:self.dragSourceIndex];
        self.dropInsertIndex = self.dragSourceIndex;
        self.gapAnimFromDest = self.dragSourceIndex;
        self.gapAnimStart = 0;
        [self beginGhostForIndex:self.dragSourceIndex atViewPoint:p];
        if ([self.delegate respondsToSelector:@selector(taskbarView:beganDragAtIndex:)]) {
            [self.delegate taskbarView:self beganDragAtIndex:self.dragSourceIndex];
        }
        [self setNeedsDisplay:YES];
    }

    NSPoint screenPt = [NSEvent mouseLocation];
    [self moveGhostToScreenPoint:screenPt];
    if ([self.delegate respondsToSelector:@selector(taskbarView:draggedToScreenPoint:)]) {
        [self.delegate taskbarView:self draggedToScreenPoint:screenPt];
    } else {
        MLTaskbarChipZone zone = self.localDragZone;
        NSInteger dest = [self destinationIndexAtPoint:p inZone:zone sourceIndex:self.dragSourceIndex];
        if (dest >= 0) {
            [self setDropInsertIndexAnimated:dest];
        }
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint screenPt = [NSEvent mouseLocation];
    BOOL wasDragging = self.dragActive;
    NSInteger src = self.dragSourceIndex;

    if (wasDragging) {
        if ([self.delegate respondsToSelector:@selector(taskbarView:endedDragAtScreenPoint:cancelled:)]) {
            [self.delegate taskbarView:self endedDragAtScreenPoint:screenPt cancelled:NO];
        }
        [self endDragVisualsKeepingPreview:NO];
        return;
    }

    self.dragTracking = NO;
    self.dragActive = NO;
    self.dragSourceIndex = -1;
    (void)p;
    if (src >= 0 && [self.delegate respondsToSelector:@selector(taskbarView:didClickItemAtIndex:)]) {
        [self.delegate taskbarView:self didClickItemAtIndex:src];
    }
}

- (void)endDragVisualsKeepingPreview:(BOOL)keepPreview {
    [self destroyGhostWindow];
    self.dragTracking = NO;
    self.dragActive = NO;
    if (!keepPreview) {
        [self clearDragPreview];
        self.dragSourceIndex = -1;
    }
}

- (void)cancelActiveDrag {
    [self endDragVisualsKeepingPreview:NO];
}

- (NSMenuItem *)menuItemWithTitle:(NSString *)title
                           action:(MLTaskbarMenuAction)action
                          enabled:(BOOL)enabled {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(contextMenuAction:)
                                           keyEquivalent:@""];
    item.target = self;
    item.tag = (NSInteger)action;
    item.enabled = enabled;
    return item;
}

- (NSMenu *)meolaunchSubmenu {
    NSMenu *sub = [[NSMenu alloc] initWithTitle:[MLStrings t:@"taskbar.submenu.meolaunch"]];
    [sub addItem:[self menuItemWithTitle:[MLStrings t:@"taskbar.about"]
                                  action:MLTaskbarMenuActionAbout
                                 enabled:YES]];
    [sub addItem:[self menuItemWithTitle:[MLStrings t:@"menu.preferences"]
                                  action:MLTaskbarMenuActionPreferences
                                 enabled:YES]];
    [sub addItem:[NSMenuItem separatorItem]];
    [sub addItem:[self menuItemWithTitle:[MLStrings t:@"menu.quit"]
                                  action:MLTaskbarMenuActionQuit
                                 enabled:YES]];
    return sub;
}

- (void)rightMouseDown:(NSEvent *)event {
    if (self.dragActive) {
        if ([self.delegate respondsToSelector:@selector(taskbarView:endedDragAtScreenPoint:cancelled:)]) {
            [self.delegate taskbarView:self endedDragAtScreenPoint:[NSEvent mouseLocation] cancelled:YES];
        }
        [self endDragVisualsKeepingPreview:NO];
    }
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:p];
    if (idx >= (NSInteger)self.items.count) {
        idx = -1;
    }
    self.menuIndex = idx;

    MLTaskbarMenuFlags *flags = [[MLTaskbarMenuFlags alloc] init];
    if ([self.delegate respondsToSelector:@selector(taskbarView:menuFlags:forIndex:)]) {
        [self.delegate taskbarView:self menuFlags:flags forIndex:idx];
    } else if (idx >= 0) {
        MLTaskbarItem *chip = self.items[(NSUInteger)idx];
        flags.hasWindow = (chip.kind == MLTaskbarItemRunningWindow && chip.windowID != 0);
        flags.minimized = chip.minimized;
        flags.pinned = chip.pinned;
        flags.fullscreenSupported = flags.hasWindow;
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Taskbar"];

    if (idx >= 0) {
        BOOL winOK = flags.hasWindow && AXIsProcessTrusted();
        [menu addItem:[self menuItemWithTitle:[MLStrings t:@"taskbar.close"]
                                       action:MLTaskbarMenuActionClose
                                      enabled:winOK]];
        NSString *minTitle = flags.minimized ? [MLStrings t:@"taskbar.restore"]
                                             : [MLStrings t:@"taskbar.minimize"];
        [menu addItem:[self menuItemWithTitle:minTitle
                                       action:MLTaskbarMenuActionMinimizeToggle
                                      enabled:winOK]];
        NSString *fsTitle = flags.fullscreen ? [MLStrings t:@"taskbar.exit_fullscreen"]
                                             : [MLStrings t:@"taskbar.enter_fullscreen"];
        [menu addItem:[self menuItemWithTitle:fsTitle
                                       action:MLTaskbarMenuActionFullscreenToggle
                                      enabled:(winOK && flags.fullscreenSupported)]];
        [menu addItem:[NSMenuItem separatorItem]];

        NSString *pinTitle = flags.pinned ? [MLStrings t:@"taskbar.unpin"]
                                          : [MLStrings t:@"taskbar.pin"];
        [menu addItem:[self menuItemWithTitle:pinTitle
                                       action:MLTaskbarMenuActionPinToggle
                                      enabled:YES]];
        [menu addItem:[NSMenuItem separatorItem]];
    }

    NSMenuItem *mlRoot = [[NSMenuItem alloc] initWithTitle:[MLStrings t:@"taskbar.submenu.meolaunch"]
                                                    action:nil
                                             keyEquivalent:@""];
    mlRoot.submenu = [self meolaunchSubmenu];
    [menu addItem:mlRoot];

    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)contextMenuAction:(NSMenuItem *)sender {
    MLTaskbarMenuAction action = (MLTaskbarMenuAction)sender.tag;
    NSInteger idx = self.menuIndex;
    self.menuIndex = -1;
    if ([self.delegate respondsToSelector:@selector(taskbarView:didSelectAction:atIndex:)]) {
        [self.delegate taskbarView:self didSelectAction:action atIndex:idx];
    }
}

@end
