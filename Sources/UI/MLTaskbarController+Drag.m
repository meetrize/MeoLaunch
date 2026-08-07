#import "MLTaskbarController+Private.h"

#import "MLAXWindowHelper.h"
#import "MLScreenGeometry.h"
#import "MLTaskbarController+Categories.h"
#import "MLWindowSoftState.h"

#import <ApplicationServices/ApplicationServices.h>

@implementation MLTaskbarController (Drag)

#pragma mark - Session helpers

- (MLTaskbarScreenBar *)barForView:(MLTaskbarView *)view {
    if (!view) {
        return nil;
    }
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (bar.barView == view) {
            return bar;
        }
    }
    return nil;
}

- (void)clearAllDragPreviews {
    for (MLTaskbarScreenBar *bar in self.bars) {
        [bar.barView clearDragPreview];
    }
}

- (void)cancelChipDragSession {
    if (!self.chipDragActive) {
        for (MLTaskbarScreenBar *bar in self.bars) {
            [bar.barView cancelActiveDrag];
        }
        return;
    }
    self.chipDragActive = NO;
    self.chipDragSourceBar = nil;
    self.chipDragSourceIndex = -1;
    self.chipDragItem = nil;
    self.chipDragZone = MLTaskbarChipZoneNone;
    self.chipDragTargetBar = nil;
    self.chipDragTargetInsert = -1;
    self.chipDragPlaceholderWidth = 0;
    for (MLTaskbarScreenBar *bar in self.bars) {
        [bar.barView cancelActiveDrag];
    }
}

- (MLTaskbarScreenBar *)barContainingScreenPoint:(NSPoint)screenPoint localPoint:(NSPoint *)outLocal {
    for (MLTaskbarScreenBar *bar in self.bars) {
        NSWindow *w = bar.window;
        if (!w || !bar.barView) {
            continue;
        }
        NSRect screenFrame = w.frame;
        if (!NSPointInRect(screenPoint, screenFrame)) {
            continue;
        }
        NSPoint winPt = [w convertPointFromScreen:screenPoint];
        NSPoint local = [bar.barView convertPoint:winPt fromView:nil];
        if (outLocal) {
            *outLocal = local;
        }
        return bar;
    }
    return nil;
}

- (BOOL)point:(NSPoint)local inZone:(MLTaskbarChipZone)zone onView:(MLTaskbarView *)view {
    if (!view || zone == MLTaskbarChipZoneNone) {
        return NO;
    }
    if (local.y < -4.0 || local.y > NSHeight(view.bounds) + 4.0) {
        return NO;
    }
    NSInteger pins = [view pinZoneCount];
    NSInteger windows = [view zoneCount:MLTaskbarChipZoneWindow];
    CGFloat inset = 3.0;
    CGFloat splitX = inset;
    if (pins > 0) {
        NSRect lastPin = [view rectForItemAtIndex:pins - 1];
        splitX = NSMaxX(lastPin) + view.spacing * 0.5;
    }
    if (zone == MLTaskbarChipZonePin) {
        if (pins == 0 && windows > 0) {
            /* No visible pins — still allow drop in a leading strip. */
            return local.x < splitX + 48.0;
        }
        CGFloat maxX = (windows > 0) ? splitX : NSWidth(view.bounds);
        return local.x >= -4.0 && local.x <= maxX;
    }
    if (zone == MLTaskbarChipZoneWindow) {
        CGFloat minX = (pins > 0) ? splitX : -4.0;
        return local.x >= minX && local.x <= NSWidth(view.bounds) + 4.0;
    }
    return NO;
}

#pragma mark - Delegate

- (BOOL)taskbarViewShouldBeginDrag:(MLTaskbarView *)view {
    (void)view;
    if (!self.started || !self.enabled) {
        return NO;
    }
    if (self.itemsFrozenForDesktopReveal || self.desktopPeekUserArmed) {
        return NO;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (self.stickyDisplayUntil > 0 && now < self.stickyDisplayUntil) {
        return NO;
    }
    return YES;
}

- (void)taskbarView:(MLTaskbarView *)view beganDragAtIndex:(NSInteger)index {
    MLTaskbarScreenBar *bar = [self barForView:view];
    if (!bar || index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    MLTaskbarItem *item = view.items[(NSUInteger)index];
    MLTaskbarChipZone zone = [view zoneForIndex:index];
    if (zone == MLTaskbarChipZoneNone) {
        return;
    }

    self.chipDragActive = YES;
    self.chipDragSourceBar = bar;
    self.chipDragSourceIndex = index;
    self.chipDragItem = item;
    self.chipDragZone = zone;
    self.chipDragTargetBar = bar;
    self.chipDragTargetInsert = index;
    self.chipDragPlaceholderWidth = [view widthForItemAtIndex:index];
    [self cancelItemsCommitTimer];
}

- (void)taskbarView:(MLTaskbarView *)view draggedToScreenPoint:(NSPoint)screenPoint {
    if (!self.chipDragActive || !self.chipDragItem) {
        return;
    }
    (void)view;

    NSPoint local = NSZeroPoint;
    MLTaskbarScreenBar *hit = [self barContainingScreenPoint:screenPoint localPoint:&local];
    MLTaskbarChipZone zone = self.chipDragZone;

    MLTaskbarScreenBar *previewBar = nil;
    NSInteger insert = -1;

    if (hit && hit.barView && [self point:local inZone:zone onView:hit.barView]) {
        if (hit == self.chipDragSourceBar) {
            insert = [hit.barView destinationIndexAtPoint:local
                                                   inZone:zone
                                             sourceIndex:self.chipDragSourceIndex];
        } else {
            insert = [hit.barView externalInsertIndexAtPoint:local inZone:zone];
        }
        if (insert >= 0) {
            previewBar = hit;
        }
    }

    for (MLTaskbarScreenBar *bar in self.bars) {
        if (bar == previewBar) {
            continue;
        }
        if (bar == self.chipDragSourceBar && previewBar != self.chipDragSourceBar) {
            /* Source bar: keep hole at source, no insert gap on foreign target. */
            [bar.barView setLocalDragPreviewSourceIndex:self.chipDragSourceIndex
                                            insertIndex:self.chipDragSourceIndex];
            continue;
        }
        [bar.barView clearDragPreview];
    }

    if (previewBar == self.chipDragSourceBar) {
        [previewBar.barView setLocalDragPreviewSourceIndex:self.chipDragSourceIndex
                                               insertIndex:insert];
    } else if (previewBar) {
        [self.chipDragSourceBar.barView setLocalDragPreviewSourceIndex:self.chipDragSourceIndex
                                                           insertIndex:self.chipDragSourceIndex];
        [previewBar.barView setExternalDragPreviewInZone:zone
                                             insertIndex:insert
                                        placeholderWidth:self.chipDragPlaceholderWidth];
    } else if (self.chipDragSourceBar) {
        [self.chipDragSourceBar.barView setLocalDragPreviewSourceIndex:self.chipDragSourceIndex
                                                           insertIndex:self.chipDragSourceIndex];
    }

    self.chipDragTargetBar = previewBar;
    self.chipDragTargetInsert = insert;
}

- (void)taskbarView:(MLTaskbarView *)view
    endedDragAtScreenPoint:(NSPoint)screenPoint
                 cancelled:(BOOL)cancelled {
    (void)view;
    if (!self.chipDragActive) {
        return;
    }

    /* Final hit-test so mouseUp without last dragged still commits. */
    if (!cancelled) {
        [self taskbarView:view draggedToScreenPoint:screenPoint];
    }

    MLTaskbarScreenBar *target = self.chipDragTargetBar;
    NSInteger insert = self.chipDragTargetInsert;
    MLTaskbarChipZone zone = self.chipDragZone;
    MLTaskbarItem *item = self.chipDragItem;
    MLTaskbarScreenBar *source = self.chipDragSourceBar;
    NSInteger sourceIndex = self.chipDragSourceIndex;

    self.chipDragActive = NO;
    [self clearAllDragPreviews];

    BOOL shouldCommit = !cancelled && target && insert >= 0 && item && source && zone != MLTaskbarChipZoneNone;
    if (shouldCommit && target == source && insert == sourceIndex) {
        shouldCommit = NO;
    }

    self.chipDragSourceBar = nil;
    self.chipDragSourceIndex = -1;
    self.chipDragItem = nil;
    self.chipDragZone = MLTaskbarChipZoneNone;
    self.chipDragTargetBar = nil;
    self.chipDragTargetInsert = -1;
    self.chipDragPlaceholderWidth = 0;

    if (!shouldCommit) {
        return;
    }

    if (zone == MLTaskbarChipZonePin) {
        [self commitPinDragFromBar:source
                       sourceIndex:sourceIndex
                            toBar:target
                      insertIndex:insert
                             item:item];
    } else {
        [self commitWindowDragFromBar:source
                          sourceIndex:sourceIndex
                               toBar:target
                         insertIndex:insert
                                item:item];
    }
}

#pragma mark - Pin commit

- (void)commitPinDragFromBar:(MLTaskbarScreenBar *)source
                 sourceIndex:(NSInteger)sourceIndex
                      toBar:(MLTaskbarScreenBar *)target
                insertIndex:(NSInteger)insertIndex
                       item:(MLTaskbarItem *)item {
    (void)source;
    (void)sourceIndex;
    if (item.path.length == 0 || !target.barView) {
        return;
    }

    NSString *beforePath = nil;
    NSInteger pinStart = [target.barView zoneStartIndex:MLTaskbarChipZonePin];
    NSInteger pinCount = [target.barView zoneCount:MLTaskbarChipZonePin];

    /*
     * insertIndex is absolute: for same-bar local dest it's final index among pins;
     * for external it's insert-before absolute (pinStart..pinStart+pinCount).
     */
    BOOL sameBar = (source == target);
    NSInteger beforeAbs;
    if (sameBar) {
        /* Final position among current pins — beforePath is the pin that ends up after us. */
        beforeAbs = insertIndex + 1;
        if (beforeAbs < pinStart + pinCount) {
            MLTaskbarItem *next = target.barView.items[(NSUInteger)beforeAbs];
            /* If next is the dragged item itself, take the following. */
            if ([next.path isEqualToString:item.path] ||
                [next.path.stringByStandardizingPath isEqualToString:item.path.stringByStandardizingPath]) {
                beforeAbs++;
            }
        }
        /* After removing source, the "next" chip in final order: */
        NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSInteger i = pinStart; i < pinStart + pinCount; i++) {
            MLTaskbarItem *chip = target.barView.items[(NSUInteger)i];
            if (chip.path.length) {
                [paths addObject:chip.path];
            }
        }
        NSInteger fromLocal = sourceIndex - pinStart;
        if (fromLocal < 0 || fromLocal >= (NSInteger)paths.count) {
            return;
        }
        NSInteger destLocal = insertIndex - pinStart;
        if (destLocal < 0) {
            destLocal = 0;
        }
        if (destLocal >= (NSInteger)paths.count) {
            destLocal = (NSInteger)paths.count - 1;
        }
        NSString *moving = paths[(NSUInteger)fromLocal];
        [paths removeObjectAtIndex:(NSUInteger)fromLocal];
        [paths insertObject:moving atIndex:(NSUInteger)destLocal];
        NSInteger idxInNew = [paths indexOfObject:moving];
        if (idxInNew + 1 < (NSInteger)paths.count) {
            beforePath = paths[(NSUInteger)idxInNew + 1];
        } else {
            beforePath = nil;
        }
        [self.pinStore movePinPath:moving beforePath:beforePath];
        return;
    }

    /* Cross-bar: insertIndex is insert-before absolute among target visual pins. */
    beforeAbs = insertIndex;
    if (beforeAbs >= pinStart && beforeAbs < pinStart + pinCount) {
        beforePath = target.barView.items[(NSUInteger)beforeAbs].path;
        if ([beforePath isEqualToString:item.path] ||
            [beforePath.stringByStandardizingPath isEqualToString:item.path.stringByStandardizingPath]) {
            if (beforeAbs + 1 < pinStart + pinCount) {
                beforePath = target.barView.items[(NSUInteger)beforeAbs + 1].path;
            } else {
                beforePath = nil;
            }
        }
    } else {
        beforePath = nil; /* append */
    }
    [self.pinStore movePinPath:item.path beforePath:beforePath];
}

#pragma mark - Window commit

- (NSMutableArray<MLTaskbarItem *> *)windowChipsOnBar:(MLTaskbarScreenBar *)bar {
    NSMutableArray<MLTaskbarItem *> *out = [NSMutableArray array];
    for (MLTaskbarItem *chip in bar.barView.items ?: @[]) {
        if (chip.kind == MLTaskbarItemRunningWindow) {
            [out addObject:chip];
        }
    }
    return out;
}

- (void)applySeenOrdersForWindowChips:(NSArray<MLTaskbarItem *> *)chips startingAt:(NSUInteger)start {
    NSMutableDictionary<NSNumber *, NSNumber *> *map = [NSMutableDictionary dictionary];
    NSUInteger ord = start;
    for (MLTaskbarItem *chip in chips) {
        if (chip.windowID == 0) {
            continue;
        }
        map[@(chip.windowID)] = @(ord);
        chip.seenOrder = ord;
        ord++;
    }
    if (map.count > 0) {
        [self.monitor applySeenOrderByWindowID:map];
    }
}

- (NSRect)frameMappedFrom:(NSRect)frame ontoScreen:(NSScreen *)target {
    if (!target) {
        return frame;
    }
    NSScreen *src = [MLScreenGeometry screenForCocoaRect:frame] ?: NSScreen.mainScreen;
    NSRect srcVis = src.visibleFrame;
    NSRect dstVis = target.visibleFrame;
    CGFloat w = MIN(NSWidth(frame), NSWidth(dstVis));
    CGFloat h = MIN(NSHeight(frame), NSHeight(dstVis));
    if (w < 80) {
        w = MIN(NSWidth(frame), NSWidth(dstVis));
    }
    if (h < 60) {
        h = MIN(NSHeight(frame), NSHeight(dstVis));
    }
    CGFloat relX = 0.1;
    CGFloat relY = 0.1;
    if (NSWidth(srcVis) > 1.0) {
        relX = (NSMinX(frame) - NSMinX(srcVis)) / NSWidth(srcVis);
    }
    if (NSHeight(srcVis) > 1.0) {
        relY = (NSMinY(frame) - NSMinY(srcVis)) / NSHeight(srcVis);
    }
    relX = MAX(0.0, MIN(1.0, relX));
    relY = MAX(0.0, MIN(1.0, relY));
    CGFloat x = NSMinX(dstVis) + relX * MAX(NSWidth(dstVis) - w, 0);
    CGFloat y = NSMinY(dstVis) + relY * MAX(NSHeight(dstVis) - h, 0);
    if (NSMaxX(NSMakeRect(x, y, w, h)) > NSMaxX(dstVis)) {
        x = NSMaxX(dstVis) - w;
    }
    if (NSMaxY(NSMakeRect(x, y, w, h)) > NSMaxY(dstVis)) {
        y = NSMaxY(dstVis) - h;
    }
    if (x < NSMinX(dstVis)) {
        x = NSMinX(dstVis);
    }
    if (y < NSMinY(dstVis)) {
        y = NSMinY(dstVis);
    }
    return NSMakeRect(x, y, w, h);
}

- (BOOL)moveWindowItem:(MLTaskbarItem *)item ontoScreen:(NSScreen *)targetScreen {
    if (!item || !targetScreen || item.windowID == 0) {
        return NO;
    }
    if (!AXIsProcessTrusted()) {
        return NO;
    }
    AXUIElementRef win = [self copyAXWindowForItem:item];
    if (!win) {
        return NO;
    }
    if ([MLAXWindowHelper isFullscreen:win] || [self readFullscreenForAXWindow:win]) {
        CFRelease(win);
        return NO;
    }

    NSRect current = NSZeroRect;
    if (![MLScreenGeometry readCocoaFrame:&current fromAXWindow:win] || current.size.width < 2.0) {
        /* Fall back to monitor bounds. */
        for (MLTaskbarWindowInfo *w in self.monitor.snapshot.windows) {
            if (w.windowID == item.windowID) {
                current = [MLScreenGeometry cocoaRectFromQuartzBounds:w.bounds];
                break;
            }
        }
    }
    if (current.size.width < 2.0) {
        current = NSInsetRect(targetScreen.visibleFrame, 80, 80);
    }

    NSRect mapped = [self frameMappedFrom:current ontoScreen:targetScreen];
    [MLScreenGeometry applyCocoaFrame:mapped toAXWindow:win];
    CFRelease(win);

    NSNumber *sid = [[self class] screenIDForScreen:targetScreen];
    if (sid && item.windowID != 0) {
        self.chipScreenAffinityByWid[@(item.windowID)] = sid;
    }
    self.stickyDisplayUntil = [NSDate date].timeIntervalSinceReferenceDate + 1.25;
    return YES;
}

- (void)commitWindowDragFromBar:(MLTaskbarScreenBar *)source
                    sourceIndex:(NSInteger)sourceIndex
                         toBar:(MLTaskbarScreenBar *)target
                   insertIndex:(NSInteger)insertIndex
                          item:(MLTaskbarItem *)item {
    if (!source.barView || !target.barView || !item) {
        return;
    }

    BOOL sameBar = (source == target);
    NSInteger winStart = [target.barView zoneStartIndex:MLTaskbarChipZoneWindow];

    if (sameBar) {
        NSMutableArray<MLTaskbarItem *> *windows = [self windowChipsOnBar:source];
        NSInteger fromLocal = sourceIndex - [source.barView zoneStartIndex:MLTaskbarChipZoneWindow];
        NSInteger destLocal = insertIndex - winStart;
        if (fromLocal < 0 || fromLocal >= (NSInteger)windows.count) {
            return;
        }
        if (destLocal < 0) {
            destLocal = 0;
        }
        if (destLocal >= (NSInteger)windows.count) {
            destLocal = (NSInteger)windows.count - 1;
        }
        if (fromLocal == destLocal) {
            return;
        }
        MLTaskbarItem *moving = windows[(NSUInteger)fromLocal];
        [windows removeObjectAtIndex:(NSUInteger)fromLocal];
        [windows insertObject:moving atIndex:(NSUInteger)destLocal];
        [self applySeenOrdersForWindowChips:windows startingAt:1];
        [self rebuildItemsImmediate:YES];
        return;
    }

    /* Cross-screen: move real window, then rewrite orders on both bars. */
    NSDictionary<NSNumber *, NSScreen *> *screens = [self screensByID];
    NSScreen *targetScreen = screens[target.screenID];
    if (!targetScreen) {
        return;
    }
    if (![self moveWindowItem:item ontoScreen:targetScreen]) {
        return;
    }

    NSMutableArray<MLTaskbarItem *> *srcWindows = [self windowChipsOnBar:source];
    NSMutableArray<MLTaskbarItem *> *dstWindows = [self windowChipsOnBar:target];

    NSInteger fromLocal = -1;
    for (NSInteger i = 0; i < (NSInteger)srcWindows.count; i++) {
        MLTaskbarItem *c = srcWindows[(NSUInteger)i];
        if (c.windowID != 0 && c.windowID == item.windowID) {
            fromLocal = i;
            break;
        }
        if (c.windowID == 0 && [c.path isEqualToString:item.path] &&
            [c.title isEqualToString:item.title]) {
            fromLocal = i;
            break;
        }
    }
    MLTaskbarItem *moving = item;
    if (fromLocal >= 0) {
        moving = srcWindows[(NSUInteger)fromLocal];
        [srcWindows removeObjectAtIndex:(NSUInteger)fromLocal];
    }

    NSInteger destLocal = insertIndex - winStart;
    if (destLocal < 0) {
        destLocal = 0;
    }
    if (destLocal > (NSInteger)dstWindows.count) {
        destLocal = (NSInteger)dstWindows.count;
    }
    /* Avoid duplicate if somehow already present. */
    for (NSInteger i = (NSInteger)dstWindows.count - 1; i >= 0; i--) {
        MLTaskbarItem *c = dstWindows[(NSUInteger)i];
        if (c.windowID != 0 && c.windowID == moving.windowID) {
            [dstWindows removeObjectAtIndex:(NSUInteger)i];
            if (destLocal > i) {
                destLocal--;
            }
        }
    }
    [dstWindows insertObject:moving atIndex:(NSUInteger)destLocal];

    [self applySeenOrdersForWindowChips:srcWindows startingAt:1];
    [self applySeenOrdersForWindowChips:dstWindows startingAt:1];

    /* Optimistic affinity already set; force rebuild/paint. */
    [self.monitor pollNow];
    [self rebuildItemsImmediate:YES];
}

@end
