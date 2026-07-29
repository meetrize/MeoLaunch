#import <Cocoa/Cocoa.h>

@class MLHotKeyManager;
@class MLConfigStore;

@protocol MLHotKeyManagerDelegate <NSObject>
- (void)hotKeyManagerDidFire:(MLHotKeyManager *)manager;
@end

@interface MLHotKeyManager : NSObject

@property (nonatomic, weak) id<MLHotKeyManagerDelegate> delegate;
@property (nonatomic, assign, readonly, getter=isRegistered) BOOL registered;

- (void)applyConfig:(MLConfigStore *)config;
- (BOOL)registerDefaultHotKey;
- (void)unregisterAll;

@end
