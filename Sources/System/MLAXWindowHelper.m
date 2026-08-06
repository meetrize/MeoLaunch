#import "MLAXWindowHelper.h"

#import <dlfcn.h>

typedef AXError (*MLAXGetWindowFn)(AXUIElementRef, CGWindowID *);

@implementation MLAXWindowHelper

+ (MLAXGetWindowFn)resolvedGetWindowFn {
    static MLAXGetWindowFn sFn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sFn = (MLAXGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    });
    return sFn;
}

+ (CGWindowID)windowIDForAXWindow:(AXUIElementRef)win {
    if (!win) {
        return kCGNullWindowID;
    }
    MLAXGetWindowFn fn = [self resolvedGetWindowFn];
    if (!fn) {
        return kCGNullWindowID;
    }
    CGWindowID wid = kCGNullWindowID;
    if (fn(win, &wid) != kAXErrorSuccess) {
        return kCGNullWindowID;
    }
    return wid;
}

+ (BOOL)copyStringAttribute:(CFStringRef)attr
                fromElement:(AXUIElementRef)el
                       into:(NSString **)out {
    if (!el || !out) {
        return NO;
    }
    CFTypeRef ref = NULL;
    if (AXUIElementCopyAttributeValue(el, attr, &ref) != kAXErrorSuccess || !ref) {
        return NO;
    }
    BOOL ok = NO;
    if (CFGetTypeID(ref) == CFStringGetTypeID()) {
        *out = [(__bridge NSString *)ref copy];
        ok = YES;
    }
    CFRelease(ref);
    return ok;
}

+ (AXUIElementRef)copyWindowElementFromElement:(AXUIElementRef)el {
    if (!el) {
        return NULL;
    }
    CFTypeRef winRef = NULL;
    if (AXUIElementCopyAttributeValue(el, kAXWindowAttribute, &winRef) == kAXErrorSuccess && winRef) {
        return (AXUIElementRef)winRef;
    }
    AXUIElementRef cur = (AXUIElementRef)CFRetain(el);
    for (int i = 0; i < 8; i++) {
        NSString *role = nil;
        [self copyStringAttribute:kAXRoleAttribute fromElement:cur into:&role];
        if ([role isEqualToString:(__bridge NSString *)kAXWindowRole]) {
            return cur;
        }
        CFTypeRef parent = NULL;
        if (AXUIElementCopyAttributeValue(cur, kAXParentAttribute, &parent) != kAXErrorSuccess || !parent) {
            CFRelease(cur);
            return NULL;
        }
        CFRelease(cur);
        cur = (AXUIElementRef)parent;
    }
    CFRelease(cur);
    return NULL;
}

+ (BOOL)isFullscreen:(AXUIElementRef)win {
    if (!win) {
        return NO;
    }
    CFTypeRef ref = NULL;
    if (AXUIElementCopyAttributeValue(win, CFSTR("AXFullScreen"), &ref) != kAXErrorSuccess || !ref) {
        return NO;
    }
    BOOL fs = NO;
    if (CFGetTypeID(ref) == CFBooleanGetTypeID()) {
        fs = CFBooleanGetValue((CFBooleanRef)ref);
    }
    CFRelease(ref);
    return fs;
}

@end
