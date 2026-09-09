#import "MLTaskbarHideStore.h"

#import "MLDebouncedSave.h"

NSNotificationName const MLTaskbarHideDidChangeNotification = @"MLTaskbarHideDidChangeNotification";

@interface MLTaskbarHideStore ()
@property (nonatomic, strong) NSMutableArray<NSString *> *hidden;
@property (nonatomic, strong) MLDebouncedSave *saveDebouncer;
@end

@implementation MLTaskbarHideStore

+ (NSURL *)hiddenChipsFileURL {
    NSString *override = NSProcessInfo.processInfo.environment[@"MEOLAUNCH_TASKBAR_HIDDEN_CHIPS_PATH"];
    if (override.length > 0) {
        return [NSURL fileURLWithPath:override];
    }
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                    inDomains:NSUserDomainMask];
    NSURL *base = urls.firstObject;
    return [base URLByAppendingPathComponent:@"meoLaunch/taskbar_hidden_chips.json"];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _hidden = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [_saveDebouncer cancel];
}

- (NSArray<NSString *> *)hiddenPaths {
    return [self.hidden copy];
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:MLTaskbarHideDidChangeNotification
                                                        object:self];
}

- (BOOL)loadFromDisk {
    NSURL *url = [[self class] hiddenChipsFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:url.path]) {
        return NO;
    }

    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&err];
    if (!data) {
        NSLog(@"[MeoLaunch] taskbar hidden chips read failed: %@", err);
        return NO;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[MeoLaunch] taskbar hidden chips corrupt, ignoring: %@", err);
        return NO;
    }

    NSArray *arr = ((NSDictionary *)json)[@"hidden"];
    [self.hidden removeAllObjects];
    if ([arr isKindOfClass:[NSArray class]]) {
        for (id item in arr) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                NSString *path = (NSString *)item;
                if (![self.hidden containsObject:path]) {
                    [self.hidden addObject:path];
                }
            }
        }
    }
    NSLog(@"[MeoLaunch] taskbar hidden chips loaded %@ (%lu)", url.path, (unsigned long)self.hidden.count);
    return YES;
}

- (BOOL)saveToDisk {
    NSURL *url = [[self class] hiddenChipsFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtURL:[url URLByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&err]) {
        NSLog(@"[MeoLaunch] taskbar hidden chips dir failed: %@", err);
        return NO;
    }

    NSDictionary *doc = @{
        @"version" : @1,
        @"hidden" : [self.hidden copy],
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:doc
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data) {
        NSLog(@"[MeoLaunch] taskbar hidden chips encode failed: %@", err);
        return NO;
    }
    if (![data writeToURL:url options:NSDataWritingAtomic error:&err]) {
        NSLog(@"[MeoLaunch] taskbar hidden chips write failed: %@", err);
        return NO;
    }
    NSLog(@"[MeoLaunch] taskbar hidden chips saved %@ (%lu)", url.path, (unsigned long)self.hidden.count);
    return YES;
}

- (MLDebouncedSave *)saveDebouncer {
    if (!_saveDebouncer) {
        __weak typeof(self) weakSelf = self;
        _saveDebouncer = [[MLDebouncedSave alloc] initWithAction:^{
            [weakSelf saveToDisk];
        }];
    }
    return _saveDebouncer;
}

- (void)scheduleSave {
    [self.saveDebouncer schedule];
}

- (BOOL)hidePath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    path = path.stringByStandardizingPath;
    if (path.length == 0) {
        return NO;
    }
    if ([self isHidden:path]) {
        return NO;
    }
    [self.hidden addObject:path];
    [self scheduleSave];
    [self notifyChanged];
    return YES;
}

- (BOOL)unhidePath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    NSString *std = path.stringByStandardizingPath;
    NSUInteger idx = [self.hidden indexOfObject:path];
    if (idx == NSNotFound && std.length > 0) {
        idx = [self.hidden indexOfObject:std];
    }
    if (idx == NSNotFound && std.length > 0) {
        for (NSUInteger i = 0; i < self.hidden.count; i++) {
            if ([self.hidden[i].stringByStandardizingPath isEqualToString:std]) {
                idx = i;
                break;
            }
        }
    }
    if (idx == NSNotFound) {
        return NO;
    }
    [self.hidden removeObjectAtIndex:idx];
    [self scheduleSave];
    [self notifyChanged];
    return YES;
}

- (BOOL)isHidden:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    if ([self.hidden containsObject:path]) {
        return YES;
    }
    NSString *std = path.stringByStandardizingPath;
    if (std.length == 0) {
        return NO;
    }
    if ([self.hidden containsObject:std]) {
        return YES;
    }
    for (NSString *existing in self.hidden) {
        if ([existing.stringByStandardizingPath isEqualToString:std]) {
            return YES;
        }
    }
    return NO;
}

@end
