#import <Cocoa/Cocoa.h>

#import "MLStrings.h"

#include "ml_grid.h"

typedef NS_ENUM(NSInteger, MLHotCornerPosition) {
    MLHotCornerPositionOff = 0,
    MLHotCornerPositionTopLeft,
    MLHotCornerPositionTopRight,
    MLHotCornerPositionBottomLeft,
    MLHotCornerPositionBottomRight,
};

/** Where the overlay appears when multiple displays are connected. */
typedef NS_ENUM(NSInteger, MLOverlayScreenMode) {
    MLOverlayScreenModeMouse = 0, /* screen under mouse (default) */
    MLOverlayScreenModeMain,      /* NSScreen.mainScreen */
    MLOverlayScreenModeFixed,     /* ui.overlay_screen_id */
};

FOUNDATION_EXPORT NSNotificationName const MLConfigStoreDidChangeNotification;
/** Posted when scan.roots extras change, or when an explicit rescan is requested. */
FOUNDATION_EXPORT NSNotificationName const MLConfigStoreScanRootsDidChangeNotification;

@interface MLConfigStore : NSObject

@property (nonatomic, assign, readonly) MLGridConfig gridConfig;
@property (nonatomic, assign, readonly) BOOL showLabels;

@property (nonatomic, assign, readonly) BOOL hotCornerEnabled;
@property (nonatomic, assign, readonly) MLHotCornerPosition hotCornerPosition;
@property (nonatomic, assign, readonly) CGFloat hotCornerSizePt;
@property (nonatomic, assign, readonly) NSInteger hotCornerDelayMs;

@property (nonatomic, assign, readonly) BOOL hotkeyEnabled;
@property (nonatomic, assign, readonly) NSInteger hotkeyKeyCode;
@property (nonatomic, assign, readonly) BOOL hotkeyOption;
@property (nonatomic, assign, readonly) BOOL hotkeyCommand;
@property (nonatomic, assign, readonly) BOOL hotkeyControl;
@property (nonatomic, assign, readonly) BOOL hotkeyShift;

@property (nonatomic, assign, readonly) CGFloat wheelThreshold;
@property (nonatomic, assign, readonly) NSInteger fadeMs;
@property (nonatomic, assign, readonly) CGFloat overlayOpacity; /* 0…1 scrim alpha, default 0.55 */
@property (nonatomic, assign, readonly) BOOL overlayBlur; /* blur desktop behind overlay */
@property (nonatomic, assign, readonly) MLOverlayScreenMode overlayScreenMode; /* default mouse */
@property (nonatomic, assign, readonly) uint32_t overlayScreenID; /* NSScreenNumber when mode=fixed */
@property (nonatomic, assign, readonly) MLLanguage language; /* ui.language: en | zh */

/// Full scan root list as stored (may contain ~). Built-ins first, then extras.
@property (nonatomic, copy, readonly) NSArray<NSString *> *scanRoots;
@property (nonatomic, assign, readonly) NSInteger scanRefreshSeconds;

/** Taskbar / performance (P2). */
@property (nonatomic, assign, readonly) BOOL taskbarEnabled;
@property (nonatomic, assign, readonly) NSTimeInterval taskbarWindowPollSeconds; /* default 1.0 */
@property (nonatomic, assign, readonly) NSUInteger overlayIconCacheMax; /* default 128 */

/** Menu bar free-memory % (doc/13). */
@property (nonatomic, assign, readonly) BOOL memoryFreeEnabled; /* default NO */
@property (nonatomic, assign, readonly) NSTimeInterval memoryFreeIntervalSeconds; /* default 2.0 */

+ (NSURL *)configFileURL;
+ (NSArray<NSString *> *)builtInScanRoots;

- (void)loadDefaults;
- (BOOL)loadFromDisk;
- (BOOL)saveToDisk;

- (void)updateGridCols:(int)cols rows:(int)rows;
- (void)updateGridIconSize:(float)iconSize; /* 0 = auto */
- (void)updateOverlayOpacity:(CGFloat)opacity;
- (void)updateOverlayScreenMode:(MLOverlayScreenMode)mode screenID:(uint32_t)screenID;
- (void)updateHotCornerEnabled:(BOOL)enabled
                      position:(MLHotCornerPosition)position
                        sizePt:(CGFloat)sizePt
                       delayMs:(NSInteger)delayMs;
- (void)updateLanguage:(MLLanguage)language;

/** Resolve preferred overlay screen; falls back to main / first if fixed ID missing. */
- (NSScreen *)resolvedOverlayScreen;

- (void)updateTaskbarEnabled:(BOOL)enabled;
- (void)updateTaskbarWindowPollSeconds:(NSTimeInterval)seconds;
- (void)updateOverlayIconCacheMax:(NSUInteger)maxEntries;
- (void)updateMemoryFreeEnabled:(BOOL)enabled;
- (void)updateMemoryFreeIntervalSeconds:(NSTimeInterval)seconds;

/// Extra roots only (after built-ins). Normalized absolute-or-~ paths.
- (NSArray<NSString *> *)scanExtraRoots;
- (void)setScanExtraRoots:(NSArray<NSString *> *)extras;
- (BOOL)addScanExtraRoot:(NSString *)path; /* NO if duplicate / empty */
- (void)removeScanExtraRootAtIndex:(NSInteger)index;

/// Expanded for filesystem scan (tilde resolved).
- (NSArray<NSString *> *)expandedScanRoots;

- (void)requestAppRescan; /* notify AppDelegate to rescan without changing roots */
- (void)scheduleSave; /* debounce 300ms */

@end
