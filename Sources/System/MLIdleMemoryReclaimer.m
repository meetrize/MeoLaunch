#import "MLIdleMemoryReclaimer.h"

#include <mach/mach.h>
#include <malloc/malloc.h>

static const NSTimeInterval kMLIdleReclaimInterval = 5.0 * 60.0;

static void MLIdleLogMemory(NSString *tag) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
        return;
    }
    double mb = (double)info.phys_footprint / (1024.0 * 1024.0);
    NSLog(@"[MeoLaunch] mem %@ phys_footprint=%.1fMB", tag, mb);
}

@interface MLIdleMemoryReclaimer ()
@property (nonatomic, strong) NSTimer *idleTimer;
@property (nonatomic, strong) dispatch_source_t pressureSource;
@property (nonatomic, assign, getter=isRunning) BOOL running;
@end

@implementation MLIdleMemoryReclaimer

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
}

- (void)stop {
    if (!self.running) {
        return;
    }
    self.running = NO;
    [self.idleTimer invalidate];
    self.idleTimer = nil;
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

@end
