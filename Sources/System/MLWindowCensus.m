#import "MLWindowCensus.h"

#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>

@implementation MLWindowCensus

+ (NSInteger)screenIndexForCocoaPoint:(CGPoint)point {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    for (NSInteger i = 0; i < (NSInteger)screens.count; i++) {
        if (NSPointInRect(NSMakePoint(point.x, point.y), screens[(NSUInteger)i].frame)) {
            return i;
        }
    }
    return -1;
}

- (NSString *)computeTokenSkippingSoftHidden:(NSSet<NSNumber *> *)softHiddenIDs {
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                     kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    if (!list) {
        return @"";
    }
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        if (!info) {
            continue;
        }
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        int layer = 0;
        if (layerRef) {
            CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        }
        if (layer != 0) {
            continue;
        }
        CGRect bounds = CGRectZero;
        CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
        if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)) {
            continue;
        }
        if (bounds.size.width < 100.0 || bounds.size.height < 80.0) {
            continue;
        }
        CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
        if (alphaRef) {
            double alpha = 1.0;
            CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
            if (alpha < 0.1) {
                continue;
            }
        }
        CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
        CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
        CGWindowID wid = 0;
        pid_t pid = 0;
        if (winRef) {
            CFNumberGetValue(winRef, kCFNumberIntType, &wid);
        }
        if (pidRef) {
            CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
        }
        if (wid == 0 || pid <= 0) {
            continue;
        }
        if ([softHiddenIDs containsObject:@(wid)]) {
            continue;
        }
        CGPoint mid = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
        NSInteger screenIdx = [[self class] screenIndexForCocoaPoint:mid];
        int bw = (int)(bounds.size.width / 32.0);
        int bh = (int)(bounds.size.height / 32.0);
        [rows addObject:[NSString stringWithFormat:@"%u:%d:%ld:%d:%d",
                                                   (unsigned)wid, (int)pid, (long)screenIdx, bw, bh]];
    }
    CFRelease(list);
    [rows sortUsingSelector:@selector(compare:)];
    if (softHiddenIDs.count > 0) {
        NSArray *soft = [[softHiddenIDs allObjects] sortedArrayUsingSelector:@selector(compare:)];
        for (NSNumber *widNum in soft) {
            [rows addObject:[NSString stringWithFormat:@"soft:%u", (unsigned)widNum.unsignedIntValue]];
        }
    }
    return [rows componentsJoinedByString:@"|"];
}

@end
