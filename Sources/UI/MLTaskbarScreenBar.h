#import <Cocoa/Cocoa.h>

#import "MLTaskbarConstants.h"

@class MLTaskbarView;
@class MLTaskbarItem;

/** One per-screen taskbar window + view. */
@interface MLTaskbarScreenBar : NSObject

@property (nonatomic, strong) NSNumber *screenID;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) MLTaskbarView *barView;
@property (nonatomic, assign) MLTaskbarBarMode mode;
/** Bumped on every peek frame apply/cancel — stale animators must not win. */
@property (nonatomic, assign) NSUInteger peekPresentationGeneration;
/** Latest computed chips; painted only via commit (not on every monitor tick). */
@property (nonatomic, strong) NSArray<MLTaskbarItem *> *pendingItems;
/** Same as pending before width fit — Chip Locator uses this so squeezed chips stay findable. */
@property (nonatomic, strong) NSArray<MLTaskbarItem *> *unfittedItems;

@end
