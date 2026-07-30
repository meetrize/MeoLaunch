#import <Cocoa/Cocoa.h>

/** Login item via SMAppService (macOS 13+). System Login Items is source of truth. */
@interface MLLaunchAtLogin : NSObject

/** YES when registered and enabled (or waiting for Login Items approval). */
+ (BOOL)isEnabled;

/**
 * Register or unregister as a login item.
 * On RequiresApproval, opens System Settings → Login Items.
 * Returns YES on success (including "already in desired state").
 */
+ (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error;

+ (void)openLoginItemsSettings;

@end
