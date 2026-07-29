#import "MLConfigStore.h"

NSNotificationName const MLConfigStoreDidChangeNotification = @"MLConfigStoreDidChangeNotification";

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
@property (nonatomic, strong) NSTimer *saveTimer;
@end

@implementation MLConfigStore

+ (NSURL *)configFileURL {
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                    inDomains:NSUserDomainMask];
    NSURL *base = urls.firstObject;
    return [base URLByAppendingPathComponent:@"meoLaunch/config.json"];
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
            /* Migrate tiny legacy default that missed top-edge pixels */
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
        /* Migrate legacy insensitive default (8) to high sensitivity */
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
    }
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *mods = [NSMutableArray array];
    if (self.hotkeyCommand) [mods addObject:@"command"];
    if (self.hotkeyOption) [mods addObject:@"option"];
    if (self.hotkeyControl) [mods addObject:@"control"];
    if (self.hotkeyShift) [mods addObject:@"shift"];

    MLGridConfig g = self.gridConfig;
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
            @"roots" : @[ @"/Applications", @"/System/Applications", @"~/Applications" ],
            @"include_hidden" : @NO,
            @"refresh_seconds" : @60,
        },
        @"ui" : @{
            @"blur" : @(self.overlayBlur),
            @"fade_ms" : @(self.fadeMs),
            @"overlay_opacity" : @(self.overlayOpacity),
            @"menubar_icon" : @YES,
            @"lsuielement" : @YES,
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
    NSLog(@"[MeoLaunch] config loaded %@ (%dx%d)", url.path, self.gridConfig.cols, self.gridConfig.rows);
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
    /* Quantize to percent so slider noise doesn't spam reloads */
    opacity = round(opacity * 100.0) / 100.0;
    if (fabs(self.overlayOpacity - opacity) < 0.0001) {
        return;
    }
    self.overlayOpacity = opacity;
    [self notifyChanged];
    [self scheduleSave];
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
