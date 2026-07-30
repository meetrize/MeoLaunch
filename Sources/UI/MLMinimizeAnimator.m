#import "MLMinimizeAnimator.h"

#import <QuartzCore/QuartzCore.h>

@implementation MLMinimizeAnimator

+ (void)animateImage:(NSImage *)image
           fromRect:(NSRect)fromScreenRect
             toRect:(NSRect)toScreenRect
          onCovered:(void (^)(void))onCovered
         completion:(void (^)(void))completion {
    if (!image || NSIsEmptyRect(fromScreenRect)) {
        if (onCovered) {
            onCovered();
        }
        if (completion) {
            completion();
        }
        return;
    }

    NSRect target = NSIsEmptyRect(toScreenRect) ? fromScreenRect : toScreenRect;
    NSRect unionRect = NSUnionRect(fromScreenRect, target);
    unionRect = NSInsetRect(unionRect, -24.0, -24.0);

    NSWindow *host = [[NSWindow alloc] initWithContentRect:unionRect
                                                 styleMask:NSWindowStyleMaskBorderless
                                                   backing:NSBackingStoreBuffered
                                                     defer:NO];
    host.opaque = NO;
    host.backgroundColor = [NSColor clearColor];
    host.hasShadow = NO;
    host.level = NSScreenSaverWindowLevel;
    host.ignoresMouseEvents = YES;
    host.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                              NSWindowCollectionBehaviorStationary |
                              NSWindowCollectionBehaviorIgnoresCycle;
    host.releasedWhenClosed = NO;

    NSImageView *view = [[NSImageView alloc] initWithFrame:NSZeroRect];
    view.imageScaling = NSImageScaleAxesIndependently;
    view.image = image;
    view.wantsLayer = YES;
    [host.contentView addSubview:view];

    NSRect fromLocal = fromScreenRect;
    fromLocal.origin.x -= unionRect.origin.x;
    fromLocal.origin.y -= unionRect.origin.y;
    NSRect toLocal = target;
    toLocal.origin.x -= unionRect.origin.x;
    toLocal.origin.y -= unionRect.origin.y;

    view.frame = fromLocal;
    view.alphaValue = 1.0;
    [host orderFrontRegardless];
    /* Force the cover on screen before hiding the real window. */
    [host displayIfNeeded];
    [CATransaction flush];

    if (onCovered) {
        onCovered(); /* Hide real window immediately while cover is opaque. */
    }

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.28;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        view.animator.frame = toLocal;
        view.animator.alphaValue = 0.25;
    } completionHandler:^{
        [host orderOut:nil];
        if (completion) {
            completion();
        }
    }];
}

@end
