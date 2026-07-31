#import "MLIconCache.h"

@interface MLIconCache ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *cache;
@property (nonatomic, strong) NSMutableArray<NSString *> *lru; /* most-recent at end */
@property (nonatomic, strong) NSMutableSet<NSString *> *inflight;
@property (nonatomic, strong) dispatch_queue_t queue;
/** Bumped on purge so in-flight loads do not repopulate the cache. */
@property (nonatomic, assign) NSUInteger loadGeneration;
@end

@implementation MLIconCache

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [NSMutableDictionary dictionary];
        _lru = [NSMutableArray array];
        _inflight = [NSMutableSet set];
        _maxEntries = 128;
        _queue = dispatch_queue_create("com.meetrice.meolaunch.iconcache", DISPATCH_QUEUE_SERIAL);
    }
    return self;
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

    dispatch_async(self.queue, ^{
        NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
        [icon setSize:NSMakeSize(128, 128)];
        NSImage *copy = [icon copy];

        @synchronized (self.cache) {
            if (gen != self.loadGeneration) {
                /* Purged while loading — drop result. */
            } else if (copy) {
                self.cache[path] = copy;
                [self touchKey:path];
                [self evictIfNeeded];
            }
        }
        @synchronized (self.inflight) {
            [self.inflight removeObject:path];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen == self.loadGeneration) {
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

- (NSUInteger)cachedCount {
    @synchronized (self.cache) {
        return self.cache.count;
    }
}

@end
