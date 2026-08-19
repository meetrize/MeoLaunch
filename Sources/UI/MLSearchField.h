#import <Cocoa/Cocoa.h>

@class MLSearchField;

@protocol MLSearchFieldSettingsDelegate <NSObject>
- (void)searchFieldDidClickSettings:(MLSearchField *)field;
@end

@interface MLSearchField : NSTextField

@property (nonatomic, weak) id<MLSearchFieldSettingsDelegate> settingsDelegate;

/** Soften AppKit focus chrome paint only (never remove/reparent clip views). */
- (void)ml_purgeStaleFocusChrome;

/**
 * Size `_NSKeyboardFocusClipView` / field editor to the cell titleRect in place.
 * Never reparents out of AppKit's focus clip (that over-releases and SIGABRTs).
 */
- (void)ml_fitFocusChromeInPlace;

@end
