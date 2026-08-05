#import "MLHotCornerMonitor.h"

#import <ApplicationServices/ApplicationServices.h>

@interface MLHotCornerMonitor ()
@property (nonatomic, strong) id globalMouseMonitor;
@property (nonatomic, strong) id localMouseMonitor;
@property (nonatomic, assign) BOOL wasInside;
@property (nonatomic, strong) NSDate *enteredAt;
@property (nonatomic, assign) BOOL armed; /* after fire, wait until leave */
@end

@implementation MLHotCornerMonitor

- (instancetype)init {
    self = [super init];
    if (self) {
        _enabled = YES;
        _position = MLHotCornerPositionTopLeft;
        _sizePt = 12.0;
        _delayMs = 0;
        _wasInside = NO;
        _armed = YES;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(screensChanged:)
                                                     name:NSApplicationDidChangeScreenParametersNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stop];
}

- (void)screensChanged:(NSNotification *)note {
    (void)note;
    self.wasInside = NO;
    self.enteredAt = nil;
    self.armed = YES;
    NSLog(@"[MeoLaunch] screens changed — hot corner state reset");
}

- (void)applyConfig:(MLConfigStore *)config {
    if (!config) {
        return;
    }
    self.enabled = config.hotCornerEnabled;
    self.position = config.hotCornerPosition;
    /* Legacy 4pt was too small / missed top-edge pixels */
    CGFloat size = config.hotCornerSizePt;
    if (size < 8.0) {
        size = 12.0;
    }
    self.sizePt = size;
    self.delayMs = config.hotCornerDelayMs;
}

+ (BOOL)isAccessibilityTrustedPrompting:(BOOL)prompt {
    NSDictionary *opts = @{
        (__bridge NSString *)kAXTrustedCheckOptionPrompt : @(prompt)
    };
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts) ? YES : NO;
}

- (void)start {
    [self stop];
    if (!self.enabled || self.position == MLHotCornerPositionOff) {
        NSLog(@"[MeoLaunch] HotCornerMonitor not started (disabled/off)");
        return;
    }
    if (![MLHotCornerMonitor isAccessibilityTrustedPrompting:NO]) {
        NSLog(@"[MeoLaunch] HotCornerMonitor waiting for Accessibility permission");
        return;
    }

    self.wasInside = NO;
    self.enteredAt = nil;
    self.armed = YES;

    __weak typeof(self) weakSelf = self;
    self.globalMouseMonitor =
        [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
                                               handler:^(NSEvent *event) {
                                                   [weakSelf handleMouseMoved:event];
                                               }];
    self.localMouseMonitor =
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved
                                              handler:^NSEvent *(NSEvent *event) {
                                                  [weakSelf handleMouseMoved:event];
                                                  return event;
                                              }];
    NSLog(@"[MeoLaunch] HotCornerMonitor started (corner=%ld size=%.1f delay=%ldms, event-driven)",
          (long)self.position, self.sizePt, (long)self.delayMs);
}

- (void)handleMouseMoved:(NSEvent *)event {
    (void)event;
    [self tick];
}

- (void)stop {
    if (self.globalMouseMonitor) {
        [NSEvent removeMonitor:self.globalMouseMonitor];
        self.globalMouseMonitor = nil;
    }
    if (self.localMouseMonitor) {
        [NSEvent removeMonitor:self.localMouseMonitor];
        self.localMouseMonitor = nil;
    }
    self.wasInside = NO;
    self.enteredAt = nil;
    self.armed = YES;
}

- (BOOL)isRunning {
    return self.globalMouseMonitor != nil || self.localMouseMonitor != nil;
}

/* NSPointInRect excludes top/right edges — bad for screen corners. */
- (BOOL)point:(NSPoint)p insideInclusiveRect:(NSRect)r {
    return (p.x >= NSMinX(r) && p.x <= NSMaxX(r) &&
            p.y >= NSMinY(r) && p.y <= NSMaxY(r));
}

- (NSScreen *)screenForHotCornerAtPoint:(NSPoint)p {
    /* Prefer screen whose inclusive frame contains the point */
    for (NSScreen *s in [NSScreen screens]) {
        if ([self point:p insideInclusiveRect:s.frame]) {
            return s;
        }
    }
    /* Mouse clamped to absolute desktop corner — pick nearest screen corner */
    NSScreen *best = [NSScreen mainScreen];
    CGFloat bestDist = CGFLOAT_MAX;
    for (NSScreen *s in [NSScreen screens]) {
        NSRect f = s.frame;
        NSPoint corner;
        switch (self.position) {
            case MLHotCornerPositionTopLeft:
                corner = NSMakePoint(NSMinX(f), NSMaxY(f));
                break;
            case MLHotCornerPositionTopRight:
                corner = NSMakePoint(NSMaxX(f), NSMaxY(f));
                break;
            case MLHotCornerPositionBottomLeft:
                corner = NSMakePoint(NSMinX(f), NSMinY(f));
                break;
            case MLHotCornerPositionBottomRight:
                corner = NSMakePoint(NSMaxX(f), NSMinY(f));
                break;
            default:
                continue;
        }
        CGFloat dx = p.x - corner.x;
        CGFloat dy = p.y - corner.y;
        CGFloat d = dx * dx + dy * dy;
        if (d < bestDist) {
            bestDist = d;
            best = s;
        }
    }
    return best;
}

- (BOOL)pointInConfiguredHotCorner:(NSPoint)p onScreen:(NSScreen *)screen {
    if (!screen || self.position == MLHotCornerPositionOff) {
        return NO;
    }

    CGFloat size = self.sizePt > 0 ? self.sizePt : 12.0;
    if (size < 8.0) {
        size = 8.0;
    }
    /* Outward slop so the absolute outer pixel / menu-bar edge always counts */
    const CGFloat slop = 3.0;
    NSRect f = screen.frame;

    CGFloat left = NSMinX(f);
    CGFloat right = NSMaxX(f);
    CGFloat bottom = NSMinY(f);
    CGFloat top = NSMaxY(f);

    switch (self.position) {
        case MLHotCornerPositionTopLeft:
            return (p.x >= left - slop && p.x <= left + size &&
                    p.y <= top + slop && p.y >= top - size);
        case MLHotCornerPositionTopRight:
            return (p.x <= right + slop && p.x >= right - size &&
                    p.y <= top + slop && p.y >= top - size);
        case MLHotCornerPositionBottomLeft:
            return (p.x >= left - slop && p.x <= left + size &&
                    p.y >= bottom - slop && p.y <= bottom + size);
        case MLHotCornerPositionBottomRight:
            return (p.x <= right + slop && p.x >= right - size &&
                    p.y >= bottom - slop && p.y <= bottom + size);
        default:
            return NO;
    }
}

- (void)tick {
    if (!self.enabled || self.position == MLHotCornerPositionOff) {
        return;
    }

    NSPoint p = [NSEvent mouseLocation];
    NSScreen *screen = [self screenForHotCornerAtPoint:p];
    BOOL inside = [self pointInConfiguredHotCorner:p onScreen:screen];

    if (!inside) {
        self.wasInside = NO;
        self.enteredAt = nil;
        self.armed = YES;
        return;
    }

    if (!self.wasInside) {
        self.wasInside = YES;
        self.enteredAt = [NSDate date];
    }

    if (!self.armed) {
        return;
    }

    NSTimeInterval need = (NSTimeInterval)self.delayMs / 1000.0;
    if (need > 0 && self.enteredAt) {
        if ([[NSDate date] timeIntervalSinceDate:self.enteredAt] < need) {
            return;
        }
    }

    self.armed = NO;
    NSLog(@"[MeoLaunch] HotCorner triggered at (%.1f, %.1f)", p.x, p.y);
    [self.delegate hotCornerMonitorDidTrigger:self];
}

@end
