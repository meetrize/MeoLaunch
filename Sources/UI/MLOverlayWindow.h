#import <Cocoa/Cocoa.h>

/** Borderless NSWindow cannot become key by default — required for search typing. */
@interface MLOverlayWindow : NSWindow
@end
