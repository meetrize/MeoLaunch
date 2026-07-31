#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

/**
 * Single source of truth for screen / window coordinate conversion.
 * kCGWindowBounds uses Quartz (origin top-left of main display);
 * NSScreen / AX frames use Cocoa (origin bottom-left).
 */
@interface MLScreenGeometry : NSObject

+ (NSRect)screensUnionFrame;

/** Quartz kCGWindowBounds → Cocoa. */
+ (NSRect)cocoaRectFromQuartzBounds:(CGRect)quartzBounds;

/** Cocoa → Quartz global bounds. */
+ (CGRect)quartzBoundsFromCocoaRect:(NSRect)cocoa;

/** AX top-left position + size → Cocoa rect. */
+ (NSRect)cocoaRectFromAXPosition:(CGPoint)axPos size:(CGSize)axSize;

/** Cocoa rect → AX top-left position. */
+ (CGPoint)axPositionFromCocoaRect:(NSRect)cocoa;

/** Screen with largest intersection with Cocoa bounds. */
+ (NSScreen *)screenForCocoaRect:(NSRect)cocoa;

+ (NSNumber *)screenIDForScreen:(NSScreen *)screen;

+ (BOOL)nearlyEqual:(CGFloat)a b:(CGFloat)b tolerance:(CGFloat)tol;

/** Apply Cocoa frame to an AX window (position → size → position → size). */
+ (void)applyCocoaFrame:(NSRect)cocoa toAXWindow:(AXUIElementRef)win;

/** Read Cocoa frame from an AX window. */
+ (BOOL)readCocoaFrame:(NSRect *)outCocoa fromAXWindow:(AXUIElementRef)win;

@end
