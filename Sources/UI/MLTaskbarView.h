#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

@class MLIconCache;
@class MLTaskbarView;

typedef NS_ENUM(NSInteger, MLTaskbarItemKind) {
    MLTaskbarItemPinnedOnly = 0,
    MLTaskbarItemRunningNoWindow,
    MLTaskbarItemRunningWindow,
};

typedef NS_ENUM(NSInteger, MLTaskbarMenuAction) {
    MLTaskbarMenuActionClose = 0,
    MLTaskbarMenuActionMinimizeToggle,
    MLTaskbarMenuActionFullscreenToggle,
    MLTaskbarMenuActionPinToggle,
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
@end

/** Live flags for context menu (read at popup time). index < 0 = empty bar. */
@interface MLTaskbarMenuFlags : NSObject
@property (nonatomic, assign) BOOL hasWindow;
@property (nonatomic, assign) BOOL minimized;
@property (nonatomic, assign) BOOL fullscreen;
@property (nonatomic, assign) BOOL fullscreenSupported;
@property (nonatomic, assign) BOOL pinned;
@end

@protocol MLTaskbarAppActions <NSObject>
- (void)taskbarShowAbout;
- (void)taskbarShowPreferences;
- (void)taskbarQuitApp;
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
@end

@interface MLTaskbarView : NSView

@property (nonatomic, weak) id<MLTaskbarViewDelegate> delegate;
@property (nonatomic, copy) NSArray<MLTaskbarItem *> *items;
@property (nonatomic, weak) MLIconCache *iconCache;

@property (nonatomic, assign) CGFloat iconSize;
@property (nonatomic, assign) CGFloat spacing;
@property (nonatomic, assign) CGFloat barHeight;
@property (nonatomic, assign) CGFloat itemMaxWidth;
@property (nonatomic, assign) CGFloat itemMinWidth;

- (NSInteger)indexAtPoint:(NSPoint)p;
- (NSRect)rectForItemAtIndex:(NSInteger)index;

@end
