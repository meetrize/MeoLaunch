#import "MLDebouncedSave.h"

@interface MLDebouncedSave ()
@property (nonatomic, copy) void (^action)(void);
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation MLDebouncedSave

- (instancetype)initWithAction:(void (^)(void))action {
    self = [super init];
    if (self) {
        _action = [action copy];
        _interval = 0.3;
    }
    return self;
}

- (void)dealloc {
    [self cancel];
}

- (void)schedule {
    [self cancel];
    if (!self.action) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:self.interval
                                                 repeats:NO
                                                   block:^(__unused NSTimer *timer) {
                                                       __strong typeof(weakSelf) self = weakSelf;
                                                       if (self.action) {
                                                           self.action();
                                                       }
                                                   }];
}

- (void)cancel {
    [self.timer invalidate];
    self.timer = nil;
}

@end
