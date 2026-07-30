#import "MLTaskbarPinStore.h"

NSNotificationName const MLTaskbarPinsDidChangeNotification = @"MLTaskbarPinsDidChangeNotification";

@interface MLTaskbarPinStore ()
@property (nonatomic, strong) NSMutableArray<NSString *> *pins;
@property (nonatomic, strong) NSTimer *saveTimer;
@end

@implementation MLTaskbarPinStore

+ (NSURL *)pinsFileURL {
    NSString *override = NSProcessInfo.processInfo.environment[@"MEOLAUNCH_TASKBAR_PINS_PATH"];
    if (override.length > 0) {
        return [NSURL fileURLWithPath:override];
    }
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                    inDomains:NSUserDomainMask];
    NSURL *base = urls.firstObject;
    return [base URLByAppendingPathComponent:@"meoLaunch/taskbar_pins.json"];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _pins = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [self.saveTimer invalidate];
}

- (NSArray<NSString *> *)pinnedPaths {
    return [self.pins copy];
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:MLTaskbarPinsDidChangeNotification
                                                        object:self];
}

- (BOOL)loadFromDisk {
    NSURL *url = [[self class] pinsFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:url.path]) {
        return NO;
    }

    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&err];
    if (!data) {
        NSLog(@"[MeoLaunch] taskbar pins read failed: %@", err);
        return NO;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[MeoLaunch] taskbar pins corrupt, ignoring: %@", err);
        return NO;
    }

    NSArray *arr = ((NSDictionary *)json)[@"pins"];
    [self.pins removeAllObjects];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (id item in arr) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                NSString *path = (NSString *)item;
                if (![self.pins containsObject:path]) {
                    [self.pins addObject:path];
                }
            }
        }
    }
    NSLog(@"[MeoLaunch] taskbar pins loaded %@ (%lu)", url.path, (unsigned long)self.pins.count);
    return YES;
}

- (BOOL)saveToDisk {
    NSURL *url = [[self class] pinsFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtURL:[url URLByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&err]) {
        NSLog(@"[MeoLaunch] taskbar pins dir failed: %@", err);
        return NO;
    }

    NSDictionary *doc = @{
        @"version" : @1,
        @"pins" : [self.pins copy],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:doc
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data) {
        NSLog(@"[MeoLaunch] taskbar pins encode failed: %@", err);
        return NO;
    }
    if (![data writeToURL:url options:NSDataWritingAtomic error:&err]) {
        NSLog(@"[MeoLaunch] taskbar pins write failed: %@", err);
        return NO;
    }
    NSLog(@"[MeoLaunch] taskbar pins saved %@ (%lu)", url.path, (unsigned long)self.pins.count);
    return YES;
}

- (void)scheduleSave {
    [self.saveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                     repeats:NO
                                                       block:^(__unused NSTimer *timer) {
                                                           [weakSelf saveToDisk];
                                                       }];
}

- (BOOL)pinPath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    path = path.stringByStandardizingPath;
    if (path.length == 0) {
        return NO;
    }
    if ([self.pins containsObject:path]) {
        return NO;
    }
    for (NSString *existing in self.pins) {
        if ([existing.stringByStandardizingPath isEqualToString:path]) {
            return NO;
        }
    }
    [self.pins addObject:path];
    [self scheduleSave];
    [self notifyChanged];
    return YES;
}

- (BOOL)unpinPath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    NSString *std = path.stringByStandardizingPath;
    NSUInteger idx = [self.pins indexOfObject:path];
    if (idx == NSNotFound && std.length > 0) {
        idx = [self.pins indexOfObject:std];
    }
    if (idx == NSNotFound && std.length > 0) {
        for (NSUInteger i = 0; i < self.pins.count; i++) {
            if ([self.pins[i].stringByStandardizingPath isEqualToString:std]) {
                idx = i;
                break;
            }
        }
    }
    if (idx == NSNotFound) {
        return NO;
    }
    [self.pins removeObjectAtIndex:idx];
    [self scheduleSave];
    [self notifyChanged];
    return YES;
}

- (BOOL)isPinned:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    if ([self.pins containsObject:path]) {
        return YES;
    }
    NSString *std = path.stringByStandardizingPath;
    if (std.length == 0) {
        return NO;
    }
    if ([self.pins containsObject:std]) {
        return YES;
    }
    for (NSString *existing in self.pins) {
        if ([existing.stringByStandardizingPath isEqualToString:std]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)movePinFrom:(NSInteger)from to:(NSInteger)to {
    if (from < 0 || to < 0 || from >= (NSInteger)self.pins.count || to >= (NSInteger)self.pins.count) {
        return NO;
    }
    if (from == to) {
        return YES;
    }
    NSString *path = self.pins[(NSUInteger)from];
    [self.pins removeObjectAtIndex:(NSUInteger)from];
    [self.pins insertObject:path atIndex:(NSUInteger)to];
    [self scheduleSave];
    [self notifyChanged];
    return YES;
}

@end
