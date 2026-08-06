#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface MLAXWindowHelper : NSObject

/** Private API via dlsym; returns 0 when unavailable. */
+ (CGWindowID)windowIDForAXWindow:(AXUIElementRef _Nullable)win;

/** Copy a string AX attribute into *out (autoreleased). */
+ (BOOL)copyStringAttribute:(CFStringRef _Nonnull)attr
                fromElement:(AXUIElementRef _Nullable)el
                       into:(NSString * _Nullable * _Nonnull)out;

/** Walk parents to find an AX window; caller must CFRelease. */
+ (AXUIElementRef _Nullable)copyWindowElementFromElement:(AXUIElementRef _Nullable)el;

+ (BOOL)isFullscreen:(AXUIElementRef _Nullable)win;

@end
