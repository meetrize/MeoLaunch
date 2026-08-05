#import "MLAppScanWatcher.h"

#import <CoreServices/CoreServices.h>

@interface MLAppScanWatcher ()
@property (nonatomic, assign) FSEventStreamRef stream;
@end

static void ml_app_scan_fs_callback(ConstFSEventStreamRef streamRef,
                                    void *clientCallBackInfo,
                                    size_t numEvents,
                                    void *eventPaths,
                                    const FSEventStreamEventFlags eventFlags[],
                                    const FSEventStreamEventId eventIds[]) {
    (void)streamRef;
    (void)numEvents;
    (void)eventPaths;
    (void)eventFlags;
    (void)eventIds;

    MLAppScanWatcher *watcher = (__bridge MLAppScanWatcher *)clientCallBackInfo;
    if (!watcher.onChange) {
        return;
    }
    watcher.onChange();
}

@implementation MLAppScanWatcher

- (void)dealloc {
    [self stop];
}

- (void)watchPaths:(NSArray<NSString *> *)paths {
    [self stop];
    if (paths.count == 0) {
        return;
    }

    NSMutableArray<NSString *> *existing = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *path in paths) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
            [existing addObject:path];
        }
    }
    if (existing.count == 0) {
        return;
    }

    FSEventStreamContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
    /* 0.2s coalesce — fast enough for installs, avoids rescan storms during bulk copies. */
    self.stream = FSEventStreamCreate(NULL,
                                      ml_app_scan_fs_callback,
                                      &ctx,
                                      (__bridge CFArrayRef)existing,
                                      kFSEventStreamEventIdSinceNow,
                                      0.2,
                                      kFSEventStreamCreateFlagFileEvents |
                                          kFSEventStreamCreateFlagUseCFTypes |
                                          kFSEventStreamCreateFlagNoDefer);
    if (!self.stream) {
        NSLog(@"[MeoLaunch] AppScanWatcher: FSEventStreamCreate failed");
        return;
    }

    FSEventStreamSetDispatchQueue(self.stream, dispatch_get_main_queue());
    if (!FSEventStreamStart(self.stream)) {
        NSLog(@"[MeoLaunch] AppScanWatcher: FSEventStreamStart failed");
        FSEventStreamInvalidate(self.stream);
        FSEventStreamRelease(self.stream);
        self.stream = NULL;
        return;
    }

    NSLog(@"[MeoLaunch] AppScanWatcher watching %lu roots", (unsigned long)existing.count);
}

- (void)stop {
    if (!self.stream) {
        return;
    }
    FSEventStreamStop(self.stream);
    FSEventStreamInvalidate(self.stream);
    FSEventStreamRelease(self.stream);
    self.stream = NULL;
}

@end
