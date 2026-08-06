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
/** Latest computed chips; painted only via commit (not on every monitor tick). */
@property (nonatomic, strong) NSArray<MLTaskbarItem *> *pendingItems;

@end
