#import "MLMemoryStatusController.h"

#import "MLStrings.h"

#include <mach/mach.h>
#include <mach/mach_host.h>
#include <math.h>

@interface MLMemoryStatusController ()
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) NSTimeInterval interval;
@property (nonatomic, assign) int lastPercent;
@property (nonatomic, assign, readwrite, getter=isRunning) BOOL running;
@end

@implementation MLMemoryStatusController

- (instancetype)init {
    self = [super init];
    if (self) {
        _interval = 2.0;
        _lastPercent = -1;
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSTimeInterval)clampedInterval:(NSTimeInterval)seconds {
    if (seconds < 1.0) {
        return 1.0;
    }
    if (seconds > 5.0) {
        return 5.0;
    }
    return seconds;
}

/** Remaining free memory percent 0…100; -1 on failure. */
- (int)sampleFreePercent:(uint64_t *)outFreeBytes physical:(uint64_t *)outPhysical {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    kern_return_t kr = host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count);
    if (kr != KERN_SUCCESS) {
        return -1;
    }

    uint64_t page = (uint64_t)vm_page_size;
    uint64_t used = ((uint64_t)vm.active_count + (uint64_t)vm.wire_count +
                     (uint64_t)vm.compressor_page_count) *
                    page;
    uint64_t physical = [NSProcessInfo processInfo].physicalMemory;
    if (physical == 0) {
        return -1;
    }
    uint64_t freeBytes = physical > used ? physical - used : 0;
    int pct = (int)lround(100.0 * (double)freeBytes / (double)physical);
    if (pct < 0) {
        pct = 0;
    }
    if (pct > 100) {
        pct = 100;
    }
    if (outFreeBytes) {
        *outFreeBytes = freeBytes;
    }
    if (outPhysical) {
        *outPhysical = physical;
    }
    return pct;
}

- (NSString *)formatBytesShort:(uint64_t)bytes {
    const double gib = 1024.0 * 1024.0 * 1024.0;
    const double mib = 1024.0 * 1024.0;
    if (bytes >= (uint64_t)(10.0 * gib)) {
        return [NSString stringWithFormat:@"%.1f GB", bytes / gib];
    }
    if (bytes >= (uint64_t)gib) {
        return [NSString stringWithFormat:@"%.1f GB", bytes / gib];
    }
    return [NSString stringWithFormat:@"%.0f MB", bytes / mib];
}

- (void)ensureStatusItem {
    if (self.statusItem) {
        return;
    }
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    if (button) {
        button.title = @"—%";
        button.image = nil;
        button.imagePosition = NSNoImage;
        button.font = [NSFont monospacedDigitSystemFontOfSize:13.0 weight:NSFontWeightRegular];
    }
}

- (void)refresh {
    uint64_t freeBytes = 0;
    uint64_t physical = 0;
    int pct = [self sampleFreePercent:&freeBytes physical:&physical];
    if (pct < 0) {
        return;
    }
    [self ensureStatusItem];
    NSStatusBarButton *button = self.statusItem.button;
    if (!button) {
        return;
    }
    if (pct != self.lastPercent) {
        self.lastPercent = pct;
        button.title = [NSString stringWithFormat:@"%d%%", pct];
    }
    button.toolTip =
        [NSString stringWithFormat:[MLStrings t:@"menubar.memory_free.tooltip"],
                                   pct,
                                   [self formatBytesShort:freeBytes]];
}

- (void)startWithInterval:(NSTimeInterval)seconds {
    self.interval = [self clampedInterval:seconds];
    if (self.running) {
        [self applyInterval:self.interval];
        return;
    }
    self.running = YES;
    self.lastPercent = -1;
    [self ensureStatusItem];
    [self refresh];

    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:self.interval
                                                 repeats:YES
                                                   block:^(__unused NSTimer *timer) {
                                                       [weakSelf refresh];
                                                   }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)applyInterval:(NSTimeInterval)seconds {
    NSTimeInterval next = [self clampedInterval:seconds];
    self.interval = next;
    if (!self.running) {
        return;
    }
    [self.timer invalidate];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:next
                                                 repeats:YES
                                                   block:^(__unused NSTimer *timer) {
                                                       [weakSelf refresh];
                                                   }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    self.running = NO;
    self.lastPercent = -1;
    if (self.statusItem) {
        [[NSStatusBar systemStatusBar] removeStatusItem:self.statusItem];
        self.statusItem = nil;
    }
}

@end
