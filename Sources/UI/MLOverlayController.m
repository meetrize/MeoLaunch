#import "MLOverlayController.h"

#import "MLConfigStore.h"
#import "MLDismissBackgroundView.h"
#import "MLGridView.h"
#import "MLIconCache.h"
#import "MLLayoutStore.h"
#import "MLOverlayWindow.h"
#import "MLPageIndicator.h"
#import "MLSearchField.h"
#import "MLStandardEditMenu.h"
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

    if (!self.gridView.allowsExtractOnDragOutside) {
        [self dismissFieldEditors];
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
        [self.window makeFirstResponder:self.folderTitleField];
        [self.folderTitleField selectText:nil];
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

    self.blurView.hidden = !blur;
    self.tintView.hidden = NO;

    if (blur) {
        self.window.backgroundColor = [NSColor clearColor];
        self.tintView.layer.backgroundColor =
            [[NSColor blackColor] colorWithAlphaComponent:opacity].CGColor;
        /* Only keep the expensive material live while overlay is showing. */
        self.blurView.state = self.visible ? NSVisualEffectStateActive
                                          : NSVisualEffectStateInactive;
    } else {
        self.window.backgroundColor =
            [[NSColor blackColor] colorWithAlphaComponent:opacity];
        self.tintView.layer.backgroundColor = [NSColor clearColor].CGColor;
        self.blurView.state = NSVisualEffectStateInactive;
    }
}

/** Drop fullscreen Overlay window + icon bitmaps so Idle returns near cold-start footprint.
 * Must not [NSWindow close] with releasedWhenClosed while AppKit animations/autoreleases
 * still hold the window — that caused EXC_BAD_ACCESS in objc_release on hide. */
- (void)destroyOverlayWindow {
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
        [content addSubview:self.folderTitleField positioned:NSWindowAbove relativeTo:self.searchField];
        gridTop = topPad + searchH + 12.0 + titleH + searchGap;
    } else if (self.folderTitleField) {
        [self.window endEditingFor:self.folderTitleField];
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
    [self removeStrayFieldEditors];
}

- (void)ensureWindow {
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
    /* Added to hierarchy only while editing a folder title (see layoutChrome). */

    self.pageIndicator = [[MLPageIndicator alloc] initWithFrame:NSMakeRect(0, 0, 200, 16)];
    self.pageIndicator.delegate = self;
    [content addSubview:self.pageIndicator];

    self.window = w;
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
    [self applyFilterWithQuery:@""];
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

- (void)removeStrayFieldEditors {
    if (!self.window) {
        return;
    }
    NSView *content = self.window.contentView;
    if (!content) {
        return;
    }
    id fr = self.window.firstResponder;
    for (NSView *sub in [content.subviews copy]) {
        if (![sub isKindOfClass:[NSTextView class]]) {
            continue;
        }
        NSTextView *tv = (NSTextView *)sub;
        /* Keep the live search editor; remove orphaned folder / stale editors. */
        if (fr == tv && (id)tv.delegate == self.searchField && self.visible) {
            [self styleFieldEditor:tv];
            continue;
        }
        [tv removeFromSuperview];
    }
}

- (void)dismissFieldEditors {
    if (!self.window) {
        return;
    }
    [self.window endEditingFor:nil];
    [self removeStrayFieldEditors];
    if (self.searchField) {
        self.searchField.alphaValue = 1.0;
    }
    if (self.folderTitleField) {
        self.folderTitleField.alphaValue = 1.0;
    }
}

- (void)styleFieldEditor:(NSText *)editor {
    if (![editor isKindOfClass:[NSTextView class]]) {
        return;
    }
    NSTextView *tv = (NSTextView *)editor;
    tv.drawsBackground = NO;
    tv.backgroundColor = [NSColor clearColor];
    tv.textContainerInset = NSZeroSize;
    if (tv.enclosingScrollView) {
        tv.enclosingScrollView.drawsBackground = NO;
        tv.enclosingScrollView.backgroundColor = [NSColor clearColor];
        tv.enclosingScrollView.borderType = NSNoBorder;
        tv.enclosingScrollView.hasVerticalScroller = NO;
        tv.enclosingScrollView.hasHorizontalScroller = NO;
    }
}

- (void)focusSearchField {
    if (!self.visible || !self.searchField) {
        return;
    }
    [self removeStrayFieldEditors];
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
        [self styleFieldEditor:editor];
        [editor setSelectedRange:NSMakeRange([[editor string] length], 0)];
    } else {
        [self.searchField selectText:nil];
    }
    NSLog(@"[MeoLaunch] search field focused (firstResponder=%@)",
          NSStringFromClass([self.window.firstResponder class]));
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
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
                       NSLog(@"[MeoLaunch] Overlay icon cache purged (30s idle)");
                   });
}

- (void)cancelDelayedIconPurge {
    self.iconPurgeGeneration += 1;
}

- (void)show {
    [self showWithFade:YES];
}

- (void)showImmediate {
    [self showWithFade:NO];
}

- (void)showWithFade:(BOOL)fade {
    /* Cancel stuck fade state from a previous interrupted hide/show */
    self.animating = NO;
    self.showGeneration += 1;
    [self cancelDelayedIconPurge];
    NSUInteger gen = self.showGeneration;

    [self ensureWindow];
    [self.gridView cancelActiveDrag];
    [self dismissFieldEditors];

    NSScreen *screen = [self preferredScreen];
    if (screen) {
        [self.window setFrame:screen.frame display:YES];
    }
    [self applyBackdropAppearance];
    [self layoutChrome];

    self.gridView.gridConfig = self.config.gridConfig;
    self.gridView.wheelThreshold = self.config.wheelThreshold > 0 ? self.config.wheelThreshold : 8.0;
    self.searchField.stringValue = @"";
    self.openFolderId = nil;
    self.focusFolderTitleOnEnter = NO;
    self.folderTitleField.hidden = YES;
    [self applyFilterWithQuery:@""];

    NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
    if (front && ![front.bundleIdentifier isEqualToString:[[NSBundle mainBundle] bundleIdentifier]]) {
        self.previousApp = front;
    }

    self.visible = YES;

    if ([self.delegate respondsToSelector:@selector(overlayControllerWillShow:)]) {
        [self.delegate overlayControllerWillShow:self];
    }

    /* Re-enable blur / chrome after hide released CA backing. */
    [self applyBackdropAppearance];
    [self layoutChrome];

    NSTimeInterval dur = fade ? [self fadeDuration] : 0;
    self.window.alphaValue = 1.0;
    [NSApp activateIgnoringOtherApps:YES];
    [self.window orderFrontRegardless];
    [self.window makeKeyAndOrderFront:nil];
    [self installEscapeMonitor];
    [self installOutsideClickMonitors];
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
    [self.searchDebounceTimer invalidate];
    self.searchDebounceTimer = nil;
    [self.gridView cancelActiveDrag];
    [self dismissFieldEditors];
    if (self.openFolderId.length > 0) {
        [self commitFolderTitleIfNeeded];
        self.openFolderId = nil;
        /* folderTitleField may already be gone on re-entrant hide */
        self.folderTitleField.hidden = YES;
    }

    /* Stop any in-flight window alpha animation before teardown. */
    NSWindow *w = self.window;
    if (w) {
        [w.animator setAlphaValue:w.alphaValue];
        w.alphaValue = 1.0;
        [w orderOut:nil];
        [w makeFirstResponder:nil];
    }

    self.visible = NO;
    self.animating = NO;

    NSRunningApplication *prev = self.previousApp;
    self.previousApp = nil;
    if (prev && !prev.isTerminated) {
        [prev activateWithOptions:(NSApplicationActivationOptions)0];
    }
    if ([self.delegate respondsToSelector:@selector(overlayControllerDidHide:)]) {
        [self.delegate overlayControllerDidHide:self];
    }

    /* Defer destroy one turn so AppKit animation/autorelease cleanup finishes first. */
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self.visible) {
            return;
        }
        [self destroyOverlayWindow];
        MLLogMemory(@"hide-destroyed");
        NSLog(@"[MeoLaunch] Overlay hidden (window destroyed, icons purged)");
    });
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
    NSText *editor = [control currentEditor];
    [self styleFieldEditor:editor];
}

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == self.folderTitleField) {
        return;
    }
    [self.searchDebounceTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.searchDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.06
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
    if (control == self.folderTitleField) {
        if (commandSelector == @selector(insertNewline:) ||
            commandSelector == @selector(insertNewlineIgnoringFieldEditor:)) {
            [self commitFolderTitleIfNeeded];
            [self.window makeFirstResponder:self.gridView];
            return YES;
        }
        if (commandSelector == @selector(cancelOperation:)) {
            [self exitFolderSavingTitle:YES];
            return YES;
        }
        if (MLIsStandardTextEditingCommand(commandSelector)) {
            [textView doCommandBySelector:commandSelector];
            return YES;
        }
        return NO;
    }
    if (MLIsStandardTextEditingCommand(commandSelector)) {
        [textView doCommandBySelector:commandSelector];
        return YES;
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
