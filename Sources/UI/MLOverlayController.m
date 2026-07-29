#import "MLOverlayController.h"

#import "MLConfigStore.h"
#import "MLDismissBackgroundView.h"
#import "MLGridView.h"
#import "MLIconCache.h"
#import "MLOverlayWindow.h"
#import "MLPageIndicator.h"
#import "MLSearchField.h"

#include "ml_filter.h"

#include <mach/mach.h>
#include <stdlib.h>

#import <QuartzCore/QuartzCore.h>

@interface MLOverlayController () <MLGridViewDelegate, MLPageIndicatorDelegate, MLDismissBackgroundViewDelegate, NSTextFieldDelegate, MLSearchFieldSettingsDelegate>
@property (nonatomic, weak) MLConfigStore *config;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSVisualEffectView *blurView;
@property (nonatomic, strong) NSView *tintView;
@property (nonatomic, strong) MLDismissBackgroundView *dismissBackground;
@property (nonatomic, strong) MLGridView *gridView;
@property (nonatomic, strong) MLSearchField *searchField;
@property (nonatomic, strong) MLPageIndicator *pageIndicator;
@property (nonatomic, strong) MLIconCache *iconCache;
@property (nonatomic, assign) const MLAppIndex *appIndex;
@property (nonatomic, assign) uint32_t *filterIndices;
@property (nonatomic, assign) size_t filterCapacity;
@property (nonatomic, assign) size_t filterCount;
@property (nonatomic, strong) id escapeMonitor;
@property (nonatomic, assign, readwrite) BOOL visible;
@property (nonatomic, assign) BOOL animating;
@property (nonatomic, assign) NSUInteger showGeneration;
@property (nonatomic, strong) NSRunningApplication *previousApp;
@end

/** Lets clicks fall through to the dismiss catcher below. */
@interface MLPassthroughTintView : NSView
@end

@implementation MLPassthroughTintView
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

@implementation MLOverlayController

static void MLLogMemory(NSString *tag) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
        return;
    }
    double mb = (double)info.phys_footprint / (1024.0 * 1024.0);
    NSLog(@"[MeoLaunch] mem %@ phys_footprint=%.1fMB icons_cache later", tag, mb);
}

- (instancetype)initWithConfigStore:(MLConfigStore *)config {
    self = [super init];
    if (self) {
        _config = config;
        _visible = NO;
        _animating = NO;
        _iconCache = [[MLIconCache alloc] init];
        _iconCache.maxEntries = 128;
        _appIndex = NULL;
        _filterIndices = NULL;
        _filterCapacity = 0;
        _filterCount = 0;
    }
    return self;
}

- (void)dealloc {
    [self removeEscapeMonitor];
    free(_filterIndices);
    _filterIndices = NULL;
}

- (NSScreen *)screenUnderMouse {
    NSPoint p = [NSEvent mouseLocation];
    for (NSScreen *s in [NSScreen screens]) {
        if (NSPointInRect(p, s.frame)) {
            return s;
        }
    }
    return [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
}

- (void)ensureFilterCapacity:(size_t)need {
    if (need <= self.filterCapacity) {
        return;
    }
    uint32_t *nbuf = (uint32_t *)realloc(self.filterIndices, need * sizeof(uint32_t));
    if (!nbuf) {
        return;
    }
    self.filterIndices = nbuf;
    self.filterCapacity = need;
}

- (void)syncPageIndicator {
    NSInteger pages = [self.gridView pageCount];
    NSInteger page = self.gridView.currentPage;
    [self.pageIndicator updateWithPage:page pageCount:pages];
}

- (void)applyFilterWithQuery:(NSString *)query {
    if (!self.appIndex) {
        self.filterCount = 0;
        self.gridView.visibleIndices = NULL;
        self.gridView.visibleCount = 0;
        [self.gridView goToPage:0];
        [self.gridView reloadData];
        [self syncPageIndicator];
        return;
    }

    [self ensureFilterCapacity:self.appIndex->count > 0 ? self.appIndex->count : 1];
    if (!self.filterIndices && self.appIndex->count > 0) {
        return;
    }

    const char *q = query.UTF8String ?: "";
    size_t n = 0;
    if (self.appIndex->count > 0 && self.filterIndices) {
        n = ml_filter_apply(self.appIndex, q, self.filterIndices, self.filterCapacity);
    }
    self.filterCount = n;

    self.gridView.appIndex = self.appIndex;
    self.gridView.visibleIndices = self.filterIndices;
    self.gridView.visibleCount = self.filterCount;
    self.gridView.wheelThreshold = self.config.wheelThreshold > 0 ? self.config.wheelThreshold : 8.0;
    [self.gridView clearSelection];
    [self.gridView goToPage:0];
    [self.gridView reloadData];
    [self syncPageIndicator];

    NSLog(@"[MeoLaunch] filter \"%@\" -> %zu (pages=%ld)",
          query ?: @"", n, (long)[self.gridView pageCount]);
}

- (void)reloadWithAppIndex:(const MLAppIndex *)index {
    self.appIndex = index;
    [self applyBackdropAppearance];
    if (self.gridView) {
        NSInteger page = self.gridView.currentPage;
        self.gridView.gridConfig = self.config.gridConfig;
        [self applyFilterWithQuery:self.searchField.stringValue ?: @""];
        [self.gridView goToPage:page];
        [self syncPageIndicator];
    }
}

- (void)applyBackdropAppearance {
    if (!self.window) {
        return;
    }

    BOOL blur = self.config.overlayBlur;
    CGFloat opacity = self.config.overlayOpacity;
    if (opacity < 0.0) opacity = 0.0;
    if (opacity > 1.0) opacity = 1.0;

    self.blurView.hidden = !blur;
    self.tintView.hidden = NO;

    if (blur) {
        self.window.backgroundColor = [NSColor clearColor];
        self.tintView.layer.backgroundColor =
            [[NSColor blackColor] colorWithAlphaComponent:opacity].CGColor;
        self.blurView.state = NSVisualEffectStateActive;
    } else {
        self.window.backgroundColor =
            [[NSColor blackColor] colorWithAlphaComponent:opacity];
        self.tintView.layer.backgroundColor = [NSColor clearColor].CGColor;
    }
}

- (void)layoutChrome {
    NSView *content = self.window.contentView;
    NSRect bounds = content.bounds;
    CGFloat searchW = 420.0;
    CGFloat searchH = 40.0;
    /* Sit below the (covered) menu-bar band with a little breathing room */
    CGFloat topPad = 52.0;
    /* Extra bottom inset so page dots clear Dock / third-party taskbars */
    CGFloat bottomPad = 72.0;
    CGFloat searchGap = 20.0;

    /* Pin search bar near the top (non-flipped contentView). */
    self.searchField.frame = NSMakeRect((NSWidth(bounds) - searchW) * 0.5,
                                        NSHeight(bounds) - topPad - searchH,
                                        searchW,
                                        searchH);
    self.searchField.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    self.searchField.hidden = NO;
    [self.searchField setEnabled:YES];

    CGFloat gridTop = topPad + searchH + searchGap;
    self.gridView.frame = NSMakeRect(0,
                                     bottomPad,
                                     NSWidth(bounds),
                                     MAX(0, NSHeight(bounds) - gridTop - bottomPad));
    self.gridView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat indW = MIN(420.0, NSWidth(bounds) - 40.0);
    CGFloat indH = 28.0;
    CGFloat indBottom = 44.0; /* lift above taskbar */
    self.pageIndicator.frame = NSMakeRect((NSWidth(bounds) - indW) * 0.5, indBottom, indW, indH);
    self.pageIndicator.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin;

    /* Backdrop stack: blur → tint → dismiss catcher, then grid/chrome above. */
    [content addSubview:self.blurView positioned:NSWindowBelow relativeTo:self.dismissBackground];
    self.blurView.frame = bounds;
    self.blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [content addSubview:self.tintView positioned:NSWindowAbove relativeTo:self.blurView];
    self.tintView.frame = bounds;
    self.tintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [content addSubview:self.dismissBackground positioned:NSWindowBelow relativeTo:self.gridView];
    self.dismissBackground.frame = bounds;
    self.dismissBackground.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    [content addSubview:self.pageIndicator positioned:NSWindowAbove relativeTo:self.gridView];
    [content addSubview:self.searchField positioned:NSWindowAbove relativeTo:self.pageIndicator];
    [self syncPageIndicator];
}

- (void)ensureWindow {
    if (self.window) {
        return;
    }

    NSScreen *screen = [self screenUnderMouse];
    /* Full frame covers the menu bar; window level is raised above it in ensureWindow. */
    NSRect frame = screen ? screen.frame : NSMakeRect(0, 0, 800, 600);

    NSWindow *w = [[MLOverlayWindow alloc] initWithContentRect:frame
                                                     styleMask:NSWindowStyleMaskBorderless
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    w.opaque = NO;
    w.backgroundColor = [NSColor clearColor];
    /* Above menu bar so the scrim covers the system status area */
    w.level = NSStatusWindowLevel;
    w.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                           NSWindowCollectionBehaviorFullScreenAuxiliary;
    w.ignoresMouseEvents = NO;
    w.releasedWhenClosed = NO;
    w.alphaValue = 1.0;
    w.acceptsMouseMovedEvents = YES;

    NSView *content = w.contentView;

    self.blurView = [[NSVisualEffectView alloc] initWithFrame:content.bounds];
    self.blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.blurView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.blurView.material = NSVisualEffectMaterialFullScreenUI;
    self.blurView.state = NSVisualEffectStateActive;
    self.blurView.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [content addSubview:self.blurView];

    self.tintView = [[MLPassthroughTintView alloc] initWithFrame:content.bounds];
    self.tintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.tintView.wantsLayer = YES;
    self.tintView.layer.backgroundColor =
        [[NSColor blackColor] colorWithAlphaComponent:self.config.overlayOpacity].CGColor;
    [content addSubview:self.tintView];

    self.dismissBackground = [[MLDismissBackgroundView alloc] initWithFrame:content.bounds];
    self.dismissBackground.delegate = self;
    self.dismissBackground.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:self.dismissBackground];

    self.gridView = [[MLGridView alloc] initWithFrame:content.bounds];
    self.gridView.delegate = self;
    self.gridView.iconCache = self.iconCache;
    self.gridView.gridConfig = self.config.gridConfig;
    self.gridView.appIndex = self.appIndex;
    self.gridView.currentPage = 0;
    self.gridView.wheelThreshold = self.config.wheelThreshold > 0 ? self.config.wheelThreshold : 8.0;
    [content addSubview:self.gridView];

    self.searchField = [[MLSearchField alloc] initWithFrame:NSMakeRect(0, 0, 420, 40)];
    self.searchField.delegate = self;
    self.searchField.settingsDelegate = self;
    [content addSubview:self.searchField];

    self.pageIndicator = [[MLPageIndicator alloc] initWithFrame:NSMakeRect(0, 0, 200, 16)];
    self.pageIndicator.delegate = self;
    [content addSubview:self.pageIndicator];

    self.window = w;
    [self applyBackdropAppearance];
    [self layoutChrome];
}

- (void)installEscapeMonitor {
    if (self.escapeMonitor) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.escapeMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                               handler:^NSEvent *(NSEvent *event) {
                                                                   if (event.keyCode == 53) {
                                                                       [weakSelf handleEscape];
                                                                       return nil;
                                                                   }
                                                                   if (event.keyCode == 116) {
                                                                       [weakSelf.gridView nudgePage:-1];
                                                                       return nil;
                                                                   }
                                                                   if (event.keyCode == 121) {
                                                                       [weakSelf.gridView nudgePage:1];
                                                                       return nil;
                                                                   }
                                                                   return event;
                                                               }];
}

- (void)removeEscapeMonitor {
    if (self.escapeMonitor) {
        [NSEvent removeMonitor:self.escapeMonitor];
        self.escapeMonitor = nil;
    }
}

- (void)handleEscape {
    if (self.gridView.selectedVisibleIndex >= 0 &&
        self.window.firstResponder == self.gridView) {
        [self.gridView clearSelection];
        [self focusSearchField];
        return;
    }
    NSString *q = self.searchField.stringValue ?: @"";
    if (q.length > 0) {
        self.searchField.stringValue = @"";
        [self applyFilterWithQuery:@""];
        [self focusSearchField];
        return;
    }
    [self hide];
}

- (void)focusGridSelectingFirst {
    if ([self.gridView visibleItemCount] == 0) {
        return;
    }
    [self.gridView selectFirstVisibleItem];
    [self.window makeFirstResponder:self.gridView];
}

- (NSTimeInterval)fadeDuration {
    NSInteger ms = self.config.fadeMs;
    if (ms <= 0) {
        return 0;
    }
    return (NSTimeInterval)ms / 1000.0;
}

- (void)focusSearchField {
    if (!self.visible || !self.searchField) {
        return;
    }
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
    BOOL ok = [self.window makeFirstResponder:self.searchField];
    if (!ok) {
        /* Retry once after runloop turn */
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !self.visible) {
                return;
            }
            [self.window makeKeyWindow];
            [self.window makeFirstResponder:self.searchField];
            [[self.searchField currentEditor] setSelectedRange:NSMakeRange(0, 0)];
        });
        return;
    }
    NSText *editor = [self.searchField currentEditor];
    if (editor) {
        [editor setSelectedRange:NSMakeRange([[editor string] length], 0)];
    } else {
        [self.searchField selectText:nil];
    }
    NSLog(@"[MeoLaunch] search field focused (firstResponder=%@)",
          NSStringFromClass([self.window.firstResponder class]));
}

- (void)show {
    /* Cancel stuck fade state from a previous interrupted hide/show */
    self.animating = NO;
    self.showGeneration += 1;
    NSUInteger gen = self.showGeneration;

    [self ensureWindow];

    NSScreen *screen = [self screenUnderMouse];
    if (screen) {
        [self.window setFrame:screen.frame display:YES];
    }
    [self applyBackdropAppearance];
    [self layoutChrome];

    self.gridView.gridConfig = self.config.gridConfig;
    self.gridView.wheelThreshold = self.config.wheelThreshold > 0 ? self.config.wheelThreshold : 8.0;
    self.searchField.stringValue = @"";
    [self applyFilterWithQuery:@""];

    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (front && ![front.bundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
        self.previousApp = front;
    }

    self.visible = YES;

    NSTimeInterval dur = [self fadeDuration];
    self.window.alphaValue = 1.0;
    [NSApp activateIgnoringOtherApps:YES];
    [self.window orderFrontRegardless];
    [self.window makeKeyAndOrderFront:nil];
    [self installEscapeMonitor];
    [self focusSearchField];

    /* Focus again after menu/activation settles */
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf focusSearchField];
                   });

    if (dur > 0) {
        self.window.alphaValue = 0.01;
        self.animating = YES;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = dur;
            ctx.allowsImplicitAnimation = YES;
            self.window.animator.alphaValue = 1.0;
        } completionHandler:^{
            if (self.showGeneration != gen) {
                return;
            }
            self.window.alphaValue = 1.0;
            self.animating = NO;
            [self focusSearchField];
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((dur + 0.25) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           __strong typeof(weakSelf) self = weakSelf;
                           if (!self || self.showGeneration != gen) {
                               return;
                           }
                           self.window.alphaValue = 1.0;
                           self.animating = NO;
                       });
    }

    MLLogMemory(@"show");
    NSLog(@"[MeoLaunch] Overlay shown on %@ (%zu apps, pages=%ld, search=%@)",
          screen.localizedName ?: @"screen",
          self.appIndex ? self.appIndex->count : 0,
          (long)[self.gridView pageCount],
          NSStringFromRect(self.searchField.frame));
}

- (void)finishHide {
    [self.window orderOut:nil];
    self.window.alphaValue = 1.0;
    [self resetChromeAlpha];
    self.visible = NO;
    self.animating = NO;
    [self.iconCache purge];
    MLLogMemory(@"hide-purged");

    NSRunningApplication *prev = self.previousApp;
    self.previousApp = nil;
    if (prev && !prev.isTerminated) {
        [prev activateWithOptions:(NSApplicationActivationOptions)0];
    }
    NSLog(@"[MeoLaunch] Overlay hidden (icon cache purged)");
}

- (void)hide {
    if (!self.visible && !self.window.isVisible) {
        return;
    }
    [self removeEscapeMonitor];
    self.showGeneration += 1;
    NSUInteger gen = self.showGeneration;

    NSTimeInterval dur = [self fadeDuration];
    if (dur <= 0) {
        [self finishHide];
        return;
    }

    self.animating = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = dur;
        ctx.allowsImplicitAnimation = YES;
        self.window.animator.alphaValue = 0.0;
    } completionHandler:^{
        if (self.showGeneration != gen) {
            return;
        }
        [self finishHide];
    }];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((dur + 0.25) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (!self || self.showGeneration != gen) {
                           return;
                       }
                       if (self.visible || self.animating) {
                           [self finishHide];
                       }
                   });
}

- (BOOL)isVisible {
    return self.visible;
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification *)obj {
    (void)obj;
    [self applyFilterWithQuery:self.searchField.stringValue ?: @""];
}

- (BOOL)control:(NSControl *)control
       textView:(NSTextView *)textView
doCommandBySelector:(SEL)commandSelector {
    (void)control;
    (void)textView;
    if (commandSelector == @selector(insertNewline:) ||
        commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
        [self focusGridSelectingFirst];
        return YES;
    }
    if (commandSelector == @selector(moveDown:)) {
        [self focusGridSelectingFirst];
        return YES;
    }
    return NO;
}

#pragma mark - MLSearchFieldSettingsDelegate

- (void)searchFieldDidClickSettings:(MLSearchField *)field {
    (void)field;
    if ([self.delegate respondsToSelector:@selector(overlayControllerDidRequestPreferences:)]) {
        [self.delegate overlayControllerDidRequestPreferences:self];
    }
}

#pragma mark - MLGridViewDelegate

- (NSInteger)visibleIndexForPath:(NSString *)path {
    if (!path.length || !self.appIndex) {
        return -1;
    }
    size_t total = [self.gridView visibleItemCount];
    const uint32_t *indices = self.gridView.visibleIndices;
    for (size_t i = 0; i < total; i++) {
        uint32_t appIdx = indices ? indices[i] : (uint32_t)i;
        if (appIdx >= self.appIndex->count) {
            continue;
        }
        const char *cpath = self.appIndex->items[appIdx].path;
        if (!cpath) {
            continue;
        }
        if ([path isEqualToString:[NSString stringWithUTF8String:cpath]]) {
            return (NSInteger)i;
        }
    }
    return -1;
}

- (void)resetChromeAlpha {
    self.gridView.alphaValue = 1.0;
    self.blurView.alphaValue = 1.0;
    self.tintView.alphaValue = 1.0;
    self.searchField.alphaValue = 1.0;
    self.pageIndicator.alphaValue = 1.0;
    self.dismissBackground.alphaValue = 1.0;
}

- (void)gridView:(NSView *)gridView didActivateAppAtPath:(NSString *)path {
    (void)gridView;
    if (path.length == 0 || self.animating) {
        return;
    }
    NSLog(@"[MeoLaunch] launch %@", path);
    self.previousApp = nil;

    NSInteger vis = self.gridView.selectedVisibleIndex;
    if (vis < 0) {
        vis = [self visibleIndexForPath:path];
        if (vis >= 0) {
            self.gridView.selectedVisibleIndex = vis;
        }
    }

    NSRect iconRect = [self.gridView iconRectForVisibleIndex:vis];
    NSImage *icon = [self.gridView iconImageForVisibleIndex:vis];
    if (!icon && path.length) {
        icon = [[NSWorkspace sharedWorkspace] iconForFile:path];
        if (icon && !NSIsEmptyRect(iconRect)) {
            icon = [icon copy];
            icon.size = iconRect.size;
        }
    }

    if (NSIsEmptyRect(iconRect) || !icon) {
        [self removeEscapeMonitor];
        self.showGeneration += 1;
        [self finishHide];
        [self openApplicationAtPath:path];
        return;
    }

    NSView *content = self.window.contentView;
    NSRect startRect = [self.gridView convertRect:iconRect toView:content];
    /* Ensure a valid on-screen rect before animating */
    if (NSWidth(startRect) < 8.0 || NSHeight(startRect) < 8.0) {
        [self removeEscapeMonitor];
        self.showGeneration += 1;
        [self finishHide];
        [self openApplicationAtPath:path];
        return;
    }

    content.wantsLayer = YES;
    CGFloat w = NSWidth(startRect);
    CGFloat h = NSHeight(startRect);
    CGFloat midX = NSMidX(startRect);
    CGFloat midY = NSMidY(startRect);

    /* Rasterize icon into a free CALayer — AppKit rewrites NSView layer geometry,
       which made scale appear to grow from a corner (biased right). */
    NSImage *raster = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [raster lockFocus];
    [icon drawInRect:NSMakeRect(0, 0, w, h)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];
    [raster unlockFocus];

    NSRect proposed = NSMakeRect(0, 0, w, h);
    CGImageRef cgImage = [raster CGImageForProposedRect:&proposed context:nil hints:nil];
    if (!cgImage) {
        [self removeEscapeMonitor];
        self.showGeneration += 1;
        [self finishHide];
        [self openApplicationAtPath:path];
        return;
    }

    CALayer *iconLayer = [CALayer layer];
    iconLayer.contents = (__bridge id)cgImage;
    iconLayer.contentsGravity = kCAGravityResize;
    iconLayer.contentsScale = self.window.backingScaleFactor;
    iconLayer.bounds = CGRectMake(0, 0, w, h);
    iconLayer.anchorPoint = CGPointMake(0.5, 0.5);
    iconLayer.position = CGPointMake(midX, midY);
    iconLayer.opacity = 1.0;
    [content.layer addSublayer:iconLayer];

    [self removeEscapeMonitor];
    self.showGeneration += 1;
    self.animating = YES;

    /* Fade chrome; keep launch icon on its own layer animation. */
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = 0.26;
        ctx.allowsImplicitAnimation = YES;
        self.gridView.animator.alphaValue = 0.0;
        self.blurView.animator.alphaValue = 0.0;
        self.tintView.animator.alphaValue = 0.0;
        self.searchField.animator.alphaValue = 0.0;
        self.pageIndicator.animator.alphaValue = 0.0;
        self.dismissBackground.animator.alphaValue = 0.0;
    } completionHandler:nil];

    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform"];
    scale.fromValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    scale.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeScale(1.65, 1.65, 1.0)];

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @1.0;
    fade.toValue = @0.0;

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[ scale, fade ];
    group.duration = 0.28;
    group.fillMode = kCAFillModeForwards;
    group.removedOnCompletion = NO;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];

    __weak typeof(self) weakSelf = self;
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        [iconLayer removeFromSuperlayer];
        [self resetChromeAlpha];
        [self finishHide];
        [self openApplicationAtPath:path];
    }];
    [iconLayer addAnimation:group forKey:@"ml.launch"];
    [CATransaction commit];
}

- (void)openApplicationAtPath:(NSString *)path {
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                          configuration:cfg
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
                                          if (error) {
                                              NSLog(@"[MeoLaunch] launch error: %@", error);
                                          } else {
                                              NSLog(@"[MeoLaunch] launched %@", app.bundleIdentifier ?: path);
                                          }
                                      }];
}

- (void)gridViewDidClickBackground:(NSView *)gridView {
    (void)gridView;
    [self hide];
}

- (void)gridView:(NSView *)gridView didChangePage:(NSInteger)page pageCount:(NSInteger)pageCount {
    (void)gridView;
    [self.pageIndicator updateWithPage:page pageCount:pageCount];
}

#pragma mark - MLPageIndicatorDelegate

- (void)pageIndicator:(MLPageIndicator *)indicator didSelectPage:(NSInteger)page {
    (void)indicator;
    [self.gridView goToPage:page];
}

- (void)pageIndicatorDidClickBackground:(MLPageIndicator *)indicator {
    (void)indicator;
    [self hide];
}

#pragma mark - MLDismissBackgroundViewDelegate

- (void)dismissBackgroundViewClicked:(MLDismissBackgroundView *)view {
    (void)view;
    [self hide];
}

@end
