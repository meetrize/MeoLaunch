#import <Cocoa/Cocoa.h>

@class MLConfigStore;
@class MLTaskbarHideStore;

@interface MLPrefsWindow : NSObject

- (instancetype)initWithConfigStore:(MLConfigStore *)config
                          hideStore:(MLTaskbarHideStore *)hideStore;
- (void)show;

@end
