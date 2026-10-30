#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

@class MLIconCache;
@class MLTaskbarView;

typedef NS_ENUM(NSInteger, MLTaskbarItemKind) {
    MLTaskbarItemPinnedOnly = 0,
    MLTaskbarItemRunningNoWindow,
    MLTaskbarItemRunningWindow,
};

/** Audio chrome on a chip (doc/19). None/Playing in A1; Muted in A2. */
typedef NS_ENUM(NSInteger, MLTaskbarAudioState) {
    MLTaskbarAudioNone = 0,
    MLTaskbarAudioPlaying,
    MLTaskbarAudioMuted,
};

typedef NS_ENUM(NSInteger, MLTaskbarChipZone) {
    MLTaskbarChipZoneNone = 0,
    MLTaskbarChipZonePin,
    MLTaskbarChipZoneWindow,
};

typedef NS_ENUM(NSInteger, MLTaskbarMenuAction) {
    MLTaskbarMenuActionClose = 0,
    MLTaskbarMenuActionMinimizeToggle,
    MLTaskbarMenuActionFullscreenToggle,
    MLTaskbarMenuActionPinToggle,
    MLTaskbarMenuActionHideChipToggle,
    MLTaskbarMenuActionAudioMuteToggle,
    MLTaskbarMenuActionSearchButtonToggle,
    MLTaskbarMenuActionShowDesktopButtonToggle,
    MLTaskbarMenuActionAbout,
    MLTaskbarMenuActionPreferences,
    MLTaskbarMenuActionQuit,
};

@interface MLTaskbarItem : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) CGWindowID windowID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) MLTaskbarItemKind kind;
@property (nonatomic, assign) BOOL pinned;
@property (nonatomic, assign) BOOL minimized;
/** Frontmost on-screen window of the frontmost app. */
@property (nonatomic, assign) BOOL active;
@property (nonatomic, assign) NSUInteger seenOrder;
/** Per-process audio indicator (shared across chips with same pid). */
@property (nonatomic, assign) MLTaskbarAudioState audioState;
@end

/** Live flags for context menu (read at popup time). index < 0 = empty bar. */
@interface MLTaskbarMenuFlags : NSObject
@property (nonatomic, assign) BOOL hasWindow;
/** RunningNoWindow chip — Close should quit the process. */
@property (nonatomic, assign) BOOL canQuitProcess;
@property (nonatomic, assign) BOOL minimized;
@property (nonatomic, assign) BOOL fullscreen;
@property (nonatomic, assign) BOOL fullscreenSupported;
@property (nonatomic, assign) BOOL pinned;
@property (nonatomic, assign) BOOL taskChipHidden;
@property (nonatomic, assign) BOOL canToggleHideChip;
@property (nonatomic, assign) BOOL audioMuteAvailable;
@property (nonatomic, assign) BOOL audioMuted;
@end

@protocol MLTaskbarAppActions <NSObject>
- (void)taskbarShowAbout;
- (void)taskbarShowPreferences;
- (void)taskbarQuitApp;
@optional
/** Open / toggle Chip Locator panel. */
- (void)taskbarToggleChipLocator;
/** Persist + apply show/hide of the leftmost search icon. */
- (void)taskbarToggleSearchButtonVisibility;
/** Persist + apply show/hide of the rightmost Show Desktop icon. */
- (void)taskbarToggleShowDesktopButtonVisibility;
@end

@protocol MLTaskbarViewDelegate <NSObject>
- (void)taskbarView:(MLTaskbarView *)view didClickItemAtIndex:(NSInteger)index;
- (void)taskbarView:(MLTaskbarView *)view
    didSelectAction:(MLTaskbarMenuAction)action
            atIndex:(NSInteger)index;
/** Fill live menu state; index < 0 means empty bar (no chip). */
- (void)taskbarView:(MLTaskbarView *)view
     menuFlags:(MLTaskbarMenuFlags *)flags
      forIndex:(NSInteger)index;

@optional
/** Return NO to keep click-only (e.g. peek freeze). */
- (BOOL)taskbarViewShouldBeginDrag:(MLTaskbarView *)view;
- (void)taskbarView:(MLTaskbarView *)view beganDragAtIndex:(NSInteger)index;
/** `screenPoint` is AppKit global (bottom-left origin). */
- (void)taskbarView:(MLTaskbarView *)view draggedToScreenPoint:(NSPoint)screenPoint;
- (void)taskbarView:(MLTaskbarView *)view
    endedDragAtScreenPoint:(NSPoint)screenPoint
                 cancelled:(BOOL)cancelled;
/** Audio badge only — must not activate / soft-min the chip. */
- (void)taskbarView:(MLTaskbarView *)view didClickAudioBadgeAtIndex:(NSInteger)index;
/** Leftmost search / Chip Locator button. */
- (void)taskbarViewDidClickSearchButton:(MLTaskbarView *)view;
/** Rightmost Show Desktop toggle (soft-min all / restore). */
- (void)taskbarViewDidClickShowDesktopButton:(MLTaskbarView *)view;
@end

@interface MLTaskbarView : NSView

@property (nonatomic, weak) id<MLTaskbarViewDelegate> delegate;
@property (nonatomic, copy) NSArray<MLTaskbarItem *> *items;
@property (nonatomic, weak) MLIconCache *iconCache;

/**
 * After icon cache purge: re-request icons for current chips and repaint.
 * (setNeedsDisplay alone does not start loadIconForPath.)
 */
- (void)reloadIconsFromApps;

@property (nonatomic, assign) CGFloat iconSize;
@property (nonatomic, assign) CGFloat spacing;
@property (nonatomic, assign) CGFloat barHeight;
@property (nonatomic, assign) CGFloat itemMaxWidth;
@property (nonatomic, assign) CGFloat itemMinWidth;
/** Leftmost magnifier that opens Chip Locator; default YES. */
@property (nonatomic, assign) BOOL showsSearchButton;
/** Rightmost Show Desktop button; default YES. */
@property (nonatomic, assign) BOOL showsShowDesktopButton;
/** Highlight when Show Desktop session is active (windows soft-hidden). */
@property (nonatomic, assign) BOOL showDesktopButtonActive;

- (NSInteger)indexAtPoint:(NSPoint)p;
- (NSRect)rectForItemAtIndex:(NSInteger)index;
/** Hit / draw rect for audio badge; empty if none. */
- (NSRect)audioBadgeRectForItemAtIndex:(NSInteger)index;
/** Hit / draw rect for leftmost search button; empty if hidden. */
- (NSRect)searchButtonRect;
/** Hit / draw rect for rightmost Show Desktop button. */
- (NSRect)showDesktopButtonRect;
/** Extra leading width reserved for search chrome (0 when hidden). */
- (CGFloat)leadingChromeWidth;
/** Extra trailing width reserved for Show Desktop chrome. */
- (CGFloat)trailingChromeWidth;

/** Leading contiguous PinnedOnly count (pin zone length). */
- (NSInteger)pinZoneCount;
- (MLTaskbarChipZone)zoneForIndex:(NSInteger)index;
- (NSInteger)zoneStartIndex:(MLTaskbarChipZone)zone;
- (NSInteger)zoneCount:(MLTaskbarChipZone)zone;

/**
 * Final absolute item index within `zone` after a same-bar move from `sourceIndex`.
 * Returns -1 when point is outside the zone / invalid.
 */
- (NSInteger)destinationIndexAtPoint:(NSPoint)p
                              inZone:(MLTaskbarChipZone)zone
                        sourceIndex:(NSInteger)sourceIndex;

/**
 * Absolute insert index on this bar for an external chip (source not in items).
 * Returns zoneStart..zoneStart+zoneCount (append = end). -1 if outside zone.
 */
- (NSInteger)externalInsertIndexAtPoint:(NSPoint)p inZone:(MLTaskbarChipZone)zone;

/** Local drag preview: source leaves a hole; others in zone shift toward `insertIndex`. */
- (void)setLocalDragPreviewSourceIndex:(NSInteger)sourceIndex
                           insertIndex:(NSInteger)insertIndex;
/** Target-bar preview while another bar owns the ghost. */
- (void)setExternalDragPreviewInZone:(MLTaskbarChipZone)zone
                         insertIndex:(NSInteger)insertIndex
                    placeholderWidth:(CGFloat)width;
- (void)clearDragPreview;

/** Tear down in-progress drag visuals (ghost + preview). */
- (void)cancelActiveDrag;

/** Width of the chip at index (for cross-bar placeholder sizing). */
- (CGFloat)widthForItemAtIndex:(NSInteger)index;

@property (nonatomic, assign, readonly, getter=isDragActive) BOOL dragActive;

@end
