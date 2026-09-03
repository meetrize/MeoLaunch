#import "MLIconCache.h"

#import <CommonCrypto/CommonDigest.h>

static const NSUInteger kMLIconLoadConcurrency = 12;

@interface MLIconCache ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *cache;
@property (nonatomic, strong) NSMutableArray<NSString *> *lru; /* most-recent at end */
@property (nonatomic, strong) NSMutableSet<NSString *> *inflight;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) dispatch_queue_t diskQueue;
@property (nonatomic, strong) dispatch_semaphore_t loadSemaphore;
@property (nonatomic, strong) NSURL *diskCacheDirectory;
/** Bumped on RAM purge so in-flight loads do not repopulate the cache. */
@property (nonatomic, assign) NSUInteger loadGeneration;
/** After one directory probe (or a successful write). */
@property (nonatomic, assign) BOOL diskDirectoryProbed;
/** YES only when disk may contain hits — skip file I/O on cold first launch. */
@property (nonatomic, assign) BOOL diskHasEntries;
@end

@implementation MLIconCache

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [NSMutableDictionary dictionary];
        _lru = [NSMutableArray array];
        _inflight = [NSMutableSet set];
        _maxEntries = 128;
        _iconPointSize = 128.0;
        _diskCacheEnabled = NO;
        _diskCacheMaxEntries = 256;
        _diskDirectoryProbed = NO;
        _diskHasEntries = NO;
        _queue = dispatch_queue_create("com.meetrice.meolaunch.iconcache", DISPATCH_QUEUE_CONCURRENT);
        _diskQueue = dispatch_queue_create("com.meetrice.meolaunch.iconcache.disk", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_diskQueue,
                                  dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        _loadSemaphore = dispatch_semaphore_create((long)kMLIconLoadConcurrency);
    }
    return self;
}

- (CGFloat)effectiveIconPointSize {
    return self.iconPointSize > 0 ? self.iconPointSize : 128.0;
}

- (void)touchKey:(NSString *)path {
    [self.lru removeObject:path];
    [self.lru addObject:path];
}

- (void)evictIfNeeded {
    while (self.cache.count > self.maxEntries && self.lru.count > 0) {
        NSString *oldest = self.lru.firstObject;
        [self.lru removeObjectAtIndex:0];
        [self.cache removeObjectForKey:oldest];
    }
}

- (NSImage *)cachedIconForPath:(NSString *)path {
    if (path.length == 0) {
        return nil;
    }
    @synchronized (self.cache) {
        NSImage *img = self.cache[path];
        if (img) {
            [self touchKey:path];
        }
        return img;
    }
}

#pragma mark - Disk

- (NSURL *)ensureDiskCacheDirectory {
    if (self.diskCacheDirectory) {
        return self.diskCacheDirectory;
    }
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory
                                                                    inDomains:NSUserDomainMask];
    NSURL *base = urls.firstObject;
    if (!base) {
        return nil;
    }
    NSURL *dir = [base URLByAppendingPathComponent:@"com.meetrice.meolaunch/overlay-icons"
                                       isDirectory:YES];
    NSError *err = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&err]) {
        if (err) {
            NSLog(@"[MeoLaunch] icon disk cache mkdir failed: %@", err);
        }
        return nil;
    }
    self.diskCacheDirectory = dir;
    return dir;
}

- (void)probeDiskDirectoryIfNeeded {
    if (self.diskDirectoryProbed || !self.diskCacheEnabled) {
        return;
    }
    self.diskDirectoryProbed = YES;
    NSURL *dir = [self ensureDiskCacheDirectory];
    if (!dir) {
        self.diskHasEntries = NO;
        return;
    }
    NSError *err = nil;
    NSArray<NSURL *> *files =
        [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir
                                      includingPropertiesForKeys:nil
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                           error:&err];
    self.diskHasEntries = (files.count > 0);
}

- (NSString *)diskFileNameForPath:(NSString *)path pointSize:(CGFloat)pointSize {
    const char *c = path.UTF8String ?: "";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256((const unsigned char *)c, (CC_LONG)strlen(c), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    int sz = (int)lround(pointSize);
    return [NSString stringWithFormat:@"%@_%d.png", hex, sz];
}

- (NSURL *)diskURLForPath:(NSString *)path pointSize:(CGFloat)pointSize {
    NSURL *dir = [self ensureDiskCacheDirectory];
    if (!dir) {
        return nil;
    }
    return [dir URLByAppendingPathComponent:[self diskFileNameForPath:path pointSize:pointSize]
                                isDirectory:NO];
}

- (NSImage *)loadImageFromDiskURL:(NSURL *)url pointSize:(CGFloat)pointSize {
    if (!url) {
        return nil;
    }
    /* Cheap miss: avoid decoding work when file absent. */
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return nil;
    }
    NSImage *img = [[NSImage alloc] initWithContentsOfURL:url];
    if (!img) {
        return nil;
    }
    [img setSize:NSMakeSize(pointSize, pointSize)];
    return img;
}

- (void)writeImage:(NSImage *)image toDiskURL:(NSURL *)url {
    if (!image || !url) {
        return;
    }
    NSData *tiff = image.TIFFRepresentation;
    if (!tiff.length) {
        return;
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:tiff];
    if (!rep) {
        return;
    }
    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png.length) {
        return;
    }
    if ([png writeToURL:url atomically:YES]) {
        self.diskDirectoryProbed = YES;
        self.diskHasEntries = YES;
        [self evictDiskIfNeeded];
    }
}

- (void)scheduleDiskWrite:(NSImage *)image forPath:(NSString *)path pointSize:(CGFloat)pointSize {
    if (!self.diskCacheEnabled || !image || path.length == 0) {
        return;
    }
    NSImage *snapshot = [image copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.diskQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        NSURL *diskURL = [self diskURLForPath:path pointSize:pointSize];
        [self writeImage:snapshot toDiskURL:diskURL];
    });
}

- (void)evictDiskIfNeeded {
    if (!self.diskCacheEnabled || self.diskCacheMaxEntries == 0) {
        return;
    }
    NSURL *dir = self.diskCacheDirectory;
    if (!dir) {
        return;
    }
    NSError *err = nil;
    NSArray<NSURL *> *files =
        [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir
                                      includingPropertiesForKeys:@[ NSURLContentModificationDateKey ]
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                           error:&err];
    if (!files || files.count <= self.diskCacheMaxEntries) {
        return;
    }
    NSArray<NSURL *> *sorted =
        [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
            NSDate *da = nil;
            NSDate *db = nil;
            [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
            [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
            if (!da && !db) {
                return NSOrderedSame;
            }
            if (!da) {
                return NSOrderedAscending;
            }
            if (!db) {
                return NSOrderedDescending;
            }
            return [da compare:db];
        }];
    NSUInteger excess = sorted.count - self.diskCacheMaxEntries;
    for (NSUInteger i = 0; i < excess; i++) {
        [[NSFileManager defaultManager] removeItemAtURL:sorted[i] error:nil];
    }
}

- (void)storeInRAM:(NSImage *)image forPath:(NSString *)path generation:(NSUInteger)gen {
    if (!image || path.length == 0) {
        return;
    }
    @synchronized (self.cache) {
        if (gen != self.loadGeneration) {
            return;
        }
        self.cache[path] = image;
        [self touchKey:path];
        [self evictIfNeeded];
    }
}

#pragma mark - Load

- (void)loadIconForPath:(NSString *)path onLoaded:(void (^)(NSString *path, NSImage *image))onLoaded {
    if (path.length == 0 || !onLoaded) {
        return;
    }

    NSImage *existing = [self cachedIconForPath:path];
    if (existing) {
        dispatch_async(dispatch_get_main_queue(), ^{
            onLoaded(path, existing);
        });
        return;
    }

    @synchronized (self.inflight) {
        if ([self.inflight containsObject:path]) {
            return;
        }
        [self.inflight addObject:path];
    }

    NSUInteger gen;
    @synchronized (self.cache) {
        gen = self.loadGeneration;
    }

    CGFloat pointSize = [self effectiveIconPointSize];
    BOOL useDisk = self.diskCacheEnabled;
    dispatch_semaphore_t sem = self.loadSemaphore;

    dispatch_async(self.queue, ^{
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        NSImage *copy = nil;
        BOOL loadedFromWorkspace = NO;
        @autoreleasepool {
            if (useDisk) {
                [self probeDiskDirectoryIfNeeded];
                if (self.diskHasEntries) {
                    NSURL *diskURL = [self diskURLForPath:path pointSize:pointSize];
                    copy = [self loadImageFromDiskURL:diskURL pointSize:pointSize];
                    if (copy) {
                        copy = [copy copy];
                    }
                }
            }

            if (!copy) {
                NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
                [icon setSize:NSMakeSize(pointSize, pointSize)];
                copy = [icon copy];
                loadedFromWorkspace = (copy != nil);
            }

            [self storeInRAM:copy forPath:path generation:gen];
        }
        @synchronized (self.inflight) {
            [self.inflight removeObject:path];
        }
        /* Release slot before any disk encode — first paint must not wait on PNG. */
        dispatch_semaphore_signal(sem);

        if (loadedFromWorkspace && useDisk && copy) {
            [self scheduleDiskWrite:copy forPath:path pointSize:pointSize];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger cur;
            @synchronized (self.cache) {
                cur = self.loadGeneration;
            }
            if (gen == cur) {
                onLoaded(path, copy);
            }
        });
    });
}

- (void)purge {
    @synchronized (self.cache) {
        self.loadGeneration += 1;
        [self.cache removeAllObjects];
        [self.lru removeAllObjects];
    }
    @synchronized (self.inflight) {
        [self.inflight removeAllObjects];
    }
}

- (void)purgeDiskCache {
    if (!self.diskCacheEnabled) {
        return;
    }
    NSURL *dir = [self ensureDiskCacheDirectory];
    if (!dir) {
        return;
    }
    NSError *err = nil;
    NSArray<NSURL *> *files =
        [[NSFileManager defaultManager] contentsOfDirectoryAtURL:dir
                                      includingPropertiesForKeys:nil
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                           error:&err];
    for (NSURL *file in files) {
        [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
    }
    self.diskDirectoryProbed = YES;
    self.diskHasEntries = NO;
}

- (NSUInteger)cachedCount {
    @synchronized (self.cache) {
        return self.cache.count;
    }
}

@end
