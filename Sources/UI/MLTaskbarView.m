#import "MLTaskbarView.h"

#import "MLStrings.h"
#import "MLTaskbarIconCache.h"

@implementation MLTaskbarItem
@end

@interface MLTaskbarView ()
@property (nonatomic, assign) NSInteger menuIndex;
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
        self.wantsLayer = YES;
    }
    return self;
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

    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        MLTaskbarItem *item = self.items[(NSUInteger)i];
        NSRect cell = [self rectForItemAtIndex:i chipWidth:chipW];
        if (NSIsEmptyRect(cell)) {
            continue;
        }

        BOOL pinnedOnly = [self isPinnedIconOnly:item];
        BOOL isActive = item.active && !pinnedOnly;

        if (pinnedOnly) {
            /* Icon only — full color, no chip / title; pack from the left. */
            NSRect iconRect = NSMakeRect(NSMinX(cell) + (NSWidth(cell) - self.iconSize) * 0.5,
                                         NSMinY(cell) + (NSHeight(cell) - self.iconSize) * 0.5,
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
                NSRectFill(iconRect);
            }
            continue;
        }

        NSRect chip = NSInsetRect(cell, 0.0, 3.0);
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

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:p];
    if (idx < 0) {
        return;
    }
    if (event.type == NSEventTypeRightMouseDown || event.modifierFlags & NSEventModifierFlagControl) {
        return;
    }
    if ([self.delegate respondsToSelector:@selector(taskbarView:didClickItemAtIndex:)]) {
        [self.delegate taskbarView:self didClickItemAtIndex:idx];
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger idx = [self indexAtPoint:p];
    if (idx < 0 || idx >= (NSInteger)self.items.count) {
        return;
    }
    self.menuIndex = idx;
    MLTaskbarItem *item = self.items[(NSUInteger)idx];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Taskbar"];
    NSString *title = item.pinned ? [MLStrings t:@"taskbar.unpin"] : [MLStrings t:@"taskbar.pin"];
    NSMenuItem *pinItem = [[NSMenuItem alloc] initWithTitle:title
                                                     action:@selector(togglePin:)
                                              keyEquivalent:@""];
    pinItem.target = self;
    [menu addItem:pinItem];
    [NSMenu popUpContextMenu:menu withEvent:event forView:self];
}

- (void)togglePin:(id)sender {
    (void)sender;
    if (self.menuIndex < 0) {
        return;
    }
    if ([self.delegate respondsToSelector:@selector(taskbarView:didRequestPinToggleAtIndex:)]) {
        [self.delegate taskbarView:self didRequestPinToggleAtIndex:self.menuIndex];
    }
    self.menuIndex = -1;
}

@end
