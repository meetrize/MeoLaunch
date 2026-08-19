#import "MLIdleMemoryReclaimer.h"

#include <mach/mach.h>
#include <malloc/malloc.h>

static const NSTimeInterval kMLIdleReclaimInterval = 5.0 * 60.0;
static const NSTimeInterval kMLDefaultHeartbeatInterval = 3600.0;

static double MLIdlePhysFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
        return -1.0;
    }
    return (double)info.phys_footprint / (1024.0 * 1024.0);
}

static void MLIdleLogMemory(NSString *tag) {
    double mb = MLIdlePhysFootprintMB();
    if (mb < 0) {
        return;
    }
    NSLog(@"[MeoLaunch] mem %@ phys_footprint=%.1fMB", tag, mb);
}

@interface MLIdleMemoryReclaimer ()
@property (nonatomic, strong) NSTimer *idleTimer;
@property (nonatomic, strong) NSTimer *heartbeatTimer;
@property (nonatomic, strong) dispatch_source_t pressureSource;
@property (nonatomic, assign, getter=isRunning) BOOL running;
@end

@implementation MLIdleMemoryReclaimer

- (instancetype)init {
    self = [super init];
    if (self) {
        _heartbeatIntervalSeconds = kMLDefaultHeartbeatInterval;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    if (self.running) {
        return;
    }
    self.running = YES;

    __weak typeof(self) weakSelf = self;
    self.idleTimer = [NSTimer scheduledTimerWithTimeInterval:kMLIdleReclaimInterval
                                                      repeats:YES
                                                        block:^(__unused NSTimer *timer) {
                                                            [weakSelf idleTimerFired];
                                                        }];
    [[NSRunLoop mainRunLoop] addTimer:self.idleTimer forMode:NSRunLoopCommonModes];

    [self restartHeartbeatTimer];

    dispatch_source_t src =
        dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                               DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
                               dispatch_get_main_queue());
    if (src) {
        dispatch_source_set_event_handler(src, ^{
            [weakSelf pressureFired];
        });
        dispatch_resume(src);
        self.pressureSource = src;
    }

    /* One early sample so Console has a baseline without waiting an hour. */
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf emitHeartbeatNow];
    });
}

- (void)restartHeartbeatTimer {
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
    if (!self.running) {
        return;
    }
    NSTimeInterval interval = self.heartbeatIntervalSeconds;
    if (interval < 60.0) {
        interval = 60.0;
    }
    __weak typeof(self) weakSelf = self;
    self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                           repeats:YES
                                                             block:^(__unused NSTimer *timer) {
                                                                 [weakSelf emitHeartbeatNow];
                                                             }];
    [[NSRunLoop mainRunLoop] addTimer:self.heartbeatTimer forMode:NSRunLoopCommonModes];
}

- (void)setHeartbeatIntervalSeconds:(NSTimeInterval)heartbeatIntervalSeconds {
    _heartbeatIntervalSeconds = heartbeatIntervalSeconds;
    if (self.running) {
        [self restartHeartbeatTimer];
    }
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    [self.idleTimer invalidate];
    self.idleTimer = nil;
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
    if (self.pressureSource) {
        dispatch_source_cancel(self.pressureSource);
        self.pressureSource = nil;
    }
}

- (void)idleTimerFired {
    if (!self.running) {
        return;
    }
    if (self.isOverlayVisible && self.isOverlayVisible()) {
        return;
    }
    [self runReclaimUnderPressure:NO tag:@"idle-reclaim"];
}

- (void)pressureFired {
    if (!self.running) {
        return;
    }
    [self runReclaimUnderPressure:YES tag:@"pressure-reclaim"];
}

- (void)runReclaimUnderPressure:(BOOL)underPressure tag:(NSString *)tag {
    void (^work)(BOOL) = self.performReclaim;
    @autoreleasepool {
        if (work) {
            work(underPressure);
        }
        malloc_zone_pressure_relief(NULL, 0);
    }
    MLIdleLogMemory(tag);
}

- (void)emitHeartbeatNow {
    if (!self.running) {
        return;
    }
    double mb = MLIdlePhysFootprintMB();
    NSString *extra = nil;
    if (self.collectHeartbeat) {
        extra = self.collectHeartbeat();
    }
    if (extra.length > 0) {
        NSLog(@"[MeoLaunch] heartbeat phys_footprint=%.1fMB %@", mb, extra);
    } else {
        NSLog(@"[MeoLaunch] heartbeat phys_footprint=%.1fMB", mb);
    }
}

@end
