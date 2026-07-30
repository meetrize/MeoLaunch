#import "AppDelegate.h"

#import "MLConfigStore.h"
#import "MLHotCornerMonitor.h"
#import "MLHotKeyManager.h"
#import "MLLayoutStore.h"
#import "MLOverlayController.h"
#import "MLPrefsWindow.h"

#include "ml_app_index.h"
#include "ml_layout.h"

#include <stdlib.h>
#include <string.h>

static NSString *const kMLDidPromptAccessibilityKey = @"MLDidPromptAccessibilityGuide";

@interface AppDelegate () <MLHotCornerMonitorDelegate, MLHotKeyManagerDelegate, MLOverlayControllerDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) MLOverlayController *overlay;
@property (nonatomic, strong) MLHotCornerMonitor *hotCorner;
@property (nonatomic, strong) MLHotKeyManager *hotKey;
@property (nonatomic, strong) MLConfigStore *config;
@property (nonatomic, strong) MLLayoutStore *layoutStore;
@property (nonatomic, strong) MLPrefsWindow *prefs;
@property (nonatomic, assign) MLAppIndex appIndex;
@property (nonatomic, strong) NSTimer *rescanDebounceTimer;
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

    memset(&_appIndex, 0, sizeof(_appIndex));
    [self rescanApps];

    [self setupStatusItem];
    [self setupHotCornerWithAccessibility];

    NSLog(@"[MeoLaunch] ready — layout + configurable scan roots");
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

    [self.overlay reloadWithAppIndex:&_appIndex];
    NSLog(@"[MeoLaunch] config applied live (%dx%d)",
          self.config.gridConfig.cols, self.config.gridConfig.rows);
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
    alert.messageText = @"需要「辅助功能」权限";
    alert.informativeText =
        @"MeoLaunch 用触发角唤起应用列表。请在「系统设置 → 隐私与安全性 → 辅助功能」中允许 MeoLaunch。\n\n"
        @"未授权时仍可通过菜单栏或 ⌥Space 打开。";
    [alert addButtonWithTitle:@"打开系统设置"];
    [alert addButtonWithTitle:@"稍后"];
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

    const char **croots = (const char **)calloc(roots.count, sizeof(char *));
    if (!croots) {
        NSLog(@"[MeoLaunch] app scan OOM");
        return;
    }
    for (NSUInteger i = 0; i < roots.count; i++) {
        croots[i] = roots[i].UTF8String;
    }
    int rc = ml_app_index_scan(&_appIndex, croots, roots.count);
    free(croots);
    if (rc != 0) {
        NSLog(@"[MeoLaunch] app scan failed (%d)", rc);
        return;
    }
    NSLog(@"[MeoLaunch] scanned %zu apps from %zu roots", _appIndex.count, (size_t)roots.count);
    int layoutChanges = [self.layoutStore syncWithAppIndex:&_appIndex];
    NSLog(@"[MeoLaunch] layout sync changes=%d root=%zu",
          layoutChanges,
          self.layoutStore.layout ? self.layoutStore.layout->count : 0);
    [self.overlay reloadWithAppIndex:&_appIndex];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.rescanDebounceTimer invalidate];
    self.rescanDebounceTimer = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.hotKey unregisterAll];
    [self.hotCorner stop];
    ml_app_index_clear(&_appIndex);
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    if (button) {
        button.title = @"ML";
        button.toolTip = @"MeoLaunch (⌥Space)";
    }

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"MeoLaunch"];
    [menu addItemWithTitle:@"Show Overlay" action:@selector(showOverlay:) keyEquivalent:@"s"];
    [menu addItemWithTitle:@"Retry Hot Corner Permission" action:@selector(retryHotCorner:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Preferences…" action:@selector(showPrefs:) keyEquivalent:@","];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Quit MeoLaunch" action:@selector(quit:) keyEquivalent:@"q"];
    self.statusItem.menu = menu;
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

- (void)quit:(id)sender {
    (void)sender;
    [NSApp terminate:nil];
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
    [self showOverlay:nil];
}

#pragma mark - MLHotKeyManagerDelegate

- (void)hotKeyManagerDidFire:(MLHotKeyManager *)manager {
    (void)manager;
    NSLog(@"[MeoLaunch] ⌥Space toggle");
    [self toggleOverlay];
}

@end
