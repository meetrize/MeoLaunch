#import "MLTaskbarController.h"

#import "MLTaskbarConstants.h"
#import "MLTaskbarScreenBar.h"
#import "MLIconCache.h"
#import "MLRunningAppsMonitor.h"
#import "MLWindowCensus.h"
#import "MLTaskbarPinStore.h"
#import "MLWindowSoftState.h"

#import <ApplicationServices/ApplicationServices.h>

@class MLMinimizeInterceptor;
@class MLWorkAreaEnforcer;

@interface MLTaskbarController ()
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
@end
