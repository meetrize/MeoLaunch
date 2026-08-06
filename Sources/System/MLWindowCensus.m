#import "MLWindowCensus.h"

#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>

@interface MLWindowCensus ()
@property (nonatomic, assign) CFArrayRef cachedOnScreenList;
@property (nonatomic, assign) CFArrayRef cachedAllList;
@property (nonatomic, assign) NSTimeInterval lastRefreshTime;
@end

@implementation MLWindowCensus

- (instancetype)init {
    self = [super init];
    if (self) {
        _maxStaleInterval = 0.25;
    }
    return self;
}

- (void)dealloc {
    if (_cachedOnScreenList) {
        CFRelease(_cachedOnScreenList);
        _cachedOnScreenList = NULL;
    }
    if (_cachedAllList) {
        CFRelease(_cachedAllList);
        _cachedAllList = NULL;
    }
}

+ (NSInteger)screenIndexForCocoaPoint:(CGPoint)point {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    for (NSInteger i = 0; i < (NSInteger)screens.count; i++) {
        if (NSPointInRect(NSMakePoint(point.x, point.y), screens[(NSUInteger)i].frame)) {
            return i;
        }
    }
    return -1;
}

- (void)replaceCachedList:(CFArrayRef _Nullable * _Nonnull)slot withNewList:(CFArrayRef)newList {
    if (*slot) {
        CFRelease(*slot);
        *slot = NULL;
    }
    if (newList) {
        *slot = (CFArrayRef)CFRetain(newList);
    }
}

- (void)refreshWindowLists {
    CFArrayRef onScreen = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                         kCGWindowListExcludeDesktopElements,
                                                     kCGNullWindowID);
    CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionAll |
                                                   kCGWindowListExcludeDesktopElements,
                                               kCGNullWindowID);
    [self replaceCachedList:&_cachedOnScreenList withNewList:onScreen];
    [self replaceCachedList:&_cachedAllList withNewList:all];
    if (onScreen) {
        CFRelease(onScreen);
    }
    if (all) {
        CFRelease(all);
    }
    self.lastRefreshTime = [NSDate date].timeIntervalSinceReferenceDate;
}

- (BOOL)shouldRefreshForStaleCheck:(BOOL)refreshIfStale {
    if (!refreshIfStale) {
        return NO;
    }
    if (!_cachedOnScreenList || !_cachedAllList) {
        return YES;
    }
    if (self.maxStaleInterval <= 0) {
        return YES;
    }
    NSTimeInterval age = [NSDate date].timeIntervalSinceReferenceDate - self.lastRefreshTime;
    return age > self.maxStaleInterval;
}

- (CFArrayRef)cachedOnScreenWindowListRefreshingIfNeeded:(BOOL)refreshIfStale {
    if ([self shouldRefreshForStaleCheck:refreshIfStale]) {
        [self refreshWindowLists];
    }
    return _cachedOnScreenList;
}

- (CFArrayRef)cachedAllWindowListRefreshingIfNeeded:(BOOL)refreshIfStale {
    if ([self shouldRefreshForStaleCheck:refreshIfStale]) {
        [self refreshWindowLists];
    }
    return _cachedAllList;
}

- (NSString *)computeTokenSkippingSoftHidden:(NSSet<NSNumber *> *)softHiddenIDs {
    CFArrayRef list = [self cachedOnScreenWindowListRefreshingIfNeeded:YES];
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
