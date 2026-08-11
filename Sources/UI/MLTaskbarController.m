#import "MLTaskbarController+Private.h"

#import "MLMinimizeInterceptor.h"
#import "MLRunningAppsMonitor.h"
#import "MLTaskbarPinStore.h"
#import "MLTaskbarView.h"
#import "MLWorkAreaEnforcer.h"

#import <ApplicationServices/ApplicationServices.h>

@implementation MLTaskbarController

- (instancetype)initWithPinStore:(MLTaskbarPinStore *)pins
                         monitor:(MLRunningAppsMonitor *)monitor
                       iconCache:(MLIconCache *)icons {
    self = [super init];
    if (self) {
        _pinStore = pins;
        _monitor = monitor;
        _iconCache = icons;
        _enabled = YES;
        _bars = [NSMutableArray array];
        _displayNameCache = [NSMutableDictionary dictionary];
        _fullscreenHideStreaks = [NSMutableDictionary dictionary];
        _lastStableWindowCountByScreen = [NSMutableDictionary dictionary];
        _frozenItemsByScreenID = [NSMutableDictionary dictionary];
        _chipScreenAffinityByWid = [NSMutableDictionary dictionary];
        _fullscreenScreenIDs = [NSSet set];
        _desktopRevealScreenIDs = [NSSet set];
        _itemsFrozenForDesktopReveal = NO;
        _lastStableLiveWindowCount = 0;
        _freezeLiveBaseline = 0;
        _desktopRevealArmTime = 0;
        _desktopPeekUserArmed = NO;
        _stickyDisplayUntil = 0;
    }
    return self;
}
- (void)dealloc {
    [self stop];
}
+ (NSNumber *)screenIDForScreen:(NSScreen *)screen {
    if (!screen) {
        return @0;
    }
    id num = screen.deviceDescription[@"NSScreenNumber"];
    if ([num isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)num;
    }
    return @(screen.hash);
}
- (void)start {
    if (self.started) {
        return;
    }
    if (!self.enabled) {
        return;
    }
    self.started = YES;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(softStateDidChange:)
                                                 name:MLWindowSoftStateDidChangeNotification
                                               object:self.monitor.softState];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(pinsDidChange:)
                                                 name:MLTaskbarPinsDidChangeNotification
                                               object:self.pinStore];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(runningDidChange:)
                                                 name:MLRunningAppsDidChangeNotification
                                               object:self.monitor];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(frontWindowDidChange:)
                                                 name:MLRunningAppsFrontWindowDidChangeNotification
                                               object:self.monitor];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(screenParamsChanged:)
                                                 name:NSApplicationDidChangeScreenParametersNotification
                                               object:nil];
    NSNotificationCenter *wsnc = [[NSWorkspace sharedWorkspace] notificationCenter];
    [wsnc addObserver:self
             selector:@selector(frontAppDidChange:)
                 name:NSWorkspaceDidActivateApplicationNotification
               object:nil];
    [wsnc addObserver:self
             selector:@selector(activeSpaceDidChange:)
                 name:NSWorkspaceActiveSpaceDidChangeNotification
               object:nil];

    [self.monitor start];
    /* Allow Show Desktop freeze only after census has settled (avoid startup false peek). */
    self.desktopRevealArmTime = [NSDate date].timeIntervalSinceReferenceDate + 1.0;
    self.lastStableLiveWindowCount = 0;
    self.freezeLiveBaseline = 0;
    self.itemsFrozenForDesktopReveal = NO;
    self.desktopRevealScreenIDs = [NSSet set];
    self.desktopPeekUserArmed = NO;
    [self.frozenItemsByScreenID removeAllObjects];
    [self.chipScreenAffinityByWid removeAllObjects];

    [self syncBarsToScreens];
    [self scheduleStartupVisibilityRechecks];
    [self updateVisibilitySafetyTimer];

    self.minimizeInterceptor = [[MLMinimizeInterceptor alloc] init];
    self.minimizeInterceptor.taskbar = self;
    [self.minimizeInterceptor start];

    self.workAreaEnforcer = [[MLWorkAreaEnforcer alloc] init];
    self.workAreaEnforcer.monitor = self.monitor;
    self.workAreaEnforcer.barHeight = (CGFloat)MLTaskbarBarHeight;
    [self.workAreaEnforcer start];
}
- (void)stop {
    if (!self.started) {
        return;
    }
    self.started = NO;
    self.fullscreenCheckPending = NO;
    self.startupVisibilityGeneration += 1;
    [self cancelItemsCommitTimer];
    [self.visibilitySafetyTimer invalidate];
    self.visibilitySafetyTimer = nil;
    self.fullscreenScreenIDs = [NSSet set];
    self.desktopRevealScreenIDs = [NSSet set];
    self.itemsFrozenForDesktopReveal = NO;
    self.desktopPeekUserArmed = NO;
    self.lastStableLiveWindowCount = 0;
    self.freezeLiveBaseline = 0;
    self.desktopRevealArmTime = 0;
    [self.frozenItemsByScreenID removeAllObjects];
    [self.chipScreenAffinityByWid removeAllObjects];
    [self.fullscreenHideStreaks removeAllObjects];
    [self.lastStableWindowCountByScreen removeAllObjects];
    self.stickyDisplayUntil = 0;
    [self.workAreaEnforcer stop];
    self.workAreaEnforcer = nil;
    [self.minimizeInterceptor stop];
    self.minimizeInterceptor = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
    [self.monitor stop];
    for (MLTaskbarScreenBar *bar in self.bars) {
        [bar.window orderOut:nil];
        bar.window = nil;
        bar.barView = nil;
    }
    [self.bars removeAllObjects];
    [self.iconCache purge];
    [self.displayNameCache removeAllObjects];
}
- (void)clearDisplayNameCacheForIdleReclaim {
    [self.displayNameCache removeAllObjects];
}
- (void)purgeRebuildableCachesForMemoryPressure {
    [self.iconCache purge];
    [self.displayNameCache removeAllObjects];
}
- (void)pinsDidChange:(NSNotification *)note {
    (void)note;
    if (self.itemsFrozenForDesktopReveal) {
        return;
    }
    [self rebuildItemsImmediate:YES];
}
- (void)runningDidChange:(NSNotification *)note {
    (void)note;
    [self applyActiveHighlightImmediate];
    if ([self shouldFreezeForDesktopReveal]) {
        [self freezeDesktopReveal];
    }
    [self refreshFullscreenVisibility];
    if (!self.itemsFrozenForDesktopReveal) {
        /* Debounce monitor churn so Show Desktop can freeze before chips drop. */
        [self rebuildItemsImmediate:NO];
    } else {
        [self restoreFrozenItemsOntoBars];
    }
}
- (void)frontWindowDidChange:(NSNotification *)note {
    NSNumber *widNum = note.userInfo[MLRunningAppsFrontWindowIDKey];
    CGWindowID wid = widNum.unsignedIntValue;
    [self applyActiveHighlightForWindowID:wid];
}
- (void)frontAppDidChange:(NSNotification *)note {
    (void)note;
    [self applyActiveHighlightImmediate];
    if ([self shouldFreezeForDesktopReveal]) {
        [self freezeDesktopReveal];
    }
    [self refreshFullscreenVisibility];
    if (!self.itemsFrozenForDesktopReveal) {
        [self rebuildItemsImmediate:NO];
    } else {
        [self restoreFrozenItemsOntoBars];
    }
    [self updateVisibilitySafetyTimer];
    __weak typeof(self) weakSelf = self;
    /* CG window order can lag NSWorkspace by a frame — re-paint highlight once settled. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf applyActiveHighlightImmediate];
                   });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (!self) {
                           return;
                       }
                       if ([self shouldFreezeForDesktopReveal]) {
                           [self freezeDesktopReveal];
                       }
                       [self refreshFullscreenVisibility];
                       [self applyActiveHighlightImmediate];
                   });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf refreshFullscreenVisibility];
                   });
}
- (void)activeSpaceDidChange:(NSNotification *)note {
    (void)note;
    [self applyActiveHighlightImmediate];
    [self scheduleFullscreenVisibilityCheck];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf refreshFullscreenVisibility];
                   });
}
- (void)screenParamsChanged:(NSNotification *)note {
    (void)note;
    [self syncBarsToScreens];
    if (!self.itemsFrozenForDesktopReveal) {
        [self rebuildItems];
    }
}
- (void)overlayWillShow {
    /* Overlay uses NSStatusWindowLevel; taskbars stay at NSFloatingWindowLevel and
       remain visible underneath — the scrim covers them on the overlay screen. */
}
- (void)overlayDidHide {
}

@end
