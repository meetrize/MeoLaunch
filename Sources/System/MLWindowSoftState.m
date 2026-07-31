#import "MLWindowSoftState.h"

NSNotificationName const MLWindowSoftStateDidChangeNotification = @"MLWindowSoftStateDidChangeNotification";

@implementation MLWindowSoftRecord

- (void)dealloc {
    if (_axWindow) {
        CFRelease(_axWindow);
        _axWindow = NULL;
    }
}

- (void)setAxWindow:(AXUIElementRef)axWindow {
    if (_axWindow == axWindow) {
        return;
    }
    if (_axWindow) {
        CFRelease(_axWindow);
    }
    _axWindow = axWindow ? (AXUIElementRef)CFRetain(axWindow) : NULL;
}

@end

@interface MLWindowSoftState ()
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, MLWindowSoftRecord *> *byID;
@end

@implementation MLWindowSoftState

- (instancetype)init {
    self = [super init];
    if (self) {
        _byID = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)notify {
    [[NSNotificationCenter defaultCenter] postNotificationName:MLWindowSoftStateDidChangeNotification
                                                        object:self];
}

- (BOOL)isSoftHiddenWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return NO;
    }
    return self.byID[@(windowID)] != nil;
}

- (MLWindowSoftRecord *)recordForWindowID:(CGWindowID)windowID {
    if (windowID == 0) {
        return nil;
    }
    return self.byID[@(windowID)];
}

- (NSArray<MLWindowSoftRecord *> *)allRecords {
    return [self.byID.allValues copy];
}

- (NSSet<NSNumber *> *)softHiddenWindowIDs {
    return [NSSet setWithArray:self.byID.allKeys];
}

- (BOOL)hasRestoreFrameForWindowID:(CGWindowID)windowID {
    MLWindowSoftRecord *r = [self recordForWindowID:windowID];
    return r && r.restoreFrameCocoa.size.width > 2.0 && r.restoreFrameCocoa.size.height > 2.0;
}

- (NSRect)restoreFrameForWindowID:(CGWindowID)windowID {
    MLWindowSoftRecord *r = [self recordForWindowID:windowID];
    return r ? r.restoreFrameCocoa : NSZeroRect;
}

- (void)markSoftHiddenWindowID:(CGWindowID)windowID
                           pid:(pid_t)pid
                          path:(NSString *)path
                         title:(NSString *)title
                 restoreFrame:(NSRect)restoreFrameCocoa
                     screenID:(NSNumber *)screenID
                   hideMethod:(MLWindowHideMethod)method
                    seenOrder:(NSUInteger)seenOrder
                     axWindow:(AXUIElementRef)axWindow {
    if (windowID == 0) {
        NSLog(@"[Taskbar] soft mark skipped — windowID=0 pid=%d title=%@", (int)pid, title ?: @"");
        return;
    }
    MLWindowSoftRecord *r = self.byID[@(windowID)];
    if (!r) {
        r = [[MLWindowSoftRecord alloc] init];
        r.windowID = windowID;
        self.byID[@(windowID)] = r;
    }
    r.pid = pid;
    if (path.length > 0) {
        r.path = path;
    }
    if (title) {
        r.title = title;
    }
    if (restoreFrameCocoa.size.width > 2.0 && restoreFrameCocoa.size.height > 2.0) {
        r.restoreFrameCocoa = restoreFrameCocoa;
    }
    if (screenID) {
        r.affinityScreenID = screenID;
    }
    if (method != MLWindowHideMethodNone) {
        r.hideMethod = method;
    }
    if (seenOrder > 0) {
        r.seenOrder = seenOrder;
    }
    if (axWindow) {
        r.axWindow = axWindow;
    }
    NSLog(@"[Taskbar] soft mark wid=%u pid=%d method=%ld frame=(%.0f,%.0f %.0fx%.0f) ax=%p",
          (unsigned)windowID, (int)pid, (long)r.hideMethod,
          r.restoreFrameCocoa.origin.x, r.restoreFrameCocoa.origin.y,
          r.restoreFrameCocoa.size.width, r.restoreFrameCocoa.size.height,
          r.axWindow);
    [self notify];
}

- (void)updateHideMethod:(MLWindowHideMethod)method forWindowID:(CGWindowID)windowID {
    MLWindowSoftRecord *r = [self recordForWindowID:windowID];
    if (!r) {
        return;
    }
    r.hideMethod = method;
    NSLog(@"[Taskbar] soft hideMethod wid=%u → %ld", (unsigned)windowID, (long)method);
    [self notify];
}

- (void)clearVerifiedWindowID:(CGWindowID)windowID {
    if (windowID == 0 || !self.byID[@(windowID)]) {
        return;
    }
    NSLog(@"[Taskbar] soft clear verified wid=%u", (unsigned)windowID);
    [self.byID removeObjectForKey:@(windowID)];
    [self notify];
}

- (void)removeClosedWindowID:(CGWindowID)windowID {
    if (windowID == 0 || !self.byID[@(windowID)]) {
        return;
    }
    NSLog(@"[Taskbar] soft remove closed wid=%u", (unsigned)windowID);
    [self.byID removeObjectForKey:@(windowID)];
    [self notify];
}

- (void)removeAll {
    if (self.byID.count == 0) {
        return;
    }
    [self.byID removeAllObjects];
    [self notify];
}

@end
