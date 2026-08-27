/*
 * Headless smoke tests for taskbar peek / multi-screen invariants (§7 checklist logic).
 * Does not drive the GUI — validates pure controller state machines only.
 *
 * Manual GUI regression: ./Scripts/taskbar_peek_checklist.sh
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#import "MLTaskbarController+Private.h"
#import "MLRunningAppsMonitor+Private.h"
#import "MLTaskbarConstants.h"
#import "MLTaskbarScreenBar.h"
#import "MLTaskbarView.h"
#import "MLTaskbarPinStore.h"
#import "MLIconCache.h"
#import "MLWindowSoftState.h"

static int g_failures = 0;
static NSMutableArray *g_keepAlive;

static void RetainForProcessLifetime(id obj) {
    if (!g_keepAlive) {
        g_keepAlive = [NSMutableArray array];
    }
    if (obj) {
        [g_keepAlive addObject:obj];
    }
}

static void Assert(BOOL cond, const char *msg) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", msg);
        g_failures += 1;
    }
}

static MLTaskbarItem *WindowChip(CGWindowID wid, BOOL minimized) {
    MLTaskbarItem *it = [[MLTaskbarItem alloc] init];
    it.kind = MLTaskbarItemRunningWindow;
    it.windowID = wid;
    it.minimized = minimized;
    it.path = @"/Applications/Smoke.app";
    it.pid = 4242;
    it.title = @"Smoke";
    return it;
}

static MLTaskbarScreenBar *Bar(NSNumber *sid, NSArray<MLTaskbarItem *> *items) {
    MLTaskbarScreenBar *bar = [[MLTaskbarScreenBar alloc] init];
    bar.screenID = sid;
    bar.barView = [[MLTaskbarView alloc] initWithFrame:NSMakeRect(0, 0, 800, 40)];
    bar.barView.items = items;
    return bar;
}

static MLTaskbarController *FreshController(void) {
    MLTaskbarPinStore *pins = [[MLTaskbarPinStore alloc] init];
    MLRunningAppsMonitor *mon = [[MLRunningAppsMonitor alloc] init];
    MLIconCache *icons = [[MLIconCache alloc] init];
    icons.maxEntries = 8;
    icons.iconPointSize = 32;
    MLTaskbarController *tb =
        [[MLTaskbarController alloc] initWithPinStore:pins monitor:mon iconCache:icons];
    tb.desktopRevealArmTime = 0; /* armed immediately for looksLike tests */
    RetainForProcessLifetime(pins);
    RetainForProcessLifetime(mon);
    RetainForProcessLifetime(icons);
    RetainForProcessLifetime(tb);
    return tb;
}

static MLTaskbarWindowInfo *WindowInfo(CGWindowID wid, pid_t pid, BOOL minimized, CGRect bounds) {
    MLTaskbarWindowInfo *w = [[MLTaskbarWindowInfo alloc] init];
    w.windowID = wid;
    w.pid = pid;
    w.minimized = minimized;
    w.bounds = bounds;
    w.path = @"/Applications/Smoke.app";
    w.title = @"Doc";
    return w;
}

static void SetSnapshot(MLTaskbarController *tb, NSArray<MLTaskbarWindowInfo *> *windows) {
    MLRunningAppsSnapshot *snap = [[MLRunningAppsSnapshot alloc] init];
    snap.windows = windows ?: @[];
    snap.runningAppPaths = @[];
    snap.pathsWithVisibleWindows = [NSSet set];
    snap.pidToPath = @{};
    tb.monitor.snapshot = snap;
}

static CGRect OnScreenBoundsForAnyDisplay(void) {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) {
        return CGRectMake(100, 100, 400, 300);
    }
    NSRect vf = screen.visibleFrame;
    return NSRectToCGRect(NSInsetRect(vf, 80, 80));
}

static CGRect OffScreenParkingBounds(void) {
    return CGRectMake(-8000, -8000, 900, 700);
}

#pragma mark - Tests

static void test_boundsClearlyOnAScreen(void) {
    MLTaskbarController *tb = FreshController();
    Assert(![tb boundsClearlyOnAScreen:CGRectZero], "empty bounds not on-screen");
    Assert(![tb boundsClearlyOnAScreen:OffScreenParkingBounds()],
           "off-screen parking not clearly on display");
    if (NSScreen.mainScreen) {
        Assert([tb boundsClearlyOnAScreen:OnScreenBoundsForAnyDisplay()],
               "visible inset rect is on-screen");
    }
}

static void test_passiveMinimizeAllState(void) {
    MLTaskbarController *tb = FreshController();
    tb.bars = [NSMutableArray arrayWithObject:Bar(@1, @[ WindowChip(10, YES), WindowChip(11, YES) ])];
    Assert([tb isPassiveMinimizeAllState], "all minimized chips → passive minimize-all");

    tb.bars = [NSMutableArray arrayWithObject:Bar(@1, @[ WindowChip(10, YES), WindowChip(11, NO) ])];
    Assert(![tb isPassiveMinimizeAllState], "mixed minimized/live chips → not passive-all");

    tb.bars = [NSMutableArray arrayWithObject:Bar(@1, @[ WindowChip(10, NO) ])];
    SetSnapshot(tb, @[]);
    Assert([tb shouldIgnoreDesktopRevealBecauseAllMinimized],
           "all closed (no live windows) → ignore auto peek");
}

static void test_userArmedBypassesIgnore(void) {
    MLTaskbarController *tb = FreshController();
    tb.bars = [NSMutableArray arrayWithObject:Bar(@1, @[ WindowChip(10, YES) ])];
    tb.desktopPeekUserArmed = YES;
    Assert(![tb shouldIgnoreDesktopRevealBecauseAllMinimized],
           "user-armed peek bypasses minimize-all ignore");
}

static void test_looksLikeNeverOnPassiveMinimize(void) {
    MLTaskbarController *tb = FreshController();
    tb.bars = [NSMutableArray arrayWithObject:Bar(@1, @[ WindowChip(10, YES) ])];
    tb.desktopRevealArmTime = 0;
    Assert(![tb looksLikeDesktopReveal], "passive minimize-all never looksLike reveal");
}

static void test_liveOnScreenBlocksLooksLike(void) {
    MLTaskbarController *tb = FreshController();
    tb.bars = [NSMutableArray arrayWithObject:Bar(@1, @[ WindowChip(10, NO) ])];
    CGRect on = OnScreenBoundsForAnyDisplay();
    SetSnapshot(tb, @[ WindowInfo(10, 4242, NO, on) ]);
    Assert(![tb looksLikeDesktopReveal], "on-screen live window blocks looksLike");
}

static void test_pendingMovesChipsAcrossScreens(void) {
    MLTaskbarController *tb = FreshController();
    MLTaskbarScreenBar *barA = Bar(@1, @[ WindowChip(100, NO) ]);
    MLTaskbarScreenBar *barB = Bar(@2, @[]);
    barB.pendingItems = @[ WindowChip(100, NO) ];
    tb.bars = [NSMutableArray arrayWithObjects:barA, barB, nil];
    Assert([tb pendingMovesChipsAcrossScreens], "pending wid hop across screens detected");

    barB.pendingItems = @[ WindowChip(100, NO) ];
    barB.barView.items = @[];
    barA.barView.items = @[ WindowChip(100, NO) ];
    barB.pendingItems = @[ WindowChip(100, NO) ];
    tb.chipScreenAffinityByWid[@(100)] = @1;
    barB.pendingItems = @[ WindowChip(100, NO) ];
    Assert([tb pendingMovesChipsAcrossScreens], "affinity mismatch with pending on other screen");

    barB.pendingItems = @[ WindowChip(100, NO) ];
    barB.screenID = @1;
    barA.screenID = @1;
    tb.bars = [NSMutableArray arrayWithObjects:barA, barB, nil];
    barA.barView.items = @[ WindowChip(100, NO) ];
    barB.pendingItems = @[ WindowChip(100, NO) ];
    Assert(![tb pendingMovesChipsAcrossScreens], "same-screen pending OK");
}

static void test_chipAffinityRemembered(void) {
    MLTaskbarController *tb = FreshController();
    MLTaskbarScreenBar *bar = Bar(@42, @[ WindowChip(200, NO) ]);
    tb.bars = [NSMutableArray arrayWithObject:bar];
    [tb rememberChipScreenAffinityFromBars];
    Assert([tb.chipScreenAffinityByWid[@(200)] isEqualToNumber:@42],
           "commit affinity recorded from bars");
}

static void test_softHiddenExcludedFromLiveCount(void) {
    MLTaskbarController *tb = FreshController();
    CGRect on = OnScreenBoundsForAnyDisplay();
    SetSnapshot(tb, @[ WindowInfo(50, 4242, NO, on) ]);
    [tb.monitor.softState markSoftHiddenWindowID:50
                                             pid:4242
                                            path:@"/Applications/Smoke.app"
                                           title:@"Doc"
                                    restoreFrame:NSMakeRect(10, 10, 400, 300)
                                        screenID:@1
                                      hideMethod:MLWindowHideMethodAlpha
                                       seenOrder:1
                                        axWindow:NULL];
    Assert([tb liveNonMinimizedWindowCount] == 0,
           "soft-hidden wid excluded from live count");
    Assert([tb liveOnScreenNonMinimizedWindowCount] == 0,
           "soft-hidden wid excluded from on-screen live count");
}

static void test_peekOffsetConstant(void) {
    Assert(MLTaskbarPeekOffset > 0 && MLTaskbarPeekOffset < MLTaskbarBarHeight,
           "peek offset within bar height");
}

static void test_shouldFreezeBlockedForPassive(void) {
    MLTaskbarController *tb = FreshController();
    tb.desktopRevealArmTime = 0;
    tb.lastStableLiveWindowCount = 2;
    tb.bars = [NSMutableArray arrayWithObject:Bar(@1, @[ WindowChip(10, YES), WindowChip(11, YES) ])];
    Assert(![tb shouldFreezeForDesktopReveal], "passive minimize-all must not auto-freeze");
}

static void test_peekFrameAuthority(void) {
    MLTaskbarController *tb = FreshController();
    Assert(![tb taskbarRequiresPeekFramePresentation], "unfrozen → no peek frame");
    tb.itemsFrozenForDesktopReveal = YES;
    Assert([tb taskbarRequiresPeekFramePresentation], "frozen → peek frame required");

    tb.itemsFrozenForDesktopReveal = NO;
    tb.desktopPeekUserArmed = YES;
    Assert([tb taskbarRequiresPeekFramePresentation], "user armed → peek frame required");

    MLTaskbarScreenBar *bar = Bar(@1, @[ WindowChip(10, NO) ]);
    bar.mode = MLTaskbarBarModePeek;
    tb.bars = [NSMutableArray arrayWithObject:bar];
    tb.itemsFrozenForDesktopReveal = NO;
    tb.desktopPeekUserArmed = NO;
    [tb reconcileOrphanPeekFramesAnimated:NO];
    Assert(bar.mode == MLTaskbarBarModeNormal, "orphan peek mode cleared when unfrozen");
}

static void test_canArmUserPeekRejectsMenuBarStrip(void) {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) {
        return;
    }
    MLTaskbarController *tb = FreshController();
    tb.desktopRevealArmTime = 1.0;
    NSPoint pt = NSMakePoint(NSMidX(screen.frame), NSMaxY(screen.visibleFrame) + 4.0);
    if (pt.y > NSMaxY(screen.frame)) {
        pt.y = NSMaxY(screen.frame) - 1.0;
    }
    Assert(![tb canArmUserDesktopPeekAtCocoaPoint:pt],
           "system menu bar strip click must not arm peek");
    Assert(![tb cocoaPointIsExposedDesktop:pt],
           "menu bar strip is not exposed desktop");

    /* Just below menu bar — top edge / title-bar band must not peek either. */
    NSPoint edgePt = NSMakePoint(NSMidX(screen.frame), NSMaxY(screen.visibleFrame) - 4.0);
    Assert(![tb canArmUserDesktopPeekAtCocoaPoint:edgePt],
           "top edge below menu bar must not arm peek");
}

static void test_canArmUserPeekRequiresExposedDesktop(void) {
    MLTaskbarController *tb = FreshController();
    tb.desktopRevealArmTime = 1.0;
    tb.bars = [NSMutableArray arrayWithObject:Bar(@1, @[ WindowChip(10, YES) ])];
    SetSnapshot(tb, @[]);
    NSPoint pt = NSMakePoint(400, 400);
    BOOL onDesktop = [tb cocoaPointIsExposedDesktop:pt];
    BOOL canArm = [tb canArmUserDesktopPeekAtCocoaPoint:pt];
    Assert(canArm == onDesktop,
           "canArm must follow exposed-desktop hit-test (no liveOnScreen bypass)");
}

static void test_userArmedPeekDoesNotUnfreezeOnCoverAlone(void) {
    MLTaskbarController *tb = FreshController();
    tb.itemsFrozenForDesktopReveal = YES;
    tb.desktopPeekUserArmed = YES;
    tb.desktopRevealArmTime = 1.0;
    SetSnapshot(tb, @[]);
    Assert(![tb shouldUnfreezeDesktopReveal],
           "user-armed peek stays frozen while no on-screen live window");
}

static void test_userArmedPeekNeverAutoUnfreezes(void) {
    MLTaskbarController *tb = FreshController();
    tb.itemsFrozenForDesktopReveal = YES;
    tb.desktopPeekUserArmed = YES;
    tb.desktopRevealArmTime = 1.0;
    CGRect on = OnScreenBoundsForAnyDisplay();
    SetSnapshot(tb, @[ WindowInfo(10, 4242, NO, on) ]);
    Assert(![tb shouldUnfreezeDesktopReveal],
           "user-armed peek never auto-unfreezes from live/cover census");
}

static void PumpMainRunLoopBriefly(void) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
}

static MLTaskbarScreenBar *BarWithWindow(MLTaskbarController *tb, NSScreen *screen) {
    NSNumber *sid = [MLTaskbarController screenIDForScreen:screen];
    MLTaskbarScreenBar *bar = Bar(sid, @[ WindowChip(10, YES) ]);
    NSRect home = [tb normalFrameForScreen:screen height:(CGFloat)MLTaskbarBarHeight];
    NSWindow *w = [[NSWindow alloc] initWithContentRect:home
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    w.releasedWhenClosed = NO;
    [w orderFrontRegardless];
    bar.window = w;
    bar.barView.frame = w.contentView.bounds;
    RetainForProcessLifetime(w);
    return bar;
}

/** Regression: user desktop peek enter → one downward frame commit per bar, refresh idempotent. */
static void test_userDesktopPeekEnterSingleApply(void) {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) {
        fprintf(stderr, "SKIP: no NSScreen for desktop peek apply test\n");
        return;
    }

    MLTaskbarController *tb = FreshController();
    tb.started = YES;
    tb.enabled = YES;
    tb.desktopRevealArmTime = 1.0;
    tb.bars = [NSMutableArray arrayWithObject:BarWithWindow(tb, screen)];

    /* Same sequence as handleDesktopPeekClick after hit-test passes. */
    tb.desktopPeekClickInProgress = YES;
    tb.desktopPeekUserArmed = YES;
    tb.peekFrameDownApplyCount = 0;
    [tb freezeDesktopRevealApplyingPresentation:NO];
    if (!tb.itemsFrozenForDesktopReveal) {
        tb.itemsFrozenForDesktopReveal = YES;
        tb.desktopRevealScreenIDs = [NSSet setWithObject:tb.bars.firstObject.screenID];
    }
    [tb applyPeekFramesIfDrifted];

    NSInteger afterEnter = tb.peekFrameDownApplyCount;
    Assert(afterEnter == 1, "user peek enter must commit peek down exactly once per bar");

    MLTaskbarScreenBar *bar = tb.bars.firstObject;
    Assert([tb barWindowIsAtPeekOffset:bar], "bar must rest at peek offset after enter");

    [tb refreshFullscreenVisibility];
    [tb applyBarVisibility];
    Assert(tb.peekFrameDownApplyCount == afterEnter,
           "sync refresh must not peek down again");

    PumpMainRunLoopBriefly();
    tb.desktopPeekClickInProgress = NO;
    [tb refreshFullscreenVisibility];
    [tb applyBarVisibility];
    [tb applyPeekFramesIfDrifted];
    Assert(tb.peekFrameDownApplyCount == afterEnter,
           "post-enter refresh/drift must not peek down again");
}

/** Re-entrant freeze/refresh during click must not double-apply peek down. */
static void test_reentrantFreezeDuringClickNoDoubleApply(void) {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) {
        fprintf(stderr, "SKIP: no NSScreen for reentrant peek test\n");
        return;
    }

    MLTaskbarController *tb = FreshController();
    tb.started = YES;
    tb.enabled = YES;
    tb.desktopRevealArmTime = 1.0;
    tb.bars = [NSMutableArray arrayWithObject:BarWithWindow(tb, screen)];

    tb.desktopPeekClickInProgress = YES;
    tb.desktopPeekUserArmed = YES;
    tb.peekFrameDownApplyCount = 0;
    [tb freezeDesktopRevealApplyingPresentation:NO];
    [tb applyPeekFramesIfDrifted];
    /* Simulate runningDidChange / refresh firing mid-click. */
    [tb freezeDesktopReveal];
    [tb refreshFullscreenVisibility];
    [tb applyBarVisibility];
    [tb applyPeekFramesIfDrifted];

    Assert(tb.peekFrameDownApplyCount == 1,
           "re-entrant freeze during click must not peek down twice");
}

/** Simulates old bug: refresh after enter must not unfreeze then re-peek (down-up-down). */
static void test_userPeekEnterThenRefreshStaysDown(void) {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) {
        fprintf(stderr, "SKIP: no NSScreen for peek refresh bounce test\n");
        return;
    }

    MLTaskbarController *tb = FreshController();
    tb.started = YES;
    tb.enabled = YES;
    tb.desktopRevealArmTime = 1.0;
    tb.bars = [NSMutableArray arrayWithObject:BarWithWindow(tb, screen)];
    CGRect on = OnScreenBoundsForAnyDisplay();
    SetSnapshot(tb, @[ WindowInfo(10, 4242, NO, on) ]);

    tb.desktopPeekUserArmed = YES;
    tb.itemsFrozenForDesktopReveal = YES;
    tb.desktopRevealScreenIDs = [NSSet setWithObject:tb.bars.firstObject.screenID];
    tb.peekFrameDownApplyCount = 0;
    [tb applyPeekFramesIfDrifted];

    Assert(![tb shouldUnfreezeDesktopReveal],
           "live window snapshot must not auto-unfreeze user peek");
    NSInteger afterApply = tb.peekFrameDownApplyCount;
    Assert(afterApply == 1, "initial peek apply");

    [tb refreshFullscreenVisibility];
    Assert(tb.peekFrameDownApplyCount == afterApply,
           "refresh must not unfreeze/re-peek (down-up-down)");
    Assert([tb barWindowIsAtPeekOffset:tb.bars.firstObject],
           "bar stays at peek offset after refresh");
}

static void test_unfreezeRestoresNormalFrame(void) {
    NSScreen *screen = NSScreen.mainScreen;
    if (!screen) {
        fprintf(stderr, "SKIP: no NSScreen for unfreeze restore test\n");
        return;
    }

    MLTaskbarController *tb = FreshController();
    tb.started = YES;
    tb.enabled = YES;
    tb.desktopRevealArmTime = 1.0;
    MLTaskbarScreenBar *bar = BarWithWindow(tb, screen);
    tb.bars = [NSMutableArray arrayWithObject:bar];
    tb.desktopPeekUserArmed = YES;
    tb.itemsFrozenForDesktopReveal = YES;
    tb.desktopRevealScreenIDs = [NSSet setWithObject:bar.screenID];
    [tb applyPeekFramesIfDrifted];
    Assert([tb barWindowIsAtPeekOffset:bar], "pre-unfreeze at peek offset");

    [tb unfreezeDesktopRevealAndRefresh];
    Assert(![tb barWindowIsAtPeekOffset:bar], "unfreeze restores normal Y");
    Assert(bar.mode == MLTaskbarBarModeNormal, "unfreeze sets normal mode");
    Assert(bar.window.isVisible, "taskbar stays visible after peek exit");
}

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        test_boundsClearlyOnAScreen();
        test_passiveMinimizeAllState();
        test_userArmedBypassesIgnore();
        test_looksLikeNeverOnPassiveMinimize();
        test_liveOnScreenBlocksLooksLike();
        test_pendingMovesChipsAcrossScreens();
        test_chipAffinityRemembered();
        test_softHiddenExcludedFromLiveCount();
        test_peekOffsetConstant();
        test_shouldFreezeBlockedForPassive();
        test_peekFrameAuthority();
        test_canArmUserPeekRejectsMenuBarStrip();
        test_canArmUserPeekRequiresExposedDesktop();
        test_userArmedPeekDoesNotUnfreezeOnCoverAlone();
        test_userArmedPeekNeverAutoUnfreezes();
        test_userDesktopPeekEnterSingleApply();
        test_reentrantFreezeDuringClickNoDoubleApply();
        test_userPeekEnterThenRefreshStaysDown();
        test_unfreezeRestoresNormalFrame();

        if (g_failures == 0) {
            printf("taskbar_peek_smoke OK (%d assertions)\n", 18);
            return 0;
        }
        fprintf(stderr, "taskbar_peek_smoke FAILED (%d failures)\n", g_failures);
        return 1;
    }
}
