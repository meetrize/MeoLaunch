#import <Cocoa/Cocoa.h>

@class MLHotKeyManager;
@class MLConfigStore;

typedef NS_ENUM(NSUInteger, MLHotKeyAction) {
    MLHotKeyActionOverlay = 1,
    MLHotKeyActionChipLocator = 2,
};

@protocol MLHotKeyManagerDelegate <NSObject>
- (void)hotKeyManager:(MLHotKeyManager *)manager didFireAction:(MLHotKeyAction)action;
@end

@interface MLHotKeyManager : NSObject

@property (nonatomic, weak) id<MLHotKeyManagerDelegate> delegate;
/** YES if at least one hotkey is registered. */
@property (nonatomic, assign, readonly, getter=isRegistered) BOOL registered;
@property (nonatomic, assign, readonly, getter=isOverlayRegistered) BOOL overlayRegistered;
@property (nonatomic, assign, readonly, getter=isChipLocatorRegistered) BOOL chipLocatorRegistered;

- (void)applyConfig:(MLConfigStore *)config;
- (BOOL)registerDefaultHotKey;
- (void)unregisterAll;

@end
