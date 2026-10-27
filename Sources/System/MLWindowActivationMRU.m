#import "MLWindowActivationMRU.h"

enum {
    MLWindowActivationMRUDefaultWindowCap = 64,
    MLWindowActivationMRUDefaultPathCap = 64,
    MLWindowActivationMRUDefaultScreenCap = 16,
};

@interface MLWindowActivationMRU ()
@property (nonatomic, strong) NSMutableArray<NSNumber *> *windowOrder;
@property (nonatomic, strong) NSMutableArray<NSString *> *pathOrder;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *screenOrder;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *pathByWindowID;
@end

@implementation MLWindowActivationMRU

- (instancetype)init {
    self = [super init];
    if (self) {
        _windowCapacity = MLWindowActivationMRUDefaultWindowCap;
        _pathCapacity = MLWindowActivationMRUDefaultPathCap;
        _screenCapacity = MLWindowActivationMRUDefaultScreenCap;
        _windowOrder = [NSMutableArray array];
        _pathOrder = [NSMutableArray array];
        _screenOrder = [NSMutableArray array];
        _pathByWindowID = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)standardizedPath:(NSString *)path {
    if (path.length == 0) {
        return @"";
    }
    NSString *std = path.stringByStandardizingPath;
    return std.length > 0 ? std : path;
}

- (void)touchScreenID:(NSNumber *)screenID {
    if (!screenID) {
        return;
    }
    NSUInteger idx = [self.screenOrder indexOfObject:screenID];
    if (idx != NSNotFound) {
        [self.screenOrder removeObjectAtIndex:idx];
    }
    [self.screenOrder insertObject:screenID atIndex:0];
    while (self.screenOrder.count > self.screenCapacity) {
        [self.screenOrder removeLastObject];
    }
}

- (void)touchWindowID:(CGWindowID)windowID
                 path:(NSString *)path
             screenID:(NSNumber *)screenID {
    if (windowID == 0) {
        if (path.length > 0) {
            [self touchPath:path screenID:screenID];
        }
        return;
    }
    NSNumber *key = @(windowID);
    NSUInteger idx = [self.windowOrder indexOfObject:key];
    if (idx != NSNotFound) {
        [self.windowOrder removeObjectAtIndex:idx];
    }
    [self.windowOrder insertObject:key atIndex:0];
    while (self.windowOrder.count > self.windowCapacity) {
        NSNumber *dropped = self.windowOrder.lastObject;
        [self.windowOrder removeLastObject];
        if (dropped) {
            [self.pathByWindowID removeObjectForKey:dropped];
        }
    }
    NSString *std = [self standardizedPath:path];
    if (std.length > 0) {
        self.pathByWindowID[key] = std;
        /* Also bump path MRU so NoWindow/Pin can follow recent app use. */
        [self touchPath:std screenID:nil];
    }
    [self touchScreenID:screenID];
}

- (void)touchPath:(NSString *)path screenID:(NSNumber *)screenID {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return;
    }
    NSUInteger idx = [self.pathOrder indexOfObject:std];
    if (idx != NSNotFound) {
        [self.pathOrder removeObjectAtIndex:idx];
    }
    [self.pathOrder insertObject:std atIndex:0];
    while (self.pathOrder.count > self.pathCapacity) {
        [self.pathOrder removeLastObject];
    }
    [self touchScreenID:screenID];
}

- (void)removeWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return;
    }
    NSNumber *key = @(windowID);
    [self.windowOrder removeObject:key];
    [self.pathByWindowID removeObjectForKey:key];
}

- (void)removePath:(NSString *)path {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return;
    }
    [self.pathOrder removeObject:std];
}

- (NSInteger)rankForWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return NSIntegerMax;
    }
    NSUInteger idx = [self.windowOrder indexOfObject:@(windowID)];
    return idx == NSNotFound ? NSIntegerMax : (NSInteger)idx;
}

- (NSInteger)rankForPath:(NSString *)path {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return NSIntegerMax;
    }
    NSUInteger idx = [self.pathOrder indexOfObject:std];
    return idx == NSNotFound ? NSIntegerMax : (NSInteger)idx;
}

- (NSInteger)rankForScreenID:(NSNumber *)screenID {
    if (!screenID) {
        return NSIntegerMax;
    }
    NSUInteger idx = [self.screenOrder indexOfObject:screenID];
    return idx == NSNotFound ? NSIntegerMax : (NSInteger)idx;
}

- (void)pruneToLiveWindowIDs:(NSSet<NSNumber *> *)liveWindowIDs
                   livePaths:(NSSet<NSString *> *)livePaths {
    if (liveWindowIDs) {
        NSMutableArray<NSNumber *> *kept = [NSMutableArray array];
        for (NSNumber *wid in self.windowOrder) {
            if ([liveWindowIDs containsObject:wid]) {
                [kept addObject:wid];
            } else {
                [self.pathByWindowID removeObjectForKey:wid];
            }
        }
        self.windowOrder = kept;
    }
    if (livePaths) {
        NSMutableSet<NSString *> *stdLive = [NSMutableSet set];
        for (NSString *p in livePaths) {
            NSString *std = [self standardizedPath:p];
            if (std.length > 0) {
                [stdLive addObject:std];
            }
        }
        NSMutableArray<NSString *> *keptPaths = [NSMutableArray array];
        for (NSString *p in self.pathOrder) {
            if ([stdLive containsObject:p]) {
                [keptPaths addObject:p];
            }
        }
        self.pathOrder = keptPaths;
    }
}

@end
