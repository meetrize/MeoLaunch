#import "MLOverlayController.h"

#import "MLAppLauncher.h"
#import "MLConfigStore.h"
#import "MLDismissBackgroundView.h"
#import "MLGridView.h"
#import "MLIconCache.h"
#import "MLLayoutStore.h"
#import "MLGhostPanelProbe.h"
#import "MLOverlayWindow.h"
#import "MLPageIndicator.h"
#import "MLSearchField.h"
#import "NSTextField+MLEditing.h"

#include "ml_filter.h"
#include "ml_layout.h"

#include <mach/mach.h>
#include <malloc/malloc.h>
#include <stdlib.h>
#include <ctype.h>
#include <string.h>

#import <QuartzCore/QuartzCore.h>

@interface MLOverlayController () <MLGridViewDelegate, MLPageIndicatorDelegate, MLDismissBackgroundViewDelegate, NSTextFieldDelegate, MLSearchFieldSettingsDelegate>
@property (nonatomic, weak) MLConfigStore *config;
@property (nonatomic, weak) MLLayoutStore *layoutStore;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSVisualEffectView *blurView;
@property (nonatomic, strong) NSView *tintView;
@property (nonatomic, strong) MLDismissBackgroundView *dismissBackground;
@property (nonatomic, strong) MLGridView *gridView;
@property (nonatomic, strong) MLSearchField *searchField;
@property (nonatomic, strong) MLPageIndicator *pageIndicator;
@property (nonatomic, strong) MLIconCache *iconCache;
@property (nonatomic, strong) NSTextField *folderTitleField;
@property (nonatomic, copy) NSString *openFolderId;
@property (nonatomic, assign) BOOL focusFolderTitleOnEnter;
/** When YES, keep/restore search field first-responder across layout/reload. */
@property (nonatomic, assign) BOOL prefersSearchFocus;
/** After layoutChrome for this show — safe to focus without a misplaced editor. */
@property (nonatomic, assign) BOOL searchFocusArmed;
@property (nonatomic, assign) const MLAppIndex *appIndex;
@property (nonatomic, assign) uint32_t *filterIndices;
@property (nonatomic, assign) size_t filterCapacity;
@property (nonatomic, assign) size_t filterCount;
@property (nonatomic, strong) id escapeMonitor;
/** Dismiss when clicking another screen (other apps → global; our taskbar etc. → local). */
@property (nonatomic, strong) id outsideClickLocalMonitor;
@property (nonatomic, strong) id outsideClickGlobalMonitor;
@property (nonatomic, assign, readwrite) BOOL visible;
@property (nonatomic, assign) BOOL animating;
@property (nonatomic, assign) NSUInteger showGeneration;
@property (nonatomic, assign) NSUInteger iconPurgeGeneration;
@property (nonatomic, strong) NSRunningApplication *previousApp;
@property (nonatomic, strong) NSTimer *searchDebounceTimer;
/** Periodic scan for orphan AppKit chrome (ghost panel under search). */
@property (nonatomic, strong) NSTimer *chromeWatchdogTimer;
/** Layer host for launch/pulse — keeps contentView non-layer-backed. */
@property (nonatomic, strong) NSView *animationHost;
@property (nonatomic, assign) NSUInteger chromeAnomalyCount;
/** When the overlay was last parked warm (orderOut, window kept). */
@property (nonatomic, strong) NSDate *lastParkedAt;
/** Bumped to cancel post-focus chrome scrub bursts. */
@property (nonatomic, assign) NSUInteger chromeScrubGeneration;
@end

/** Idle park → cold destroy (M1.1: 3 min slim warm). */
static const NSTimeInterval kMLOverlayWarmIdleDestroySeconds = 3.0 * 60.0;

/** Lets clicks fall through to the dismiss catcher below. */
@interface MLPassthroughTintView : NSView
@end

@implementation MLPassthroughTintView
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

/** Layer-backed host for transient CALayer animations; never intercepts hits. */
@interface MLAnimationHostView : NSView
@end

@implementation MLAnimationHostView
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

/** Minimum area (pt²) for a contentView subview to count as a "ghost panel".
 * Search-bar-sized (~420×40) is ~16k; also catch smaller flashes (~1200). */
static const CGFloat kMLChromeGhostMinArea = 1200.0;

@implementation MLOverlayController

static void MLLogMemory(NSString *tag) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count);
    if (kr != KERN_SUCCESS) {
        return;
    }
    double mb = (double)info.phys_footprint / (1024.0 * 1024.0);
    NSLog(@"[MeoLaunch] mem %@ phys_footprint=%.1fMB", tag, mb);
}

- (instancetype)initWithConfigStore:(MLConfigStore *)config
                        layoutStore:(MLLayoutStore *)layoutStore {
    self = [super init];
    if (self) {
        _config = config;
        _layoutStore = layoutStore;
        _visible = NO;
        _animating = NO;
        _iconCache = [[MLIconCache alloc] init];
        _iconCache.maxEntries = 128;
        _appIndex = NULL;
        _filterIndices = NULL;
        _filterCapacity = 0;
        _filterCount = 0;
        [MLGhostPanelProbe install];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(configDidChange:)
                                                     name:MLConfigStoreDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(screenParamsChanged:)
                                                     name:NSApplicationDidChangeScreenParametersNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self removeEscapeMonitor];
    [self removeOutsideClickMonitors];
    free(_filterIndices);
    _filterIndices = NULL;
}

- (NSScreen *)preferredScreen {
    NSScreen *screen = [self.config resolvedOverlayScreen];
    if (screen) {
        return screen;
    }
    return [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
}

- (void)applyPreferredScreenFrame {
    if (!self.window) {
        return;
    }
    NSScreen *screen = [self preferredScreen];
    if (!screen) {
        return;
    }
    NSRect frame = screen.frame;
    if (NSEqualRects(self.window.frame, frame)) {
        return;
    }
    [self.window setFrame:frame display:YES];
    [self layoutChrome];
}

- (void)configDidChange:(NSNotification *)note {
    (void)note;
    if (!self.visible) {
        return;
    }
    [self applyPreferredScreenFrame];
    [self applyBackdropAppearance];
}

- (void)screenParamsChanged:(NSNotification *)note {
    (void)note;
    if (!self.visible) {
        return;
    }
    [self applyPreferredScreenFrame];
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
    if (!self.gridView || !self.pageIndicator) {
        return;
    }
    NSInteger pages = [self.gridView pageCount];
    NSInteger page = self.gridView.currentPage;
    [self.pageIndicator updateWithPage:page pageCount:pages];
}

- (BOOL)queryIsEmpty:(NSString *)query {
    if (query.length == 0) {
        return YES;
    }
    const char *q = query.UTF8String ?: "";
    for (size_t i = 0; q[i] != '\0'; i++) {
        if (!isspace((unsigned char)q[i])) {
            return NO;
        }
    }
    return YES;
}

- (void)applyFilterWithQuery:(NSString *)query {
    [self applyFilterWithQuery:query preservePage:NO];
}

- (void)applyFilterWithQuery:(NSString *)query preservePage:(BOOL)preservePage {
    if (!self.gridView) {
        return;
    }
    NSInteger page = preservePage ? self.gridView.currentPage : 0;
    NSInteger sel = preservePage ? self.gridView.selectedVisibleIndex : -1;

    if (!self.appIndex) {
        self.filterCount = 0;
        self.gridView.layout = NULL;
        self.gridView.visibleIndices = NULL;
        self.gridView.visibleCount = 0;
        [self.gridView goToPage:0];
        [self.gridView reloadData];
        [self syncPageIndicator];
        return;
    }

    size_t need = self.appIndex->count > 0 ? self.appIndex->count : 1;
    [self ensureFilterCapacity:need];
    if (!self.filterIndices && self.appIndex->count > 0) {
        return;
    }

    BOOL empty = [self queryIsEmpty:query];
    self.gridView.appIndex = self.appIndex;
    self.gridView.wheelThreshold = self.config.wheelThreshold > 0 ? self.config.wheelThreshold : 8.0;

    if (self.openFolderId.length > 0 && empty) {
        /* Inside a folder: show folder apps only (no nested layout chrome). */
        MLLayoutFolder *folder = ml_layout_folder_by_id(self.layoutStore.layout, self.openFolderId.UTF8String);
        size_t n = 0;
        self.gridView.layout = NULL;
        if (folder && self.filterIndices) {
            for (size_t i = 0; i < folder->count && n < self.filterCapacity; i++) {
                const char *path = folder->items[i].path;
                if (!path) {
                    continue;
                }
                for (size_t a = 0; a < self.appIndex->count; a++) {
                    if (self.appIndex->items[a].path && strcmp(self.appIndex->items[a].path, path) == 0) {
                        self.filterIndices[n++] = (uint32_t)a;
                        break;
                    }
                }
            }
        }
        self.filterCount = n;
        self.gridView.visibleIndices = self.filterIndices;
        self.gridView.visibleCount = self.filterCount;
        self.gridView.allowsExtractOnDragOutside = YES;
        [self updateFolderTitleField];
        self.folderTitleField.hidden = NO;
    } else if (empty && self.layoutStore.layout) {
        /* Browse: root nodes (apps + folders) */
        if (self.openFolderId.length > 0) {
            [self commitFolderTitleIfNeeded];
        }
        self.openFolderId = nil;
        self.folderTitleField.hidden = YES;
        self.gridView.layout = self.layoutStore.layout;
        self.gridView.visibleIndices = NULL;
        self.gridView.visibleCount = 0;
        self.gridView.allowsExtractOnDragOutside = NO;
        self.filterCount = self.layoutStore.layout->count;
    } else {
        /* Search: flat apps */
        if (self.openFolderId.length > 0) {
            [self commitFolderTitleIfNeeded];
        }
        self.openFolderId = nil;
        self.folderTitleField.hidden = YES;
        self.gridView.layout = NULL;
        self.gridView.allowsExtractOnDragOutside = NO;
        size_t n = 0;
        if (self.appIndex->count > 0 && self.filterIndices) {
            n = ml_filter_apply(self.appIndex,
                                query.UTF8String ?: "",
                                self.filterIndices,
                                self.filterCapacity);
        }
        self.filterCount = n;
        self.gridView.visibleIndices = self.filterIndices;
        self.gridView.visibleCount = self.filterCount;
    }

    if (!preservePage) {
        [self.gridView clearSelection];
    }
    [self.gridView goToPage:page];
    if (preservePage && sel >= 0) {
        self.gridView.selectedVisibleIndex = sel;
    }
    [self.gridView reloadData];
    [self syncPageIndicator];
    [self layoutChrome];

    if (self.focusFolderTitleOnEnter && !self.folderTitleField.hidden) {
        self.focusFolderTitleOnEnter = NO;
        self.prefersSearchFocus = NO;
        [self.window makeFirstResponder:self.folderTitleField];
        [self.folderTitleField selectText:nil];
    } else if (self.visible && self.prefersSearchFocus && [self.searchField currentEditor] == nil) {
        /* Do not re-focus while already editing — breaks field-editor binding / filter. */
        [self focusSearchField];
    }

    NSLog(@"[MeoLaunch] %@ \"%@\" -> %zu (pages=%ld folder=%@)",
          empty ? (self.openFolderId ? @"folder" : @"layout") : @"filter",
          query ?: @"",
          self.filterCount,
          (long)[self.gridView pageCount],
          self.openFolderId ?: @"-");
}

- (void)updateFolderTitleField {
    if (!self.openFolderId.length || !self.layoutStore.layout) {
        return;
    }
    MLLayoutFolder *folder = ml_layout_folder_by_id(self.layoutStore.layout, self.openFolderId.UTF8String);
    NSString *name = @"";
    if (folder && folder->name) {
        name = [NSString stringWithUTF8String:folder->name];
    }
    if (name.length == 0) {
        name = @"文件夹";
    }
    self.folderTitleField.stringValue = name;
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

    if (self.blurView) {
        self.blurView.hidden = !blur;
    }
    if (self.tintView) {
        self.tintView.hidden = NO;
    }

    if (blur) {
        self.window.backgroundColor = [NSColor clearColor];
        if (self.tintView.layer) {
            self.tintView.layer.backgroundColor =
                [[NSColor blackColor] colorWithAlphaComponent:opacity].CGColor;
        }
        /* Only keep the expensive material live while overlay is showing. */
        if (self.blurView) {
            self.blurView.state = self.visible ? NSVisualEffectStateActive
                                              : NSVisualEffectStateInactive;
        }
    } else {
        self.window.backgroundColor =
            [[NSColor blackColor] colorWithAlphaComponent:opacity];
        if (self.tintView.layer) {
            self.tintView.layer.backgroundColor = [NSColor clearColor].CGColor;
        }
        if (self.blurView) {
            self.blurView.state = NSVisualEffectStateInactive;
        }
    }
}

/** Warm park: drop VisualEffect entirely (Inactive still retains material cost). */
- (void)stripWarmBlurView {
    NSVisualEffectView *blur = self.blurView;
    if (!blur) {
        return;
    }
    blur.state = NSVisualEffectStateInactive;
    [blur removeFromSuperview];
    self.blurView = nil;
    MLLogMemory(@"hide-strip-blur");
}

/** Recreate fullscreen blur under existing warm chrome (contentView bottom). */
- (void)ensureBlurViewAttached {
    if (!self.window || self.blurView) {
        return;
    }
    if (!self.config.overlayBlur) {
        return;
    }
    NSView *content = self.window.contentView;
    if (!content) {
        return;
    }
    NSVisualEffectView *blur = [[NSVisualEffectView alloc] initWithFrame:content.bounds];
    blur.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    blur.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    blur.material = NSVisualEffectMaterialFullScreenUI;
    blur.state = NSVisualEffectStateActive;
    blur.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    blur.identifier = @"ml.blur";
    NSView *first = content.subviews.firstObject;
    if (first) {
        [content addSubview:blur positioned:NSWindowBelow relativeTo:first];
    } else {
        [content addSubview:blur];
    }
    self.blurView = blur;
}

/** Drop fullscreen Overlay window + icon bitmaps (Cold path / pressure / idle timeout).
 * Must not [NSWindow close] with releasedWhenClosed while AppKit animations/autoreleases
 * still hold the window — that caused EXC_BAD_ACCESS in objc_release on hide. */
- (void)destroyOverlayWindow {
    self.lastParkedAt = nil;
    [self cancelDelayedIconPurge];
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;

    /* Invalidate in-flight icon callbacks before tearing down the grid. */
    [self.iconCache purge];
    [self releaseFilterBuffer];

    NSWindow *w = self.window;
    if (!w) {
        return;
    }

    [w makeFirstResponder:nil];
    [w endEditingFor:nil];
    [w orderOut:nil];
    w.alphaValue = 1.0;

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSWindowDidBecomeKeyNotification
                                                  object:w];

    /* Detach expensive blur first; keep strong locals so hierarchy release is orderly. */
    NSVisualEffectView *blur = self.blurView;
    blur.state = NSVisualEffectStateInactive;
    [blur removeFromSuperview];
    self.blurView = nil;

    [self.gridView clearFolderCompositeCache];
    self.gridView.iconCache = nil;
    [self.gridView removeFromSuperview];
    self.gridView = nil;

    [self.tintView removeFromSuperview];
    self.tintView = nil;
    [self.dismissBackground removeFromSuperview];
    self.dismissBackground = nil;
    [self.searchField removeFromSuperview];
    self.searchField = nil;
    [self.folderTitleField removeFromSuperview];
    self.folderTitleField = nil;
    [self.pageIndicator removeFromSuperview];
    self.pageIndicator = nil;
    [self.animationHost removeFromSuperview];
    self.animationHost = nil;
    [self stopChromeWatchdog];

    [MLGhostPanelProbe detach];

    /* Replace content view after children are gone. Do NOT close/releasedWhenClosed. */
    self.window = nil;
    w.contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    w = nil;

    /* Drain autorelease then ask libmalloc to return free pages (best-effort). */
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            malloc_zone_pressure_relief(NULL, 0);
        }
        MLLogMemory(@"hide-relieved");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (!weakSelf || weakSelf.visible) {
                               return;
                           }
                           malloc_zone_pressure_relief(NULL, 0);
                           MLLogMemory(@"hide-relieved+0.5s");
                       });
    });
}

- (void)layoutChrome {
    if (!self.window) {
        return;
    }
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
    if (self.folderTitleField && !self.folderTitleField.hidden) {
        CGFloat titleH = 28.0;
        CGFloat titleW = 320.0;
        self.folderTitleField.frame = NSMakeRect((NSWidth(bounds) - titleW) * 0.5,
                                                 NSHeight(bounds) - topPad - searchH - 12.0 - titleH,
                                                 titleW,
                                                 titleH);
        self.folderTitleField.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
        if (self.folderTitleField.superview != content) {
            [content addSubview:self.folderTitleField positioned:NSWindowAbove relativeTo:self.searchField];
        }
        gridTop = topPad + searchH + 12.0 + titleH + searchGap;
    } else if (self.folderTitleField.superview) {
        if ([self.folderTitleField currentEditor]) {
            [self.window endEditingFor:self.folderTitleField];
        }
        [self.folderTitleField removeFromSuperview];
    }

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

    self.blurView.frame = bounds;
    self.blurView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.tintView.frame = bounds;
    self.tintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.dismissBackground.frame = bounds;
    self.dismissBackground.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (self.animationHost) {
        self.animationHost.frame = bounds;
        self.animationHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }

    /*
     * Re-addSubview: while a field editor is live ends editing (caret flash → blur).
     * Only reorder the stack when search/folder title are not being edited.
     * Chrome sanitize always runs — including while editing — so orphan field-editor
     * chrome cannot survive for the whole session (ghost panel under search).
     */
    BOOL textEditing = [self.searchField currentEditor] != nil ||
                       [self.folderTitleField currentEditor] != nil;
    if (!textEditing) {
        [content addSubview:self.blurView positioned:NSWindowBelow relativeTo:self.dismissBackground];
        [content addSubview:self.tintView positioned:NSWindowAbove relativeTo:self.blurView];
        [content addSubview:self.dismissBackground positioned:NSWindowBelow relativeTo:self.gridView];
        [content addSubview:self.pageIndicator positioned:NSWindowAbove relativeTo:self.gridView];
        [content addSubview:self.searchField positioned:NSWindowAbove relativeTo:self.pageIndicator];
        if (self.folderTitleField && !self.folderTitleField.hidden) {
            [content addSubview:self.folderTitleField positioned:NSWindowAbove relativeTo:self.searchField];
        }
        if (self.animationHost) {
            [content addSubview:self.animationHost positioned:NSWindowAbove relativeTo:nil];
        }
        [self sanitizeOverlayChrome:@"layoutChrome"];
    } else {
        /* While typing: only fit focus chrome — full sanitize can disturb the field editor. */
        [self.searchField ml_fitFocusChromeInPlace];
        [self.searchField ml_purgeStaleFocusChrome];
    }
    [self syncPageIndicator];
}

- (void)ensureWindow {
    [MLGhostPanelProbe install];
    if (self.window) {
        return;
    }

    NSScreen *screen = [self preferredScreen];
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
    self.blurView.identifier = @"ml.blur";
    [content addSubview:self.blurView];

    self.tintView = [[MLPassthroughTintView alloc] initWithFrame:content.bounds];
    self.tintView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.tintView.wantsLayer = YES;
    self.tintView.identifier = @"ml.tint";
    self.tintView.layer.backgroundColor =
        [[NSColor blackColor] colorWithAlphaComponent:self.config.overlayOpacity].CGColor;
    [content addSubview:self.tintView];

    self.dismissBackground = [[MLDismissBackgroundView alloc] initWithFrame:content.bounds];
    self.dismissBackground.delegate = self;
    self.dismissBackground.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.dismissBackground.identifier = @"ml.dismiss";
    [content addSubview:self.dismissBackground];

    self.gridView = [[MLGridView alloc] initWithFrame:content.bounds];
    self.gridView.delegate = self;
    self.gridView.iconCache = self.iconCache;
    self.gridView.gridConfig = self.config.gridConfig;
    self.gridView.appIndex = self.appIndex;
    self.gridView.currentPage = 0;
    self.gridView.wheelThreshold = self.config.wheelThreshold > 0 ? self.config.wheelThreshold : 8.0;
    self.gridView.identifier = @"ml.grid";
    [content addSubview:self.gridView];

    self.searchField = [[MLSearchField alloc] initWithFrame:NSMakeRect(0, 0, 420, 40)];
    self.searchField.delegate = self;
    self.searchField.settingsDelegate = self;
    self.searchField.identifier = @"ml.search";
    [content addSubview:self.searchField];

    /* Dedicated layer host — never set contentView.wantsLayer (breaks VisualEffect + editors). */
    MLAnimationHostView *animHost = [[MLAnimationHostView alloc] initWithFrame:content.bounds];
    animHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    animHost.identifier = @"ml.animationHost";
    animHost.wantsLayer = YES;
    animHost.layer.backgroundColor = [NSColor clearColor].CGColor;
    self.animationHost = animHost;
    [content addSubview:animHost];

    self.folderTitleField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 320, 28)];
    self.folderTitleField.bezeled = NO;
    self.folderTitleField.bordered = NO;
    self.folderTitleField.drawsBackground = NO;
    self.folderTitleField.editable = YES;
    self.folderTitleField.selectable = YES;
    self.folderTitleField.alignment = NSTextAlignmentCenter;
    self.folderTitleField.font = [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];
    self.folderTitleField.textColor = [NSColor whiteColor];
    self.folderTitleField.focusRingType = NSFocusRingTypeNone;
    self.folderTitleField.delegate = self;
    self.folderTitleField.hidden = YES;
    self.folderTitleField.identifier = @"ml.folderTitle";
    /* Added to hierarchy only while editing a folder title (see layoutChrome). */

    self.pageIndicator = [[MLPageIndicator alloc] initWithFrame:NSMakeRect(0, 0, 200, 16)];
    self.pageIndicator.delegate = self;
    self.pageIndicator.identifier = @"ml.page";
    [content addSubview:self.pageIndicator];

    self.window = w;
    if ([w isKindOfClass:[MLOverlayWindow class]]) {
        [(MLOverlayWindow *)w ml_setHostSearchField:self.searchField titleField:self.folderTitleField];
        [(MLOverlayWindow *)w ml_styledFieldEditor];
    }
    [MLGhostPanelProbe attachOverlayWindow:w searchField:self.searchField];
    [MLGhostPanelProbe dumpSnapshot:@"ensureWindow"];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(overlayWindowDidBecomeKey:)
                                                 name:NSWindowDidBecomeKeyNotification
                                               object:w];
    [self applyBackdropAppearance];
    [self layoutChrome];
}

- (BOOL)isOverlayTextInputFirstResponder {
    NSResponder *fr = self.window.firstResponder;
    if (fr == self.searchField || fr == self.folderTitleField) {
        return YES;
    }
    if ([fr isKindOfClass:[NSTextView class]]) {
        id delegate = ((NSTextView *)fr).delegate;
        return delegate == self.searchField || delegate == self.folderTitleField;
    }
    return NO;
}

- (BOOL)ml_isConfiguredHotKeyEvent:(NSEvent *)event {
    if (!self.config || !self.config.hotkeyEnabled) {
        return NO;
    }
    if ((NSInteger)event.keyCode != self.config.hotkeyKeyCode) {
        return NO;
    }
    NSEventModifierFlags mask = NSEventModifierFlagShift | NSEventModifierFlagControl |
                                NSEventModifierFlagOption | NSEventModifierFlagCommand;
    NSEventModifierFlags got = event.modifierFlags & mask;
    NSEventModifierFlags want = 0;
    if (self.config.hotkeyOption) {
        want |= NSEventModifierFlagOption;
    }
    if (self.config.hotkeyCommand) {
        want |= NSEventModifierFlagCommand;
    }
    if (self.config.hotkeyControl) {
        want |= NSEventModifierFlagControl;
    }
    if (self.config.hotkeyShift) {
        want |= NSEventModifierFlagShift;
    }
    if (want == 0) {
        want = NSEventModifierFlagOption;
    }
    return got == want;
}

- (void)installEscapeMonitor {
    if (self.escapeMonitor) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    self.escapeMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                               handler:^NSEvent *(NSEvent *event) {
                                                                   __strong typeof(weakSelf) self = weakSelf;
                                                                   if (!self) {
                                                                       return event;
                                                                   }
                                                                   /* Carbon already toggles overlay; do not deliver Option+Space to the editor. */
                                                                   if ([self ml_isConfiguredHotKeyEvent:event]) {
                                                                       return nil;
                                                                   }
                                                                   if (event.keyCode == 53) {
                                                                       if ([self isOverlayTextInputFirstResponder]) {
                                                                           [self handleEscape];
                                                                           return nil;
                                                                       }
                                                                       [self handleEscape];
                                                                       return nil;
                                                                   }
                                                                   if ([self isOverlayTextInputFirstResponder]) {
                                                                       return event;
                                                                   }
                                                                   if (event.keyCode == 116) {
                                                                       [self.gridView nudgePage:-1];
                                                                       return nil;
                                                                   }
                                                                   if (event.keyCode == 121) {
                                                                       [self.gridView nudgePage:1];
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

- (BOOL)shouldDismissForOutsideScreenClick {
    if (!self.visible || !self.window) {
        return NO;
    }
    NSPoint p = [NSEvent mouseLocation];
    /* Overlay fills one screen; any click outside that frame is on another display. */
    return !NSPointInRect(p, self.window.frame);
}

- (void)handleOutsideScreenClick {
    if (![self shouldDismissForOutsideScreenClick]) {
        return;
    }
    [self hide];
}

- (void)installOutsideClickMonitors {
    if (self.outsideClickLocalMonitor || self.outsideClickGlobalMonitor) {
        return;
    }
    __weak typeof(self) weakSelf = self;
    NSEventMask mask = NSEventMaskLeftMouseDown;
    self.outsideClickLocalMonitor =
        [NSEvent addLocalMonitorForEventsMatchingMask:mask
                                              handler:^NSEvent *(NSEvent *event) {
                                                  (void)event;
                                                  [weakSelf handleOutsideScreenClick];
                                                  return event;
                                              }];
    self.outsideClickGlobalMonitor =
        [NSEvent addGlobalMonitorForEventsMatchingMask:mask
                                               handler:^(NSEvent *event) {
                                                   (void)event;
                                                   [weakSelf handleOutsideScreenClick];
                                               }];
}

- (void)removeOutsideClickMonitors {
    if (self.outsideClickLocalMonitor) {
        [NSEvent removeMonitor:self.outsideClickLocalMonitor];
        self.outsideClickLocalMonitor = nil;
    }
    if (self.outsideClickGlobalMonitor) {
        [NSEvent removeMonitor:self.outsideClickGlobalMonitor];
        self.outsideClickGlobalMonitor = nil;
    }
}

- (void)handleEscape {
    if (self.openFolderId.length > 0) {
        [self exitFolderSavingTitle:YES];
        return;
    }
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

- (void)commitFolderTitleIfNeeded {
    if (!self.openFolderId.length || !self.folderTitleField) {
        return;
    }
    NSString *name = self.folderTitleField.stringValue ?: @"";
    if ([name isEqualToString:@"文件夹"]) {
        name = @"";
    }
    [self.layoutStore renameFolderId:self.openFolderId name:name];
}

- (void)exitFolderSavingTitle:(BOOL)save {
    if (save) {
        [self commitFolderTitleIfNeeded];
    }
    [self dismissFieldEditors];
    self.openFolderId = nil;
    self.focusFolderTitleOnEnter = NO;
    self.folderTitleField.hidden = YES;
    [self applyFilterWithQuery:@""];
    [self focusSearchField];
}

- (void)enterFolderId:(NSString *)folderId focusTitle:(BOOL)focusTitle {
    if (folderId.length == 0) {
        return;
    }
    self.searchField.stringValue = @"";
    self.openFolderId = folderId;
    self.focusFolderTitleOnEnter = focusTitle;
    if (focusTitle) {
        self.prefersSearchFocus = NO;
    }
    [self applyFilterWithQuery:@""];
}

- (void)focusGridSelectingFirst {
    if ([self.gridView visibleItemCount] == 0) {
        return;
    }
    self.prefersSearchFocus = NO;
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

- (BOOL)isKnownOverlayChromeView:(NSView *)view {
    return view == self.blurView ||
           view == self.tintView ||
           view == self.dismissBackground ||
           view == self.gridView ||
           view == self.searchField ||
           view == self.folderTitleField ||
           view == self.pageIndicator ||
           view == self.animationHost;
}

- (NSText *)liveSearchEditor {
    return self.visible ? [self.searchField currentEditor] : nil;
}

- (NSText *)liveTitleEditor {
    return self.visible ? [self.folderTitleField currentEditor] : nil;
}

- (BOOL)isLiveFieldEditorView:(NSView *)view {
    NSString *cls = NSStringFromClass(view.class);
    if ([cls isEqualToString:@"_NSKeyboardFocusClipView"] ||
        [cls isEqualToString:@"NSTextIndicatorOverlay"] ||
        [cls isEqualToString:@"NSTextInsertionIndicator"]) {
        return YES;
    }
    NSText *searchEditor = [self liveSearchEditor];
    NSText *titleEditor = [self liveTitleEditor];
    if (view == (id)searchEditor || view == (id)titleEditor) {
        return YES;
    }
    /* Scroll/clip wrappers that only host the live editor. */
    if ([view isKindOfClass:[NSScrollView class]]) {
        NSView *doc = ((NSScrollView *)view).documentView;
        return doc == (id)searchEditor || doc == (id)titleEditor;
    }
    if ([view isKindOfClass:[NSClipView class]]) {
        NSView *doc = ((NSClipView *)view).documentView;
        return doc == (id)searchEditor || doc == (id)titleEditor;
    }
    /* currentEditor can briefly be nil while firstResponder is still the field /
     * its editor — do not treat that NSTextView as an orphan. */
    NSResponder *fr = self.window.firstResponder;
    if (view == (id)fr) {
        return YES;
    }
    if ([view isKindOfClass:[NSTextView class]] &&
        ((NSTextView *)view).isFieldEditor &&
        (fr == self.searchField || fr == self.folderTitleField ||
         fr == (id)searchEditor || fr == (id)titleEditor)) {
        return YES;
    }
    if ([self.window isKindOfClass:[MLOverlayWindow class]]) {
        NSTextView *owned = [(MLOverlayWindow *)self.window ml_ownedFieldEditorIfAny];
        if (owned && (view == owned ||
                      ([view isKindOfClass:[NSScrollView class]] &&
                       ((NSScrollView *)view).documentView == owned))) {
            return YES;
        }
    }
    return NO;
}

- (void)logChromeAnomaly:(NSString *)reason view:(NSView *)view {
    self.chromeAnomalyCount += 1;
    NSMutableString *chain = [NSMutableString string];
    for (NSView *v = view; v; v = v.superview) {
        if (chain.length) {
            [chain appendString:@" ← "];
        }
        [chain appendFormat:@"%@%@", NSStringFromClass(v.class), NSStringFromRect(v.frame)];
    }
    NSResponder *fr = self.window.firstResponder;
    NSLog(@"[MeoLaunch][ChromeAnomaly] #%lu reason=%@ class=%@ frame=%@ hidden=%d alpha=%.2f "
          @"editingSearch=%d editingTitle=%d firstResponder=%@ prefersSearchFocus=%d chain=%@\n  stack:\n  %@",
          (unsigned long)self.chromeAnomalyCount,
          reason,
          NSStringFromClass(view.class),
          NSStringFromRect(view.frame),
          view.hidden ? 1 : 0,
          view.alphaValue,
          [self liveSearchEditor] != nil,
          [self liveTitleEditor] != nil,
          fr ? NSStringFromClass(fr.class) : @"(nil)",
          self.prefersSearchFocus ? 1 : 0,
          chain,
          [[NSThread callStackSymbols] componentsJoinedByString:@"\n  "]);
    if ([reason rangeOfString:@"editor-frame"].location == NSNotFound) {
        [MLGhostPanelProbe dumpSnapshot:[NSString stringWithFormat:@"anomaly-%@", reason]];
    }

    /* Also dump sibling inventory once so Console.app captures the full picture. */
    NSView *content = self.window.contentView;
    if (!content) {
        return;
    }
    NSMutableArray<NSString *> *subs = [NSMutableArray array];
    for (NSView *sub in content.subviews) {
        [subs addObject:[NSString stringWithFormat:@"%@%@",
                         NSStringFromClass(sub.class), NSStringFromRect(sub.frame)]];
    }
    NSLog(@"[MeoLaunch][ChromeAnomaly] contentView.subviews=%@", [subs componentsJoinedByString:@", "]);

    /* Cross-window check: IME / system panels live outside our contentView. */
    for (NSWindow *w in [NSApp windows]) {
        if (w == self.window || ![w isVisible]) {
            continue;
        }
        if (w.level < self.window.level) {
            continue;
        }
        NSLog(@"[MeoLaunch][ChromeAnomaly] otherWindow class=%@ level=%ld frame=%@ title=%@",
              NSStringFromClass(w.class),
              (long)w.level,
              NSStringFromRect(w.frame),
              w.title ?: @"");
    }
}

- (void)styleFieldEditor:(NSText *)editor {
    if (![editor isKindOfClass:[NSTextView class]]) {
        return;
    }
    if ([self.window isKindOfClass:[MLOverlayWindow class]]) {
        [(MLOverlayWindow *)self.window ml_restyleFieldEditor];
    }
    NSTextView *tv = (NSTextView *)editor;
    NSFont *font = self.searchField.font ?: [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
    tv.font = font;
    tv.alignment = NSTextAlignmentCenter;
    tv.drawsBackground = NO;
    tv.backgroundColor = [NSColor clearColor];
    tv.textColor = [NSColor whiteColor];
    tv.insertionPointColor = [NSColor whiteColor];
    tv.textContainerInset = NSZeroSize;
    tv.focusRingType = NSFocusRingTypeNone;
    /* Do not force wantsLayer — layer-backed editors flash gray chrome. */
    NSScrollView *scroll = tv.enclosingScrollView;
    if (scroll) {
        scroll.drawsBackground = NO;
        scroll.backgroundColor = [NSColor clearColor];
        scroll.borderType = NSNoBorder;
        scroll.hasVerticalScroller = NO;
        scroll.hasHorizontalScroller = NO;
        NSClipView *clip = scroll.contentView;
        if ([clip isKindOfClass:[NSClipView class]]) {
            clip.drawsBackground = NO;
            clip.backgroundColor = [NSColor clearColor];
        }
    }
}

/** Keep the live editor geometry inside its control's title rect (in-place). */
- (void)clampFieldEditor:(NSTextView *)tv toField:(NSTextField *)field reason:(NSString *)reason {
    if (!tv || !field || field.hidden) {
        return;
    }
    (void)reason;
    if ([field isKindOfClass:[MLSearchField class]]) {
        [(MLSearchField *)field ml_fitFocusChromeInPlace];
        return;
    }
    if ([self.window isKindOfClass:[MLOverlayWindow class]]) {
        [(MLOverlayWindow *)self.window ml_pinFieldEditorToHostField];
    }
    NSRect titleRect = [[field cell] titleRectForBounds:field.bounds];
    if (NSIsEmptyRect(titleRect) || NSWidth(titleRect) < 4.0 || NSHeight(titleRect) < 4.0) {
        return;
    }
    /* Never reparent out of AppKit keyboard-focus clip — size clip/editor in place. */
    for (NSView *v = tv.superview; v && v != field; v = v.superview) {
        if ([NSStringFromClass(v.class) isEqualToString:@"_NSKeyboardFocusClipView"]) {
            if ([v isKindOfClass:[NSClipView class]]) {
                ((NSClipView *)v).drawsBackground = NO;
                ((NSClipView *)v).backgroundColor = [NSColor clearColor];
            }
            v.focusRingType = NSFocusRingTypeNone;
            v.frame = titleRect;
            NSView *host = tv.enclosingScrollView ?: (NSView *)tv;
            if (host.superview == v || host == v) {
                host.frame = (host == v) ? titleRect : v.bounds;
            }
            if (host != tv) {
                tv.frame = host.bounds;
            } else if (tv.superview == v) {
                tv.frame = v.bounds;
            }
            return;
        }
    }
    NSView *host = tv.enclosingScrollView ?: (NSView *)tv;
    if (host.superview == field) {
        NSRect expected = [field convertRect:titleRect toView:field];
        if (!NSEqualRects(NSIntegralRect(host.frame), NSIntegralRect(expected))) {
            host.frame = expected;
            if (host != tv) {
                tv.frame = host.bounds;
            }
        }
    }
}

/**
 * Heal intermittent AppKit chrome: orphan field editors / scroll wrappers /
 * unexpected visual-effect panels that cover the icon grid under search.
 * Safe while editing — never ends editing or reorders known chrome via addSubview:.
 */
- (void)sanitizeOverlayChrome:(NSString *)reason {
    if (!self.window) {
        return;
    }
    NSView *content = self.window.contentView;
    if (!content) {
        return;
    }

    NSText *searchEditor = [self liveSearchEditor];
    NSText *titleEditor = [self liveTitleEditor];
    if ([searchEditor isKindOfClass:[NSTextView class]]) {
        [self styleFieldEditor:searchEditor];
        [self clampFieldEditor:(NSTextView *)searchEditor toField:self.searchField reason:reason];
    }
    if ([titleEditor isKindOfClass:[NSTextView class]]) {
        [self styleFieldEditor:titleEditor];
        [self clampFieldEditor:(NSTextView *)titleEditor toField:self.folderTitleField reason:reason];
    }

    for (NSView *sub in [content.subviews copy]) {
        if ([self isKnownOverlayChromeView:sub]) {
            continue;
        }
        if ([self isLiveFieldEditorView:sub]) {
            if ([sub isKindOfClass:[NSTextView class]]) {
                [self styleFieldEditor:(NSText *)sub];
                NSTextField *owner = (sub == (id)searchEditor ||
                                      self.window.firstResponder == self.searchField)
                    ? self.searchField : self.folderTitleField;
                if (owner == self.folderTitleField && self.folderTitleField.hidden) {
                    owner = self.searchField;
                }
                [self clampFieldEditor:(NSTextView *)sub toField:owner reason:reason];
            } else if ([sub isKindOfClass:[NSScrollView class]]) {
                NSView *doc = ((NSScrollView *)sub).documentView;
                if ([doc isKindOfClass:[NSTextView class]]) {
                    [self styleFieldEditor:(NSText *)doc];
                    NSTextField *owner = self.searchField;
                    if (self.folderTitleField && !self.folderTitleField.hidden &&
                        (self.window.firstResponder == self.folderTitleField ||
                         doc == (id)titleEditor)) {
                        owner = self.folderTitleField;
                    }
                    [self clampFieldEditor:(NSTextView *)doc toField:owner reason:reason];
                }
            }
            continue;
        }

        CGFloat area = NSWidth(sub.frame) * NSHeight(sub.frame);
        BOOL looksLikeGhost = area >= kMLChromeGhostMinArea ||
                              [sub isKindOfClass:[NSVisualEffectView class]] ||
                              [sub isKindOfClass:[NSTextView class]] ||
                              [sub isKindOfClass:[NSScrollView class]] ||
                              [sub isKindOfClass:[NSClipView class]];
        if (!looksLikeGhost) {
            continue;
        }

        [self logChromeAnomaly:[NSString stringWithFormat:@"orphan/%@", reason] view:sub];
        [sub removeFromSuperview];
    }

    if ([self.window isKindOfClass:[MLOverlayWindow class]]) {
        [(MLOverlayWindow *)self.window ml_pinFieldEditorToHostField];
    }
    [self.searchField ml_fitFocusChromeInPlace];
    [self.searchField ml_purgeStaleFocusChrome];
    [self dismissCompletionChromeWindows];
}

- (void)dismissCompletionChromeWindows {
    if (!self.window) {
        return;
    }
    NSRect searchInWindow = [self.searchField convertRect:self.searchField.bounds toView:nil];
    NSRect searchScreen = [self.window convertRectToScreen:searchInWindow];
    for (NSWindow *w in [NSApp windows]) {
        if (w == self.window || !w.isVisible) {
            continue;
        }
        NSString *cls = NSStringFromClass(w.class);
        BOOL looksIME = [cls rangeOfString:@"IMK" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                        [cls rangeOfString:@"TSM" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                        [cls rangeOfString:@"InputContext" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (looksIME) {
            continue;
        }
        BOOL looksCompletion =
            [cls rangeOfString:@"Completion" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cls rangeOfString:@"Prediction" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cls rangeOfString:@"WritingTools" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cls rangeOfString:@"AutoFill" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [cls rangeOfString:@"Candidate" options:NSCaseInsensitiveSearch].location != NSNotFound;
        BOOL childOfOverlay = (w.parentWindow == self.window);
        /* Small rounded panel parked directly under the search field. */
        NSRect wf = w.frame;
        BOOL underSearch = NSMaxY(wf) <= NSMinY(searchScreen) + 8.0 &&
                           NSMaxY(wf) >= NSMinY(searchScreen) - 280.0 &&
                           NSIntersectsRect(NSInsetRect(searchScreen, -80, -400), wf) &&
                           NSHeight(wf) < 360.0 && NSWidth(wf) < 720.0;
        if (looksCompletion || (childOfOverlay && underSearch)) {
            NSLog(@"[MeoLaunch][ChromeAnomaly] dismissing panel class=%@ frame=%@",
                  cls, NSStringFromRect(wf));
            [w orderOut:nil];
        }
    }
}

- (void)dismissFieldEditors {
    if (!self.window) {
        return;
    }
    [self.window endEditingFor:nil];
    [self sanitizeOverlayChrome:@"dismiss"];
    if (self.searchField) {
        self.searchField.alphaValue = 1.0;
    }
    if (self.folderTitleField) {
        self.folderTitleField.alphaValue = 1.0;
    }
}

- (void)startChromeWatchdog {
    [self stopChromeWatchdog];
    __weak typeof(self) weakSelf = self;
    /* Light touch: fit search chrome; avoid aggressive orphan stripping while typing. */
    self.chromeWatchdogTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
                                                                repeats:YES
                                                                  block:^(__unused NSTimer *timer) {
                                                                      __strong typeof(weakSelf) self = weakSelf;
                                                                      if (!self || !self.visible || self.animating) {
                                                                          return;
                                                                      }
                                                                      [self.searchField ml_fitFocusChromeInPlace];
                                                                      [self.searchField ml_purgeStaleFocusChrome];
                                                                      [self dismissCompletionChromeWindows];
                                                                  }];
    [[NSRunLoop mainRunLoop] addTimer:self.chromeWatchdogTimer forMode:NSRunLoopCommonModes];
}

- (void)stopChromeWatchdog {
    [self.chromeWatchdogTimer invalidate];
    self.chromeWatchdogTimer = nil;
}

- (void)cancelChromeScrub {
    self.chromeScrubGeneration += 1;
}

/** After focus: restyle+fit for a couple frames (not a long scrub storm). */
- (void)schedulePostFocusChromeScrub {
    self.chromeScrubGeneration += 1;
    NSUInteger gen = self.chromeScrubGeneration;
    __weak typeof(self) weakSelf = self;
    static const double kDelays[] = { 0.0, 0.016, 0.05 };
    for (size_t i = 0; i < sizeof(kDelays) / sizeof(kDelays[0]); i++) {
        double delay = kDelays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           __strong typeof(weakSelf) self = weakSelf;
                           if (!self || self.chromeScrubGeneration != gen || !self.visible) {
                               return;
                           }
                           NSText *editor = [self.searchField currentEditor];
                           if (editor) {
                               [self styleFieldEditor:editor];
                               if ([editor isKindOfClass:[NSTextView class]]) {
                                   [self clampFieldEditor:(NSTextView *)editor
                                                  toField:self.searchField
                                                   reason:[NSString stringWithFormat:@"focus+%.0fms", delay * 1000.0]];
                               }
                           } else {
                               [self.searchField ml_fitFocusChromeInPlace];
                           }
                           [self.searchField ml_purgeStaleFocusChrome];
                           [self dismissCompletionChromeWindows];
                       });
    }
}

- (void)prewarmFieldEditor {
    if (![self.window isKindOfClass:[MLOverlayWindow class]]) {
        return;
    }
    /* Touch AppKit field editor so first focus is not a cold gray insert. */
    [(MLOverlayWindow *)self.window ml_styledFieldEditor];
}

- (void)focusSearchFieldNow {
    if (!self.visible || !self.searchField || !self.searchFocusArmed) {
        return;
    }
    self.prefersSearchFocus = YES;
    [self prewarmFieldEditor];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyWindow];

    if ([self.searchField currentEditor] != nil) {
        [self styleFieldEditor:[self.searchField currentEditor]];
        [self clampFieldEditor:(NSTextView *)[self.searchField currentEditor]
                       toField:self.searchField
                        reason:@"refocus"];
        [self schedulePostFocusChromeScrub];
        return;
    }

    BOOL ok = [self.window makeFirstResponder:self.searchField];
    if (!ok) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || !self.visible || !self.prefersSearchFocus || !self.searchFocusArmed) {
                return;
            }
            [self prewarmFieldEditor];
            [self.window makeKeyWindow];
            [self.window makeFirstResponder:self.searchField];
            NSText *editor = [self.searchField currentEditor];
            if (editor) {
                [self styleFieldEditor:editor];
                if ([editor isKindOfClass:[NSTextView class]]) {
                    [self clampFieldEditor:(NSTextView *)editor toField:self.searchField reason:@"focus-retry"];
                }
                [editor setSelectedRange:NSMakeRange(0, 0)];
            } else {
                [self.searchField selectText:nil];
                editor = [self.searchField currentEditor];
                if (editor && [editor isKindOfClass:[NSTextView class]]) {
                    [self styleFieldEditor:editor];
                    [self clampFieldEditor:(NSTextView *)editor toField:self.searchField reason:@"selectText-retry"];
                    [editor setSelectedRange:NSMakeRange([[editor string] length], 0)];
                }
            }
            [self.searchField ml_fitFocusChromeInPlace];
            [self schedulePostFocusChromeScrub];
        });
        return;
    }

    NSText *editor = [self.searchField currentEditor];
    if (editor) {
        [self styleFieldEditor:editor];
        if ([editor isKindOfClass:[NSTextView class]]) {
            [self clampFieldEditor:(NSTextView *)editor toField:self.searchField reason:@"focus"];
        }
        [editor setSelectedRange:NSMakeRange([[editor string] length], 0)];
    } else {
        [self.searchField selectText:nil];
        editor = [self.searchField currentEditor];
        if (editor) {
            [self styleFieldEditor:editor];
            if ([editor isKindOfClass:[NSTextView class]]) {
                [self clampFieldEditor:(NSTextView *)editor toField:self.searchField reason:@"selectText"];
            }
            [editor setSelectedRange:NSMakeRange([[editor string] length], 0)];
        }
    }
    [self.searchField ml_fitFocusChromeInPlace];
    [self schedulePostFocusChromeScrub];
    NSLog(@"[MeoLaunch] search field focused (firstResponder=%@ key=%d)",
          NSStringFromClass([self.window.firstResponder class]),
          self.window.isKeyWindow ? 1 : 0);
}

- (void)focusSearchField {
    if (!self.visible || !self.searchField) {
        return;
    }
    if (!self.searchFocusArmed) {
        return;
    }
    /* Wait until Option (hotkey) is released so Space is not delivered into the editor. */
    if ([NSEvent modifierFlags] & NSEventModifierFlagOption) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf focusSearchField];
                       });
        return;
    }
    [self focusSearchFieldNow];
}

- (void)overlayWindowDidBecomeKey:(NSNotification *)note {
    if (note.object != self.window || !self.visible || !self.prefersSearchFocus) {
        return;
    }
    if (!self.searchFocusArmed) {
        return;
    }
    NSText *editor = [self.searchField currentEditor];
    if (editor) {
        [self styleFieldEditor:editor];
        if ([editor isKindOfClass:[NSTextView class]]) {
            [self clampFieldEditor:(NSTextView *)editor toField:self.searchField reason:@"didBecomeKey"];
        }
        [self.searchField ml_fitFocusChromeInPlace];
        return;
    }
    [self focusSearchField];
}

- (void)releaseFilterBuffer {
    free(self.filterIndices);
    self.filterIndices = NULL;
    self.filterCapacity = 0;
    self.filterCount = 0;
    if (self.gridView) {
        self.gridView.visibleIndices = NULL;
        self.gridView.visibleCount = 0;
    }
}

- (void)scheduleDelayedIconPurge {
    self.iconPurgeGeneration += 1;
    NSUInteger gen = self.iconPurgeGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (!self || self.iconPurgeGeneration != gen) {
                           return;
                       }
                       if (self.visible || self.animating) {
                           return;
                       }
                       [self.iconCache purge];
                       MLLogMemory(@"delayed-purge");
                       NSLog(@"[MeoLaunch] Overlay icon cache purged (5s idle)");
                   });
}

- (void)cancelDelayedIconPurge {
    self.iconPurgeGeneration += 1;
}

- (void)show {
    [self showWithFade:YES];
}

- (void)showImmediate {
    [self showCritical];
    __weak typeof(self) weakSelf = self;
    NSUInteger gen = self.showGeneration;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.showGeneration != gen || !self.visible) {
            return;
        }
        [self showDeferredChrome];
    });
}

- (void)showCritical {
    [MLGhostPanelProbe install];
    self.animating = NO;
    self.showGeneration += 1;
    [self cancelDelayedIconPurge];

    BOOL warmReuse = (self.window != nil);
    [self ensureWindow];
    [self ensureBlurViewAttached];
    if (warmReuse) {
        NSLog(@"[MeoLaunch] Overlay warm-reuse");
    }
    self.lastParkedAt = nil;

    self.searchField.refusesFirstResponder = YES;
    [self.gridView cancelActiveDrag];
    [self dismissFieldEditors];
    [self.searchField ml_purgeStaleFocusChrome];

    NSScreen *screen = [self preferredScreen];
    if (screen) {
        [self.window setFrame:screen.frame display:NO];
    }

    self.gridView.gridConfig = self.config.gridConfig;
    self.gridView.wheelThreshold = self.config.wheelThreshold > 0 ? self.config.wheelThreshold : 8.0;
    self.searchField.stringValue = @"";
    self.openFolderId = nil;
    self.focusFolderTitleOnEnter = NO;
    self.folderTitleField.hidden = YES;
    self.prefersSearchFocus = YES;
    self.searchFocusArmed = NO;

    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (front && ![front.bundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
        self.previousApp = front;
    }

    self.visible = YES;

    if ([self.delegate respondsToSelector:@selector(overlayControllerWillShow:)]) {
        [self.delegate overlayControllerWillShow:self];
    }

    [self applyBackdropAppearance];
    /* Fast path: avoid full layoutChrome sanitize before first pixel. */
    if (self.blurView) {
        self.blurView.frame = self.window.contentView.bounds;
    }
    if (self.tintView) {
        self.tintView.frame = self.window.contentView.bounds;
    }

    self.window.alphaValue = 1.0;
    /* Do not makeKeyAndOrderFront — that runs `_selectFirstKeyView` and injects
     * `_NSKeyboardFocusClipView` before layout (zero-size ghost + Option+Space crash). */
    self.searchField.refusesFirstResponder = YES;
    [NSApp activateIgnoringOtherApps:YES];
    [self.window orderFrontRegardless];
    if (self.gridView) {
        [self.window makeFirstResponder:self.gridView];
    }
    [self.window makeKeyWindow];
    /* Cheap: Esc / outside-click must work even if deferred chrome is one turn late. */
    [self installEscapeMonitor];
    [self installOutsideClickMonitors];

    MLLogMemory(@"show-critical");
    [MLGhostPanelProbe attachOverlayWindow:self.window searchField:self.searchField];
    [MLGhostPanelProbe noteEvent:warmReuse ? @"showCritical-warm" : @"showCritical-cold"];
    [MLGhostPanelProbe dumpSnapshot:warmReuse ? @"showCritical-warm" : @"showCritical-cold"];
}

- (void)showDeferredChrome {
    if (!self.visible || !self.window) {
        return;
    }
    NSUInteger gen = self.showGeneration;

    [MLGhostPanelProbe noteEvent:@"showDeferred-begin"];
    [self applyBackdropAppearance];
    [self layoutChrome];
    [self applyFilterWithQuery:@""];

    self.searchFocusArmed = YES;
    self.searchField.refusesFirstResponder = NO;
    [self.searchField ml_purgeStaleFocusChrome];
    [self focusSearchField];
    [self startChromeWatchdog];
    [self.searchField ml_fitFocusChromeInPlace];
    [self dismissCompletionChromeWindows];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (!self || self.showGeneration != gen || !self.visible) {
                           return;
                       }
                       if ([self.searchField currentEditor] == nil) {
                           [self focusSearchField];
                       } else {
                           [self.searchField ml_fitFocusChromeInPlace];
                       }
                   });

    NSScreen *screen = [self preferredScreen];
    MLLogMemory(@"show");
    NSLog(@"[MeoLaunch] Overlay shown on %@ (%zu apps, pages=%ld, search=%@)",
          screen.localizedName ?: @"screen",
          self.appIndex ? self.appIndex->count : 0,
          (long)[self.gridView pageCount],
          NSStringFromRect(self.searchField.frame));
    [MLGhostPanelProbe dumpSnapshot:@"showDeferred-end"];
    [MLGhostPanelProbe scheduleShowBurst];
}

- (void)showWithFade:(BOOL)fade {
    if (!fade) {
        [self showImmediate];
        return;
    }

    [self showCritical];
    NSUInteger gen = self.showGeneration;
    NSTimeInterval dur = [self fadeDuration];
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
        }];
        __weak typeof(self) weakSelf = self;
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

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.showGeneration != gen || !self.visible) {
            return;
        }
        [self showDeferredChrome];
    });
}

- (void)finishHide {
    self.chromeScrubGeneration += 1;
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    [self stopChromeWatchdog];
    [self.gridView cancelActiveDrag];
    [self dismissFieldEditors];
    self.searchField.refusesFirstResponder = YES;
    /* Purge after AppKit finishes resigning first responder — removing a live
     * `_NSKeyboardFocusClipView` crashes in its dealloc (hotkey Option+Space). */
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        [self.searchField ml_purgeStaleFocusChrome];
    });
    if (self.openFolderId.length > 0) {
        [self commitFolderTitleIfNeeded];
        self.openFolderId = nil;
        /* folderTitleField may already be gone on re-entrant hide */
        self.folderTitleField.hidden = YES;
    }

    /* Stop any in-flight window alpha animation before parking warm. */
    NSWindow *w = self.window;
    if (w) {
        [w.animator setAlphaValue:w.alphaValue];
        w.alphaValue = 1.0;
        [w orderOut:nil];
        [w makeFirstResponder:nil];
        [w endEditingFor:nil];
    }

    /* Drop VisualEffect while parked — keep NSWindow + light chrome for warm-reuse. */
    [self stripWarmBlurView];

    self.visible = NO;
    self.animating = NO;
    self.prefersSearchFocus = NO;
    self.searchFocusArmed = NO;
    self.lastParkedAt = [NSDate date];

    NSRunningApplication *prev = self.previousApp;
    self.previousApp = nil;
    if (prev && !prev.isTerminated) {
        [prev activateWithOptions:(NSApplicationActivationOptions)0];
    }
    if ([self.delegate respondsToSelector:@selector(overlayControllerDidHide:)]) {
        [self.delegate overlayControllerDidHide:self];
    }

    /* Keep window warm for fast re-show; purge heavy caches on a delay. */
    [self releaseFilterBuffer];
    if (self.gridView) {
        [self.gridView clearFolderCompositeCache];
    }
    [self scheduleDelayedIconPurge];
    MLLogMemory(@"hide-warm");
    NSLog(@"[MeoLaunch] Overlay hidden (warm park)");
    [MLGhostPanelProbe noteEvent:@"hide-warm"];
}

- (void)hide {
    if (!self.visible && !self.window.isVisible) {
        return;
    }
    [self removeEscapeMonitor];
    [self removeOutsideClickMonitors];
    self.showGeneration += 1;
    NSUInteger gen = self.showGeneration;

    NSTimeInterval dur = [self fadeDuration];
    if (dur <= 0 || !self.window) {
        [self finishHide];
        return;
    }

    self.animating = YES;
    NSWindow *w = self.window;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = dur;
        ctx.allowsImplicitAnimation = YES;
        w.animator.alphaValue = 0.0;
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

- (NSString *)overlayResidenceState {
    if (self.visible) {
        return @"visible";
    }
    if (self.window) {
        return @"warm";
    }
    return @"cold";
}

- (BOOL)isOverlayWindowWarm {
    return !self.visible && self.window != nil;
}

- (void)reclaimIdleCachesIfHidden {
    if (self.visible || self.animating) {
        return;
    }
    [self cancelDelayedIconPurge];
    [self.iconCache purge];
    [self releaseFilterBuffer];
    if (self.gridView) {
        [self.gridView clearFolderCompositeCache];
    }
}

- (void)destroyWarmOverlayIfNeededForce:(BOOL)force {
    if (self.visible || self.animating) {
        return;
    }
    if (!self.window) {
        return;
    }
    if (!force) {
        if (!self.lastParkedAt) {
            return;
        }
        NSTimeInterval parked = [[NSDate date] timeIntervalSinceDate:self.lastParkedAt];
        if (parked < kMLOverlayWarmIdleDestroySeconds) {
            return;
        }
    }
    NSLog(@"[MeoLaunch] Overlay cold-destroy (force=%d)", force ? 1 : 0);
    [self destroyOverlayWindow];
    self.lastParkedAt = nil;
    MLLogMemory(@"hide-destroyed");
}

- (void)setIconCacheMaxEntries:(NSUInteger)maxEntries {
    if (maxEntries < 32) {
        maxEntries = 32;
    }
    if (maxEntries > 256) {
        maxEntries = 256;
    }
    self.iconCache.maxEntries = maxEntries;
    /* Cap dropped a lot → free memory now; else next insert evicts via LRU. */
    if (self.iconCache.cachedCount > maxEntries) {
        [self.iconCache purge];
    }
}

#pragma mark - NSTextFieldDelegate

- (void)controlTextDidBeginEditing:(NSNotification *)obj {
    NSControl *control = obj.object;
    if (control != self.searchField && control != self.folderTitleField) {
        return;
    }
    if ([control isKindOfClass:[MLSearchField class]]) {
        [(MLSearchField *)control ml_fitFocusChromeInPlace];
    }
    NSText *editor = [control currentEditor];
    [self styleFieldEditor:editor];
    if ([editor isKindOfClass:[NSTextView class]] && [control isKindOfClass:[NSTextField class]]) {
        [self clampFieldEditor:(NSTextView *)editor toField:(NSTextField *)control reason:@"beginEdit"];
    }
    [self.searchField ml_purgeStaleFocusChrome];
    [self schedulePostFocusChromeScrub];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == self.folderTitleField) {
        return;
    }
    NSString *query = self.searchField.stringValue ?: @"";
    /* Immediate filter so the first keystroke updates the grid. */
    [self applyFilterWithQuery:query];

    [self.searchDebounceTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.02
                                                                repeats:NO
                                                                  block:^(__unused NSTimer *timer) {
                                                                      __strong typeof(weakSelf) self = weakSelf;
                                                                      if (!self) {
                                                                          return;
                                                                      }
                                                                      self.searchDebounceTimer = nil;
                                                                      [self applyFilterWithQuery:self.searchField.stringValue ?: @""];
                                                                  }];
    [[NSRunLoop mainRunLoop] addTimer:self.searchDebounceTimer forMode:NSRunLoopCommonModes];
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == self.folderTitleField) {
        [self commitFolderTitleIfNeeded];
    }
}

- (BOOL)control:(NSControl *)control
       textView:(NSTextView *)textView
doCommandBySelector:(SEL)commandSelector {
    (void)textView;
    /* Never [textView doCommandBySelector:] here — NSTextView asks this
     * delegate again and recurses until stack overflow (e.g. Right Arrow).
     * Return NO so the field editor applies the command itself. */

    /* Borderless overlay has no safe key-view loop; swallow Tab. */
    if (commandSelector == @selector(insertTab:) ||
        commandSelector == @selector(insertBacktab:)) {
        return YES;
    }

    if (control == self.folderTitleField) {
        if (commandSelector == @selector(insertNewline:) ||
            commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
            [self commitFolderTitleIfNeeded];
            self.prefersSearchFocus = NO;
            [self.window makeFirstResponder:self.gridView];
            return YES;
        }
        if (commandSelector == @selector(cancelOperation:)) {
            [self exitFolderSavingTitle:YES];
            return YES;
        }
        return NO;
    }
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
    if (!self.window) {
        return;
    }
    self.gridView.alphaValue = 1.0;
    self.blurView.alphaValue = 1.0;
    self.tintView.alphaValue = 1.0;
    self.pageIndicator.alphaValue = 1.0;
    self.dismissBackground.alphaValue = 1.0;
}

- (void)gridView:(MLGridView *)gridView didActivateAppAtPath:(NSString *)path {
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
    NSView *layerHost = self.animationHost ?: content;
    NSRect startRect = [self.gridView convertRect:iconRect toView:layerHost];
    /* Ensure a valid on-screen rect before animating */
    if (NSWidth(startRect) < 8.0 || NSHeight(startRect) < 8.0) {
        [self removeEscapeMonitor];
        self.showGeneration += 1;
        [self finishHide];
        [self openApplicationAtPath:path];
        return;
    }

    layerHost.wantsLayer = YES;
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
    [layerHost.layer addSublayer:iconLayer];

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
    [MLAppLauncher openApplicationAtPath:path];
}

- (void)gridViewDidClickBackground:(MLGridView *)gridView {
    (void)gridView;
    if (self.openFolderId.length > 0) {
        [self exitFolderSavingTitle:YES];
        return;
    }
    [self hide];
}

- (void)gridView:(MLGridView *)gridView didChangePage:(NSInteger)page pageCount:(NSInteger)pageCount {
    (void)gridView;
    [self.pageIndicator updateWithPage:page pageCount:pageCount];
}

- (BOOL)gridViewAllowsReorder:(MLGridView *)gridView {
    (void)gridView;
    if (!self.layoutStore.layout) {
        return NO;
    }
    if (![self queryIsEmpty:self.searchField.stringValue]) {
        return NO;
    }
    /* Browse root or inside folder both allow drag. */
    return YES;
}

- (void)gridView:(MLGridView *)gridView didReorderFrom:(NSInteger)fromIndex to:(NSInteger)toIndex {
    (void)gridView;
    if (self.openFolderId.length > 0) {
        if (![self.layoutStore reorderFolderId:self.openFolderId from:fromIndex to:toIndex]) {
            return;
        }
        [self applyFilterWithQuery:@"" preservePage:YES];
        if (toIndex >= 0) {
            self.gridView.selectedVisibleIndex = toIndex;
        }
        return;
    }
    if (![self.layoutStore moveRootFrom:fromIndex to:toIndex]) {
        return;
    }
    [self applyFilterWithQuery:@"" preservePage:YES];
    if (toIndex >= 0) {
        self.gridView.selectedVisibleIndex = toIndex;
    }
}

- (void)gridView:(MLGridView *)gridView didMergeItem:(NSInteger)fromIndex ontoItem:(NSInteger)toIndex {
    (void)gridView;
    NSString *fid = [self.layoutStore mergeRootAppFrom:fromIndex onto:toIndex];
    if (!fid.length) {
        return;
    }
    NSInteger folderIndex = MIN(fromIndex, toIndex);
    [self applyFilterWithQuery:@"" preservePage:YES];
    if (folderIndex >= 0) {
        self.gridView.selectedVisibleIndex = folderIndex;
        [self.gridView pulseVisibleIndex:folderIndex];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       __strong typeof(weakSelf) self = weakSelf;
                       if (!self || !self.visible) {
                           return;
                       }
                       [self enterFolderId:fid focusTitle:YES];
                   });
}

- (void)gridView:(MLGridView *)gridView didExtractItemAt:(NSInteger)index {
    (void)gridView;
    if (!self.openFolderId.length) {
        return;
    }
    BOOL gone = NO;
    if (![self.layoutStore extractAppAt:index fromFolderId:self.openFolderId folderGone:&gone]) {
        return;
    }
    if (gone) {
        [self exitFolderSavingTitle:NO];
    } else {
        [self applyFilterWithQuery:@"" preservePage:YES];
    }
}

- (void)gridView:(MLGridView *)gridView didAddItem:(NSInteger)fromIndex toFolderAt:(NSInteger)folderIndex {
    (void)gridView;
    if (![self.layoutStore addRootAppFrom:fromIndex toFolderAt:folderIndex]) {
        return;
    }
    /* Removing a lower-index app shifts the folder left by one. */
    NSInteger pulseIndex = folderIndex;
    if (fromIndex < folderIndex) {
        pulseIndex = folderIndex - 1;
    }
    [self applyFilterWithQuery:@"" preservePage:YES];
    if (pulseIndex >= 0) {
        self.gridView.selectedVisibleIndex = pulseIndex;
        [self.gridView pulseVisibleIndex:pulseIndex];
    }
}

- (void)gridView:(MLGridView *)gridView didActivateFolderId:(NSString *)folderId {
    (void)gridView;
    [self enterFolderId:folderId focusTitle:NO];
}

#pragma mark - MLPageIndicatorDelegate

- (void)pageIndicator:(MLPageIndicator *)indicator didSelectPage:(NSInteger)page {
    (void)indicator;
    [self.gridView goToPage:page];
}

- (void)pageIndicatorDidClickBackground:(MLPageIndicator *)indicator {
    (void)indicator;
    if (self.openFolderId.length > 0) {
        [self exitFolderSavingTitle:YES];
        return;
    }
    [self hide];
}

#pragma mark - MLDismissBackgroundViewDelegate

- (void)dismissBackgroundViewClicked:(MLDismissBackgroundView *)view {
    (void)view;
    if (self.openFolderId.length > 0) {
        [self exitFolderSavingTitle:YES];
        return;
    }
    [self hide];
}

@end
