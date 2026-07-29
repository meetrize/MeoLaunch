#import <Cocoa/Cocoa.h>

#include "ml_app_index.h"

@class MLConfigStore;
@class MLOverlayController;

@protocol MLOverlayControllerDelegate <NSObject>
@optional
- (void)overlayControllerDidRequestPreferences:(MLOverlayController *)controller;
@end

@interface MLOverlayController : NSObject

@property (nonatomic, weak) id<MLOverlayControllerDelegate> delegate;

- (instancetype)initWithConfigStore:(MLConfigStore *)config;
- (void)reloadWithAppIndex:(const MLAppIndex *)index;
- (void)show;
- (void)hide;
- (BOOL)isVisible;

@end
