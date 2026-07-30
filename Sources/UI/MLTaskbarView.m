#import "MLTaskbarView.h"

#import "MLStrings.h"
#import "MLTaskbarIconCache.h"

@implementation MLTaskbarItem
@end

@interface MLTaskbarView ()
@property (nonatomic, assign) NSInteger menuIndex;
@end

@implementation MLTaskbarView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _iconSize = 32.0;
        _spacing = 8.0;
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

- (CGFloat)effectiveItemWidth {
    NSUInteger n = self.items.count;
    if (n == 0) {
        return self.itemMaxWidth;
    }
    CGFloat avail = NSWidth(self.bounds) - 16.0;
    CGFloat spacing = self.spacing;
    CGFloat maxW = self.itemMaxWidth;
    CGFloat minW = self.itemMinWidth;
    CGFloat need = n * maxW + (n > 0 ? (n - 1) * spacing : 0);
    if (need <= avail) {
        return maxW;
    }
    CGFloat w = (avail - (n - 1) * spacing) / (CGFloat)n;
    if (w < minW) {
        w = minW;
    }
    if (w > maxW) {
        w = maxW;
    }
    return w;
}

- (NSRect)rectForItemAtIndex:(NSInteger)index itemWidth:(CGFloat)itemW {
    if (index < 0 || index >= (NSInteger)self.items.count) {
        return NSZeroRect;
    }
    CGFloat x = 8.0 + index * (itemW + self.spacing);
    CGFloat y = (NSHeight(self.bounds) - self.barHeight) * 0.5;
    if (y < 0) {
        y = 0;
    }
    return NSMakeRect(x, y, itemW, self.barHeight);
}

- (NSInteger)indexAtPoint:(NSPoint)p {
    CGFloat itemW = [self effectiveItemWidth];
    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        NSRect r = [self rectForItemAtIndex:i itemWidth:itemW];
        if (NSPointInRect(p, r)) {
            return i;
        }
    }
    return -1;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;

    [[NSColor colorWithCalibratedWhite:0.12 alpha:0.92] setFill];
    NSRectFill(self.bounds);

    CGFloat itemW = [self effectiveItemWidth];
    NSDictionary *titleAttrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:0.92 alpha:1.0],
        NSParagraphStyleAttributeName : ({
            NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
            ps.lineBreakMode = NSLineBreakByTruncatingTail;
            ps.alignment = NSTextAlignmentLeft;
            ps;
        }),
    };
    NSDictionary *dimTitleAttrs = @{
        NSFontAttributeName : titleAttrs[NSFontAttributeName],
        NSForegroundColorAttributeName : [NSColor colorWithCalibratedWhite:0.92 alpha:0.55],
        NSParagraphStyleAttributeName : titleAttrs[NSParagraphStyleAttributeName],
    };

    for (NSInteger i = 0; i < (NSInteger)self.items.count; i++) {
        MLTaskbarItem *item = self.items[(NSUInteger)i];
        NSRect cell = [self rectForItemAtIndex:i itemWidth:itemW];
        if (NSIsEmptyRect(cell)) {
            continue;
        }

        CGFloat alpha = (item.kind == MLTaskbarItemPinnedOnly) ? 0.55 : 1.0;

        NSRect iconRect = NSMakeRect(NSMinX(cell) + 4.0,
                                     NSMinY(cell) + (NSHeight(cell) - self.iconSize) * 0.5,
                                     self.iconSize,
                                     self.iconSize);
        NSImage *icon = [self.iconCache cachedIconForPath:item.path];
        if (icon) {
            [icon drawInRect:iconRect
                    fromRect:NSZeroRect
                   operation:NSCompositingOperationSourceOver
                    fraction:alpha
              respectFlipped:YES
                       hints:nil];
        } else {
            [[NSColor colorWithCalibratedWhite:0.35 alpha:alpha] setFill];
            NSRectFill(iconRect);
        }

        NSRect titleRect = NSMakeRect(NSMaxX(iconRect) + 6.0,
                                      NSMinY(cell) + (NSHeight(cell) - 14.0) * 0.5,
                                      NSMaxX(cell) - (NSMaxX(iconRect) + 6.0) - 8.0,
                                      14.0);
        if (titleRect.size.width > 8.0 && item.title.length > 0) {
            NSDictionary *attrs = (item.kind == MLTaskbarItemPinnedOnly) ? dimTitleAttrs : titleAttrs;
            [item.title drawInRect:titleRect withAttributes:attrs];
        }

        NSRect indicator = NSMakeRect(NSMinX(cell) + 8.0,
                                      NSMaxY(cell) - 4.0,
                                      MAX(8.0, self.iconSize - 8.0),
                                      2.0);
        if (item.kind == MLTaskbarItemRunningWindow) {
            [[NSColor colorWithCalibratedRed:0.35 green:0.75 blue:1.0 alpha:0.95] setFill];
            NSRectFill(indicator);
        } else if (item.kind == MLTaskbarItemRunningNoWindow || item.minimized) {
            [[NSColor colorWithCalibratedWhite:0.55 alpha:0.9] setFill];
            NSRectFill(indicator);
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
