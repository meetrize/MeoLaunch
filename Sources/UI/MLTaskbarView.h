#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>

@class MLTaskbarIconCache;
@class MLTaskbarView;

typedef NS_ENUM(NSInteger, MLTaskbarItemKind) {
    MLTaskbarItemPinnedOnly = 0,
    MLTaskbarItemRunningNoWindow,
    MLTaskbarItemRunningWindow,
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
@property (nonatomic, assign) NSUInteger seenOrder;
@end

@protocol MLTaskbarViewDelegate <NSObject>
- (void)taskbarView:(MLTaskbarView *)view didClickItemAtIndex:(NSInteger)index;
- (void)taskbarView:(MLTaskbarView *)view didRequestPinToggleAtIndex:(NSInteger)index;
@end

@interface MLTaskbarView : NSView

@property (nonatomic, weak) id<MLTaskbarViewDelegate> delegate;
@property (nonatomic, copy) NSArray<MLTaskbarItem *> *items;
@property (nonatomic, weak) MLTaskbarIconCache *iconCache;

@property (nonatomic, assign) CGFloat iconSize;
@property (nonatomic, assign) CGFloat spacing;
@property (nonatomic, assign) CGFloat barHeight;
@property (nonatomic, assign) CGFloat itemMaxWidth;
@property (nonatomic, assign) CGFloat itemMinWidth;

- (NSInteger)indexAtPoint:(NSPoint)p;

@end
