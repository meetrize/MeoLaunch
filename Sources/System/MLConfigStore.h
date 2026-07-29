#import <Cocoa/Cocoa.h>

#include "ml_grid.h"

typedef NS_ENUM(NSInteger, MLHotCornerPosition) {
    MLHotCornerPositionOff = 0,
    MLHotCornerPositionTopLeft,
    MLHotCornerPositionTopRight,
    MLHotCornerPositionBottomLeft,
    MLHotCornerPositionBottomRight,
};

FOUNDATION_EXPORT NSNotificationName const MLConfigStoreDidChangeNotification;

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

+ (NSURL *)configFileURL;

- (void)loadDefaults;
- (BOOL)loadFromDisk;
- (BOOL)saveToDisk;

- (void)updateGridCols:(int)cols rows:(int)rows;
- (void)updateGridIconSize:(float)iconSize; /* 0 = auto */
- (void)updateOverlayOpacity:(CGFloat)opacity;
- (void)updateHotCornerEnabled:(BOOL)enabled
                      position:(MLHotCornerPosition)position
                        sizePt:(CGFloat)sizePt
                       delayMs:(NSInteger)delayMs;
- (void)scheduleSave; /* debounce 300ms */

@end
