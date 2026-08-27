#import "MLTaskbarController+Private.h"

#import "MLDebugLog.h"
#import "MLScreenGeometry.h"

#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>

@implementation MLTaskbarController (Peek)

- (void)restoreFrozenItemsOntoBars {
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.screenID || !bar.barView) {
            continue;
        }
        NSArray<MLTaskbarItem *> *frozen = self.frozenItemsByScreenID[bar.screenID];
        if (frozen) {
            bar.barView.items = frozen;
            bar.pendingItems = frozen;
        }
    }
}

- (BOOL)isDesktopRevealArmed {
    if (self.desktopRevealArmTime <= 0) {
        return NO;
    }
    return [NSDate date].timeIntervalSinceReferenceDate >= self.desktopRevealArmTime;
}

/**
 * Scan app windows: center coverage (0…1 max across screens), on-screen count,
 * and all-spaces count (includes Show Desktop off-screen / edge windows).
 */
- (void)measureDesktopRevealWithCenterCover:(CGFloat *)outCover
                                   onScreen:(NSInteger *)outOnScreen
                                        all:(NSInteger *)outAll {
    __block CGFloat maxCover = 0.0;
    __block NSInteger onScreen = 0;
    __block NSInteger all = 0;
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;

    void (^consume)(CFDictionaryRef, BOOL) = ^(CFDictionaryRef info, BOOL countAllOnly) {
        if (!info) {
            return;
        }
        CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        pid_t pid = 0;
        if (pidRef) {
            CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
        }
        if (pid <= 0 || pid == selfPid) {
            return;
        }
        CFStringRef ownerRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (ownerRef && CFGetTypeID(ownerRef) == CFStringGetTypeID()) {
            NSString *owner = (__bridge NSString *)ownerRef;
            if ([[self class] isSystemWindowOwner:owner] ||
                [owner isEqualToString:@"Finder"]) {
                return;
            }
        }
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        int layer = 0;
        if (layerRef) {
            CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        }
        if (layer != 0) {
            return;
        }
        CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (alphaRef) {
            double alpha = 1.0;
            CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
            if (alpha < 0.2) {
                return;
            }
        }
        CGRect boundsQ = CGRectZero;
        CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &boundsQ)) {
            return;
        }
        if (boundsQ.size.width < 60.0 || boundsQ.size.height < 40.0) {
            return;
        }
        if (countAllOnly) {
            all += 1;
            return;
        }
        NSRect bounds = [MLScreenGeometry cocoaRectFromQuartzBounds:boundsQ];
        onScreen += 1;
        for (NSScreen *screen in NSScreen.screens) {
            NSRect sf = screen.frame;
            NSRect center = NSInsetRect(sf, NSWidth(sf) * 0.18, NSHeight(sf) * 0.18);
            NSRect hit = NSIntersectionRect(bounds, center);
            if (NSIsEmptyRect(hit)) {
                continue;
            }
            CGFloat area = NSWidth(center) * NSHeight(center);
            if (area < 1.0) {
                continue;
            }
            CGFloat cover = (NSWidth(hit) * NSHeight(hit)) / area;
            if (cover > maxCover) {
                maxCover = cover;
            }
        }
    };

    CFArrayRef onList = [self.monitor.windowCensus cachedOnScreenWindowListRefreshingIfNeeded:YES];
    if (onList) {
        CFIndex count = CFArrayGetCount(onList);
        for (CFIndex i = 0; i < count; i++) {
            consume((CFDictionaryRef)CFArrayGetValueAtIndex(onList, i), NO);
        }
    }
    CFArrayRef allList = [self.monitor.windowCensus cachedAllWindowListRefreshingIfNeeded:YES];
    if (allList) {
        CFIndex count = CFArrayGetCount(allList);
        for (CFIndex i = 0; i < count; i++) {
            consume((CFDictionaryRef)CFArrayGetValueAtIndex(allList, i), YES);
        }
    }

    if (outCover) {
        *outCover = maxCover;
    }
    if (outOnScreen) {
        *outOnScreen = onScreen;
    }
    if (outAll) {
        *outAll = all;
    }
}

- (void)updateStableLiveCensus {
    if (self.itemsFrozenForDesktopReveal) {
        return;
    }
    NSInteger live = [self liveNonMinimizedWindowCount];
    if (live > 0) {
        self.lastStableLiveWindowCount = live;
    }
}

- (NSInteger)frozenWindowChipTotal {
    NSInteger n = 0;
    for (NSNumber *sid in self.frozenItemsByScreenID) {
        for (MLTaskbarItem *it in self.frozenItemsByScreenID[sid] ?: @[]) {
            if (it.kind == MLTaskbarItemRunningWindow) {
                n += 1;
            }
        }
    }
    return n;
}

- (BOOL)shouldUnfreezeDesktopReveal {
    if (!self.itemsFrozenForDesktopReveal) {
        return NO;
    }

    /*
     * User-armed peek: exit only when a real window is back on-screen (chip restore),
     * or via second desktop click (handleDesktopPeekClick → unfreeze directly).
     * Must run before isDesktopRevealArmed — startup arm time must not bounce peek.
     */
    /*
     * User-armed peek exits ONLY via second desktop click (handleDesktopPeekClick)
     * or chip restore (activateOrLaunchItem → unfreeze). Never auto-unfreeze from
     * cover/live census — that caused down → up → down on desktop click.
     */
    if (self.desktopPeekUserArmed) {
        return NO;
    }

    if (![self isDesktopRevealArmed]) {
        return YES;
    }
    CGFloat cover = 0;
    NSInteger onScreen = 0;
    NSInteger all = 0;
    [self measureDesktopRevealWithCenterCover:&cover onScreen:&onScreen all:&all];

    /* Minimize-only empty desktop (no Show Desktop evidence) — leave peek. */
    if ([self shouldIgnoreDesktopRevealBecauseAllMinimized]) {
        return YES;
    }

    /*
     * CG list empty can mean Show Desktop parked windows were filtered (alpha/size),
     * not "truly empty". Keep peek while we still hold frozen chips and desktop is clear.
     */
    if (all < 1 && onScreen < 1) {
        if ([self frozenWindowChipTotal] >= 1 && cover < 0.14) {
            return NO;
        }
        return YES;
    }
    /* Windows back covering the desktop center. */
    if (cover >= 0.18) {
        return YES;
    }
    NSInteger liveOn = [self liveOnScreenNonMinimizedWindowCount];
    if (liveOn >= 1 && cover >= 0.10) {
        return YES;
    }
    if (liveOn >= MAX(1, self.freezeLiveBaseline) && onScreen >= liveOn) {
        return YES;
    }
    return NO;
}

- (void)freezeDesktopReveal {
    [self freezeDesktopRevealApplyingPresentation:YES];
}

- (void)freezeDesktopRevealApplyingPresentation:(BOOL)applyPresentation {
    if (self.itemsFrozenForDesktopReveal) {
        [self restoreFrozenItemsOntoBars];
        if (applyPresentation && !self.desktopPeekClickInProgress) {
            [self applyPeekFramesIfDrifted];
        }
        return;
    }
    if (![self isDesktopRevealArmed]) {
        return;
    }
    /*
     * Passive minimize-all must not freeze. User-armed desktop peek sets
     * desktopPeekUserArmed first and must always be allowed through.
     */
    if (!self.desktopPeekUserArmed &&
        [self shouldIgnoreDesktopRevealBecauseAllMinimized]) {
        MLDebugLog(@"[Taskbar] desktop reveal freeze skipped — all minimized/soft-hidden");
        return;
    }
    [self cancelChipDragSession];
    [self cancelItemsCommitTimer];
    [self.frozenItemsByScreenID removeAllObjects];
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (!bar.screenID || !bar.barView) {
            continue;
        }
        NSArray<MLTaskbarItem *> *shot = [self deepCopyItems:bar.barView.items];
        self.frozenItemsByScreenID[bar.screenID] = shot;
        bar.pendingItems = shot;
        NSInteger chips = [self windowChipCountOnBar:bar];
        if (chips > 0) {
            self.lastStableWindowCountByScreen[bar.screenID] = @(chips);
        }
    }
    self.freezeLiveBaseline = MAX(self.lastStableLiveWindowCount, [self frozenWindowChipTotal]);
    self.itemsFrozenForDesktopReveal = YES;
    NSMutableSet<NSNumber *> *all = [NSMutableSet set];
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (bar.screenID) {
            [all addObject:bar.screenID];
        }
    }
    self.desktopRevealScreenIDs = all;
    self.fullscreenScreenIDs = [NSSet set];
    [self rememberChipScreenAffinityFromFrozenShots];
    MLDebugLog(@"[Taskbar] desktop reveal FREEZE baseline=%ld chips=%ld userArmed=%d",
          (long)self.freezeLiveBaseline, (long)[self frozenWindowChipTotal],
          (int)self.desktopPeekUserArmed);
    if (applyPresentation && !self.desktopPeekClickInProgress) {
        [self applyPeekFramesIfDrifted];
    }
}

- (void)unfreezeDesktopRevealAndRefresh {
    BOOL needsRestore = self.itemsFrozenForDesktopReveal || self.desktopPeekUserArmed ||
                        self.desktopRevealScreenIDs.count > 0;
    if (!needsRestore) {
        for (MLTaskbarScreenBar *bar in self.bars) {
            if (bar.mode == MLTaskbarBarModePeek || [self barWindowIsAtPeekOffset:bar]) {
                needsRestore = YES;
                break;
            }
        }
    }
    if (!needsRestore) {
        return;
    }

    BOOL userPeekExit = self.desktopPeekUserArmed;
    NSSet<NSNumber *> *wasReveal = [self.desktopRevealScreenIDs copy] ?: [NSSet set];
    self.itemsFrozenForDesktopReveal = NO;
    self.desktopRevealScreenIDs = [NSSet set];
    self.desktopPeekUserArmed = NO;
    self.desktopPeekClickInProgress = NO;
    self.freezeLiveBaseline = 0;
    /* Keep frozenItems until first successful commit so a partial live list cannot paint. */
    NSDictionary<NSNumber *, NSArray<MLTaskbarItem *> *> *hold =
        [self.frozenItemsByScreenID copy] ?: @{};
    [self.frozenItemsByScreenID removeAllObjects];

    /*
     * Peek exit: show every taskbar at normal Y — do not let fullscreen heuristics
     * orderOut/orderFront bars during settle (hide-flash-hide).
     */
    [self.fullscreenHideStreaks removeAllObjects];
    self.fullscreenScreenIDs = [NSSet set];
    (void)wasReveal;
    (void)userPeekExit;

    NSDictionary<NSNumber *, NSScreen *> *screensByID = [self screensByID];
    for (MLTaskbarScreenBar *bar in self.bars) {
        NSScreen *screen = screensByID[bar.screenID];
        if (!screen || !bar.window) {
            continue;
        }
        bar.mode = MLTaskbarBarModeNormal;
        [self applyPeekPresentationForBar:bar peeking:NO animated:NO];
        bar.barView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        bar.barView.frame = bar.window.contentView.bounds;
        NSArray<MLTaskbarItem *> *kept = hold[bar.screenID];
        if (kept.count > 0) {
            bar.barView.items = kept;
            bar.pendingItems = kept;
        }
    }
    MLFlushTaskbarWindows(self.bars);
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (bar.window) {
            [bar.window orderFrontRegardless];
        }
    }

    self.stickyDisplayUntil = [NSDate date].timeIntervalSinceReferenceDate + 1.25;
    [self cancelItemsCommitTimer];
    __weak typeof(self) weakSelf = self;
    self.itemsCommitTimer = [NSTimer scheduledTimerWithTimeInterval:MLTaskbarExitSettleDelay
                                                             repeats:NO
                                                               block:^(__unused NSTimer *timer) {
                                                                   __strong typeof(weakSelf) self = weakSelf;
                                                                   if (!self) {
                                                                       return;
                                                                   }
                                                                   self.itemsCommitTimer = nil;
                                                                   if (self.itemsFrozenForDesktopReveal) {
                                                                       return;
                                                                   }
                                                                   [self computePendingItemsForAllBars];
                                                                   [self commitPendingItemsForce:YES];
                                                               }];
    [[NSRunLoop mainRunLoop] addTimer:self.itemsCommitTimer forMode:NSRunLoopCommonModes];
    [self updateStableLiveCensus];
    MLDebugLog(@"[Taskbar] desktop reveal UNFREEZE + settle commit");
}

- (BOOL)isInPeekExitSettlePeriod {
    if (self.stickyDisplayUntil <= 0) {
        return NO;
    }
    return [NSDate date].timeIntervalSinceReferenceDate < self.stickyDisplayUntil;
}

- (void)flushAllTaskbarWindows {
    MLFlushTaskbarWindows(self.bars);
}

- (NSInteger)liveNonMinimizedWindowCount {
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    NSSet<NSNumber *> *softHidden = [self.monitor.softState softHiddenWindowIDs] ?: [NSSet set];
    NSInteger n = 0;
    for (MLTaskbarWindowInfo *w in self.monitor.snapshot.windows ?: @[]) {
        if (w.pid == selfPid || w.minimized) {
            continue;
        }
        /* Soft-hidden may still appear in a stale snapshot row as minimized=NO. */
        if (w.windowID != 0 && [softHidden containsObject:@(w.windowID)]) {
            continue;
        }
        n += 1;
    }
    return n;
}

/**
 * Non-minimized windows that still clearly occupy a display.
 * Show Desktop parks windows off-screen without minimized=YES — those must NOT
 * block peek freeze (unlike restore-from-minimize, which has real on-screen bounds).
 */
- (NSInteger)liveOnScreenNonMinimizedWindowCount {
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    NSSet<NSNumber *> *softHidden = [self.monitor.softState softHiddenWindowIDs] ?: [NSSet set];
    NSInteger n = 0;
    for (MLTaskbarWindowInfo *w in self.monitor.snapshot.windows ?: @[]) {
        if (w.pid == selfPid || w.minimized) {
            continue;
        }
        if (w.windowID != 0 && [softHidden containsObject:@(w.windowID)]) {
            continue;
        }
        if (![self boundsClearlyOnAScreen:w.bounds]) {
            continue;
        }
        n += 1;
    }
    return n;
}

/**
 * Hidden window IDs = soft-hidden ∪ snapshot minimized.
 * Used to tell "all minimized" apart from Show Desktop parked ghosts.
 */
- (NSSet<NSNumber *> *)hiddenTaskWindowIDSet {
    NSMutableSet<NSNumber *> *hidden = [NSMutableSet set];
    NSSet<NSNumber *> *soft = [self.monitor.softState softHiddenWindowIDs];
    if (soft.count > 0) {
        [hidden unionSet:soft];
    }
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    for (MLTaskbarWindowInfo *w in self.monitor.snapshot.windows ?: @[]) {
        if (w.pid == selfPid || !w.minimized || w.windowID == 0) {
            continue;
        }
        [hidden addObject:@(w.windowID)];
    }
    return hidden;
}

/**
 * YES when every window chip on the bars is minimized or soft-hidden.
 * Show Desktop freezes BEFORE chip flags flip, so chips stay "live" there —
 * that is the reliable difference from minimize-all.
 */
- (BOOL)allDisplayedWindowChipsAreHidden {
    NSSet<NSNumber *> *softHidden = [self.monitor.softState softHiddenWindowIDs] ?: [NSSet set];
    NSInteger chips = 0;
    NSInteger hidden = 0;
    for (MLTaskbarScreenBar *bar in self.bars) {
        for (MLTaskbarItem *it in bar.barView.items ?: @[]) {
            if (it.kind != MLTaskbarItemRunningWindow) {
                continue;
            }
            chips += 1;
            BOOL isHidden = it.minimized;
            if (!isHidden && it.windowID != 0 && [softHidden containsObject:@(it.windowID)]) {
                isHidden = YES;
            }
            if (isHidden) {
                hidden += 1;
            }
        }
    }
    return chips >= 1 && hidden == chips;
}

/**
 * Count layer-0 app windows that are off-screen and NOT in our hidden set.
 * Show Desktop parks real windows off-screen without marking them minimized;
 * those show up here. Helper/AX-min extras must not use a raw `all > minimized`
 * count (that false-triggered peek three times already).
 */
- (NSInteger)countForeignOffscreenWindowsExcluding:(NSSet<NSNumber *> *)hiddenIDs {
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    NSInteger foreign = 0;
    CFArrayRef allList = [self.monitor.windowCensus cachedAllWindowListRefreshingIfNeeded:YES];
    if (!allList) {
        return 0;
    }
    CFIndex count = CFArrayGetCount(allList);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(allList, i);
        if (!info) {
            continue;
        }
        CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        pid_t pid = 0;
        if (pidRef) {
            CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
        }
        if (pid <= 0 || pid == selfPid) {
            continue;
        }
        CFStringRef ownerRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
        if (ownerRef && CFGetTypeID(ownerRef) == CFStringGetTypeID()) {
            NSString *owner = (__bridge NSString *)ownerRef;
            if ([[self class] isSystemWindowOwner:owner] ||
                [owner isEqualToString:@"Finder"]) {
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
        CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (alphaRef) {
            double alpha = 1.0;
            CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
            if (alpha < 0.2) {
                continue;
            }
        }
        CGRect boundsQ = CGRectZero;
        CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &boundsQ)) {
            continue;
        }
        if (boundsQ.size.width < 60.0 || boundsQ.size.height < 40.0) {
            continue;
        }
        CFNumberRef numRef = CFDictionaryGetValue(info, kCGWindowNumber);
        CGWindowID wid = 0;
        if (numRef) {
            int64_t wid64 = 0;
            if (CFNumberGetValue(numRef, kCFNumberSInt64Type, &wid64) && wid64 > 0) {
                wid = (CGWindowID)wid64;
            }
        }
        if (wid != 0 && hiddenIDs && [hiddenIDs containsObject:@(wid)]) {
            continue;
        }
        CFBooleanRef onscreenRef = CFDictionaryGetValue(info, kCGWindowIsOnscreen);
        BOOL onscreen = (onscreenRef && CFBooleanGetValue(onscreenRef));
        if (onscreen) {
            continue;
        }
        foreign += 1;
    }
    return foreign;
}

/**
 * Passive minimize-all / soft-min state.
 * Absolute: this state must never enter peek unless desktopPeekUserArmed.
 */
- (BOOL)isPassiveMinimizeAllState {
    /* Chips already (or via softState) look minimized — strongest signal. */
    if ([self allDisplayedWindowChipsAreHidden]) {
        return YES;
    }
    NSSet<NSNumber *> *hiddenIDs = [self hiddenTaskWindowIDSet];
    if (hiddenIDs.count < 1) {
        return NO;
    }
    /*
     * Soft/min recorded for every chip even if chip.minimized flag lagged.
     * Do not require live==0 first — stale snapshot rows used to block this.
     */
    NSInteger chips = 0;
    NSInteger covered = 0;
    for (MLTaskbarScreenBar *bar in self.bars) {
        for (MLTaskbarItem *it in bar.barView.items ?: @[]) {
            if (it.kind != MLTaskbarItemRunningWindow) {
                continue;
            }
            chips += 1;
            if (it.minimized ||
                (it.windowID != 0 && [hiddenIDs containsObject:@(it.windowID)])) {
                covered += 1;
            }
        }
    }
    if (chips >= 1 && covered == chips) {
        return YES;
    }
    /* No live windows left and we have soft/min tracking. */
    if ([self liveNonMinimizedWindowCount] < 1) {
        return YES;
    }
    return NO;
}

/**
 * Positive Show Desktop evidence: layer-0 app windows parked off-screen that are
 * NOT in our soft-hidden / minimized set.
 * Only used when chips still look live (not for minimize-all).
 */
- (BOOL)hasShowDesktopParkedEvidence {
    if ([self isPassiveMinimizeAllState]) {
        return NO;
    }
    NSSet<NSNumber *> *hiddenIDs = [self hiddenTaskWindowIDSet];
    NSInteger foreignOff = [self countForeignOffscreenWindowsExcluding:hiddenIDs];
    if (foreignOff < 1) {
        return NO;
    }
    CGFloat cover = 0;
    NSInteger onScreen = 0;
    NSInteger all = 0;
    [self measureDesktopRevealWithCenterCover:&cover onScreen:&onScreen all:&all];
    return cover < 0.14;
}

/**
 * When YES, refuse peek / leave peek.
 *
 * User rule: minimize-all OR all windows closed → bar stays put.
 * Only desktop click (desktopPeekUserArmed) may peek over an empty/minimized desktop.
 * Show Desktop still auto-peeks: parked windows remain non-minimized in the snapshot.
 *
 * NEVER let "foreign off-screen helper windows" override minimize-all — that was
 * why the bar slid down and stuck.
 */
- (BOOL)shouldIgnoreDesktopRevealBecauseAllMinimized {
    if (self.desktopPeekUserArmed) {
        return NO;
    }
    if ([self isPassiveMinimizeAllState]) {
        return YES;
    }
    /*
     * All windows closed: nothing live on-screen and no parked non-minimized
     * ghosts (Show Desktop keeps those). Chips may still paint until commit —
     * still refuse auto-peek so closing the last window cannot half-drop the bar.
     */
    if ([self liveOnScreenNonMinimizedWindowCount] < 1 &&
        [self liveNonMinimizedWindowCount] < 1) {
        return YES;
    }
    return NO;
}

- (NSInteger)totalWindowChipsOnBars {
    NSInteger n = 0;
    for (MLTaskbarScreenBar *bar in self.bars) {
        n += [self windowChipCountOnBar:bar];
    }
    return n;
}

/** Desktop center clear while app windows still exist somewhere (Show Desktop / Exposé). */
- (BOOL)looksLikeDesktopReveal {
    if (![self isDesktopRevealArmed]) {
        return NO;
    }
    if ([self shouldIgnoreDesktopRevealBecauseAllMinimized]) {
        return NO;
    }
    /* live→0 with soft/min or hidden chips = minimize, never "looks like" Show Desktop. */
    if ([self isPassiveMinimizeAllState]) {
        return NO;
    }
    /*
     * Only on-screen live blocks reveal. Off-screen parked (Show Desktop) windows
     * still appear in the snapshot as non-minimized — must not suppress peek.
     */
    if ([self liveOnScreenNonMinimizedWindowCount] >= 1) {
        return NO;
    }
    if ([self hasShowDesktopParkedEvidence]) {
        return YES;
    }
    CGFloat cover = 0;
    NSInteger onScreen = 0;
    NSInteger all = 0;
    [self measureDesktopRevealWithCenterCover:&cover onScreen:&onScreen all:&all];
    if (all < 1) {
        return NO;
    }
    /* Require live-looking chips and no soft/min tracking — not live→0 alone. */
    if ([self allDisplayedWindowChipsAreHidden]) {
        return NO;
    }
    if ([self hiddenTaskWindowIDSet].count >= 1) {
        return NO;
    }
    if (cover < 0.14 && onScreen <= 1) {
        return YES;
    }
    if (cover < 0.10) {
        return YES;
    }
    return NO;
}

/**
 * Show Desktop auto-freeze. Never for minimize-all (soft/min/hidden chips).
 * Peek over minimize-all is only via handleDesktopPeekClick → desktopPeekUserArmed.
 * Use on-screen live only — parked Show Desktop windows must not block freeze.
 */
- (BOOL)shouldFreezeForDesktopReveal {
    if (![self isDesktopRevealArmed] || self.itemsFrozenForDesktopReveal) {
        return NO;
    }
    if ([self shouldIgnoreDesktopRevealBecauseAllMinimized]) {
        return NO;
    }
    if ([self isPassiveMinimizeAllState]) {
        return NO;
    }
    /* Real on-screen windows (restore / normal desktop) — never auto-peek. */
    if ([self liveOnScreenNonMinimizedWindowCount] >= 1) {
        return NO;
    }
    if (self.lastStableLiveWindowCount < 1 && [self totalWindowChipsOnBars] < 1) {
        return NO;
    }

    /* Soft/min in flight or settled — not Show Desktop. */
    if ([self hiddenTaskWindowIDSet].count >= 1 || [self allDisplayedWindowChipsAreHidden]) {
        return NO;
    }

    if ([self hasShowDesktopParkedEvidence]) {
        return YES;
    }

    CGFloat cover = 0;
    NSInteger onScreen = 0;
    NSInteger all = 0;
    [self measureDesktopRevealWithCenterCover:&cover onScreen:&onScreen all:&all];

    /* Windows still exist but desktop center is clear → Show Desktop / Exposé.
     * Require live-looking chips — all-closed (chips gone) is never auto-peek. */
    if ([self totalWindowChipsOnBars] < 1) {
        return NO;
    }
    if (cover < 0.14 && all >= 1) {
        if (onScreen < MAX(1, self.lastStableLiveWindowCount) || onScreen == 0 || cover < 0.08) {
            return YES;
        }
    }
    if (cover < 0.14 && all >= 1 && onScreen == 0) {
        return YES;
    }
    return NO;
}

#pragma mark - Peek frame authority

/** Single source of truth: frozen reveal or user just armed via desktop click. */
- (BOOL)taskbarRequiresPeekFramePresentation {
    return self.itemsFrozenForDesktopReveal || self.desktopPeekUserArmed;
}

- (NSScreen *)screenForBar:(MLTaskbarScreenBar *)bar {
    if (!bar.screenID) {
        return bar.window.screen ?: NSScreen.mainScreen;
    }
    for (NSScreen *s in NSScreen.screens) {
        if ([[[self class] screenIDForScreen:s] isEqualToNumber:bar.screenID]) {
            return s;
        }
    }
    return bar.window.screen ?: NSScreen.mainScreen;
}

- (NSRect)peekTargetFrameForBar:(MLTaskbarScreenBar *)bar peeking:(BOOL)peeking {
    NSScreen *screen = [self screenForBar:bar];
    if (!screen) {
        return bar.window.frame;
    }
    CGFloat height = [self barHeightForBar:bar];
    NSRect home = [self normalFrameForScreen:screen height:height];
    if (!peeking) {
        return home;
    }
    home.origin.y -= (CGFloat)MLTaskbarPeekOffset;
    return home;
}

- (BOOL)barWindowIsAtPeekOffset:(MLTaskbarScreenBar *)bar {
    if (!bar.window) {
        return NO;
    }
    NSRect target = [self peekTargetFrameForBar:bar peeking:YES];
    return fabs(NSMinY(bar.window.frame) - NSMinY(target)) < 0.5;
}

- (void)cancelPeekFrameAnimationsForBar:(MLTaskbarScreenBar *)bar {
    if (!bar.window) {
        return;
    }
    bar.peekPresentationGeneration += 1;
    NSRect frame = bar.window.frame;
    [bar.window setFrame:frame display:YES];
    if (bar.barView) {
        bar.barView.frame = bar.window.contentView.bounds;
    }
}

/**
 * Apply the frame that matches itemsFrozenForDesktopReveal — never bar.mode alone.
 */
- (void)applyAuthoritativePeekFrameForBar:(MLTaskbarScreenBar *)bar animated:(BOOL)animated {
    if (!bar.window || !bar.barView) {
        return;
    }
    BOOL shouldPeek = [self taskbarRequiresPeekFramePresentation];
    if (shouldPeek) {
        bar.mode = MLTaskbarBarModePeek;
    } else if (bar.mode == MLTaskbarBarModePeek) {
        bar.mode = MLTaskbarBarModeNormal;
    }
    [self applyPeekPresentationForBar:bar peeking:shouldPeek animated:animated];
}

/** Snap any bar that is visually peeking while not frozen (stale animator / mode drift). */
- (void)reconcileOrphanPeekFramesAnimated:(BOOL)animated {
    if ([self taskbarRequiresPeekFramePresentation]) {
        return;
    }
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (bar.mode == MLTaskbarBarModePeek) {
            bar.mode = MLTaskbarBarModeNormal;
        }
        if (!bar.window || bar.mode == MLTaskbarBarModeHidden) {
            continue;
        }
        if ([self barWindowIsAtPeekOffset:bar]) {
            [self applyPeekPresentationForBar:bar peeking:NO animated:animated];
        }
    }
}

- (void)applyPeekPresentationForBar:(MLTaskbarScreenBar *)bar
                            peeking:(BOOL)peeking
                           animated:(BOOL)animated {
    if (!bar.window || !bar.barView) {
        return;
    }
    NSScreen *screen = [self screenForBar:bar];
    if (!screen) {
        return;
    }

    NSRect target = [self peekTargetFrameForBar:bar peeking:peeking];
    bar.barView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    if (fabs(NSMinY(bar.window.frame) - NSMinY(target)) < 0.5 &&
        fabs(NSWidth(bar.window.frame) - NSWidth(target)) < 0.5 &&
        fabs(NSHeight(bar.window.frame) - NSHeight(target)) < 0.5) {
        bar.barView.frame = bar.window.contentView.bounds;
        return;
    }

    NSUInteger generation = 0;
    BOOL shouldAnimate = animated && bar.window.isVisible &&
                         fabs(NSMinY(bar.window.frame) - NSMinY(target)) > 0.5;
    if (shouldAnimate) {
        [self cancelPeekFrameAnimationsForBar:bar];
        generation = bar.peekPresentationGeneration;
        __weak typeof(self) weakSelf = self;
        __weak MLTaskbarScreenBar *weakBar = bar;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.18;
            [[bar.window animator] setFrame:target display:YES];
        } completionHandler:^{
            __strong typeof(weakSelf) self = weakSelf;
            MLTaskbarScreenBar *strongBar = weakBar;
            if (!self || !strongBar || strongBar.peekPresentationGeneration != generation) {
                return;
            }
            BOOL shouldPeek = [self taskbarRequiresPeekFramePresentation];
            if (shouldPeek != peeking) {
                [self applyAuthoritativePeekFrameForBar:strongBar animated:NO];
                return;
            }
            [strongBar.window setFrame:target display:YES];
            strongBar.barView.frame = strongBar.window.contentView.bounds;
        }];
    } else {
        bar.peekPresentationGeneration += 1;
        CGFloat beforeY = NSMinY(bar.window.frame);
        [bar.window setFrame:target display:NO];
        bar.barView.frame = bar.window.contentView.bounds;
        if (peeking && (beforeY - NSMinY(target)) > 0.5) {
            self.peekFrameDownApplyCount += 1;
        }
    }
}

static void MLFlushTaskbarWindows(NSArray<MLTaskbarScreenBar *> *bars) {
    for (MLTaskbarScreenBar *bar in bars) {
        if (bar.window) {
            [bar.window displayIfNeeded];
        }
    }
}

/** Move bars to peek Y only when not already there — safe to call repeatedly. */
- (void)applyPeekFramesIfDrifted {
    if (![self taskbarRequiresPeekFramePresentation]) {
        return;
    }
    NSDictionary<NSNumber *, NSScreen *> *screensByID = [self screensByID];
    BOOL moved = NO;
    for (MLTaskbarScreenBar *bar in self.bars) {
        NSScreen *screen = screensByID[bar.screenID];
        if (!screen || !bar.window) {
            continue;
        }
        bar.mode = MLTaskbarBarModePeek;
        if ([self barWindowIsAtPeekOffset:bar]) {
            continue;
        }
        [self applyPeekPresentationForBar:bar peeking:YES animated:NO];
        moved = YES;
    }
    if (moved) {
        MLFlushTaskbarWindows(self.bars);
        for (MLTaskbarScreenBar *bar in self.bars) {
            if (bar.window) {
                [bar.window orderFrontRegardless];
            }
        }
    }
    [self updateVisibilitySafetyTimer];
}

/**
 * Force every bar into peek chrome. Used only for user-armed desktop click —
 * must not be gated by minimize-all ignore heuristics.
 */
- (void)applyUserArmedPeekPresentationAnimated:(BOOL)animated {
    (void)animated;
    if (![self taskbarRequiresPeekFramePresentation]) {
        [self reconcileOrphanPeekFramesAnimated:NO];
        return;
    }
    [self applyPeekFramesIfDrifted];
    for (MLTaskbarScreenBar *bar in self.bars) {
        if (bar.window && bar.window.isVisible) {
            [bar.window orderFrontRegardless];
        }
    }
}
- (void)handleDesktopPeekClickAtCocoaPoint:(NSPoint)cocoaPoint {
    if (!self.started || !self.enabled) {
        return;
    }
    if (![self isDesktopRevealArmed]) {
        return;
    }
    /* Chip / bar clicks restore windows — never arm or toggle peek. */
    if ([self cocoaPointHitsOwnTaskbar:cocoaPoint]) {
        return;
    }

    /*
     * Toggle: second click on exposed desktop exits user-armed peek and restores
     * the bar to its normal (full) position.
     */
    if (self.desktopPeekUserArmed && self.itemsFrozenForDesktopReveal) {
        MLDebugLog(@"[Taskbar] desktop click exits user-armed peek");
        [self unfreezeDesktopRevealAndRefresh];
        return;
    }

    if (![self canArmUserDesktopPeekAtCocoaPoint:cocoaPoint]) {
        return;
    }

    /*
     * Arm + snap down IMMEDIATELY (before freeze bookkeeping). Stale CG/live census
     * used to reject the click and defer peek ~0.45s to the visibility timer.
     */
    self.desktopPeekClickInProgress = YES;
    self.desktopPeekUserArmed = YES;

    MLDebugLog(@"[Taskbar] desktop click armed peek — force half-down (chips=%ld)",
          (long)[self totalWindowChipsOnBars]);
    if (!self.itemsFrozenForDesktopReveal) {
        [self freezeDesktopRevealApplyingPresentation:NO];
    }
    if (!self.itemsFrozenForDesktopReveal) {
        /* freeze was blocked — still force freeze state for user click. */
        [self cancelItemsCommitTimer];
        [self.frozenItemsByScreenID removeAllObjects];
        for (MLTaskbarScreenBar *bar in self.bars) {
            if (!bar.screenID || !bar.barView) {
                continue;
            }
            NSArray<MLTaskbarItem *> *shot = [self deepCopyItems:bar.barView.items];
            self.frozenItemsByScreenID[bar.screenID] = shot;
            bar.pendingItems = shot;
        }
        self.itemsFrozenForDesktopReveal = YES;
        NSMutableSet<NSNumber *> *all = [NSMutableSet set];
        for (MLTaskbarScreenBar *bar in self.bars) {
            if (bar.screenID) {
                [all addObject:bar.screenID];
            }
        }
        self.desktopRevealScreenIDs = all;
        self.fullscreenScreenIDs = [NSSet set];
    }
    /* Single downward commit — after all peek state is latched. */
    [self applyPeekFramesIfDrifted];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        weakSelf.desktopPeekClickInProgress = NO;
    });
}

@end
