#import "MLAudioActivityMonitor.h"
#import "MLAudioProcessSupport.h"

#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>

NSNotificationName const MLAudioActivityDidChangeNotification = @"MLAudioActivityDidChangeNotification";

@interface MLAudioActivityMonitor ()
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@property (nonatomic, copy, readwrite) NSSet<NSNumber *> *runningOutputPIDs;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *runningOutputBundleIDs;
@property (nonatomic, copy, readwrite) NSSet<NSString *> *runningOutputOwnerAppPaths;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, assign) BOOL listenerInstalled;
@property (nonatomic, assign) BOOL debounceScheduled;
@end

@implementation MLAudioActivityMonitor

static OSStatus MLAudioProcessListListener(AudioObjectID inObjectID,
                                           UInt32 inNumberAddresses,
                                           const AudioObjectPropertyAddress *inAddresses,
                                           void *inClientData) {
    (void)inObjectID;
    (void)inNumberAddresses;
    (void)inAddresses;
    MLAudioActivityMonitor *mon = (__bridge MLAudioActivityMonitor *)inClientData;
    [mon scheduleDebouncedRefresh];
    return noErr;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _runningOutputPIDs = [NSSet set];
    _runningOutputBundleIDs = [NSSet set];
    _runningOutputOwnerAppPaths = [NSSet set];
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (self.running) {
        return;
    }
    if (![MLAudioProcessSupport isAvailable]) {
        self.running = YES; /* started but inert */
        self.runningOutputPIDs = [NSSet set];
        self.runningOutputBundleIDs = [NSSet set];
        self.runningOutputOwnerAppPaths = [NSSet set];
        return;
    }
    self.running = YES;
    [self installProcessListListener];
    [self refreshNow];
    /* Light poll catches IsRunningOutput flips without per-process listeners. */
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                      target:self
                                                    selector:@selector(pollTick:)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.pollTimer forMode:NSRunLoopCommonModes];
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    self.debounceScheduled = NO;
    [self removeProcessListListener];
    self.runningOutputPIDs = [NSSet set];
    self.runningOutputBundleIDs = [NSSet set];
    self.runningOutputOwnerAppPaths = [NSSet set];
}

- (BOOL)isPIDRunningOutput:(pid_t)pid {
    if (pid <= 0) {
        return NO;
    }
    return [self.runningOutputPIDs containsObject:@(pid)];
}

- (BOOL)isAudioActiveForPID:(pid_t)pid
                   bundleID:(NSString *)bundleID
                    appPath:(NSString *)appPath {
    if ([self isPIDRunningOutput:pid]) {
        return YES;
    }
    if (bundleID.length > 0 && [self.runningOutputBundleIDs containsObject:bundleID]) {
        return YES;
    }
    if (appPath.length > 0 && [self.runningOutputOwnerAppPaths containsObject:appPath]) {
        return YES;
    }
    return NO;
}

- (void)installProcessListListener {
    if (self.listenerInstalled || ![MLAudioProcessSupport isAvailable]) {
        return;
    }
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus st = AudioObjectAddPropertyListener(kAudioObjectSystemObject,
                                                 &addr,
                                                 MLAudioProcessListListener,
                                                 (__bridge void *)self);
    if (st == noErr) {
        self.listenerInstalled = YES;
    }
}

- (void)removeProcessListListener {
    if (!self.listenerInstalled) {
        return;
    }
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject,
                                      &addr,
                                      MLAudioProcessListListener,
                                      (__bridge void *)self);
    self.listenerInstalled = NO;
}

- (void)pollTick:(NSTimer *)timer {
    (void)timer;
    [self refreshNow];
}

- (void)scheduleDebouncedRefresh {
    if (!self.running || self.debounceScheduled) {
        return;
    }
    self.debounceScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        self.debounceScheduled = NO;
        if (!self.running) {
            return;
        }
        [self refreshNow];
    });
}

- (void)refreshNow {
    if (![MLAudioProcessSupport isAvailable]) {
        return;
    }
    pid_t selfPid = [[NSProcessInfo processInfo] processIdentifier];
    NSArray<NSNumber *> *pidList = [MLAudioProcessSupport copyRunningOutputPIDsExcluding:selfPid];
    NSSet<NSNumber *> *pids = [NSSet setWithArray:pidList];
    NSSet<NSString *> *bids =
        [MLAudioProcessSupport copyRunningOutputOwnerBundleIDsExcluding:selfPid];
    NSSet<NSString *> *paths =
        [MLAudioProcessSupport copyRunningOutputOwnerAppPathsExcluding:selfPid];

    if ([pids isEqualToSet:self.runningOutputPIDs] &&
        [bids isEqualToSet:self.runningOutputBundleIDs] &&
        [paths isEqualToSet:self.runningOutputOwnerAppPaths]) {
        return;
    }
    self.runningOutputPIDs = pids;
    self.runningOutputBundleIDs = bids;
    self.runningOutputOwnerAppPaths = paths;
    [[NSNotificationCenter defaultCenter] postNotificationName:MLAudioActivityDidChangeNotification
                                                        object:self];
}

@end
