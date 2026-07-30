#import <Cocoa/Cocoa.h>

@interface MLMinimizeAnimator : NSObject

/**
 * Cocoa screen coordinates (bottom-left origin).
 * onCovered: fired after the proxy is on screen covering fromRect, before the shrink starts —
 *            hide the real window here so the user never sees it slide off-screen.
 */
+ (void)animateImage:(NSImage *)image
           fromRect:(NSRect)fromScreenRect
             toRect:(NSRect)toScreenRect
          onCovered:(void (^)(void))onCovered
         completion:(void (^)(void))completion;

@end
