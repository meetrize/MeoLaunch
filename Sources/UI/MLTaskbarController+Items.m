#import "MLTaskbarController+Private.h"

#import "MLScreenGeometry.h"

#import <ApplicationServices/ApplicationServices.h>

@implementation MLTaskbarController (Items)

- (NSString *)displayNameForPath:(NSString *)path {
    if (path.length == 0) {
        return @"";
    }
    NSString *cached = self.displayNameCache[path];
    if (cached) {
        return cached;
    }
    NSString *name = nil;
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    [url getResourceValue:&name forKey:NSURLLocalizedNameKey error:NULL];
    if (name.length == 0) {
        name = [[NSFileManager defaultManager] displayNameAtPath:path];
    }
    if (name.length == 0) {
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (bundle) {
            name = bundle.localizedInfoDictionary[@"CFBundleDisplayName"];
            if (name.length == 0) {
                name = bundle.infoDictionary[@"CFBundleDisplayName"];
            }
            if (name.length == 0) {
                name = bundle.localizedInfoDictionary[@"CFBundleName"];
            }
            if (name.length == 0) {
                name = bundle.infoDictionary[@"CFBundleName"];
            }
        }
    }
    if (name.length == 0) {
        name = path.lastPathComponent.stringByDeletingPathExtension;
    }
    if (self.displayNameCache.count >= 32) {
        [self.displayNameCache removeAllObjects];
    }
    self.displayNameCache[path] = name ?: @"";
    return name ?: @"";
}

- (pid_t)pidForPath:(NSString *)path snapshot:(MLRunningAppsSnapshot *)snap {
    if (path.length == 0 || !snap) {
        return 0;
    }
    NSString *std = path.stringByStandardizingPath;
    for (NSNumber *pidNum in snap.pidToPath) {
        NSString *p = snap.pidToPath[pidNum];
        if ([p isEqualToString:path] ||
            (std.length > 0 && [p.stringByStandardizingPath isEqualToString:std])) {
            return (pid_t)pidNum.intValue;
        }
    }
    return 0;
}

- (BOOL)pinSet:(NSSet<NSString *> *)pinSet containsPath:(NSString *)path {
    if (path.length == 0 || pinSet.count == 0) {
        return NO;
    }
    if ([pinSet containsObject:path]) {
        return YES;
    }
    NSString *std = path.stringByStandardizingPath;
    if (std.length > 0 && [pinSet containsObject:std]) {
        return YES;
    }
    for (NSString *pin in pinSet) {
        if ([pin.stringByStandardizingPath isEqualToString:std]) {
            return YES;
        }
    }
    return NO;
}

- (MLTaskbarItem *)itemWithPath:(NSString *)path
                            pid:(pid_t)pid
                       windowID:(CGWindowID)windowID
                          title:(NSString *)title
                           kind:(MLTaskbarItemKind)kind
                         pinned:(BOOL)pinned
                      minimized:(BOOL)minimized
                         active:(BOOL)active
                      seenOrder:(NSUInteger)seenOrder {
    MLTaskbarItem *item = [[MLTaskbarItem alloc] init];
    item.path = path;
    item.pid = pid;
    item.windowID = windowID;
    item.title = title;
    item.kind = kind;
    item.pinned = pinned;
    item.minimized = minimized;
    item.active = active;
    item.seenOrder = seenOrder;
    return item;
}

/** Frontmost layer-0 window of the frontmost regular app (CG front-to-back order). */
- (CGWindowID)frontmostTrackedWindowID {
    NSRunningApplication *front = [NSWorkspace sharedWorkspace].frontmostApplication;
    if (!front || front.isTerminated || front.processIdentifier <= 0) {
        return 0;
    }
    if (front.activationPolicy != NSApplicationActivationPolicyRegular) {
        return 0;
    }
    NSString *selfBid = [NSBundle mainBundle].bundleIdentifier;
    if (selfBid.length > 0 && [front.bundleIdentifier isEqualToString:selfBid]) {
        return 0;
    }
    pid_t pid = front.processIdentifier;
    CFArrayRef list = [self.monitor.windowCensus cachedOnScreenWindowListRefreshingIfNeeded:YES];
    if (!list) {
        return 0;
    }
    CGWindowID best = 0;
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        CFNumberRef pidRef = info ? CFDictionaryGetValue(info, kCGWindowOwnerPID) : NULL;
        pid_t wpid = 0;
        if (pidRef) {
            CFNumberGetValue(pidRef, kCFNumberIntType, &wpid);
        }
        if (wpid != pid) {
            continue;
        }
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        int layer = 0;
        if (layerRef) {
            CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        }
        if (layer != 0) {
            continue;
        }
        CGRect bounds = CGRectZero;
        CFDictionaryRef bd = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!bd || !CGRectMakeWithDictionaryRepresentation(bd, &bounds)) {
            continue;
        }
        if (bounds.size.width < 100.0 || bounds.size.height < 80.0) {
            continue;
        }
        CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
        if (winRef) {
            CFNumberGetValue(winRef, kCFNumberIntType, &best);
        }
        break; /* first match is frontmost */
    }
    return best;
}

/**
 * Topmost on-screen layer-0 user window, ignoring MeoLaunch.
 * Used for taskbar re-click minimize: clicking the bar often makes us frontmost,
 * so NSWorkspace.frontmostApplication is unreliable at click time.
 */
- (CGWindowID)topmostUserWindowIDExcludingSelf {
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (self.cachedTopmostUserAt > 0 && (now - self.cachedTopmostUserAt) < 0.08 &&
        self.cachedTopmostUserWID != 0) {
        return self.cachedTopmostUserWID;
    }
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    CFArrayRef list = [self.monitor.windowCensus cachedOnScreenWindowListRefreshingIfNeeded:YES];
    if (!list) {
        return 0;
    }
    CGWindowID best = 0;
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        CFNumberRef pidRef = info ? CFDictionaryGetValue(info, kCGWindowOwnerPID) : NULL;
        pid_t wpid = 0;
        if (pidRef) {
            CFNumberGetValue(pidRef, kCFNumberIntType, &wpid);
        }
        if (wpid <= 0 || wpid == selfPid) {
            continue;
        }
        NSRunningApplication *owner = [NSRunningApplication runningApplicationWithProcessIdentifier:wpid];
        if (!owner || owner.isTerminated ||
            owner.activationPolicy != NSApplicationActivationPolicyRegular) {
            continue;
        }
        CFStringRef ownerRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (ownerRef && CFGetTypeID(ownerRef) == CFStringGetTypeID()) {
            NSString *ownerName = (__bridge NSString *)ownerRef;
            if ([[self class] isSystemWindowOwner:ownerName]) {
                continue;
            }
        }
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        int layer = 0;
        if (layerRef) {
            CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        }
        if (layer != 0) {
            continue;
        }
        CGRect bounds = CGRectZero;
        CFDictionaryRef bd = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!bd || !CGRectMakeWithDictionaryRepresentation(bd, &bounds)) {
            continue;
        }
        if (bounds.size.width < 100.0 || bounds.size.height < 80.0) {
            continue;
        }
        CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (alphaRef) {
            double alpha = 1.0;
            CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
            if (alpha < 0.2) {
                continue;
            }
        }
        CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
        if (winRef) {
            CFNumberGetValue(winRef, kCFNumberIntType, &best);
        }
        break;
    }
    self.cachedTopmostUserWID = best;
    self.cachedTopmostUserAt = now;
    return best;
}

/** Prefer the screen with the largest intersection; ties break to containing center.
 * Soft-state reinject stores Cocoa bounds; CG polls store Quartz — try Cocoa first, then Quartz→Cocoa. */
- (NSScreen *)screenForWindowBounds:(CGRect)bounds {
    if (CGRectIsEmpty(bounds)) {
        return nil;
    }
    NSScreen *viaCocoa = [MLScreenGeometry screenForCocoaRect:NSRectFromCGRect(bounds)];
    NSRect asCocoaFromQuartz = [MLScreenGeometry cocoaRectFromQuartzBounds:bounds];
    NSScreen *viaQuartz = [MLScreenGeometry screenForCocoaRect:asCocoaFromQuartz];
    /* Prefer the interpretation that intersects a screen with larger area. */
    CGFloat a1 = 0, a2 = 0;
    if (viaCocoa) {
        CGRect inter = CGRectIntersection(bounds, NSRectToCGRect(viaCocoa.frame));
        a1 = CGRectIsNull(inter) ? 0 : inter.size.width * inter.size.height;
    }
    if (viaQuartz) {
        CGRect inter = CGRectIntersection(NSRectToCGRect(asCocoaFromQuartz), NSRectToCGRect(viaQuartz.frame));
        a2 = CGRectIsNull(inter) ? 0 : inter.size.width * inter.size.height;
    }
    if (a2 > a1) {
        return viaQuartz;
    }
    return viaCocoa ?: viaQuartz;
}

- (NSScreen *)screenWithID:(NSNumber *)sid {
    if (!sid) {
        return nil;
    }
    for (NSScreen *s in NSScreen.screens) {
        if ([[[self class] screenIDForScreen:s] isEqualToNumber:sid]) {
            return s;
        }
    }
    return nil;
}

/** YES when bounds clearly sit on a real display (not Show Desktop / peek parking). */
- (BOOL)boundsClearlyOnAScreen:(CGRect)bounds {
    if (CGRectIsEmpty(bounds) || bounds.size.width < 2.0 || bounds.size.height < 2.0) {
        return NO;
    }
    CGFloat best = 0;
    CGFloat area = bounds.size.width * bounds.size.height;
    if (area < 1.0) {
        return NO;
    }
    NSRect c1 = NSRectFromCGRect(bounds);
    NSRect c2 = [MLScreenGeometry cocoaRectFromQuartzBounds:bounds];
    for (NSScreen *s in NSScreen.screens) {
        for (NSUInteger i = 0; i < 2; i++) {
            NSRect c = (i == 0) ? c1 : c2;
            NSRect hit = NSIntersectionRect(c, s.frame);
            if (NSIsEmptyRect(hit)) {
                continue;
            }
            CGFloat a = NSWidth(hit) * NSHeight(hit);
            if (a > best) {
                best = a;
            }
        }
    }
    return (best / area) >= 0.35;
}

- (void)rememberChipScreenAffinityFromBars {
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.screenID) {
            continue;
        }
        for (MLTaskbarItem *it in bar.barView.items ?: @[]) {
            if (it.kind != MLTaskbarItemRunningWindow || it.windowID == 0) {
                continue;
            }
            self.chipScreenAffinityByWid[@(it.windowID)] = bar.screenID;
        }
    }
}

- (void)rememberChipScreenAffinityFromFrozenShots {
    for (NSNumber *sid in self.frozenItemsByScreenID) {
        for (MLTaskbarItem *it in self.frozenItemsByScreenID[sid] ?: @[]) {
            if (it.kind != MLTaskbarItemRunningWindow || it.windowID == 0) {
                continue;
            }
            self.chipScreenAffinityByWid[@(it.windowID)] = sid;
        }
    }
}

/**
 * YES if pending would move a windowID onto a different screen than the painted bar
 * (or recorded affinity). Used to block peek/Show Desktop cross-screen chip hops.
 */
- (BOOL)pendingMovesChipsAcrossScreens {
    NSMutableDictionary<NSNumber *, NSNumber *> *painted = [NSMutableDictionary dictionary];
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.screenID) {
            continue;
        }
        for (MLTaskbarItem *it in bar.barView.items ?: @[]) {
            if (it.kind != MLTaskbarItemRunningWindow || it.windowID == 0) {
                continue;
            }
            painted[@(it.windowID)] = bar.screenID;
        }
    }
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.screenID || !bar.pendingItems) {
            continue;
        }
        for (MLTaskbarItem *it in bar.pendingItems) {
            if (it.kind != MLTaskbarItemRunningWindow || it.windowID == 0) {
                continue;
            }
            NSNumber *wid = @(it.windowID);
            NSNumber *was = painted[wid] ?: self.chipScreenAffinityByWid[wid];
            if (was && ![was isEqualToNumber:bar.screenID]) {
                return YES;
            }
        }
    }
    return NO;
}

- (NSArray<MLTaskbarWindowInfo *> *)windowsOnScreen:(NSScreen *)screen
                                          fromSnap:(MLRunningAppsSnapshot *)snap
                                              cap:(NSUInteger)cap {
    NSMutableArray<MLTaskbarWindowInfo *> *out = [NSMutableArray array];
    if (!screen || !snap) {
        return out;
    }
    NSNumber *wantID = [[self class] screenIDForScreen:screen];
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    BOOL stickToAffinity = self.itemsFrozenForDesktopReveal ||
                           self.desktopPeekUserArmed ||
                           (self.stickyDisplayUntil > 0 && now < self.stickyDisplayUntil);

    for (MLTaskbarWindowInfo *w in snap.windows ?: @[]) {
        NSNumber *affinity = (w.windowID != 0) ? self.chipScreenAffinityByWid[@(w.windowID)] : nil;
        BOOL softOrMin = w.minimized ||
                         (w.windowID != 0 && [self.monitor isSoftMinimizedWindowID:w.windowID]);
        BOOL boundsOK = [self boundsClearlyOnAScreen:w.bounds];
        BOOL useAffinity = (affinity != nil) && (stickToAffinity || softOrMin || !boundsOK);

        NSScreen *owner = nil;
        if (useAffinity) {
            owner = [self screenWithID:affinity];
        }
        if (!owner) {
            owner = [self screenForWindowBounds:w.bounds];
        }
        if (!owner && w.minimized) {
            /*
             * Avoid dumping onto mainScreen: prefer affinity, then any non-empty
             * bounds center, else skip (better missing chip than wrong-screen chip).
             */
            if (affinity) {
                owner = [self screenWithID:affinity];
            }
            if (!owner && !CGRectIsEmpty(w.bounds)) {
                CGPoint c = CGPointMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds));
                for (NSScreen *s in NSScreen.screens) {
                    if (NSPointInRect(NSMakePoint(c.x, c.y), s.frame)) {
                        owner = s;
                        break;
                    }
                }
            }
        }
        if (!owner) {
            continue;
        }
        if (![[[self class] screenIDForScreen:owner] isEqualToNumber:wantID]) {
            continue;
        }
        [out addObject:w];
        if (cap > 0 && out.count >= cap) {
            break;
        }
    }
    return out;
}

- (NSInteger)windowChipCountInItems:(NSArray<MLTaskbarItem *> *)items {
    NSInteger n = 0;
    for (MLTaskbarItem *it in items ?: @[]) {
        if (it.kind == MLTaskbarItemRunningWindow) {
            n += 1;
        }
    }
    return n;
}

- (NSArray<MLTaskbarItem *> *)deepCopyItems:(NSArray<MLTaskbarItem *> *)src {
    NSMutableArray<MLTaskbarItem *> *out = [NSMutableArray arrayWithCapacity:src.count];
    for (MLTaskbarItem *it in src ?: @[]) {
        MLTaskbarItem *c = [[MLTaskbarItem alloc] init];
        c.path = it.path;
        c.bundleID = it.bundleID;
        c.pid = it.pid;
        c.windowID = it.windowID;
        c.title = it.title;
        c.kind = it.kind;
        c.pinned = it.pinned;
        c.minimized = it.minimized;
        c.active = it.active;
        c.seenOrder = it.seenOrder;
        [out addObject:c];
    }
    return out;
}

/**
 * Compute chips for one bar into pendingItems — does NOT paint.
 * Painting goes through commitPendingItemsForce: so Show Desktop churn stays invisible.
 */
- (void)rebuildItemsForBar:(MLTaskbarScreenBar *)bar screen:(NSScreen *)screen {
    if (!bar.barView || !screen) {
        return;
    }

    /* Inherit prior chip order so minimize/restore never reshuffles. */
    NSMutableDictionary<NSNumber *, NSNumber *> *priorOrderByWid = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSNumber *> *priorOrderByPathTitle = [NSMutableDictionary dictionary];
    NSUInteger priorIdx = 1;
    for (MLTaskbarItem *prev in bar.barView.items ?: @[]) {
        if (prev.kind != MLTaskbarItemRunningWindow) {
            continue;
        }
        NSUInteger ord = prev.seenOrder > 0 ? prev.seenOrder : priorIdx;
        if (prev.windowID != 0) {
            priorOrderByWid[@(prev.windowID)] = @(ord);
        }
        NSString *pt = [NSString stringWithFormat:@"%@|%@", prev.path ?: @"", prev.title ?: @""];
        if (!priorOrderByPathTitle[pt]) {
            priorOrderByPathTitle[pt] = @(ord);
        }
        priorIdx++;
    }

    MLRunningAppsSnapshot *snap = self.monitor.snapshot;
    NSArray<NSString *> *pins = self.pinStore.pinnedPaths;
    NSSet<NSString *> *pinSet = [NSSet setWithArray:pins];

    NSUInteger cap = self.monitor.maxWindowEntries > 0 ? self.monitor.maxWindowEntries
                                                       : (NSUInteger)MLTaskbarMaxWindowEntries;
    NSArray<MLTaskbarWindowInfo *> *screenWindows = [self windowsOnScreen:screen fromSnap:snap cap:cap];

    /* Dedupe again at UI layer (same windowID / path+title). */
    NSMutableArray<MLTaskbarWindowInfo *> *uniqueWindows = [NSMutableArray array];
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    for (MLTaskbarWindowInfo *w in screenWindows) {
        NSString *key = w.windowID != 0
                            ? [NSString stringWithFormat:@"id:%u", (unsigned)w.windowID]
                            : [NSString stringWithFormat:@"p:%d|%@|%@", (int)w.pid, w.path ?: @"", w.title ?: @""];
        if ([keys containsObject:key]) {
            continue;
        }
        /* Collapse path+title duplicates even when one has windowID and one does not */
        BOOL pathTitleDup = NO;
        for (MLTaskbarWindowInfo *existing in uniqueWindows) {
            if (![existing.path isEqualToString:w.path]) {
                continue;
            }
            BOOL sameID = (existing.windowID != 0 && existing.windowID == w.windowID);
            BOOL idZeroClone = (existing.windowID != 0 && w.windowID == 0) ||
                               (w.windowID != 0 && existing.windowID == 0);
            BOOL titlesBothNonEmpty = existing.title.length > 0 && w.title.length > 0;
            BOOL titleMatch = titlesBothNonEmpty &&
                              ([existing.title isEqualToString:w.title] ||
                               [existing.title hasPrefix:w.title] ||
                               [w.title hasPrefix:existing.title]);
            BOOL bothEmptyTitle = existing.title.length == 0 && w.title.length == 0;
            if (!(sameID || (idZeroClone && (titleMatch || bothEmptyTitle)) || titleMatch)) {
                continue;
            }
            pathTitleDup = YES;
            if (existing.minimized && !w.minimized) {
                NSUInteger idx = [uniqueWindows indexOfObject:existing];
                if (idx != NSNotFound) {
                    w.seenOrder = existing.seenOrder > 0 ? existing.seenOrder : w.seenOrder;
                    if (w.windowID == 0 && existing.windowID != 0) {
                        w.windowID = existing.windowID;
                    }
                    uniqueWindows[idx] = w;
                }
            } else if (!existing.minimized && w.minimized) {
                /* keep visible entry; inherit order already */
                if (existing.seenOrder == 0 && w.seenOrder > 0) {
                    existing.seenOrder = w.seenOrder;
                }
            } else if (existing.seenOrder == 0 && w.seenOrder > 0) {
                existing.seenOrder = w.seenOrder;
            } else if (w.seenOrder > 0 && existing.seenOrder > 0) {
                existing.seenOrder = MIN(existing.seenOrder, w.seenOrder);
            }
            break;
        }
        if (pathTitleDup) {
            continue;
        }
        [keys addObject:key];
        [uniqueWindows addObject:w];
    }

    NSMutableArray<MLTaskbarItem *> *windowItems = [NSMutableArray array];
    CGWindowID frontWid = self.rebuildPassFrontmostValid
                              ? self.rebuildPassFrontmostWID
                              : [self frontmostTrackedWindowID];
    for (MLTaskbarWindowInfo *w in uniqueWindows) {
        NSString *display = [self displayNameForPath:w.path];
        NSString *title = w.title.length > 0 ? w.title : display;
        BOOL pinned = [self pinSet:pinSet containsPath:w.path];
        NSUInteger ord = w.seenOrder;
        if (ord == 0 && w.windowID != 0) {
            ord = priorOrderByWid[@(w.windowID)].unsignedIntegerValue;
        }
        if (ord == 0) {
            NSString *pt = [NSString stringWithFormat:@"%@|%@", w.path ?: @"", title ?: @""];
            ord = priorOrderByPathTitle[pt].unsignedIntegerValue;
        }
        BOOL active = !w.minimized && w.windowID != 0 && frontWid != 0 && w.windowID == frontWid;
        [windowItems addObject:[self itemWithPath:w.path
                                              pid:w.pid
                                         windowID:w.windowID
                                            title:title
                                             kind:MLTaskbarItemRunningWindow
                                           pinned:pinned
                                        minimized:w.minimized
                                           active:active
                                        seenOrder:ord]];
    }

    [windowItems sortUsingComparator:^NSComparisonResult(MLTaskbarItem *a, MLTaskbarItem *b) {
        if (a.seenOrder != b.seenOrder) {
            if (a.seenOrder == 0) {
                return NSOrderedDescending;
            }
            if (b.seenOrder == 0) {
                return NSOrderedAscending;
            }
            return a.seenOrder < b.seenOrder ? NSOrderedAscending : NSOrderedDescending;
        }
        return [a.title ?: @"" compare:b.title ?: @""];
    }];

    NSMutableArray<MLTaskbarItem *> *items = [NSMutableArray array];

    /*
     * Pinned launchers with no window chip on this screen stay at the leading
     * edge (pin order). Do NOT gate on runningSet: Electron apps (Cursor, etc.)
     * often keep a process alive after the last window closes — hiding the pin
     * then makes the icon vanish. Show the bare icon whenever this screen has
     * no window for that path; click will activate or open a new window.
     */
    NSMutableSet<NSString *> *pathsWithWindows = [NSMutableSet set];
    for (MLTaskbarWindowInfo *w in uniqueWindows) {
        if (w.path.length > 0) {
            [pathsWithWindows addObject:w.path];
            NSString *std = w.path.stringByStandardizingPath;
            if (std.length > 0) {
                [pathsWithWindows addObject:std];
            }
        }
    }
    for (NSString *path in pins) {
        if (path.length == 0) {
            continue;
        }
        NSString *std = path.stringByStandardizingPath;
        if ([pathsWithWindows containsObject:path] ||
            (std.length > 0 && [pathsWithWindows containsObject:std])) {
            continue;
        }
        pid_t pinPid = [self pidForPath:path snapshot:snap];
        [items addObject:[self itemWithPath:path
                                        pid:pinPid
                                   windowID:0
                                      title:[self displayNameForPath:path]
                                       kind:MLTaskbarItemPinnedOnly
                                     pinned:YES
                                  minimized:NO
                                     active:NO
                                  seenOrder:0]];
    }
    [items addObjectsFromArray:windowItems];

    items = [self fitItems:items toWidth:NSWidth(bar.barView.bounds) spacing:bar.barView.spacing
                    minWidth:bar.barView.itemMinWidth];
    bar.pendingItems = items;
}

- (NSInteger)windowChipCountOnBar:(MLTaskbarScreenBar *)bar {
    return [self windowChipCountInItems:bar.barView.items];
}

- (BOOL)displayedItemsContainWindowID:(CGWindowID)wid {
    if (wid == 0) {
        return NO;
    }
    for (MLTaskbarScreenBar *bar in self.bars) {
        for (MLTaskbarItem *it in bar.barView.items) {
            if (it.windowID == wid) {
                return YES;
            }
        }
    }
    return NO;
}

- (void)paintActiveHighlightForWindowID:(CGWindowID)frontWid {
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.barView) {
            continue;
        }
        BOOL changed = NO;
        for (MLTaskbarItem *it in bar.barView.items) {
            BOOL shouldActive = frontWid != 0 && it.kind == MLTaskbarItemRunningWindow &&
                                !it.minimized && it.windowID != 0 && it.windowID == frontWid;
            if (it.active != shouldActive) {
                it.active = shouldActive;
                changed = YES;
            }
        }
        for (MLTaskbarItem *it in bar.pendingItems) {
            BOOL shouldActive = frontWid != 0 && it.kind == MLTaskbarItemRunningWindow &&
                                !it.minimized && it.windowID != 0 && it.windowID == frontWid;
            it.active = shouldActive;
        }
        if (changed) {
            [bar.barView setNeedsDisplay:YES];
        }
    }
}

- (CGWindowID)windowIDOnBarsForPID:(pid_t)pid matchingTitle:(NSString *)focusTitle {
    if (pid <= 0 || focusTitle.length == 0) {
        return 0;
    }
    for (MLTaskbarScreenBar *bar in self.bars) {
        for (MLTaskbarItem *it in bar.barView.items) {
            if (it.pid != pid || it.windowID == 0 || it.title.length == 0) {
                continue;
            }
            if ([focusTitle isEqualToString:it.title] || [focusTitle hasPrefix:it.title] ||
                [it.title hasPrefix:focusTitle]) {
                return it.windowID;
            }
        }
    }
    return 0;
}

- (void)applyActiveHighlightForWindowID:(CGWindowID)hintWid {
    if (!self.started || self.itemsFrozenForDesktopReveal) {
        return;
    }
    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    pid_t frontPid = front.processIdentifier;
    CGWindowID frontWid = hintWid;
    if (frontWid == 0 || ![self displayedItemsContainWindowID:frontWid]) {
        if (AXIsProcessTrusted() && frontPid > 0) {
            CGWindowID axWid = [self.monitor focusedWindowIDForPID:frontPid];
            if (axWid != 0 && [self displayedItemsContainWindowID:axWid]) {
                frontWid = axWid;
            } else {
                NSString *axTitle = [self.monitor focusedWindowTitleForPID:frontPid];
                CGWindowID byTitle = [self windowIDOnBarsForPID:frontPid matchingTitle:axTitle];
                if (byTitle != 0) {
                    frontWid = byTitle;
                }
            }
        }
    }
    if (frontWid == 0 || ![self displayedItemsContainWindowID:frontWid]) {
        frontWid = [self frontmostTrackedWindowID];
    }
    [self paintActiveHighlightForWindowID:frontWid];
}

- (void)applyActiveHighlightImmediate {
    [self applyActiveHighlightForWindowID:0];
}

- (void)cancelItemsCommitTimer {
    [self.itemsCommitTimer invalidate];
    self.itemsCommitTimer = nil;
}

- (void)scheduleItemsCommitWithDelay:(NSTimeInterval)delay {
    [self cancelItemsCommitTimer];
    if (delay < 0.01) {
        [self commitPendingItemsForce:NO];
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.itemsCommitTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                             repeats:NO
                                                               block:^(__unused NSTimer *timer) {
                                                                   __strong typeof(weakSelf) self = weakSelf;
                                                                   if (!self) {
                                                                       return;
                                                                   }
                                                                   self.itemsCommitTimer = nil;
                                                                   [self commitPendingItemsForce:NO];
                                                               }];
    [[NSRunLoop mainRunLoop] addTimer:self.itemsCommitTimer forMode:NSRunLoopCommonModes];
}

/**
 * Paint pending → barView in one shot.
 * force=YES: pin / soft-min / user actions (skip reveal-hold).
 * force=NO: refuse large drops while desktop looks revealed — freeze instead.
 */
- (void)commitPendingItemsForce:(BOOL)force {
    if (!self.started) {
        return;
    }
    if (self.chipDragActive && !force) {
        return;
    }
    if (self.itemsFrozenForDesktopReveal) {
        [self restoreFrozenItemsOntoBars];
        return;
    }

    if (!force && [self looksLikeDesktopReveal] && [self totalWindowChipsOnBars] >= 1) {
        /* Keep displayed chips; enter peek freeze so monitor churn never paints. */
        [self freezeDesktopReveal];
        return;
    }

    NSInteger pendingWindows = 0;
    NSInteger shownWindows = 0;
    for (MLTaskbarScreenBar *bar in self.bars) {
        pendingWindows += [self windowChipCountInItems:bar.pendingItems];
        shownWindows += [self windowChipCountOnBar:bar];
    }
    /* Large chip drop while reveal-armed → freeze only with Show Desktop evidence.
     * Closing windows (pending empties without parked windows) must paint normally —
     * never treat "chips went to zero" as peek. */
    if (!force && shownWindows >= 2 && pendingWindows + 1 < shownWindows &&
        [self isDesktopRevealArmed] &&
        ![self shouldIgnoreDesktopRevealBecauseAllMinimized] &&
        ([self looksLikeDesktopReveal] || [self shouldFreezeForDesktopReveal])) {
        [self freezeDesktopReveal];
        return;
    }

    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (!force && now < self.stickyDisplayUntil) {
        NSInteger expect = MAX(self.lastStableLiveWindowCount, shownWindows);
        if (expect >= 2 && pendingWindows + 1 < expect) {
            CGFloat cover = 0;
            NSInteger onScreen = 0;
            NSInteger all = 0;
            [self measureDesktopRevealWithCenterCover:&cover onScreen:&onScreen all:&all];
            BOOL newReality = (cover >= 0.15 && onScreen <= pendingWindows + 1 &&
                               all <= pendingWindows + 1);
            if (!newReality) {
                /* Windows still flying back — keep old chips, try again after quiet. */
                [self scheduleItemsCommitWithDelay:MLTaskbarItemsCommitDelay];
                return;
            }
        }
        /* Same count but wrong screens (peek parking) — refuse cross-screen hop. */
        if ([self pendingMovesChipsAcrossScreens]) {
            [self scheduleItemsCommitWithDelay:MLTaskbarItemsCommitDelay];
            return;
        }
    }

    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.barView || !bar.pendingItems) {
            continue;
        }
        bar.barView.items = bar.pendingItems;
        NSInteger windowChips = [self windowChipCountOnBar:bar];
        if (bar.screenID && windowChips > 0) {
            self.lastStableWindowCountByScreen[bar.screenID] = @(windowChips);
        } else if (bar.screenID && ![self looksLikeDesktopReveal]) {
            self.lastStableWindowCountByScreen[bar.screenID] = @(windowChips);
        }
    }
    [self rememberChipScreenAffinityFromBars];
}

- (void)computePendingItemsForAllBars {
    self.rebuildPassFrontmostWID = [self frontmostTrackedWindowID];
    self.rebuildPassFrontmostValid = YES;
    NSDictionary<NSNumber *, NSScreen *> *screensByID = [self screensByID];
    for (MLTaskbarScreenBar *bar in self.bars) {
        NSScreen *screen = screensByID[bar.screenID];
        if (screen) {
            [self rebuildItemsForBar:bar screen:screen];
        }
    }
    self.rebuildPassFrontmostValid = NO;
}

/**
 * @param immediate YES = paint now (pin / soft-min). NO = debounce (monitor / Show Desktop churn).
 * Monitor paths must use NO so Show Desktop can freeze before chips morph.
 */
- (void)rebuildItemsImmediate:(BOOL)immediate {
    if (!self.started) {
        return;
    }
    if (self.chipDragActive) {
        return;
    }
    if (self.itemsFrozenForDesktopReveal) {
        if ([self shouldUnfreezeDesktopReveal]) {
            [self unfreezeDesktopRevealAndRefresh];
            return;
        }
        [self restoreFrozenItemsOntoBars];
        return;
    }
    if ([self shouldFreezeForDesktopReveal]) {
        [self freezeDesktopReveal];
        return;
    }
    [self computePendingItemsForAllBars];
    if (immediate) {
        [self cancelItemsCommitTimer];
        /* force=YES only for intentional user-driven paints (pin / soft-min callers). */
        [self commitPendingItemsForce:YES];
    } else {
        [self scheduleItemsCommitWithDelay:MLTaskbarItemsCommitDelay];
    }
}

- (void)rebuildItems {
    /* Always debounce — coalesces Show Desktop window-list churn before paint. */
    [self rebuildItemsImmediate:NO];
}

- (NSMutableArray<MLTaskbarItem *> *)fitItems:(NSMutableArray<MLTaskbarItem *> *)items
                                      toWidth:(CGFloat)width
                                      spacing:(CGFloat)spacing
                                     minWidth:(CGFloat)minW {
    if (width < 32.0 || items.count == 0) {
        return items;
    }
    /* Pinned-only slots are bare icons (~iconSize+4); window chips use minW. */
    CGFloat pinnedW = 36.0;
    CGFloat avail = width - 6.0;
    while (items.count > 0) {
        CGFloat need = 0;
        NSUInteger n = items.count;
        for (NSUInteger i = 0; i < n; i++) {
            MLTaskbarItem *it = items[i];
            CGFloat w = (it.kind == MLTaskbarItemPinnedOnly) ? pinnedW : minW;
            need += w;
            if (i + 1 < n) {
                need += spacing;
            }
        }
        if (need <= avail) {
            break;
        }
        NSInteger drop = -1;
        for (NSInteger i = (NSInteger)items.count - 1; i >= 0; i--) {
            if (!items[(NSUInteger)i].pinned) {
                drop = i;
                break;
            }
        }
        if (drop < 0) {
            break;
        }
        [items removeObjectAtIndex:(NSUInteger)drop];
    }
    return items;
}

@end
