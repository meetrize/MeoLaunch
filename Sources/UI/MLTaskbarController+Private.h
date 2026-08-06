#import "MLTaskbarController.h"

#import "MLTaskbarConstants.h"
#import "MLTaskbarScreenBar.h"
#import "MLIconCache.h"
#import "MLRunningAppsMonitor.h"
#import "MLTaskbarPinStore.h"
#import "MLTaskbarView.h"
#import "MLWindowSoftState.h"

#import <ApplicationServices/ApplicationServices.h>

@class MLMinimizeInterceptor;
@class MLWorkAreaEnforcer;

@interface MLTaskbarController () <MLTaskbarViewDelegate>
@property (nonatomic, strong) MLTaskbarPinStore *pinStore;
@property (nonatomic, strong) MLRunningAppsMonitor *monitor;
@property (nonatomic, strong) MLIconCache *iconCache;
@property (nonatomic, strong) NSMutableArray<MLTaskbarScreenBar *> *bars;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *displayNameCache;
@property (nonatomic, strong) MLMinimizeInterceptor *minimizeInterceptor;
@property (nonatomic, strong) MLWorkAreaEnforcer *workAreaEnforcer;
@property (nonatomic, strong) NSSet<NSNumber *> *fullscreenScreenIDs;
@property (nonatomic, strong) NSSet<NSNumber *> *desktopRevealScreenIDs;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *fullscreenHideStreaks;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *lastStableWindowCountByScreen;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSArray<MLTaskbarItem *> *> *frozenItemsByScreenID;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *chipScreenAffinityByWid;
@property (nonatomic, assign) BOOL itemsFrozenForDesktopReveal;
@property (nonatomic, assign) NSInteger lastStableLiveWindowCount;
@property (nonatomic, assign) NSInteger freezeLiveBaseline;
@property (nonatomic, assign) NSTimeInterval desktopRevealArmTime;
@property (nonatomic, assign) BOOL desktopPeekUserArmed;
@property (nonatomic, strong) NSTimer *itemsCommitTimer;
@property (nonatomic, assign) NSTimeInterval stickyDisplayUntil;
@property (nonatomic, assign) CGWindowID rebuildPassFrontmostWID;
@property (nonatomic, assign) BOOL rebuildPassFrontmostValid;
@property (nonatomic, assign) CGWindowID cachedTopmostUserWID;
@property (nonatomic, assign) NSTimeInterval cachedTopmostUserAt;
@property (nonatomic, strong) NSTimer *visibilitySafetyTimer;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL fullscreenCheckPending;
@property (nonatomic, assign) NSUInteger startupVisibilityGeneration;

+ (NSNumber *)screenIDForScreen:(NSScreen *)screen;
+ (BOOL)isSystemWindowOwner:(NSString *)owner;

- (NSString *)displayNameForPath:(NSString *)path;
- (pid_t)pidForPath:(NSString *)path snapshot:(MLRunningAppsSnapshot *)snap;
- (BOOL)pinSet:(NSSet<NSString *> *)pinSet containsPath:(NSString *)path;
- (MLTaskbarItem *)itemWithPath:(NSString *)path title:(NSString *)title kind:(MLTaskbarItemKind)kind pid:(pid_t)pid windowID:(CGWindowID)wid pinned:(BOOL)pinned minimized:(BOOL)minimized seenOrder:(NSUInteger)order;
- (CGWindowID)frontmostTrackedWindowID;
- (CGWindowID)topmostUserWindowIDExcludingSelf;
- (NSScreen *)screenForWindowBounds:(CGRect)bounds;
- (NSScreen *)screenWithID:(NSNumber *)sid;
- (BOOL)boundsClearlyOnAScreen:(CGRect)bounds;
- (void)rememberChipScreenAffinityFromBars;
- (void)rememberChipScreenAffinityFromFrozenShots;
- (BOOL)pendingMovesChipsAcrossScreens;
- (NSArray<MLTaskbarWindowInfo *> *)windowsOnScreen:(NSScreen *)screen snapshot:(MLRunningAppsSnapshot *)snap;
- (NSInteger)windowChipCountInItems:(NSArray<MLTaskbarItem *> *)items;
- (NSArray<MLTaskbarItem *> *)deepCopyItems:(NSArray<MLTaskbarItem *> *)src;
- (void)rebuildItemsForBar:(MLTaskbarScreenBar *)bar screen:(NSScreen *)screen;
- (NSInteger)windowChipCountOnBar:(MLTaskbarScreenBar *)bar;
- (BOOL)displayedItemsContainWindowID:(CGWindowID)wid;
- (void)paintActiveHighlightForWindowID:(CGWindowID)frontWid;
- (CGWindowID)windowIDOnBarsForPID:(pid_t)pid matchingTitle:(NSString *)focusTitle;
- (void)applyActiveHighlightForWindowID:(CGWindowID)hintWid;
- (void)applyActiveHighlightImmediate;
- (void)cancelItemsCommitTimer;
- (void)scheduleItemsCommitWithDelay:(NSTimeInterval)delay;
- (void)commitPendingItemsForce:(BOOL)force;
- (void)restoreFrozenItemsOntoBars;
- (void)computePendingItemsForAllBars;
- (void)rebuildItemsImmediate:(BOOL)immediate;
- (NSMutableArray<MLTaskbarItem *> *)fitItems:(NSMutableArray<MLTaskbarItem *> *)items maxWidth:(CGFloat)maxW;
- (NSDictionary<NSNumber *, NSScreen *> *)screensByID;
- (CGFloat)barHeightForBar:(MLTaskbarScreenBar *)bar;
- (NSRect)normalFrameForScreen:(NSScreen *)screen height:(CGFloat)height;
- (void)applyPeekPresentationForBar:(MLTaskbarScreenBar *)bar peeking:(BOOL)peeking animated:(BOOL)animated;
- (void)applyUserArmedPeekPresentationAnimated:(BOOL)animated;
- (void)setBar:(MLTaskbarScreenBar *)bar frame:(NSRect)frame animated:(BOOL)animated;
- (MLTaskbarScreenBar *)makeBarForScreen:(NSScreen *)screen;
- (void)syncBarsToScreens;
- (void)scheduleStartupVisibilityRechecks;
- (void)scheduleFullscreenVisibilityCheck;
- (void)updateVisibilitySafetyTimer;
- (BOOL)isDesktopRevealArmed;
- (void)measureDesktopRevealWithCenterCover:(CGFloat *)outCover onScreen:(NSInteger *)outOnScreen all:(NSInteger *)outAll;
- (void)updateStableLiveCensus;
- (NSInteger)frozenWindowChipTotal;
- (BOOL)shouldUnfreezeDesktopReveal;
- (void)freezeDesktopReveal;
- (void)unfreezeDesktopRevealAndRefresh;
- (NSInteger)liveNonMinimizedWindowCount;
- (NSInteger)liveOnScreenNonMinimizedWindowCount;
- (NSSet<NSNumber *> *)hiddenTaskWindowIDSet;
- (BOOL)allDisplayedWindowChipsAreHidden;
- (NSInteger)countForeignOffscreenWindowsExcluding:(NSSet<NSNumber *> *)hiddenIDs;
- (BOOL)isPassiveMinimizeAllState;
- (BOOL)hasShowDesktopParkedEvidence;
- (BOOL)shouldIgnoreDesktopRevealBecauseAllMinimized;
- (NSInteger)totalWindowChipsOnBars;
- (BOOL)looksLikeDesktopReveal;
- (BOOL)shouldFreezeForDesktopReveal;
- (NSSet<NSNumber *> *)detectFullscreenScreenIDs;
- (NSSet<NSNumber *> *)detectDesktopRevealScreenIDsExcludingFullscreen:(NSSet<NSNumber *> *)fullscreenIDs;
- (void)refreshFullscreenVisibility;
- (void)applyBarVisibility;
- (BOOL)cocoaPointHitsOwnTaskbar:(NSPoint)cocoaPoint;
- (BOOL)cocoaPointIsExposedDesktop:(NSPoint)cocoaPoint;
@end
