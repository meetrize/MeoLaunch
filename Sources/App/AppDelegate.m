#import "AppDelegate.h"

#import "MLConfigStore.h"
#import "MLHotCornerMonitor.h"
#import "MLHotKeyManager.h"
#import "MLLayoutStore.h"
#import "MLMemoryStatusController.h"
#import "MLOverlayController.h"
#import "MLPrefsWindow.h"
#import "MLRunningAppsMonitor.h"
#import "MLStrings.h"
#import "MLTaskbarController.h"
#import "MLTaskbarIconCache.h"
#import "MLTaskbarPinStore.h"
#import "MLTaskbarView.h"

#include "ml_app_index.h"
#include "ml_layout.h"

#include <stdlib.h>
#include <string.h>

static NSString *const kMLDidPromptAccessibilityKey = @"MLDidPromptAccessibilityGuide";

@interface AppDelegate () <MLHotCornerMonitorDelegate, MLHotKeyManagerDelegate, MLOverlayControllerDelegate, MLTaskbarAppActions>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSMenuItem *showOverlayItem;
@property (nonatomic, strong) NSMenuItem *retryHotCornerItem;
@property (nonatomic, strong) NSMenuItem *prefsItem;
@property (nonatomic, strong) NSMenuItem *quitItem;
@property (nonatomic, strong) MLOverlayController *overlay;
@property (nonatomic, strong) MLHotCornerMonitor *hotCorner;
@property (nonatomic, strong) MLHotKeyManager *hotKey;
@property (nonatomic, strong) MLConfigStore *config;
@property (nonatomic, strong) MLLayoutStore *layoutStore;
@property (nonatomic, strong) MLPrefsWindow *prefs;
@property (nonatomic, strong) MLTaskbarPinStore *taskbarPins;
@property (nonatomic, strong) MLRunningAppsMonitor *runningApps;
@property (nonatomic, strong) MLTaskbarIconCache *taskbarIcons;
@property (nonatomic, strong) MLTaskbarController *taskbar;
@property (nonatomic, strong) MLMemoryStatusController *memoryStatus;
@property (nonatomic, assign) MLAppIndex appIndex;
@property (nonatomic, strong) NSTimer *rescanDebounceTimer;
/** Drop stale background scans when a newer rescan started. */
@property (nonatomic, assign) NSUInteger appScanGeneration;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    self.config = [[MLConfigStore alloc] init];
    [self.config loadFromDisk];

    self.layoutStore = [[MLLayoutStore alloc] init];
    [self.layoutStore loadFromDisk];

    self.overlay = [[MLOverlayController alloc] initWithConfigStore:self.config
                                                        layoutStore:self.layoutStore];
    self.overlay.delegate = self;
    self.hotCorner = [[MLHotCornerMonitor alloc] init];
    self.hotCorner.delegate = self;
    [self.hotCorner applyConfig:self.config];

    self.hotKey = [[MLHotKeyManager alloc] init];
    self.hotKey.delegate = self;
    [self.hotKey applyConfig:self.config];
    [self.hotKey registerDefaultHotKey];

    self.prefs = [[MLPrefsWindow alloc] initWithConfigStore:self.config];

    self.taskbarPins = [[MLTaskbarPinStore alloc] init];
    [self.taskbarPins loadFromDisk];
    self.runningApps = [[MLRunningAppsMonitor alloc] init];
    self.taskbarIcons = [[MLTaskbarIconCache alloc] init];
    self.taskbar = [[MLTaskbarController alloc] initWithPinStore:self.taskbarPins
                                                         monitor:self.runningApps
                                                       iconCache:self.taskbarIcons];
    self.taskbar.appActions = self;
    self.taskbar.enabled = self.config.taskbarEnabled;
    [self.overlay setIconCacheMaxEntries:self.config.overlayIconCacheMax];
    [self.runningApps applyWindowPollInterval:self.config.taskbarWindowPollSeconds];
    self.memoryStatus = [[MLMemoryStatusController alloc] init];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(configDidChange:)
                                                 name:MLConfigStoreDidChangeNotification
                                               object:self.config];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(scanRootsDidChange:)
                                                 name:MLConfigStoreScanRootsDidChangeNotification
                                               object:self.config];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(layoutDidChange:)
                                                 name:MLLayoutStoreDidChangeNotification
                                               object:self.layoutStore];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(languageDidChange:)
                                                 name:MLLanguageDidChangeNotification
                                               object:nil];

    memset(&_appIndex, 0, sizeof(_appIndex));
    [self rescanApps];

    [self setupStatusItem];
    [self setupHotCornerWithAccessibility];
    if (self.config.taskbarEnabled) {
        [self.taskbar start];
    }
    [self applyMemoryStatusFromConfig];

    NSLog(@"[MeoLaunch] ready — layout + configurable scan roots + taskbar");
}

- (void)layoutDidChange:(NSNotification *)note {
    (void)note;
    [self.overlay reloadWithAppIndex:&_appIndex];
}

- (void)configDidChange:(NSNotification *)note {
    (void)note;
    [self.hotCorner applyConfig:self.config];
    if (self.config.hotCornerEnabled &&
        self.config.hotCornerPosition != MLHotCornerPositionOff &&
        [MLHotCornerMonitor isAccessibilityTrustedPrompting:NO]) {
        [self.hotCorner start];
    } else {
        [self.hotCorner stop];
    }

    [self.hotKey applyConfig:self.config];
    [self.hotKey registerDefaultHotKey];

    [self.overlay setIconCacheMaxEntries:self.config.overlayIconCacheMax];
    [self.runningApps applyWindowPollInterval:self.config.taskbarWindowPollSeconds];
    if (self.config.taskbarEnabled) {
        self.taskbar.enabled = YES;
        [self.taskbar start];
    } else {
        [self.taskbar stop];
        self.taskbar.enabled = NO;
    }
    [self applyMemoryStatusFromConfig];

    [self.overlay reloadWithAppIndex:&_appIndex];
    NSLog(@"[MeoLaunch] config applied live (%dx%d) taskbar=%d poll=%.2f icons=%lu mem%%=%d",
          self.config.gridConfig.cols, self.config.gridConfig.rows,
          (int)self.config.taskbarEnabled,
          self.config.taskbarWindowPollSeconds,
          (unsigned long)self.config.overlayIconCacheMax,
          (int)self.config.memoryFreeEnabled);
}

- (void)applyMemoryStatusFromConfig {
    if (!self.memoryStatus) {
        self.memoryStatus = [[MLMemoryStatusController alloc] init];
    }
    if (self.config.memoryFreeEnabled) {
        [self.memoryStatus startWithInterval:self.config.memoryFreeIntervalSeconds];
    } else {
        [self.memoryStatus stop];
    }
}

- (void)setupHotCornerWithAccessibility {
    BOOL trusted = [MLHotCornerMonitor isAccessibilityTrustedPrompting:YES];
    if (trusted && self.config.hotCornerEnabled) {
        [self.hotCorner start];
        return;
    }

    [self.hotCorner stop];
    if (!trusted) {
        [self showAccessibilityGuideIfNeeded];
    }
}

- (void)showAccessibilityGuideIfNeeded {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud boolForKey:kMLDidPromptAccessibilityKey]) {
        return;
    }
    [ud setBool:YES forKey:kMLDidPromptAccessibilityKey];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [MLStrings t:@"a11y.title"];
    alert.informativeText = [MLStrings t:@"a11y.body"];
    [alert addButtonWithTitle:[MLStrings t:@"a11y.open_settings"]];
    [alert addButtonWithTitle:[MLStrings t:@"a11y.later"]];
    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertFirstButtonReturn) {
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
        if (@available(macOS 13.0, *)) {
            NSURL *ventura = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension?Privacy_Accessibility"];
            if (![[NSWorkspace sharedWorkspace] openURL:ventura]) {
                [[NSWorkspace sharedWorkspace] openURL:url];
            }
        } else {
            [[NSWorkspace sharedWorkspace] openURL:url];
        }
    }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    if (self.config.hotCornerEnabled &&
        [MLHotCornerMonitor isAccessibilityTrustedPrompting:NO]) {
        if (!self.hotCorner.isRunning) {
            [self.hotCorner applyConfig:self.config];
            [self.hotCorner start];
        }
    }
}

- (void)scanRootsDidChange:(NSNotification *)note {
    (void)note;
    [self.rescanDebounceTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.rescanDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                               repeats:NO
                                                                 block:^(__unused NSTimer *timer) {
                                                                     [weakSelf rescanApps];
                                                                 }];
}

- (void)rescanApps {
    NSArray<NSString *> *roots = [self.config expandedScanRoots];
    if (roots.count == 0) {
        roots = @[
            [@"~/Applications" stringByExpandingTildeInPath],
            @"/Applications",
            @"/System/Applications",
        ];
    }

    NSArray<NSString *> *rootsCopy = [roots copy];
    NSUInteger gen = ++self.appScanGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        MLAppIndex scanned = {0};
        const char **croots = (const char **)calloc(rootsCopy.count, sizeof(char *));
        if (!croots) {
            NSLog(@"[MeoLaunch] app scan OOM");
            return;
        }
        for (NSUInteger i = 0; i < rootsCopy.count; i++) {
            croots[i] = rootsCopy[i].UTF8String;
        }
        int rc = ml_app_index_scan(&scanned, croots, rootsCopy.count);
        free(croots);
        if (rc != 0) {
            NSLog(@"[MeoLaunch] app scan failed (%d)", rc);
            ml_app_index_clear(&scanned);
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            MLAppIndex result = scanned;
            if (!self || gen != self.appScanGeneration) {
                ml_app_index_clear(&result);
                return;
            }
            ml_app_index_clear(&self->_appIndex);
            self->_appIndex = result;
            NSLog(@"[MeoLaunch] scanned %zu apps from %zu roots",
                  self->_appIndex.count, (size_t)rootsCopy.count);
            int layoutChanges = [self.layoutStore syncWithAppIndex:&self->_appIndex];
            NSLog(@"[MeoLaunch] layout sync changes=%d root=%zu",
                  layoutChanges,
                  self.layoutStore.layout ? self.layoutStore.layout->count : 0);
            [self.overlay reloadWithAppIndex:&self->_appIndex];
        });
    });
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.rescanDebounceTimer invalidate];
    self.rescanDebounceTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.memoryStatus stop];
    [self.taskbar stop];
    [self.hotKey unregisterAll];
    [self.hotCorner stop];
    ml_app_index_clear(&_appIndex);
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    if (button) {
        NSImage *icon = [NSImage imageNamed:@"MenuBarIcon"];
        if (!icon) {
            NSString *path = [[NSBundle mainBundle] pathForResource:@"MenuBarIcon" ofType:@"png"];
            if (path) {
                icon = [[NSImage alloc] initWithContentsOfFile:path];
            }
        }
        if (icon) {
            icon.size = NSMakeSize(18, 18);
            icon.template = YES;
            button.image = icon;
            button.imagePosition = NSImageOnly;
        } else {
            button.title = @"ML";
        }
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"MeoLaunch"];
    self.showOverlayItem = [[NSMenuItem alloc] initWithTitle:@""
                                                      action:@selector(showOverlay:)
                                               keyEquivalent:@"s"];
    self.retryHotCornerItem = [[NSMenuItem alloc] initWithTitle:@""
                                                         action:@selector(retryHotCorner:)
                                                  keyEquivalent:@""];
    self.prefsItem = [[NSMenuItem alloc] initWithTitle:@""
                                                action:@selector(showPrefs:)
                                         keyEquivalent:@","];
    self.quitItem = [[NSMenuItem alloc] initWithTitle:@""
                                               action:@selector(quit:)
                                        keyEquivalent:@"q"];
    [menu addItem:self.showOverlayItem];
    [menu addItem:self.retryHotCornerItem];
    [menu addItem:self.prefsItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:self.quitItem];
    self.statusItem.menu = menu;
    [self refreshStatusMenuTitles];
}

- (void)refreshStatusMenuTitles {
    self.showOverlayItem.title = [MLStrings t:@"menu.show_overlay"];
    self.retryHotCornerItem.title = [MLStrings t:@"menu.retry_hot_corner"];
    self.prefsItem.title = [MLStrings t:@"menu.preferences"];
    self.quitItem.title = [MLStrings t:@"menu.quit"];
    if (self.statusItem.button) {
        self.statusItem.button.toolTip = [MLStrings t:@"menu.tooltip"];
    }
}

- (void)languageDidChange:(NSNotification *)note {
    (void)note;
    [self refreshStatusMenuTitles];
    /* Refresh free-memory tooltip language if visible. */
    if (self.config.memoryFreeEnabled) {
        [self.memoryStatus startWithInterval:self.config.memoryFreeIntervalSeconds];
    }
}

- (void)showOverlay:(id)sender {
    (void)sender;
    /* Defer until status-item menu finishes dismissing — otherwise the
       borderless overlay can fail to become key/visible. */
    const MLAppIndex *index = &_appIndex;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            return;
        }
        [self.overlay reloadWithAppIndex:index];
        [self.overlay show];
    });
}

- (void)toggleOverlay {
    if ([self.overlay isVisible]) {
        [self.overlay hide];
        return;
    }
    [self showOverlay:nil];
}

- (void)retryHotCorner:(id)sender {
    (void)sender;
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kMLDidPromptAccessibilityKey];
    [self setupHotCornerWithAccessibility];
}

- (void)showPrefs:(id)sender {
    (void)sender;
    [self.prefs show];
}

- (void)overlayControllerDidRequestPreferences:(MLOverlayController *)controller {
    (void)controller;
    [self showPrefs:nil];
}

- (void)overlayControllerWillShow:(MLOverlayController *)controller {
    (void)controller;
    [self.taskbar overlayWillShow];
}

- (void)overlayControllerDidHide:(MLOverlayController *)controller {
    (void)controller;
    [self.taskbar overlayDidHide];
}

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
}

- (void)taskbarShowAbout {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *name = bundle.infoDictionary[@"CFBundleName"] ?: @"MeoLaunch";
    NSString *shortV = bundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"—";
    NSString *build = bundle.infoDictionary[@"CFBundleVersion"] ?: @"—";
    NSString *body = [NSString stringWithFormat:[MLStrings t:@"taskbar.about.body"], shortV, build];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = name;
    alert.informativeText = body;
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    NSImage *icon = [NSApp applicationIconImage];
    if (icon) {
        alert.icon = icon;
    }
    [alert runModal];
}

- (void)taskbarShowPreferences {
    [self showPrefs:nil];
}

- (void)taskbarQuitApp {
    [self quit:nil];
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
    (void)app;
    return NO;
}

#pragma mark - MLHotCornerMonitorDelegate

- (void)hotCornerMonitorDidTrigger:(MLHotCornerMonitor *)monitor {
    (void)monitor;
    if ([self.overlay isVisible]) {
        return;
    }
    [self.overlay reloadWithAppIndex:&_appIndex];
    [self.overlay showImmediate];
}

#pragma mark - MLHotKeyManagerDelegate

- (void)hotKeyManagerDidFire:(MLHotKeyManager *)manager {
    (void)manager;
    NSLog(@"[MeoLaunch] ⌥Space toggle");
    [self toggleOverlay];
}

@end
