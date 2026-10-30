#import "MLIconCache.h"

#import <CommonCrypto/CommonDigest.h>

NSNotificationName const MLIconCacheRefreshRequestedNotification =
    @"MLIconCacheRefreshRequestedNotification";

static const NSUInteger kMLIconLoadConcurrency = 10;
static const NSInteger kMLIconPixelCap = 512;

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

- (CGFloat)effectiveBackingScale {
    CGFloat scale = 0;
    NSArray<NSScreen *> *screens = [NSScreen screens];
    for (NSScreen *s in screens) {
        if (s.backingScaleFactor > scale) {
            scale = s.backingScaleFactor;
        }
    }
    if (scale < 1.0) {
        scale = [NSScreen mainScreen].backingScaleFactor;
    }
    if (scale < 1.0) {
        scale = 2.0;
    }
    return scale;
}

- (NSInteger)pixelEdgeForPointSize:(CGFloat)pointSize scale:(CGFloat)scale {
    NSInteger px = (NSInteger)ceil(pointSize * scale);
    if (px < 16) {
        px = 16;
    }
    if (px > kMLIconPixelCap) {
        px = kMLIconPixelCap;
    }
    return px;
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

#pragma mark - Source icon (prefer on-disk app resources)

/**
 * Read the app's own icon file / asset catalog when possible.
 * Icon Services (iconForFile) can keep a stale bitmap after an app replaces
 * its icon; bundle Resources are authoritative for refresh.
 */
- (NSImage *)iconFromAppBundleAtPath:(NSString *)path {
    if (path.length == 0 || ![path.pathExtension.lowercaseString isEqualToString:@"app"]) {
        return nil;
    }
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (!bundle) {
        return nil;
    }

    NSString *iconFile = [bundle objectForInfoDictionaryKey:@"CFBundleIconFile"];
    if ([iconFile isKindOfClass:[NSString class]] && iconFile.length > 0) {
        NSString *base = iconFile.stringByDeletingPathExtension;
        NSString *ext = iconFile.pathExtension.length > 0 ? iconFile.pathExtension : @"icns";
        NSString *resPath = [bundle pathForResource:base ofType:ext];
        if (!resPath) {
            /* NSBundle resource lookup is case-sensitive even on APFS. */
            NSString *resources =
                [path stringByAppendingPathComponent:@"Contents/Resources"];
            NSArray<NSString *> *files =
                [[NSFileManager defaultManager] contentsOfDirectoryAtPath:resources error:nil];
            NSString *want =
                iconFile.pathExtension.length > 0 ? iconFile
                                                  : [iconFile stringByAppendingPathExtension:@"icns"];
            for (NSString *name in files) {
                if ([name caseInsensitiveCompare:want] == NSOrderedSame ||
                    [name.stringByDeletingPathExtension caseInsensitiveCompare:base] ==
                        NSOrderedSame) {
                    resPath = [resources stringByAppendingPathComponent:name];
                    break;
                }
            }
        }
        if (resPath.length > 0) {
            NSImage *img = [[NSImage alloc] initWithContentsOfFile:resPath];
            if (img) {
                return img;
            }
        }
    }

    NSString *iconName = [bundle objectForInfoDictionaryKey:@"CFBundleIconName"];
    if ([iconName isKindOfClass:[NSString class]] && iconName.length > 0) {
        NSImage *named = [bundle imageForResource:iconName];
        if (named) {
            return named;
        }
    }
    return nil;
}

- (NSImage *)sourceIconForPath:(NSString *)path {
    NSImage *fromBundle = [self iconFromAppBundleAtPath:path];
    if (fromBundle) {
        return fromBundle;
    }
    return [[NSWorkspace sharedWorkspace] iconForFile:path];
}

#pragma mark - Slim rasterize

/**
 * Draw Workspace (or any) icon into a single bitmap at display pixel size.
 * Drop multi-resolution representations — those were the ~GB Active spike.
 */
- (NSImage *)slimImageFromSource:(NSImage *)source
                       pointSize:(CGFloat)pointSize
                           scale:(CGFloat)scale {
    if (!source || pointSize < 1.0) {
        return nil;
    }
    NSInteger px = [self pixelEdgeForPointSize:pointSize scale:scale];

    NSBitmapImageRep *rep =
        [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                pixelsWide:px
                                                pixelsHigh:px
                                             bitsPerSample:8
                                           samplesPerPixel:4
                                                  hasAlpha:YES
                                                  isPlanar:NO
                                            colorSpaceName:NSDeviceRGBColorSpace
                                               bytesPerRow:0
                                              bitsPerPixel:0];
    if (!rep) {
        return nil;
    }
    rep.size = NSMakeSize(pointSize, pointSize);

    NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    if (!ctx) {
        return nil;
    }
    /*
     * Bitmap context user space is rep.size (points), not pixelsWide.
     * Drawing with px×px on 2x clips to ~1/4 of the icon (bottom-left).
     */
    NSRect dst = NSMakeRect(0, 0, pointSize, pointSize);
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:ctx];
    ctx.imageInterpolation = NSImageInterpolationHigh;
    [[NSColor clearColor] set];
    NSRectFill(dst);
    [source drawInRect:dst
              fromRect:NSZeroRect
             operation:NSCompositingOperationSourceOver
              fraction:1.0
        respectFlipped:YES
                 hints:@{ NSImageHintInterpolation : @(NSImageInterpolationHigh) }];
    [NSGraphicsContext restoreGraphicsState];

    NSImage *slim = [[NSImage alloc] initWithSize:NSMakeSize(pointSize, pointSize)];
    [slim addRepresentation:rep];
    return slim;
}

- (NSBitmapImageRep *)bitmapRepFromSlimImage:(NSImage *)image {
    if (!image) {
        return nil;
    }
    for (NSImageRep *r in image.representations) {
        if ([r isKindOfClass:[NSBitmapImageRep class]]) {
            return (NSBitmapImageRep *)r;
        }
    }
    return nil;
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
    NSUInteger v2Count = 0;
    for (NSURL *file in files) {
        NSString *name = file.lastPathComponent ?: @"";
        if ([name hasSuffix:@"_v2.png"]) {
            v2Count += 1;
        } else {
            /* Drop pre-v2 / fat-TIFF leftovers so probe stays accurate. */
            [[NSFileManager defaultManager] removeItemAtURL:file error:nil];
        }
    }
    self.diskHasEntries = (v2Count > 0);
}

- (NSString *)diskFileNameForPath:(NSString *)path pixelEdge:(NSInteger)pixelEdge {
    const char *c = path.UTF8String ?: "";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256((const unsigned char *)c, (CC_LONG)strlen(c), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:16];
    for (int i = 0; i < 8; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    /* v2: point-space rasterize (v1 wrongly drew px×px and clipped). */
    return [NSString stringWithFormat:@"%@_%ldpx_v2.png", hex, (long)pixelEdge];
}

- (NSURL *)diskURLForPath:(NSString *)path pixelEdge:(NSInteger)pixelEdge {
    NSURL *dir = [self ensureDiskCacheDirectory];
    if (!dir) {
        return nil;
    }
    return [dir URLByAppendingPathComponent:[self diskFileNameForPath:path pixelEdge:pixelEdge]
                                isDirectory:NO];
}

- (NSImage *)loadSlimImageFromDiskURL:(NSURL *)url pointSize:(CGFloat)pointSize {
    if (!url) {
        return nil;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data.length) {
        return nil;
    }
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithData:data];
    if (!rep) {
        return nil;
    }
    rep.size = NSMakeSize(pointSize, pointSize);
    NSImage *slim = [[NSImage alloc] initWithSize:NSMakeSize(pointSize, pointSize)];
    [slim addRepresentation:rep];
    return slim;
}

/** PNG from the single bitmap rep only — never TIFFRepresentation. */
- (void)writeSlimImage:(NSImage *)image toDiskURL:(NSURL *)url {
    if (!image || !url) {
        return;
    }
    NSBitmapImageRep *rep = [self bitmapRepFromSlimImage:image];
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

- (void)scheduleDiskWrite:(NSImage *)slimImage
                  forPath:(NSString *)path
                pixelEdge:(NSInteger)pixelEdge {
    if (!self.diskCacheEnabled || !slimImage || path.length == 0) {
        return;
    }
    /* Slim image is already single-rep; retain for async write (no fat copy). */
    NSImage *hold = slimImage;
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.diskQueue, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        NSURL *diskURL = [self diskURLForPath:path pixelEdge:pixelEdge];
        [self writeSlimImage:hold toDiskURL:diskURL];
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

- (NSImage *)slimIconForPath:(NSString *)path pointSize:(CGFloat)pointSize {
    if (path.length == 0) {
        return nil;
    }
    NSImage *hit = [self cachedIconForPath:path];
    if (hit) {
        return hit;
    }
    CGFloat pts = pointSize > 0 ? pointSize : [self effectiveIconPointSize];
    CGFloat scale = [self effectiveBackingScale];
    NSInteger pixelEdge = [self pixelEdgeForPointSize:pts scale:scale];
    NSImage *slim = nil;
    @autoreleasepool {
        if (self.diskCacheEnabled) {
            [self probeDiskDirectoryIfNeeded];
            if (self.diskHasEntries) {
                NSURL *diskURL = [self diskURLForPath:path pixelEdge:pixelEdge];
                slim = [self loadSlimImageFromDiskURL:diskURL pointSize:pts];
            }
        }
        if (!slim) {
            NSImage *sourceIcon = [self sourceIconForPath:path];
            slim = [self slimImageFromSource:sourceIcon pointSize:pts scale:scale];
            if (slim && self.diskCacheEnabled) {
                [self scheduleDiskWrite:slim forPath:path pixelEdge:pixelEdge];
            }
        }
    }
    if (slim) {
        NSUInteger gen;
        @synchronized (self.cache) {
            gen = self.loadGeneration;
        }
        [self storeInRAM:slim forPath:path generation:gen];
    }
    return slim;
}

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
    CGFloat scale = [self effectiveBackingScale];
    NSInteger pixelEdge = [self pixelEdgeForPointSize:pointSize scale:scale];
    BOOL useDisk = self.diskCacheEnabled;
    dispatch_semaphore_t sem = self.loadSemaphore;

    dispatch_async(self.queue, ^{
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        NSImage *slim = nil;
        BOOL loadedFromWorkspace = NO;
        @autoreleasepool {
            if (useDisk) {
                [self probeDiskDirectoryIfNeeded];
                if (self.diskHasEntries) {
                    NSURL *diskURL = [self diskURLForPath:path pixelEdge:pixelEdge];
                    slim = [self loadSlimImageFromDiskURL:diskURL pointSize:pointSize];
                }
            }

            if (!slim) {
                NSImage *sourceIcon = nil;
                @autoreleasepool {
                    sourceIcon = [self sourceIconForPath:path];
                    /* Rasterize inside pool so multi-rep source dies here. */
                    slim = [self slimImageFromSource:sourceIcon
                                           pointSize:pointSize
                                               scale:scale];
                    sourceIcon = nil;
                }
                loadedFromWorkspace = (slim != nil);
            }

            [self storeInRAM:slim forPath:path generation:gen];
        }
        @synchronized (self.inflight) {
            [self.inflight removeObject:path];
        }
        dispatch_semaphore_signal(sem);

        if (loadedFromWorkspace && useDisk && slim) {
            [self scheduleDiskWrite:slim forPath:path pixelEdge:pixelEdge];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger cur;
            @synchronized (self.cache) {
                cur = self.loadGeneration;
            }
            if (gen == cur) {
                onLoaded(path, slim);
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

- (void)purgeAllCaches {
    [self purge];
    [self purgeDiskCache];
}

- (NSUInteger)cachedCount {
    @synchronized (self.cache) {
        return self.cache.count;
    }
}

@end
