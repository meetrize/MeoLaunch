#import <Cocoa/Cocoa.h>

@class MLSearchField;

@protocol MLSearchFieldSettingsDelegate <NSObject>
- (void)searchFieldDidClickSettings:(MLSearchField *)field;
@end

@interface MLSearchField : NSTextField

@property (nonatomic, weak) id<MLSearchFieldSettingsDelegate> settingsDelegate;

@end
