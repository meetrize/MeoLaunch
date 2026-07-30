#import <Cocoa/Cocoa.h>

@class MLRunningAppsMonitor;

/**
 * Keeps zoomed / “fill visibleFrame” windows above the taskbar.
 * macOS has no public strut API; we inset via Accessibility when a window
 * matches the screen work area that would otherwise sit under our bar.
 */
@interface MLWorkAreaEnforcer : NSObject

@property (nonatomic, weak) MLRunningAppsMonitor *monitor;
/** Taskbar height in points (default 40). */
@property (nonatomic, assign) CGFloat barHeight;

- (void)start;
- (void)stop;
/** Immediate pass (e.g. after screen layout / bar height change). */
- (void)enforceNow;

@end
