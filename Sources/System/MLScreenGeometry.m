#import "MLScreenGeometry.h"

#import <ApplicationServices/ApplicationServices.h>

@implementation MLScreenGeometry

+ (NSRect)screensUnionFrame {
    NSRect u = NSZeroRect;
    BOOL first = YES;
    for (NSScreen *s in NSScreen.screens) {
        if (first) {
            u = s.frame;
            first = NO;
        } else {
            u = NSUnionRect(u, s.frame);
        }
    }
    return u;
}

+ (NSRect)cocoaRectFromQuartzBounds:(CGRect)quartzBounds {
    NSRect main = NSScreen.mainScreen.frame;
    CGFloat cocoaY = NSMaxY(main) - quartzBounds.origin.y - quartzBounds.size.height;
    return NSMakeRect(quartzBounds.origin.x, cocoaY,
                      quartzBounds.size.width, quartzBounds.size.height);
}

+ (CGRect)quartzBoundsFromCocoaRect:(NSRect)cocoa {
    NSRect main = NSScreen.mainScreen.frame;
    CGFloat qY = NSMaxY(main) - NSMaxY(cocoa);
    return CGRectMake(cocoa.origin.x, qY, cocoa.size.width, cocoa.size.height);
}

+ (NSRect)cocoaRectFromAXPosition:(CGPoint)axPos size:(CGSize)axSize {
    NSRect main = NSScreen.mainScreen.frame;
    CGFloat cocoaY = NSMaxY(main) - axPos.y - axSize.height;
    return NSMakeRect(axPos.x, cocoaY, axSize.width, axSize.height);
}

+ (CGPoint)axPositionFromCocoaRect:(NSRect)cocoa {
    NSRect main = NSScreen.mainScreen.frame;
    return CGPointMake(cocoa.origin.x, NSMaxY(main) - NSMaxY(cocoa));
}

+ (NSScreen *)screenForCocoaRect:(NSRect)cocoa {
    NSScreen *best = nil;
    CGFloat bestArea = -1.0;
    for (NSScreen *s in NSScreen.screens) {
        CGRect inter = CGRectIntersection(NSRectToCGRect(cocoa), NSRectToCGRect(s.frame));
        if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) {
            continue;
        }
        CGFloat area = inter.size.width * inter.size.height;
        if (area > bestArea) {
            bestArea = area;
            best = s;
        }
    }
    return best ?: NSScreen.mainScreen;
}

+ (NSNumber *)screenIDForScreen:(NSScreen *)screen {
    if (!screen) {
        return @0;
    }
    id num = screen.deviceDescription[@"NSScreenNumber"];
    if ([num isKindOfClass:[NSNumber class]]) {
        return (NSNumber *)num;
    }
    return @(screen.hash);
}

+ (BOOL)nearlyEqual:(CGFloat)a b:(CGFloat)b tolerance:(CGFloat)tol {
    return fabs(a - b) <= tol;
}

+ (void)applyCocoaFrame:(NSRect)cocoa toAXWindow:(AXUIElementRef)win {
    if (!win || cocoa.size.width < 2.0 || cocoa.size.height < 2.0) {
        return;
    }
    CGSize axSize = CGSizeMake(cocoa.size.width, cocoa.size.height);
    CGPoint axPos = [self axPositionFromCocoaRect:cocoa];
    AXValueRef sizeVal = AXValueCreate((AXValueType)kAXValueCGSizeType, &axSize);
    AXValueRef posVal = AXValueCreate((AXValueType)kAXValueCGPointType, &axPos);
    /* Size first then position — Finder often rejects grow-after-move from a clamp. */
    if (sizeVal) {
        AXUIElementSetAttributeValue(win, kAXSizeAttribute, sizeVal);
    }
    if (posVal) {
        AXUIElementSetAttributeValue(win, kAXPositionAttribute, posVal);
    }
    if (sizeVal) {
        AXUIElementSetAttributeValue(win, kAXSizeAttribute, sizeVal);
        CFRelease(sizeVal);
    }
    if (posVal) {
        AXUIElementSetAttributeValue(win, kAXPositionAttribute, posVal);
        CFRelease(posVal);
    }
}

+ (BOOL)readCocoaFrame:(NSRect *)outCocoa fromAXWindow:(AXUIElementRef)win {
    if (!win || !outCocoa) {
        return NO;
    }
    CFTypeRef posRef = NULL;
    CFTypeRef sizeRef = NULL;
    CGPoint pos = CGPointZero;
    CGSize size = CGSizeZero;
    BOOL havePos = NO;
    BOOL haveSize = NO;
    if (AXUIElementCopyAttributeValue(win, kAXPositionAttribute, &posRef) == kAXErrorSuccess && posRef) {
        havePos = AXValueGetValue((AXValueRef)posRef, (AXValueType)kAXValueCGPointType, &pos);
        CFRelease(posRef);
    }
    if (AXUIElementCopyAttributeValue(win, kAXSizeAttribute, &sizeRef) == kAXErrorSuccess && sizeRef) {
        haveSize = AXValueGetValue((AXValueRef)sizeRef, (AXValueType)kAXValueCGSizeType, &size);
        CFRelease(sizeRef);
    }
    if (!havePos || !haveSize || size.width < 1.0 || size.height < 1.0) {
        return NO;
    }
    *outCocoa = [self cocoaRectFromAXPosition:pos size:size];
    return YES;
}

@end
