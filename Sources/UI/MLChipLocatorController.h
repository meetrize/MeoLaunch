#import <Cocoa/Cocoa.h>

@class MLTaskbarController;
@class MLConfigStore;
@class MLChipLocatorController;

NS_ASSUME_NONNULL_BEGIN

@protocol MLChipLocatorControllerDelegate <NSObject>
@optional
/** Called when the locator is about to show — hide Overlay. */
- (void)chipLocatorControllerWillShow:(MLChipLocatorController *)controller;
@end

@interface MLChipLocatorController : NSObject

@property (nonatomic, weak) id<MLChipLocatorControllerDelegate> delegate;
@property (nonatomic, weak) MLTaskbarController *taskbar;
@property (nonatomic, weak) MLConfigStore *config;

- (BOOL)isVisible;
- (void)toggle;
- (void)show;
- (void)hide;

@end

NS_ASSUME_NONNULL_END
