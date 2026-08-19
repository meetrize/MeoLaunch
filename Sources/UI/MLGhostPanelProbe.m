#import "MLGhostPanelProbe.h"

#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <stdio.h>

static NSWindow *sOverlayWindow = nil;
static NSTextField *sSearchField = nil;
static BOOL sEnabled = YES;
static BOOL sDumping = NO;
static NSUInteger sBurstGeneration = 0;
static NSUInteger sInsertSeq = 0;
static NSTimeInterval sLastStrayLog = 0;
static NSString *sLastStrayReason = nil;
static NSUInteger sFieldEditorLogs = 0;
static FILE *sLogFile = NULL;
static os_log_t sOSLog;
static NSString *sLogPath = nil;

static void MLGhostLog(NSString *fmt, ...);
static NSString *MLGhostClassHistogram(NSArray<NSView *> *views);
static NSString *MLGhostStack(void);
static NSString *MLGhostDescribeView(NSView *view);
static NSString *MLGhostColor(NSColor *color);
static NSString *MLGhostLayerColor(CGColorRef cg);
static BOOL MLGhostIsSuspectView(NSView *view);
static BOOL MLGhostIsKnownChrome(NSView *view);
static NSRect MLGhostSearchWindowRect(void);
static NSRect MLGhostDangerWindowRect(void);
static NSRect MLGhostDangerScreenRect(void);
static BOOL MLGhostIntersectsDanger(NSView *view);
static void MLGhostDumpTree(NSView *view, NSUInteger depth, NSUInteger *count, NSUInteger maxCount);
static void MLGhostDumpLayers(CALayer *layer, NSUInteger depth, NSUInteger *count);
static void MLGhostDumpWindows(void);
static void MLGhostDumpCGWindows(void);

static void MLGhostLogv(NSString *fmt, va_list args) {
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    NSString *line = [NSString stringWithFormat:@"[MeoLaunch][GhostPanel] %@", body];
    /* Unified logging redacts %@ as <private> in Console.app — mark public + also write a file. */
    if (!sOSLog) {
        sOSLog = os_log_create("com.meetrice.meolaunch", "GhostPanel");
    }
    os_log(sOSLog, "%{public}s", line.UTF8String);
    if (!sLogFile && sLogPath) {
        sLogFile = fopen(sLogPath.fileSystemRepresentation, "a");
        if (sLogFile) {
            setvbuf(sLogFile, NULL, _IOLBF, 0);
        }
    }
    if (sLogFile) {
        static NSDateFormatter *df = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            df = [[NSDateFormatter alloc] init];
            df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        });
        fprintf(sLogFile, "%s %s\n",
                [df stringFromDate:[NSDate date]].UTF8String,
                line.UTF8String);
        fflush(sLogFile);
    }
}

static void MLGhostLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    MLGhostLogv(fmt, args);
    va_end(args);
}

#define GPLog(fmt, ...) MLGhostLog(@"" fmt, ##__VA_ARGS__)

static NSString *MLGhostClassHistogram(NSArray<NSView *> *views) {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSView *v in views) {
        NSString *n = NSStringFromClass(v.class) ?: @"?";
        counts[n] = @([counts[n] unsignedIntegerValue] + 1);
    }
    NSArray *keys = [counts.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in keys) {
        [parts addObject:[NSString stringWithFormat:@"%@:%@", k, counts[k]]];
    }
    return [parts componentsJoinedByString:@", "];
}

@implementation MLGhostPanelProbe

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *env = [[[NSProcessInfo processInfo] environment] objectForKey:@"MEOLAUNCH_GHOST_PROBE"];
        if ([env isEqualToString:@"0"] || [env.lowercaseString isEqualToString:@"off"]) {
            sEnabled = NO;
            NSLog(@"[MeoLaunch][GhostPanel] probe disabled (MEOLAUNCH_GHOST_PROBE=0)");
            return;
        }
        sEnabled = YES;
        NSString *logs = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:logs
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        sLogPath = [logs stringByAppendingPathComponent:@"MeoLaunch-ghostpanel.log"];
        /* Truncate on each launch so one reproduction is easy to send. */
        sLogFile = fopen(sLogPath.fileSystemRepresentation, "w");
        if (sLogFile) {
            setvbuf(sLogFile, NULL, _IOLBF, 0);
        }
        [self ml_swizzleAddSubview];
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self
               selector:@selector(ml_windowOnScreen:)
                   name:@"NSWindowDidOrderOnScreenNotification"
                 object:nil];
        [nc addObserver:self
               selector:@selector(ml_windowOcclusionChanged:)
                   name:NSWindowDidChangeOcclusionStateNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(ml_windowDidBecomeKey:)
                   name:NSWindowDidBecomeKeyNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(ml_popoverDidShow:)
                   name:NSPopoverDidShowNotification
                 object:nil];
        GPLog(@"probe installed — plaintext log: %@", sLogPath);
    });
}

+ (void)attachOverlayWindow:(NSWindow *)window searchField:(NSTextField *)searchField {
    [self install];
    if (!sEnabled) {
        return;
    }
    sOverlayWindow = window;
    sSearchField = searchField;
    sFieldEditorLogs = 0;
    GPLog(@"attached overlay=%p class=%@ search=%@",
          window, NSStringFromClass(window.class), NSStringFromRect(searchField.frame));
}

+ (void)detach {
    if (!sEnabled) {
        return;
    }
    sBurstGeneration += 1;
    GPLog(@"detached");
    sOverlayWindow = nil;
    sSearchField = nil;
}

+ (void)noteEvent:(NSString *)event {
    if (!sEnabled) {
        return;
    }
    NSResponder *fr = sOverlayWindow.firstResponder;
    NSText *editor = [sSearchField currentEditor];
    GPLog(@"event=%@ visible=%d key=%d firstResponder=%@ search=%@ editor=%@",
          event,
          sOverlayWindow.isVisible ? 1 : 0,
          sOverlayWindow.isKeyWindow ? 1 : 0,
          fr ? NSStringFromClass(fr.class) : @"(nil)",
          NSStringFromRect(sSearchField.frame),
          editor ? NSStringFromClass(editor.class) : @"(nil)");
}

+ (void)dumpSnapshot:(NSString *)reason {
    if (!sEnabled || sDumping || !sOverlayWindow) {
        return;
    }
    sDumping = YES;
    @try {
        NSWindow *w = sOverlayWindow;
        NSTextField *search = sSearchField;
        NSRect searchWin = MLGhostSearchWindowRect();
        NSRect dangerWin = MLGhostDangerWindowRect();
        NSRect dangerScreen = MLGhostDangerScreenRect();
        NSResponder *fr = w.firstResponder;
        NSText *editor = [search currentEditor];
        GPLog(@"---- SNAPSHOT reason=%@ ----", reason);
        GPLog(@"overlay class=%@ visible=%d key=%d alpha=%.2f frame=%@ level=%ld",
              NSStringFromClass(w.class),
              w.isVisible ? 1 : 0,
              w.isKeyWindow ? 1 : 0,
              w.alphaValue,
              NSStringFromRect(w.frame),
              (long)w.level);
        GPLog(@"search class=%@ frame=%@ winFrame=%@ hidden=%d alpha=%.2f wantsLayer=%d clips=%d subviews=%lu editor=%@",
              NSStringFromClass(search.class),
              NSStringFromRect(search.frame),
              NSStringFromRect(searchWin),
              search.hidden ? 1 : 0,
              search.alphaValue,
              search.wantsLayer ? 1 : 0,
              search.clipsToBounds ? 1 : 0,
              (unsigned long)search.subviews.count,
              editor ? NSStringFromClass(editor.class) : @"(nil)");
        GPLog(@"searchField.subviewClasses %@", MLGhostClassHistogram(search.subviews));
        GPLog(@"firstResponder=%@ dangerWin=%@ dangerScreen=%@",
              fr ? NSStringFromClass(fr.class) : @"(nil)",
              NSStringFromRect(dangerWin),
              NSStringFromRect(dangerScreen));

        if ([editor isKindOfClass:[NSTextView class]]) {
            NSTextView *tv = (NSTextView *)editor;
            NSView *host = tv.enclosingScrollView ?: (NSView *)tv;
            GPLog(@"editor drawsBG=%d bg=%@ fieldEditor=%d frame=%@ hostClass=%@ hostFrame=%@ hostWin=%@ inSearch=%d",
                  tv.drawsBackground ? 1 : 0,
                  MLGhostColor(tv.backgroundColor),
                  tv.isFieldEditor ? 1 : 0,
                  NSStringFromRect(tv.frame),
                  NSStringFromClass(host.class),
                  NSStringFromRect(host.frame),
                  NSStringFromRect([host convertRect:host.bounds toView:nil]),
                  NSContainsRect(NSInsetRect(searchWin, -12, -12),
                                 [host convertRect:host.bounds toView:nil]) ? 1 : 0);
        }

        NSView *content = w.contentView;
        GPLog(@"contentView class=%@ subviews(z-order, last=top)=%lu classes %@",
              NSStringFromClass(content.class),
              (unsigned long)content.subviews.count,
              MLGhostClassHistogram(content.subviews));
        NSUInteger idx = 0;
        for (NSView *sub in content.subviews) {
            BOOL danger = MLGhostIntersectsDanger(sub);
            BOOL suspect = MLGhostIsSuspectView(sub) && !MLGhostIsKnownChrome(sub);
            GPLog(@"  [%lu]%@%@ %@",
                  (unsigned long)idx,
                  suspect ? @" SUSPECT" : @"",
                  danger ? @" IN-DANGER-ZONE" : @"",
                  MLGhostDescribeView(sub));
            idx += 1;
        }

        GPLog(@"view tree (skip ml.grid internals):");
        NSUInteger count = 0;
        MLGhostDumpTree(content, 0, &count, 90);

        GPLog(@"danger-zone occupants:");
        NSUInteger found = 0;
        [self ml_collectDangerOccupants:content found:&found];
        if (found == 0) {
            GPLog(@"  (none besides known chrome)");
        }

        if (search) {
            GPLog(@"searchField.subviews:");
            if (search.subviews.count == 0) {
                GPLog(@"  (none)");
            }
            for (NSView *sub in search.subviews) {
                GPLog(@"  %@%@",
                      MLGhostIsSuspectView(sub) ? @"SUSPECT " : @"",
                      MLGhostDescribeView(sub));
                for (NSView *inner in sub.subviews) {
                    GPLog(@"    %@", MLGhostDescribeView(inner));
                }
            }
        }

        if (content.layer) {
            NSUInteger lc = 0;
            GPLog(@"contentView.layer tree:");
            MLGhostDumpLayers(content.layer, 0, &lc);
        }
        if (search.layer) {
            NSUInteger lc = 0;
            GPLog(@"searchField.layer tree:");
            MLGhostDumpLayers(search.layer, 0, &lc);
        }

        MLGhostDumpWindows();
        MLGhostDumpCGWindows();
        GPLog(@"---- END SNAPSHOT reason=%@ ----", reason);
    } @finally {
        sDumping = NO;
    }
}

+ (void)scheduleShowBurst {
    if (!sEnabled) {
        return;
    }
    sBurstGeneration += 1;
    NSUInteger gen = sBurstGeneration;
    static const double kDelays[] = { 0.0, 0.016, 0.033, 0.05, 0.1, 0.2, 0.4, 0.8 };
    for (size_t i = 0; i < sizeof(kDelays) / sizeof(kDelays[0]); i++) {
        double delay = kDelays[i];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           if (!sEnabled || sBurstGeneration != gen || !sOverlayWindow.isVisible) {
                               return;
                           }
                           [self dumpSnapshot:[NSString stringWithFormat:@"showBurst+%.0fms", delay * 1000.0]];
                       });
    }
}

+ (void)noteViewInserted:(NSView *)view parent:(NSView *)parent via:(NSString *)via {
    if (!sEnabled || sDumping || !view) {
        return;
    }
    if (!sOverlayWindow || !sOverlayWindow.isVisible) {
        return;
    }
    NSWindow *win = view.window ?: parent.window;
    if (win && win != sOverlayWindow && win.parentWindow != sOverlayWindow) {
        return;
    }
    if (!win) {
        BOOL inOverlay = NO;
        for (NSView *p = parent; p; p = p.superview) {
            if (p.window == sOverlayWindow || [p.identifier hasPrefix:@"ml."]) {
                inOverlay = YES;
                break;
            }
        }
        if (!inOverlay) {
            return;
        }
    }
    if (MLGhostIsKnownChrome(view)) {
        return;
    }
    if ([view isKindOfClass:NSClassFromString(@"NSTextInsertionIndicator")]) {
        return;
    }
    BOOL suspect = MLGhostIsSuspectView(view);
    BOOL danger = MLGhostIntersectsDanger(view);
    BOOL skipBenign = NO;
    if (!suspect && !danger) {
        for (NSView *a = parent; a; a = a.superview) {
            NSString *ident = a.identifier;
            if ([ident isEqualToString:@"ml.grid"] ||
                [ident isEqualToString:@"ml.page"] ||
                [ident isEqualToString:@"ml.animationHost"] ||
                [ident isEqualToString:@"ml.tint"] ||
                [ident isEqualToString:@"ml.dismiss"] ||
                [ident isEqualToString:@"ml.blur"]) {
                skipBenign = YES;
                break;
            }
        }
        if (skipBenign) {
            return;
        }
        /* Direct contentView children that are tiny / unknown still get logged. */
        if (parent != sOverlayWindow.contentView && !MLGhostIsSuspectView(parent)) {
            return;
        }
    }

    sInsertSeq += 1;
    GPLog(@"INSERT #%lu via=%@ suspect=%d danger=%d parent=%@\n  view %@\n  stack:\n  %@",
          (unsigned long)sInsertSeq,
          via ?: @"?",
          suspect ? 1 : 0,
          danger ? 1 : 0,
          parent ? NSStringFromClass(parent.class) : @"(nil)",
          MLGhostDescribeView(view),
          MLGhostStack());
}

+ (void)noteFieldEditorRequest:(BOOL)create object:(id)object editor:(NSText *)editor {
    if (!sEnabled) {
        return;
    }
    sFieldEditorLogs += 1;
    if (!create && sFieldEditorLogs > 8) {
        return;
    }
    GPLog(@"fieldEditor: create=%d object=%@(%p) -> %@(%p)\n  stack:\n  %@",
          create ? 1 : 0,
          object ? NSStringFromClass([object class]) : @"(nil)",
          object,
          editor ? NSStringFromClass(editor.class) : @"(nil)",
          editor,
          MLGhostStack());
}

+ (void)noteFirstResponder:(NSResponder *)responder result:(BOOL)ok previous:(NSResponder *)previous {
    if (!sEnabled) {
        return;
    }
    GPLog(@"makeFirstResponder prev=%@ next=%@ ok=%d stack:\n  %@",
          previous ? NSStringFromClass(previous.class) : @"(nil)",
          responder ? NSStringFromClass(responder.class) : @"(nil)",
          ok ? 1 : 0,
          MLGhostStack());
}

+ (void)noteStrayEditor:(NSTextView *)editor host:(NSView *)host reason:(NSString *)reason {
    if (!sEnabled || !editor) {
        return;
    }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (sLastStrayReason && [sLastStrayReason isEqualToString:reason] && (now - sLastStrayLog) < 0.4) {
        return;
    }
    sLastStrayLog = now;
    sLastStrayReason = [reason copy];
    NSRect eWin = [editor convertRect:editor.bounds toView:nil];
    NSRect hWin = host ? [host convertRect:host.bounds toView:nil] : NSZeroRect;
    GPLog(@"STRAY-EDITOR reason=%@ class=%@ winFrame=%@ host=%@ hostWin=%@ drawsBG=%d bg=%@\n  stack:\n  %@",
          reason,
          NSStringFromClass(editor.class),
          NSStringFromRect(eWin),
          host ? NSStringFromClass(host.class) : @"(nil)",
          NSStringFromRect(hWin),
          editor.drawsBackground ? 1 : 0,
          MLGhostColor(editor.backgroundColor),
          MLGhostStack());
}

+ (void)noteSearchFieldSubview:(NSView *)subview {
    if (!sEnabled || !subview) {
        return;
    }
    GPLog(@"searchField didAddSubview %@\n  stack:\n  %@",
          MLGhostDescribeView(subview),
          MLGhostStack());
}

#pragma mark - Notifications

+ (void)ml_windowOnScreen:(NSNotification *)note {
    [self ml_inspectForeignWindow:note.object reason:@"onScreen"];
}

+ (void)ml_windowOcclusionChanged:(NSNotification *)note {
    NSWindow *w = note.object;
    if (![w isKindOfClass:[NSWindow class]]) {
        return;
    }
    if ((w.occlusionState & NSWindowOcclusionStateVisible) == 0) {
        return;
    }
    [self ml_inspectForeignWindow:w reason:@"occlusionVisible"];
}

+ (void)ml_inspectForeignWindow:(id)obj reason:(NSString *)reason {
    if (!sEnabled || !sOverlayWindow.isVisible) {
        return;
    }
    NSWindow *w = obj;
    if (![w isKindOfClass:[NSWindow class]] || w == sOverlayWindow) {
        return;
    }
    NSRect danger = MLGhostDangerScreenRect();
    BOOL overlap = NSIntersectsRect(w.frame, danger);
    BOOL child = (w.parentWindow == sOverlayWindow);
    BOOL small = (NSWidth(w.frame) < 900.0 && NSHeight(w.frame) < 420.0 &&
                  NSWidth(w.frame) > 8.0 && NSHeight(w.frame) > 8.0);
    if (!(child || (overlap && small))) {
        return;
    }
    GPLog(@"WINDOW-%@ class=%@ frame=%@ level=%ld parent=%@ childOfOverlay=%d overlapDanger=%d title=%@ style=%lu content=%@\n  stack:\n  %@",
          reason,
          NSStringFromClass(w.class),
          NSStringFromRect(w.frame),
          (long)w.level,
          w.parentWindow ? NSStringFromClass(w.parentWindow.class) : @"(nil)",
          child ? 1 : 0,
          overlap ? 1 : 0,
          w.title ?: @"",
          (unsigned long)w.styleMask,
          NSStringFromClass(w.contentView.class),
          MLGhostStack());
    NSUInteger count = 0;
    MLGhostDumpTree(w.contentView, 0, &count, 40);
    [self dumpSnapshot:[NSString stringWithFormat:@"window-%@", reason]];
}

+ (void)ml_windowDidBecomeKey:(NSNotification *)note {
    if (!sEnabled || !sOverlayWindow.isVisible) {
        return;
    }
    NSWindow *w = note.object;
    if (w != sOverlayWindow) {
        return;
    }
    GPLog(@"overlay became key firstResponder=%@",
          sOverlayWindow.firstResponder
              ? NSStringFromClass(sOverlayWindow.firstResponder.class)
              : @"(nil)");
}

+ (void)ml_popoverDidShow:(NSNotification *)note {
    if (!sEnabled || !sOverlayWindow.isVisible) {
        return;
    }
    NSPopover *pop = note.object;
    if (![pop isKindOfClass:[NSPopover class]]) {
        return;
    }
    GPLog(@"POPOVER-SHOW class=%@ positioningRect=%@ contentSize=%@ appearance=%@",
          NSStringFromClass(pop.class),
          NSStringFromRect(pop.positioningRect),
          NSStringFromSize(pop.contentSize),
          pop.appearance.name);
    [self dumpSnapshot:@"popover"];
}

#pragma mark - Swizzle

+ (void)ml_swizzleAddSubview {
    Class cls = [NSView class];
    [self ml_exchange:cls orig:@selector(addSubview:) alt:@selector(ml_gp_addSubview:)];
    [self ml_exchange:cls
                 orig:@selector(addSubview:positioned:relativeTo:)
                  alt:@selector(ml_gp_addSubview:positioned:relativeTo:)];
}

+ (void)ml_exchange:(Class)cls orig:(SEL)orig alt:(SEL)alt {
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, alt);
    if (m1 && m2) {
        method_exchangeImplementations(m1, m2);
    }
}

+ (void)ml_collectDangerOccupants:(NSView *)view found:(NSUInteger *)found {
    if (!view) {
        return;
    }
    if (!MLGhostIsKnownChrome(view) && MLGhostIntersectsDanger(view)) {
        BOOL skip = [view.identifier isEqualToString:@"ml.grid"] ||
                    [view.identifier isEqualToString:@"ml.blur"] ||
                    [view.identifier isEqualToString:@"ml.tint"] ||
                    [view.identifier isEqualToString:@"ml.dismiss"] ||
                    [view.identifier isEqualToString:@"ml.animationHost"];
        if (!skip) {
            *found += 1;
            GPLog(@"  OCCUPANT%@ %@",
                  MLGhostIsSuspectView(view) ? @" SUSPECT" : @"",
                  MLGhostDescribeView(view));
        }
    }
    if ([view.identifier isEqualToString:@"ml.grid"]) {
        return;
    }
    for (NSView *sub in view.subviews) {
        [self ml_collectDangerOccupants:sub found:found];
    }
}

@end

#pragma mark - NSView hook

@implementation NSView (MLGhostPanelProbe)

- (void)ml_gp_addSubview:(NSView *)view {
    [self ml_gp_addSubview:view];
    [MLGhostPanelProbe noteViewInserted:view parent:self via:@"addSubview:"];
}

- (void)ml_gp_addSubview:(NSView *)view positioned:(NSWindowOrderingMode)place relativeTo:(NSView *)other {
    [self ml_gp_addSubview:view positioned:place relativeTo:other];
    [MLGhostPanelProbe noteViewInserted:view parent:self via:@"addSubview:positioned:"];
}

@end

#pragma mark - Helpers

static NSString *MLGhostStack(void) {
    NSArray<NSString *> *syms = [NSThread callStackSymbols];
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSUInteger n = 0;
    for (NSString *s in syms) {
        if ([s containsString:@"MLGhostPanelProbe"] ||
            [s containsString:@"ml_gp_addSubview"] ||
            [s containsString:@"callStackSymbols"] ||
            [s containsString:@"MLGhostStack"]) {
            continue;
        }
        [kept addObject:s];
        if (++n >= 16) {
            break;
        }
    }
    return kept.count ? [kept componentsJoinedByString:@"\n  "] : @"(empty)";
}

static NSString *MLGhostColor(NSColor *color) {
    if (!color) {
        return @"(nil)";
    }
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb) {
        rgb = [color colorUsingColorSpace:NSColorSpace.genericRGBColorSpace];
    }
    if (!rgb) {
        return color.description;
    }
    return [NSString stringWithFormat:@"rgba(%.2f,%.2f,%.2f,%.2f)",
            rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent];
}

static NSString *MLGhostLayerColor(CGColorRef cg) {
    if (!cg) {
        return @"(nil)";
    }
    return MLGhostColor([NSColor colorWithCGColor:cg]);
}

static BOOL MLGhostIsSuspectView(NSView *view) {
    if (!view) {
        return NO;
    }
    if ([view isKindOfClass:[NSVisualEffectView class]] ||
        [view isKindOfClass:[NSBox class]] ||
        [view isKindOfClass:[NSTextView class]] ||
        [view isKindOfClass:[NSScrollView class]] ||
        [view isKindOfClass:[NSClipView class]]) {
        return YES;
    }
    NSString *n = NSStringFromClass(view.class);
    static NSString *const kKeys[] = {
        @"VisualEffect", @"Bezel", @"FocusRing", @"Completion", @"Candidate",
        @"Prediction", @"WritingTool", @"Popover", @"Backdrop", @"Rounded",
        @"Material", @"Background", @"Chrome", @"HUD", @"Vibrant",
        @"Suggestion", @"Autofill", @"Panel", @"Capsule"
    };
    for (size_t i = 0; i < sizeof(kKeys) / sizeof(kKeys[0]); i++) {
        if ([n rangeOfString:kKeys[i] options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    if (view.wantsLayer && view.layer && view.layer.cornerRadius >= 6.0) {
        CGColorRef bg = view.layer.backgroundColor;
        if (bg && CGColorGetAlpha(bg) > 0.02) {
            return YES;
        }
    }
    return NO;
}

static BOOL MLGhostIsKnownChrome(NSView *view) {
    NSString *ident = view.identifier;
    return [ident hasPrefix:@"ml."];
}

static NSRect MLGhostSearchWindowRect(void) {
    if (!sSearchField) {
        return NSZeroRect;
    }
    return [sSearchField convertRect:sSearchField.bounds toView:nil];
}

static NSRect MLGhostDangerWindowRect(void) {
    NSRect s = MLGhostSearchWindowRect();
    if (NSIsEmptyRect(s)) {
        return NSZeroRect;
    }
    /* Window coords: origin bottom-left. On-screen "below search" = smaller Y. */
    return NSMakeRect(NSMinX(s) - 80.0,
                      NSMinY(s) - 280.0,
                      NSWidth(s) + 160.0,
                      280.0 + 12.0);
}

static NSRect MLGhostDangerScreenRect(void) {
    if (!sOverlayWindow) {
        return NSZeroRect;
    }
    return [sOverlayWindow convertRectToScreen:MLGhostDangerWindowRect()];
}

static BOOL MLGhostIntersectsDanger(NSView *view) {
    if (!view || !view.window) {
        return NO;
    }
    NSRect danger = MLGhostDangerWindowRect();
    if (NSIsEmptyRect(danger)) {
        return NO;
    }
    NSRect wr = [view convertRect:view.bounds toView:nil];
    return NSIntersectsRect(wr, danger);
}

static NSString *MLGhostDescribeView(NSView *view) {
    if (!view) {
        return @"(nil)";
    }
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@(0x%lx) ident=%@ frame=%@",
     NSStringFromClass(view.class),
     (unsigned long)view,
     view.identifier ?: @"",
     NSStringFromRect(view.frame)];
    if (view.window) {
        [s appendFormat:@" win=%@", NSStringFromRect([view convertRect:view.bounds toView:nil])];
    }
    [s appendFormat:@" hidden=%d alpha=%.2f opaque=%d wantsLayer=%d clips=%d",
     view.hidden ? 1 : 0,
     view.alphaValue,
     view.isOpaque ? 1 : 0,
     view.wantsLayer ? 1 : 0,
     view.clipsToBounds ? 1 : 0];
    if (view.wantsLayer && view.layer) {
        [s appendFormat:@" corner=%.1f layerBG=%@ masksToBounds=%d",
         view.layer.cornerRadius,
         MLGhostLayerColor(view.layer.backgroundColor),
         view.layer.masksToBounds ? 1 : 0];
    }
    if ([view isKindOfClass:[NSVisualEffectView class]]) {
        NSVisualEffectView *ve = (NSVisualEffectView *)view;
        [s appendFormat:@" material=%ld blend=%ld state=%ld",
         (long)ve.material, (long)ve.blendingMode, (long)ve.state];
    }
    if ([view isKindOfClass:[NSBox class]]) {
        NSBox *box = (NSBox *)view;
        [s appendFormat:@" boxType=%ld fill=%@ transparent=%d",
         (long)box.boxType, MLGhostColor(box.fillColor), box.transparent ? 1 : 0];
        if ([box respondsToSelector:@selector(cornerRadius)]) {
            [s appendFormat:@" boxCorner=%.1f", box.cornerRadius];
        }
    }
    if ([view isKindOfClass:[NSTextView class]]) {
        NSTextView *tv = (NSTextView *)view;
        [s appendFormat:@" fieldEditor=%d drawsBG=%d bg=%@",
         tv.isFieldEditor ? 1 : 0,
         tv.drawsBackground ? 1 : 0,
         MLGhostColor(tv.backgroundColor)];
    }
    if ([view isKindOfClass:[NSScrollView class]]) {
        NSScrollView *sv = (NSScrollView *)view;
        [s appendFormat:@" drawsBG=%d bg=%@ doc=%@",
         sv.drawsBackground ? 1 : 0,
         MLGhostColor(sv.backgroundColor),
         sv.documentView ? NSStringFromClass(sv.documentView.class) : @"(nil)"];
    }
    NSMutableString *chain = [NSMutableString string];
    NSUInteger hops = 0;
    for (NSView *v = view.superview; v && hops < 6; v = v.superview, hops++) {
        if (chain.length) {
            [chain appendString:@" ← "];
        }
        [chain appendFormat:@"%@%@", NSStringFromClass(v.class),
         v.identifier.length ? [NSString stringWithFormat:@"(%@)", v.identifier] : @""];
    }
    if (chain.length) {
        [s appendFormat:@" chain=%@", chain];
    }
    return s;
}

static void MLGhostDumpTree(NSView *view, NSUInteger depth, NSUInteger *count, NSUInteger maxCount) {
    if (!view || *count >= maxCount) {
        return;
    }
    *count += 1;
    NSMutableString *pad = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) {
        [pad appendString:@"  "];
    }
    BOOL flag = MLGhostIsSuspectView(view) && !MLGhostIsKnownChrome(view);
    BOOL danger = MLGhostIntersectsDanger(view) && !MLGhostIsKnownChrome(view);
    GPLog(@"%@%@%@%@", pad, flag ? @"SUSPECT " : @"", danger ? @"DANGER " : @"", MLGhostDescribeView(view));
    if ([view.identifier isEqualToString:@"ml.grid"] ||
        [view.identifier isEqualToString:@"ml.animationHost"]) {
        return;
    }
    for (NSView *sub in view.subviews) {
        MLGhostDumpTree(sub, depth + 1, count, maxCount);
    }
}

static void MLGhostDumpLayers(CALayer *layer, NSUInteger depth, NSUInteger *count) {
    if (!layer || *count >= 40) {
        return;
    }
    *count += 1;
    NSMutableString *pad = [NSMutableString string];
    for (NSUInteger i = 0; i < depth; i++) {
        [pad appendString:@"  "];
    }
    BOOL round = layer.cornerRadius >= 6.0;
    GPLog(@"%@%@layer class=%@ name=%@ bounds=%@ pos=%@ corner=%.1f bg=%@ opaque=%d hidden=%d",
          pad,
          round ? @"ROUND " : @"",
          NSStringFromClass(layer.class),
          layer.name ?: @"",
          NSStringFromRect(NSRectFromCGRect(layer.bounds)),
          NSStringFromPoint(NSPointFromCGPoint(layer.position)),
          layer.cornerRadius,
          MLGhostLayerColor(layer.backgroundColor),
          layer.opaque ? 1 : 0,
          layer.hidden ? 1 : 0);
    for (CALayer *sub in layer.sublayers) {
        MLGhostDumpLayers(sub, depth + 1, count);
    }
}

static void MLGhostDumpWindows(void) {
    GPLog(@"NSApp.windows (%lu):", (unsigned long)[NSApp windows].count);
    NSRect danger = MLGhostDangerScreenRect();
    for (NSWindow *w in [NSApp windows]) {
        BOOL overlap = NSIntersectsRect(w.frame, danger);
        BOOL ours = (w == sOverlayWindow || w.parentWindow == sOverlayWindow);
        if (!w.isVisible && !ours) {
            continue;
        }
        GPLog(@"  %@ class=%@ visible=%d key=%d level=%ld frame=%@ parent=%@ title=%@ content=%@ overlapDanger=%d",
              ours ? @"OURS" : @"app",
              NSStringFromClass(w.class),
              w.isVisible ? 1 : 0,
              w.isKeyWindow ? 1 : 0,
              (long)w.level,
              NSStringFromRect(w.frame),
              w.parentWindow ? NSStringFromClass(w.parentWindow.class) : @"",
              w.title ?: @"",
              NSStringFromClass(w.contentView.class),
              overlap ? 1 : 0);
        if ((overlap || w.parentWindow == sOverlayWindow) && w != sOverlayWindow) {
            NSUInteger c = 0;
            MLGhostDumpTree(w.contentView, 2, &c, 24);
        }
    }
}

static void MLGhostDumpCGWindows(void) {
    if (!sOverlayWindow) {
        return;
    }
    CFArrayRef info = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                 kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    if (!info) {
        return;
    }
    pid_t pid = [NSProcessInfo processInfo].processIdentifier;
    NSRect danger = MLGhostDangerScreenRect();
    GPLog(@"CGWindowList near search (pid=%d):", (int)pid);
    NSUInteger shown = 0;
    for (NSDictionary *d in (__bridge NSArray *)info) {
        pid_t owner = [d[(id)kCGWindowOwnerPID] intValue];
        NSDictionary *b = d[(id)kCGWindowBounds];
        CGFloat x = [b[@"X"] doubleValue];
        CGFloat y = [b[@"Y"] doubleValue];
        CGFloat w = [b[@"Width"] doubleValue];
        CGFloat h = [b[@"Height"] doubleValue];
        /* CGWindow bounds are in screen coords with origin top-left on some
         * dumps; kCGWindowBounds is actually Cocoa-like global rect. */
        /* kCGWindowBounds is Quartz (origin top-left of main display). */
        NSRect cgRect = NSMakeRect(x, y, w, h);
        NSRect main = [NSScreen mainScreen].frame;
        NSRect wr = NSMakeRect(cgRect.origin.x,
                               NSMaxY(main) - cgRect.origin.y - cgRect.size.height,
                               cgRect.size.width,
                               cgRect.size.height);
        BOOL small = (h < 420.0 && w < 900.0 && w > 8.0 && h > 8.0);
        BOOL overlap = NSIntersectsRect(wr, NSInsetRect(danger, -20, -20));
        BOOL ours = (owner == pid);
        if (!overlap || !small) {
            continue;
        }
        /* Skip the fullscreen overlay itself. */
        if (ours && w >= sOverlayWindow.frame.size.width - 4 &&
            h >= sOverlayWindow.frame.size.height - 4) {
            continue;
        }
        shown += 1;
        GPLog(@"  CG win#%d owner=%@ pid=%d layer=%@ alpha=%@ bounds=%@ name=%@",
              [d[(id)kCGWindowNumber] intValue],
              d[(id)kCGWindowOwnerName] ?: @"",
              (int)owner,
              d[(id)kCGWindowLayer],
              d[(id)kCGWindowAlpha],
              NSStringFromRect(wr),
              d[(id)kCGWindowName] ?: @"");
        if (shown >= 12) {
            break;
        }
    }
    if (shown == 0) {
        GPLog(@"  (no small on-screen windows in danger zone)");
    }
    CFRelease(info);
}
