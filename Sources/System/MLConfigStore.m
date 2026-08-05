#import "MLConfigStore.h"

NSNotificationName const MLConfigStoreDidChangeNotification = @"MLConfigStoreDidChangeNotification";
NSNotificationName const MLConfigStoreScanRootsDidChangeNotification =
    @"MLConfigStoreScanRootsDidChangeNotification";

@interface MLConfigStore ()
@property (nonatomic, assign, readwrite) MLGridConfig gridConfig;
@property (nonatomic, assign, readwrite) BOOL showLabels;
@property (nonatomic, assign, readwrite) BOOL hotCornerEnabled;
@property (nonatomic, assign, readwrite) MLHotCornerPosition hotCornerPosition;
@property (nonatomic, assign, readwrite) CGFloat hotCornerSizePt;
@property (nonatomic, assign, readwrite) NSInteger hotCornerDelayMs;
@property (nonatomic, assign, readwrite) BOOL hotkeyEnabled;
@property (nonatomic, assign, readwrite) NSInteger hotkeyKeyCode;
@property (nonatomic, assign, readwrite) BOOL hotkeyOption;
@property (nonatomic, assign, readwrite) BOOL hotkeyCommand;
@property (nonatomic, assign, readwrite) BOOL hotkeyControl;
@property (nonatomic, assign, readwrite) BOOL hotkeyShift;
@property (nonatomic, assign, readwrite) CGFloat wheelThreshold;
@property (nonatomic, assign, readwrite) NSInteger fadeMs;
@property (nonatomic, assign, readwrite) CGFloat overlayOpacity;
@property (nonatomic, assign, readwrite) BOOL overlayBlur;
@property (nonatomic, assign, readwrite) MLOverlayScreenMode overlayScreenMode;
@property (nonatomic, assign, readwrite) uint32_t overlayScreenID;
@property (nonatomic, assign, readwrite) MLLanguage language;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *scanRoots;
@property (nonatomic, assign, readwrite) NSInteger scanRefreshSeconds;
@property (nonatomic, assign, readwrite) BOOL taskbarEnabled;
@property (nonatomic, assign, readwrite) NSTimeInterval taskbarWindowPollSeconds;
@property (nonatomic, assign, readwrite) NSUInteger overlayIconCacheMax;
@property (nonatomic, assign, readwrite) BOOL memoryFreeEnabled;
@property (nonatomic, assign, readwrite) NSTimeInterval memoryFreeIntervalSeconds;
@property (nonatomic, strong) NSTimer *saveTimer;
@end

@implementation MLConfigStore

+ (NSURL *)configFileURL {
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                    inDomains:NSUserDomainMask];
    NSURL *base = urls.firstObject;
    return [base URLByAppendingPathComponent:@"meoLaunch/config.json"];
}

+ (NSArray<NSString *> *)builtInScanRoots {
    return @[ @"~/Applications", @"/Applications", @"/System/Applications" ];
}

+ (NSString *)normalizeRootPath:(NSString *)path {
    if (![path isKindOfClass:[NSString class]]) {
        return nil;
    }
    NSString *trimmed = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return nil;
    }
    if ([trimmed hasPrefix:@"~"]) {
        return trimmed;
    }
    return [trimmed stringByStandardizingPath];
}

+ (NSString *)expansionKeyForRoot:(NSString *)path {
    NSString *n = [self normalizeRootPath:path];
    if (!n) {
        return nil;
    }
    return [[n stringByExpandingTildeInPath] stringByStandardizingPath];
}

+ (NSArray<NSString *> *)mergedScanRootsWithExtras:(NSArray<NSString *> *)extras {
    NSArray<NSString *> *builtIn = [self builtInScanRoots];
    NSMutableArray<NSString *> *out = [NSMutableArray arrayWithArray:builtIn];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *b in builtIn) {
        NSString *key = [self expansionKeyForRoot:b];
        if (key) {
            [seen addObject:key];
        }
    }
    if (![extras isKindOfClass:[NSArray class]]) {
        return [out copy];
    }
    for (id item in extras) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *n = [self normalizeRootPath:(NSString *)item];
        NSString *key = [self expansionKeyForRoot:n];
        if (!n || !key || [seen containsObject:key]) {
            continue;
        }
        BOOL isBuiltIn = NO;
        for (NSString *b in builtIn) {
            if ([n isEqualToString:b] || [key isEqualToString:[self expansionKeyForRoot:b]]) {
                isBuiltIn = YES;
                break;
            }
        }
        if (isBuiltIn) {
            continue;
        }
        [seen addObject:key];
        [out addObject:n];
    }
    return [out copy];
}

+ (NSString *)stringForCorner:(MLHotCornerPosition)p {
    switch (p) {
        case MLHotCornerPositionTopLeft: return @"top_left";
        case MLHotCornerPositionTopRight: return @"top_right";
        case MLHotCornerPositionBottomLeft: return @"bottom_left";
        case MLHotCornerPositionBottomRight: return @"bottom_right";
        default: return @"off";
    }
}

+ (MLHotCornerPosition)cornerFromString:(NSString *)s {
    if ([s isEqualToString:@"top_left"]) return MLHotCornerPositionTopLeft;
    if ([s isEqualToString:@"top_right"]) return MLHotCornerPositionTopRight;
    if ([s isEqualToString:@"bottom_left"]) return MLHotCornerPositionBottomLeft;
    if ([s isEqualToString:@"bottom_right"]) return MLHotCornerPositionBottomRight;
    return MLHotCornerPositionOff;
}

+ (NSString *)stringForOverlayScreenMode:(MLOverlayScreenMode)mode {
    switch (mode) {
        case MLOverlayScreenModeMain: return @"main";
        case MLOverlayScreenModeFixed: return @"fixed";
        default: return @"mouse";
    }
}

+ (MLOverlayScreenMode)overlayScreenModeFromString:(NSString *)s {
    if ([s isEqualToString:@"main"]) return MLOverlayScreenModeMain;
    if ([s isEqualToString:@"fixed"]) return MLOverlayScreenModeFixed;
    return MLOverlayScreenModeMouse;
}

+ (NSScreen *)screenUnderMouse {
    NSPoint p = [NSEvent mouseLocation];
    for (NSScreen *s in [NSScreen screens]) {
        if (NSPointInRect(p, s.frame)) {
            return s;
        }
    }
    return [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
}

+ (uint32_t)screenIDForScreen:(NSScreen *)screen {
    if (!screen) {
        return 0;
    }
    id num = screen.deviceDescription[@"NSScreenNumber"];
    if ([num isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)num unsignedIntValue];
    }
    return (uint32_t)screen.hash;
}

+ (NSScreen *)screenWithID:(uint32_t)screenID {
    if (screenID == 0) {
        return nil;
    }
    for (NSScreen *s in [NSScreen screens]) {
        if ([[self class] screenIDForScreen:s] == screenID) {
            return s;
        }
    }
    return nil;
}

- (void)loadDefaults {
    MLGridConfig g;
    g.cols = 7;
    g.rows = 5;
    g.padding = 48.f;
    g.spacing = 28.f;
    g.icon_size = 0.f;
    self.gridConfig = g;
    self.showLabels = YES;

    self.hotCornerEnabled = YES;
    self.hotCornerPosition = MLHotCornerPositionTopLeft;
    self.hotCornerSizePt = 12.0;
    self.hotCornerDelayMs = 0;

    self.hotkeyEnabled = YES;
    self.hotkeyKeyCode = 49;
    self.hotkeyOption = YES;
    self.hotkeyCommand = NO;
    self.hotkeyControl = NO;
    self.hotkeyShift = NO;

    self.wheelThreshold = 0.15;
    self.fadeMs = 100;
    self.overlayOpacity = 0.55;
    self.overlayBlur = YES;
    self.overlayScreenMode = MLOverlayScreenModeMouse;
    self.overlayScreenID = 0;
    self.language = [MLStrings systemPreferredLanguage];
    [MLStrings setLanguage:self.language];
    self.scanRoots = [[self class] builtInScanRoots];
    self.scanRefreshSeconds = 60;
    self.taskbarEnabled = YES;
    self.taskbarWindowPollSeconds = 1.0;
    self.overlayIconCacheMax = 128;
    self.memoryFreeEnabled = NO;
    self.memoryFreeIntervalSeconds = 2.0;
}

- (void)applyScanDictionary:(NSDictionary *)scan {
    if (![scan isKindOfClass:[NSDictionary class]]) {
        return;
    }
    if (scan[@"refresh_seconds"]) {
        NSInteger sec = [scan[@"refresh_seconds"] integerValue];
        if (sec < 0) {
            sec = 0;
        }
        if (sec > 3600) {
            sec = 3600;
        }
        self.scanRefreshSeconds = sec;
    }
    NSArray *roots = scan[@"roots"];
    if ([roots isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSString *> *extras = [NSMutableArray array];
        NSArray<NSString *> *builtIn = [[self class] builtInScanRoots];
        NSMutableSet<NSString *> *builtKeys = [NSMutableSet set];
        for (NSString *b in builtIn) {
            NSString *k = [[self class] expansionKeyForRoot:b];
            if (k) {
                [builtKeys addObject:k];
            }
        }
        for (id item in roots) {
            if (![item isKindOfClass:[NSString class]]) {
                continue;
            }
            NSString *n = [[self class] normalizeRootPath:(NSString *)item];
            NSString *key = [[self class] expansionKeyForRoot:n];
            if (!n || !key) {
                continue;
            }
            if ([builtKeys containsObject:key]) {
                continue;
            }
            [extras addObject:n];
        }
        self.scanRoots = [[self class] mergedScanRootsWithExtras:extras];
    }
}

- (void)applyDictionary:(NSDictionary *)root {
    if (![root isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary *grid = root[@"grid"];
    if ([grid isKindOfClass:[NSDictionary class]]) {
        MLGridConfig g = self.gridConfig;
        if (grid[@"cols"]) g.cols = [grid[@"cols"] intValue];
        if (grid[@"rows"]) g.rows = [grid[@"rows"] intValue];
        if (grid[@"padding"]) g.padding = [grid[@"padding"] floatValue];
        if (grid[@"spacing"]) g.spacing = [grid[@"spacing"] floatValue];
        if (grid[@"icon_size"]) g.icon_size = [grid[@"icon_size"] floatValue];
        if (g.cols < 4) g.cols = 4;
        if (g.cols > 10) g.cols = 10;
        if (g.rows < 3) g.rows = 3;
        if (g.rows > 8) g.rows = 8;
        self.gridConfig = g;
        if (grid[@"show_labels"]) self.showLabels = [grid[@"show_labels"] boolValue];
    }

    NSDictionary *hc = root[@"hot_corner"];
    if ([hc isKindOfClass:[NSDictionary class]]) {
        if (hc[@"enabled"]) self.hotCornerEnabled = [hc[@"enabled"] boolValue];
        if (hc[@"corner"]) self.hotCornerPosition = [[self class] cornerFromString:hc[@"corner"]];
        if (hc[@"size_pt"]) {
            CGFloat sz = [hc[@"size_pt"] doubleValue];
            if (sz > 0 && sz < 8.0) {
                sz = 12.0;
            }
            self.hotCornerSizePt = sz;
        }
        if (hc[@"delay_ms"]) self.hotCornerDelayMs = [hc[@"delay_ms"] integerValue];
    }

    NSDictionary *hk = root[@"hotkey"];
    if ([hk isKindOfClass:[NSDictionary class]]) {
        if (hk[@"enabled"]) self.hotkeyEnabled = [hk[@"enabled"] boolValue];
        if (hk[@"key_code"]) self.hotkeyKeyCode = [hk[@"key_code"] integerValue];
        NSArray *mods = hk[@"modifiers"];
        if ([mods isKindOfClass:[NSArray class]]) {
            self.hotkeyOption = [mods containsObject:@"option"];
            self.hotkeyCommand = [mods containsObject:@"command"];
            self.hotkeyControl = [mods containsObject:@"control"];
            self.hotkeyShift = [mods containsObject:@"shift"];
        }
    }

    NSDictionary *paging = root[@"paging"];
    if ([paging isKindOfClass:[NSDictionary class]] && paging[@"wheel_threshold"]) {
        CGFloat thr = [paging[@"wheel_threshold"] doubleValue];
        if (thr >= 4.0) {
            thr = 0.15;
        }
        self.wheelThreshold = thr;
    }

    NSDictionary *ui = root[@"ui"];
    if ([ui isKindOfClass:[NSDictionary class]]) {
        if (ui[@"fade_ms"]) {
            self.fadeMs = [ui[@"fade_ms"] integerValue];
            if (self.fadeMs < 0) {
                self.fadeMs = 0;
            }
            if (self.fadeMs > 500) {
                self.fadeMs = 500;
            }
        }
        if (ui[@"overlay_opacity"]) {
            CGFloat op = [ui[@"overlay_opacity"] doubleValue];
            if (op < 0.0) op = 0.0;
            if (op > 1.0) op = 1.0;
            self.overlayOpacity = op;
        }
        if (ui[@"blur"]) {
            self.overlayBlur = [ui[@"blur"] boolValue];
        }
        if (ui[@"language"]) {
            self.language = [MLStrings languageFromCode:[ui[@"language"] description]];
            [MLStrings setLanguage:self.language];
        }
        if (ui[@"overlay_icon_cache_max"]) {
            NSInteger n = [ui[@"overlay_icon_cache_max"] integerValue];
            if (n < 32) n = 32;
            if (n > 256) n = 256;
            self.overlayIconCacheMax = (NSUInteger)n;
        }
        if (ui[@"overlay_screen_mode"]) {
            self.overlayScreenMode =
                [[self class] overlayScreenModeFromString:[ui[@"overlay_screen_mode"] description]];
        }
        if (ui[@"overlay_screen_id"]) {
            self.overlayScreenID = (uint32_t)[ui[@"overlay_screen_id"] unsignedIntValue];
        }
        if (self.overlayScreenMode == MLOverlayScreenModeFixed && self.overlayScreenID == 0) {
            self.overlayScreenMode = MLOverlayScreenModeMouse;
        }
    }

    NSDictionary *tb = root[@"taskbar"];
    if ([tb isKindOfClass:[NSDictionary class]]) {
        if (tb[@"enabled"]) {
            self.taskbarEnabled = [tb[@"enabled"] boolValue];
        }
        if (tb[@"window_poll_seconds"]) {
            NSTimeInterval s = [tb[@"window_poll_seconds"] doubleValue];
            if (s < 0.5) s = 0.5;
            if (s > 5.0) s = 5.0;
            self.taskbarWindowPollSeconds = s;
        }
    }

    NSDictionary *mb = root[@"menubar"];
    if ([mb isKindOfClass:[NSDictionary class]]) {
        NSDictionary *mf = mb[@"memory_free"];
        if ([mf isKindOfClass:[NSDictionary class]]) {
            if (mf[@"enabled"]) {
                self.memoryFreeEnabled = [mf[@"enabled"] boolValue];
            }
            if (mf[@"interval_seconds"]) {
                NSTimeInterval s = [mf[@"interval_seconds"] doubleValue];
                if (s < 1.0) s = 1.0;
                if (s > 5.0) s = 5.0;
                self.memoryFreeIntervalSeconds = s;
            }
        }
    }

    [self applyScanDictionary:root[@"scan"]];
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *mods = [NSMutableArray array];
    if (self.hotkeyCommand) [mods addObject:@"command"];
    if (self.hotkeyOption) [mods addObject:@"option"];
    if (self.hotkeyControl) [mods addObject:@"control"];
    if (self.hotkeyShift) [mods addObject:@"shift"];

    MLGridConfig g = self.gridConfig;
    NSArray *roots = self.scanRoots.count ? self.scanRoots : [[self class] builtInScanRoots];
    return @{
        @"version" : @1,
        @"grid" : @{
            @"cols" : @(g.cols),
            @"rows" : @(g.rows),
            @"padding" : @(g.padding),
            @"spacing" : @(g.spacing),
            @"icon_size" : @(g.icon_size),
            @"show_labels" : @(self.showLabels),
        },
        @"hot_corner" : @{
            @"enabled" : @(self.hotCornerEnabled),
            @"corner" : [[self class] stringForCorner:self.hotCornerPosition],
            @"size_pt" : @(self.hotCornerSizePt),
            @"delay_ms" : @(self.hotCornerDelayMs),
            @"action" : @"show",
        },
        @"hotkey" : @{
            @"enabled" : @(self.hotkeyEnabled),
            @"key_code" : @(self.hotkeyKeyCode),
            @"modifiers" : mods,
        },
        @"search" : @{
            @"autofocus" : @YES,
            @"pinyin" : @NO,
        },
        @"paging" : @{
            @"wheel_threshold" : @(self.wheelThreshold),
            @"animate" : @YES,
        },
        @"scan" : @{
            @"roots" : roots,
            @"include_hidden" : @NO,
            @"refresh_seconds" : @(self.scanRefreshSeconds > 0 ? self.scanRefreshSeconds : 60),
        },
        @"ui" : @{
            @"blur" : @(self.overlayBlur),
            @"fade_ms" : @(self.fadeMs),
            @"overlay_opacity" : @(self.overlayOpacity),
            @"language" : [MLStrings codeForLanguage:self.language],
            @"overlay_icon_cache_max" : @(self.overlayIconCacheMax > 0 ? self.overlayIconCacheMax : 128),
            @"overlay_screen_mode" : [[self class] stringForOverlayScreenMode:self.overlayScreenMode],
            @"overlay_screen_id" : @(self.overlayScreenID),
            @"menubar_icon" : @YES,
            @"lsuielement" : @YES,
        },
        @"taskbar" : @{
            @"enabled" : @(self.taskbarEnabled),
            @"window_poll_seconds" : @(self.taskbarWindowPollSeconds > 0 ? self.taskbarWindowPollSeconds : 1.0),
        },
        @"menubar" : @{
            @"memory_free" : @{
                @"enabled" : @(self.memoryFreeEnabled),
                @"interval_seconds" :
                    @(self.memoryFreeIntervalSeconds > 0 ? self.memoryFreeIntervalSeconds : 2.0),
            },
        },
        @"launch_at_login" : @NO,
    };
}

- (BOOL)loadFromDisk {
    [self loadDefaults];

    NSURL *url = [[self class] configFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:url.path]) {
        [self saveToDisk];
        return NO;
    }

    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&err];
    if (!data) {
        NSLog(@"[MeoLaunch] config read failed: %@", err);
        return NO;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[MeoLaunch] config corrupt, backing up: %@", err);
        NSURL *bak = [url URLByAppendingPathExtension:@"bak"];
        [fm removeItemAtURL:bak error:nil];
        [fm moveItemAtURL:url toURL:bak error:nil];
        [self loadDefaults];
        [self saveToDisk];
        return NO;
    }

    [self applyDictionary:(NSDictionary *)json];
    NSLog(@"[MeoLaunch] config loaded %@ (%dx%d) scanRoots=%zu",
          url.path, self.gridConfig.cols, self.gridConfig.rows, (size_t)self.scanRoots.count);
    return YES;
}

- (BOOL)saveToDisk {
    NSURL *url = [[self class] configFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtURL:[url URLByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&err]) {
        NSLog(@"[MeoLaunch] config dir failed: %@", err);
        return NO;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:[self dictionaryRepresentation]
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data) {
        NSLog(@"[MeoLaunch] config encode failed: %@", err);
        return NO;
    }
    if (![data writeToURL:url options:NSDataWritingAtomic error:&err]) {
        NSLog(@"[MeoLaunch] config write failed: %@", err);
        return NO;
    }
    NSLog(@"[MeoLaunch] config saved %@", url.path);
    return YES;
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:MLConfigStoreDidChangeNotification
                                                        object:self];
}

- (void)notifyScanRootsChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:MLConfigStoreScanRootsDidChangeNotification
                                                        object:self];
}

- (NSArray<NSString *> *)scanExtraRoots {
    NSArray<NSString *> *builtIn = [[self class] builtInScanRoots];
    NSMutableSet<NSString *> *builtKeys = [NSMutableSet set];
    for (NSString *b in builtIn) {
        NSString *k = [[self class] expansionKeyForRoot:b];
        if (k) {
            [builtKeys addObject:k];
        }
    }
    NSMutableArray<NSString *> *extras = [NSMutableArray array];
    for (NSString *r in self.scanRoots) {
        NSString *key = [[self class] expansionKeyForRoot:r];
        if (!key || [builtKeys containsObject:key]) {
            continue;
        }
        [extras addObject:r];
    }
    return [extras copy];
}

- (void)setScanExtraRoots:(NSArray<NSString *> *)extras {
    NSArray<NSString *> *merged = [[self class] mergedScanRootsWithExtras:extras];
    if ([merged isEqualToArray:self.scanRoots ?: @[]]) {
        return;
    }
    self.scanRoots = merged;
    [self notifyChanged];
    [self notifyScanRootsChanged];
    [self scheduleSave];
}

- (BOOL)addScanExtraRoot:(NSString *)path {
    NSString *n = [[self class] normalizeRootPath:path];
    if (!n) {
        return NO;
    }
    NSArray<NSString *> *current = [self scanExtraRoots];
    NSString *key = [[self class] expansionKeyForRoot:n];
    for (NSString *e in current) {
        if ([key isEqualToString:[[self class] expansionKeyForRoot:e]]) {
            return NO;
        }
    }
    NSMutableArray<NSString *> *next = [current mutableCopy] ?: [NSMutableArray array];
    [next addObject:n];
    [self setScanExtraRoots:next];
    return YES;
}

- (void)removeScanExtraRootAtIndex:(NSInteger)index {
    NSArray<NSString *> *current = [self scanExtraRoots];
    if (index < 0 || index >= (NSInteger)current.count) {
        return;
    }
    NSMutableArray<NSString *> *next = [current mutableCopy];
    [next removeObjectAtIndex:(NSUInteger)index];
    [self setScanExtraRoots:next];
}

- (NSArray<NSString *> *)expandedScanRoots {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    NSArray<NSString *> *roots = self.scanRoots.count ? self.scanRoots : [[self class] builtInScanRoots];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *r in roots) {
        NSString *exp = [[r stringByExpandingTildeInPath] stringByStandardizingPath];
        if (exp.length == 0 || [seen containsObject:exp]) {
            continue;
        }
        [seen addObject:exp];
        [out addObject:exp];
    }
    return [out copy];
}

- (void)requestAppRescan {
    [self notifyScanRootsChanged];
}

- (void)updateGridCols:(int)cols rows:(int)rows {
    if (cols < 4) cols = 4;
    if (cols > 10) cols = 10;
    if (rows < 3) rows = 3;
    if (rows > 8) rows = 8;
    MLGridConfig g = self.gridConfig;
    if (g.cols == cols && g.rows == rows) {
        return;
    }
    g.cols = cols;
    g.rows = rows;
    self.gridConfig = g;
    [self notifyChanged];
    [self scheduleSave];
}

- (void)updateGridIconSize:(float)iconSize {
    if (iconSize < 0.f) {
        iconSize = 0.f;
    }
    if (iconSize > 0.f && iconSize < 48.f) {
        iconSize = 48.f;
    }
    if (iconSize > 160.f) {
        iconSize = 160.f;
    }
    MLGridConfig g = self.gridConfig;
    if (g.icon_size == iconSize) {
        return;
    }
    g.icon_size = iconSize;
    self.gridConfig = g;
    [self notifyChanged];
    [self scheduleSave];
}

- (void)updateOverlayOpacity:(CGFloat)opacity {
    if (opacity < 0.0) opacity = 0.0;
    if (opacity > 1.0) opacity = 1.0;
    opacity = round(opacity * 100.0) / 100.0;
    if (fabs(self.overlayOpacity - opacity) < 0.0001) {
        return;
    }
    self.overlayOpacity = opacity;
    [self notifyChanged];
    [self scheduleSave];
}

- (void)updateOverlayScreenMode:(MLOverlayScreenMode)mode screenID:(uint32_t)screenID {
    if (mode != MLOverlayScreenModeFixed) {
        screenID = 0;
    } else if (screenID == 0) {
        mode = MLOverlayScreenModeMouse;
    }
    if (self.overlayScreenMode == mode && self.overlayScreenID == screenID) {
        return;
    }
    self.overlayScreenMode = mode;
    self.overlayScreenID = screenID;
    [self notifyChanged];
    [self scheduleSave];
}

- (NSScreen *)resolvedOverlayScreen {
    switch (self.overlayScreenMode) {
        case MLOverlayScreenModeMain:
            return [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
        case MLOverlayScreenModeFixed: {
            NSScreen *fixed = [[self class] screenWithID:self.overlayScreenID];
            if (fixed) {
                return fixed;
            }
            return [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
        }
        case MLOverlayScreenModeMouse:
        default:
            return [[self class] screenUnderMouse];
    }
}

- (void)updateHotCornerEnabled:(BOOL)enabled
                      position:(MLHotCornerPosition)position
                        sizePt:(CGFloat)sizePt
                       delayMs:(NSInteger)delayMs {
    CGFloat size = sizePt >= 8.0 ? sizePt : 12.0;
    NSInteger delay = delayMs >= 0 ? delayMs : 0;
    if (self.hotCornerEnabled == enabled &&
        self.hotCornerPosition == position &&
        self.hotCornerSizePt == size &&
        self.hotCornerDelayMs == delay) {
        return;
    }
    self.hotCornerEnabled = enabled;
    self.hotCornerPosition = position;
    self.hotCornerSizePt = size;
    self.hotCornerDelayMs = delay;
    [self notifyChanged];
    [self scheduleSave];
}

- (void)updateLanguage:(MLLanguage)language {
    if (self.language == language) {
        return;
    }
    self.language = language;
    [MLStrings setLanguage:language];
    [self notifyChanged];
    [self scheduleSave];
}

- (void)updateTaskbarEnabled:(BOOL)enabled {
    if (self.taskbarEnabled == enabled) {
        return;
    }
    self.taskbarEnabled = enabled;
    [self notifyChanged];
    [self scheduleSave];
}

- (void)updateTaskbarWindowPollSeconds:(NSTimeInterval)seconds {
    if (seconds < 0.5) seconds = 0.5;
    if (seconds > 5.0) seconds = 5.0;
    if (fabs(self.taskbarWindowPollSeconds - seconds) < 0.01) {
        return;
    }
    self.taskbarWindowPollSeconds = seconds;
    [self notifyChanged];
    [self scheduleSave];
}

- (void)updateOverlayIconCacheMax:(NSUInteger)maxEntries {
    if (maxEntries < 32) maxEntries = 32;
    if (maxEntries > 256) maxEntries = 256;
    if (self.overlayIconCacheMax == maxEntries) {
        return;
    }
    self.overlayIconCacheMax = maxEntries;
    [self notifyChanged];
    [self scheduleSave];
}

- (void)updateMemoryFreeEnabled:(BOOL)enabled {
    if (self.memoryFreeEnabled == enabled) {
        return;
    }
    self.memoryFreeEnabled = enabled;
    [self notifyChanged];
    [self scheduleSave];
}

- (void)updateMemoryFreeIntervalSeconds:(NSTimeInterval)seconds {
    if (seconds < 1.0) seconds = 1.0;
    if (seconds > 5.0) seconds = 5.0;
    if (fabs(self.memoryFreeIntervalSeconds - seconds) < 0.01) {
        return;
    }
    self.memoryFreeIntervalSeconds = seconds;
    [self notifyChanged];
    [self scheduleSave];
}

- (void)scheduleSave {
    [self.saveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.3
                                                     repeats:NO
                                                       block:^(__unused NSTimer *timer) {
                                                           [weakSelf saveToDisk];
                                                       }];
}

@end
