#import <Cocoa/Cocoa.h>

/**
 * Diagnostic probe for the intermittent gray rounded panel under the search bar.
 * Always logs via NSLog with prefix [MeoLaunch][GhostPanel].
 * Disable: MEOLAUNCH_GHOST_PROBE=0
 */
@interface MLGhostPanelProbe : NSObject

+ (void)install;
+ (void)attachOverlayWindow:(NSWindow *)window searchField:(NSTextField *)searchField;
+ (void)detach;
+ (void)noteEvent:(NSString *)event;
+ (void)dumpSnapshot:(NSString *)reason;
+ (void)scheduleShowBurst;
+ (void)noteViewInserted:(NSView *)view parent:(NSView *)parent via:(NSString *)via;
+ (void)noteFieldEditorRequest:(BOOL)create object:(id)object editor:(NSText *)editor;
+ (void)noteFirstResponder:(NSResponder *)responder result:(BOOL)ok previous:(NSResponder *)previous;
+ (void)noteStrayEditor:(NSTextView *)editor host:(NSView *)host reason:(NSString *)reason;
+ (void)noteSearchFieldSubview:(NSView *)subview;

@end
