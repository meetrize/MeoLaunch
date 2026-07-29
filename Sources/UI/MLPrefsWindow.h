#import <Cocoa/Cocoa.h>

@class MLConfigStore;

@interface MLPrefsWindow : NSObject

- (instancetype)initWithConfigStore:(MLConfigStore *)config;
- (void)show;

@end
