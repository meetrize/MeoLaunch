#import "MLTaskbarController+Private.h"

#import "MLAppLauncher.h"
#import "MLAXWindowHelper.h"
#import "MLCGSAlpha.h"
#import "MLDebugLog.h"
#import "MLRunningAppsMonitor.h"
#import "MLScreenGeometry.h"
#import "MLTaskbarPinStore.h"
#import "MLTaskbarView.h"
#import "MLWindowSoftState.h"

#import <ApplicationServices/ApplicationServices.h>

@implementation MLTaskbarController (WindowActions)

- (void)refreshAfterCustomMinimize {
    [self.monitor pollNow];
    if (!self.itemsFrozenForDesktopReveal) {
        [self rebuildItemsImmediate:YES];
    }
}
- (void)softStateDidChange:(NSNotification *)note {
    (void)note;
    [self.monitor pollNow];
    if (self.itemsFrozenForDesktopReveal) {
        if ([self shouldUnfreezeDesktopReveal]) {
            [self unfreezeDesktopRevealAndRefresh];
        } else {
            [self restoreFrozenItemsOntoBars];
        }
        return;
    }
    [self rebuildItemsImmediate:YES];
}
- (CGWindowID)rememberWindowForCustomMinimizePID:(pid_t)pid
                                           title:(NSString *)title
                                          bounds:(CGRect)bounds
                                        windowID:(CGWindowID)windowID {
    return [self.monitor rememberBounds:bounds forPID:pid title:title windowID:windowID];
}
- (void)markSoftHiddenWindowID:(CGWindowID)windowID
                           pid:(pid_t)pid
                         title:(NSString *)title
                 restoreFrame:(NSRect)restoreFrame
                     screenID:(NSNumber *)screenID
                     axWindow:(AXUIElementRef)axWindow {
    NSString *path = nil;
    if (pid > 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        path = app.bundleURL.path;
    }
    [self.monitor markSoftHiddenWindowID:windowID
                                     pid:pid
                                    path:path
                                   title:title
                           restoreFrame:restoreFrame
                               screenID:screenID
                               axWindow:axWindow];
    [self rebuildItemsImmediate:YES];
}
- (void)updateSoftHideMethod:(MLWindowHideMethod)method forWindowID:(CGWindowID)windowID {
    [self.monitor.softState updateHideMethod:method forWindowID:windowID];
}
- (void)markSoftMinimizedWindowID:(CGWindowID)windowID {
    [self.monitor markSoftMinimizedWindowID:windowID];
    [self rebuildItemsImmediate:YES];
}
- (MLWindowHideMethod)applySoftHideToWindow:(AXUIElementRef)win
                                   windowID:(CGWindowID)windowID
                                        pid:(pid_t)pid {
    BOOL isFinder = NO;
    if (pid > 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        isFinder = [app.bundleIdentifier isEqualToString:@"com.apple.finder"];
    }

    if (!isFinder && windowID != kCGNullWindowID && windowID != 0 && MLCGSWindowAlphaAvailable()) {
        if (MLCGSSetWindowAlpha(windowID, 0.0f)) {
            MLDebugLog(@"[Taskbar] soft hide wid=%u via alpha", (unsigned)windowID);
            return MLWindowHideMethodAlpha;
        }
    }
    if (!win) {
        return MLWindowHideMethodNone;
    }
    AXError err = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanTrue);
    if (err != kAXErrorSuccess) {
        NSLog(@"[Taskbar] soft hide wid=%u AXMinimized failed err=%d", (unsigned)windowID, (int)err);
        return MLWindowHideMethodNone;
    }
#if ML_ENABLE_DEBUG_LOG
    Boolean isMin = false;
    CFTypeRef minRef = NULL;
    if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
        if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
            isMin = CFBooleanGetValue((CFBooleanRef)minRef);
        }
        CFRelease(minRef);
    }
    MLDebugLog(@"[Taskbar] soft hide wid=%u via AXMinimized confirmed=%d finder=%d",
          (unsigned)windowID, (int)isMin, (int)isFinder);
#endif
    return MLWindowHideMethodAXMinimized;
}
- (BOOL)softMinimizeWindowWithAX:(AXUIElementRef)win
                        windowID:(CGWindowID)windowID
                             pid:(pid_t)pid
                           title:(NSString *)title
                    restoreFrame:(NSRect)restoreFrame {
    NSRect frame = restoreFrame;
    if ((frame.size.width < 2.0 || frame.size.height < 2.0) && win) {
        if (![MLScreenGeometry readCocoaFrame:&frame fromAXWindow:win]) {
            frame = NSZeroRect;
        }
    }
    if (frame.size.width < 2.0 || frame.size.height < 2.0) {
        NSLog(@"[Taskbar] soft minimize aborted — no restore frame wid=%u", (unsigned)windowID);
        return NO;
    }

    CGWindowID wid = windowID;
    if (wid == kCGNullWindowID) {
        wid = 0;
    }
    CGWindowID remembered =
        [self rememberWindowForCustomMinimizePID:pid
                                           title:title ?: @""
                                          bounds:NSRectToCGRect(frame)
                                        windowID:wid];
    if (wid == 0) {
        wid = remembered;
    }

    NSScreen *screen = [MLScreenGeometry screenForCocoaRect:frame];
    NSNumber *screenID = [MLScreenGeometry screenIDForScreen:screen];

    /* Mark soft BEFORE hide so poll never drops the chip. */
    if (wid != 0) {
        [self markSoftHiddenWindowID:wid
                                 pid:pid
                               title:title ?: @""
                       restoreFrame:frame
                           screenID:screenID
                           axWindow:win];
    }

    MLWindowHideMethod method = [self applySoftHideToWindow:win windowID:wid pid:pid];
    if (wid != 0 && method != MLWindowHideMethodNone) {
        [self updateSoftHideMethod:method forWindowID:wid];
    }
    [self refreshAfterCustomMinimize];
    return method != MLWindowHideMethodNone;
}
- (AXUIElementRef)copyAXWindowForItem:(MLTaskbarItem *)item {
    if (!item || item.pid <= 0 || item.windowID == 0 || !AXIsProcessTrusted()) {
        return NULL;
    }
    AXUIElementRef appRef = AXUIElementCreateApplication(item.pid);
    if (!appRef) {
        return NULL;
    }
    CFTypeRef windowsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
    CFRelease(appRef);
    if (err != kAXErrorSuccess || !windowsRef || CFGetTypeID(windowsRef) != CFArrayGetTypeID()) {
        if (windowsRef) {
            CFRelease(windowsRef);
        }
        return NULL;
    }
    AXUIElementRef found = NULL;
    CFArrayRef windows = (CFArrayRef)windowsRef;
    CFIndex count = CFArrayGetCount(windows);
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        CGWindowID axWid = [MLAXWindowHelper windowIDForAXWindow:win];
        if (axWid == item.windowID) {
            found = (AXUIElementRef)CFRetain(win);
            break;
        }
    }
    CFRelease(windowsRef);
    return found;
}
- (BOOL)isItemSoftHiddenOrMinimized:(MLTaskbarItem *)item {
    if (!item) {
        return NO;
    }
    if (item.minimized) {
        return YES;
    }
    if (item.windowID != 0 && [self.monitor isSoftMinimizedWindowID:item.windowID]) {
        return YES;
    }
    return NO;
}
- (BOOL)isItemFrontmostWindow:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0 || item.pid <= 0) {
        return NO;
    }
    if ([self isItemSoftHiddenOrMinimized:item]) {
        return NO;
    }
    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    if (item.pid == selfPid) {
        return NO;
    }
    /*
     * Do NOT require NSWorkspace.frontmostApplication == item.pid.
     * Clicking the taskbar often activates MeoLaunch first, which made the old
     * check fail and turned "minimize" into a no-op activate (felt like double-click).
     * Compare against the topmost on-screen user window, excluding ourselves.
     */
    return [self topmostUserWindowIDExcludingSelf] == item.windowID;
}
- (BOOL)softMinimizeItem:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0) {
        return NO;
    }
    if (!AXIsProcessTrusted()) {
        NSLog(@"[Taskbar] soft minimize item needs Accessibility");
        return NO;
    }

    AXUIElementRef win = [self copyAXWindowForItem:item];
    NSRect frame = NSZeroRect;
    if (win) {
        [MLScreenGeometry readCocoaFrame:&frame fromAXWindow:win];
    }
    if (frame.size.width < 2.0 || frame.size.height < 2.0) {
        /* Fallback: CG on-screen bounds for this windowID. */
        CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,
                                                     item.windowID);
        if (list && CFArrayGetCount(list) > 0) {
            CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, 0);
            CFDictionaryRef boundsDict = info ? CFDictionaryGetValue(info, kCGWindowBounds) : NULL;
            CGRect q = CGRectZero;
            if (boundsDict && CGRectMakeWithDictionaryRepresentation(boundsDict, &q)) {
                frame = [MLScreenGeometry cocoaRectFromQuartzBounds:q];
            }
        }
        if (list) {
            CFRelease(list);
        }
    }

    BOOL ok = [self softMinimizeWindowWithAX:win
                                    windowID:item.windowID
                                         pid:item.pid
                                       title:item.title ?: @""
                                restoreFrame:frame];
    if (win) {
        CFRelease(win);
    }
    if (!ok) {
        NSLog(@"[Taskbar] soft minimize item failed wid=%u", (unsigned)item.windowID);
    }
    return ok;
}
- (BOOL)title:(NSString *)full matchesHint:(NSString *)hint {
    if (hint.length == 0) {
        return YES;
    }
    if (full.length == 0) {
        return NO;
    }
    if ([full isEqualToString:hint]) {
        return YES;
    }
    NSString *prefix = hint;
    if ([hint hasSuffix:@"…"] || [hint hasSuffix:@"..."]) {
        NSUInteger trim = [hint hasSuffix:@"..."] ? 3 : 1;
        if (hint.length > trim) {
            prefix = [hint substringToIndex:hint.length - trim];
        }
    }
    return prefix.length > 0 && [full hasPrefix:prefix];
}
- (BOOL)frame:(NSRect)frame matchesRestore:(NSRect)restore tolerance:(CGFloat)tol {
    if (restore.size.width < 2.0 || restore.size.height < 2.0) {
        return frame.size.width > 50.0 && frame.size.height > 50.0;
    }
    return [MLScreenGeometry nearlyEqual:NSMinX(frame) b:NSMinX(restore) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSMinY(frame) b:NSMinY(restore) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSWidth(frame) b:NSWidth(restore) tolerance:tol] &&
           [MLScreenGeometry nearlyEqual:NSHeight(frame) b:NSHeight(restore) tolerance:tol];
}
- (BOOL)applyRestoreFrame:(NSRect)restoreFrame
                toAXWindow:(AXUIElementRef)target
                  windowID:(CGWindowID)wid
             clearIfMatched:(BOOL)clearIfMatched {
    if (!target || restoreFrame.size.width < 2.0 || restoreFrame.size.height < 2.0) {
        return NO;
    }
    [MLScreenGeometry applyCocoaFrame:restoreFrame toAXWindow:target];
    AXUIElementPerformAction(target, kAXRaiseAction);
    NSRect got = NSZeroRect;
    if (![MLScreenGeometry readCocoaFrame:&got fromAXWindow:target]) {
        return NO;
    }
    Boolean stillMin = false;
    CFTypeRef minRef = NULL;
    if (AXUIElementCopyAttributeValue(target, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
        if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
            stillMin = CFBooleanGetValue((CFBooleanRef)minRef);
        }
        CFRelease(minRef);
    }
    if (stillMin) {
        return NO;
    }
    BOOL matched = [self frame:got matchesRestore:restoreFrame tolerance:20.0];
    if (matched && clearIfMatched && wid != 0) {
        [self.monitor.softState clearVerifiedWindowID:wid];
        MLDebugLog(@"[Taskbar] soft restore verified wid=%u frame=(%.0f,%.0f %.0fx%.0f)",
              (unsigned)wid, got.origin.x, got.origin.y, got.size.width, got.size.height);
    } else if (!matched) {
        MLDebugLog(@"[Taskbar] soft restore mismatch wid=%u got=(%.0f,%.0f %.0fx%.0f) want=(%.0f,%.0f %.0fx%.0f)",
              (unsigned)wid,
              got.origin.x, got.origin.y, got.size.width, got.size.height,
              restoreFrame.origin.x, restoreFrame.origin.y, restoreFrame.size.width, restoreFrame.size.height);
    }
    return matched;
}
- (void)raiseAndFocusWindowForItem:(MLTaskbarItem *)item {
    if (item.pid <= 0) {
        return;
    }
    if (!AXIsProcessTrusted()) {
        return;
    }

    CGWindowID wid = item.windowID;
    MLWindowSoftRecord *soft = wid != 0 ? [self.monitor.softState recordForWindowID:wid] : nil;
    BOOL wasSoft = soft != nil;
    NSRect restoreFrame = soft ? soft.restoreFrameCocoa : NSZeroRect;
    MLWindowHideMethod hideMethod = soft ? soft.hideMethod : MLWindowHideMethodNone;
    BOOL needsGeometry = wasSoft && restoreFrame.size.width > 2.0 && restoreFrame.size.height > 2.0;
    AXUIElementRef softAX = soft ? soft.axWindow : NULL;

    AXUIElementRef appRef = AXUIElementCreateApplication(item.pid);
    if (!appRef) {
        return;
    }

    CFTypeRef windowsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
    if (err != kAXErrorSuccess || !windowsRef || CFGetTypeID(windowsRef) != CFArrayGetTypeID()) {
        if (windowsRef) {
            CFRelease(windowsRef);
        }
        /* Soft restore: still try retained AX element. */
        if (softAX && wasSoft) {
            if (hideMethod == MLWindowHideMethodAlpha && wid != 0) {
                MLCGSSetWindowAlpha(wid, 1.0f);
            }
            AXUIElementSetAttributeValue(softAX, kAXMinimizedAttribute, kCFBooleanFalse);
            AXUIElementPerformAction(softAX, kAXRaiseAction);
            AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
            if (needsGeometry) {
                [self applyRestoreFrame:restoreFrame toAXWindow:softAX windowID:wid clearIfMatched:YES];
            }
        } else {
            AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
        }
        CFRelease(appRef);
        return;
    }

    CFArrayRef windows = (CFArrayRef)windowsRef;
    CFIndex count = CFArrayGetCount(windows);

    AXUIElementRef matchedByID = NULL;
    AXUIElementRef matchedByTitle = NULL;
    AXUIElementRef firstMinimized = NULL;
    AXUIElementRef firstAny = NULL;
    BOOL softAXStillListed = NO;

    NSString *appDisplay = [self displayNameForPath:item.path];
    BOOL titleIsAppNameOnly =
        (appDisplay.length > 0 && item.title.length > 0 && [item.title isEqualToString:appDisplay]);

    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
        if (!firstAny) {
            firstAny = win;
        }
        if (softAX && win == softAX) {
            softAXStillListed = YES;
        }

        CGWindowID axWid = [MLAXWindowHelper windowIDForAXWindow:win];
        if (wid != 0 && axWid == wid) {
            matchedByID = win;
        }

        CFTypeRef minRef = NULL;
        Boolean isMin = false;
        if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
            if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                isMin = CFBooleanGetValue((CFBooleanRef)minRef);
            }
            CFRelease(minRef);
        }
        if (isMin && !firstMinimized) {
            firstMinimized = win;
        }

        if (!matchedByTitle && !titleIsAppNameOnly && soft) {
            CFTypeRef titleRef = NULL;
            NSString *title = nil;
            if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &titleRef) == kAXErrorSuccess &&
                titleRef) {
                if (CFGetTypeID(titleRef) == CFStringGetTypeID()) {
                    title = (__bridge NSString *)titleRef;
                }
                CFRelease(titleRef);
            }
            NSString *hint = soft.title.length > 0 ? soft.title : item.title;
            if (![hint isEqualToString:appDisplay] && [self title:title ?: @"" matchesHint:hint]) {
                matchedByTitle = win;
            }
        }
    }

    /* Prefer retained AX from minimize; then windowID; then title; then minimized. */
    AXUIElementRef target = nil;
    if (softAX && (softAXStillListed || wasSoft)) {
        target = softAX;
    }
    if (!target) {
        target = matchedByID ?: matchedByTitle;
    }
    if (!target) {
        if (wasSoft || item.minimized) {
            target = firstMinimized ?: firstAny;
        } else {
            target = firstAny ?: firstMinimized;
        }
    }

    BOOL verified = NO;
    if (target) {
        if (wasSoft && hideMethod == MLWindowHideMethodAlpha && wid != 0) {
            MLCGSSetWindowAlpha(wid, 1.0f);
        }

        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute, kCFBooleanFalse);
        AXUIElementPerformAction(target, kAXRaiseAction);
        AXUIElementSetAttributeValue(target, kAXMainAttribute, kCFBooleanTrue);
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute, kCFBooleanTrue);
        AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);

        if (needsGeometry) {
            verified = [self applyRestoreFrame:restoreFrame
                                     toAXWindow:target
                                       windowID:wid
                                  clearIfMatched:YES];

            if (!verified) {
                AXUIElementRef winKeep = (AXUIElementRef)CFRetain(target);
                NSRect frameKeep = restoreFrame;
                CGWindowID widKeep = wid;
                __weak typeof(self) weakSelf = self;
                /* Finder often needs several ticks after deminiaturize before AX size sticks. */
                static const double kDelays[] = { 0.05, 0.12, 0.25, 0.45, 0.75, 1.20 };
                __block NSInteger pending = (NSInteger)(sizeof(kDelays) / sizeof(kDelays[0]));
                for (size_t i = 0; i < sizeof(kDelays) / sizeof(kDelays[0]); i++) {
                    double delay = kDelays[i];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                                       __strong typeof(weakSelf) self = weakSelf;
                                       if (self &&
                                           [self.monitor.softState isSoftHiddenWindowID:widKeep]) {
                                           AXUIElementSetAttributeValue(winKeep, kAXMinimizedAttribute,
                                                                        kCFBooleanFalse);
                                           [self applyRestoreFrame:frameKeep
                                                         toAXWindow:winKeep
                                                           windowID:widKeep
                                                      clearIfMatched:YES];
                                       }
                                       if (--pending == 0) {
                                           CFRelease(winKeep);
                                       }
                                   });
                }
            }
        } else if (wasSoft) {
            /* Soft without frame — clear once deminiaturized / raised. */
            Boolean stillMin = false;
            CFTypeRef minRef = NULL;
            if (AXUIElementCopyAttributeValue(target, kAXMinimizedAttribute, &minRef) ==
                    kAXErrorSuccess &&
                minRef) {
                if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                    stillMin = CFBooleanGetValue((CFBooleanRef)minRef);
                }
                CFRelease(minRef);
            }
            if (!stillMin && wid != 0) {
                [self.monitor.softState clearVerifiedWindowID:wid];
                verified = YES;
            }
        }

        if (wasSoft) {
            if (verified) {
                MLDebugLog(@"[Taskbar] soft restore ok wid=%u", (unsigned)wid);
            } else if (needsGeometry) {
                MLDebugLog(@"[Taskbar] soft restore pending wid=%u (chip kept, retries scheduled)",
                      (unsigned)wid);
            }
        }
    } else {
        AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
        MLDebugLog(@"[Taskbar] soft restore fail — no AX target wid=%u", (unsigned)wid);
    }

    CFRelease(windowsRef);
    CFRelease(appRef);
}
- (void)activateApplicationForItem:(MLTaskbarItem *)item {
    NSRunningApplication *app = nil;
    if (item.pid > 0) {
        app = [NSRunningApplication runningApplicationWithProcessIdentifier:item.pid];
    }
    if ((!app || app.isTerminated) && item.path.length > 0) {
        NSString *std = item.path.stringByStandardizingPath;
        for (NSRunningApplication *ra in [NSWorkspace sharedWorkspace].runningApplications) {
            NSString *p = ra.bundleURL.path;
            if ([p isEqualToString:item.path] ||
                (std.length > 0 && [p.stringByStandardizingPath isEqualToString:std])) {
                app = ra;
                item.pid = ra.processIdentifier;
                break;
            }
        }
    }
    if (!app || app.isTerminated) {
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL softRestore =
        item.minimized ||
        (item.windowID != 0 && [self.monitor isSoftMinimizedWindowID:item.windowID]);
    NSApplicationActivationOptions opts = NSApplicationActivateIgnoringOtherApps;
    if (!softRestore) {
        opts |= NSApplicationActivateAllWindows;
    }
    [app activateWithOptions:opts];
#pragma clang diagnostic pop

    if (@available(macOS 14.0, *)) {
        [app unhide];
    }
}
- (void)openApplicationAtPath:(NSString *)path {
    [MLAppLauncher openApplicationAtPath:path];
}
- (BOOL)isApplicationRunningAtPath:(NSString *)path {
    if (path.length == 0) {
        return NO;
    }
    NSString *std = path.stringByStandardizingPath;
    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        NSString *p = app.bundleURL.path;
        if (p.length == 0) {
            continue;
        }
        if ([p isEqualToString:path] ||
            (std.length > 0 && [p.stringByStandardizingPath isEqualToString:std])) {
            return !app.isTerminated;
        }
    }
    return NO;
}
- (void)activateOrLaunchItem:(MLTaskbarItem *)item {
    if (item.kind == MLTaskbarItemPinnedOnly) {
        [self activateApplicationForItem:item];
        [self openApplicationAtPath:item.path];
        return;
    }

    if (item.pid > 0 || item.path.length > 0) {
        BOOL softRestore = [self isItemSoftHiddenOrMinimized:item];
        if (softRestore) {
            /* Minimized / soft-hidden → restore geometry + activate. */
            [self activateApplicationForItem:item];
            [self raiseAndFocusWindowForItem:item];
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               [weakSelf raiseAndFocusWindowForItem:item];
                               [weakSelf activateApplicationForItem:item];
                           });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                               [weakSelf raiseAndFocusWindowForItem:item];
                           });
            return;
        }

        if ([self isItemFrontmostWindow:item]) {
            /* Already frontmost → soft-minimize (same as yellow button). */
            [self softMinimizeItem:item];
            return;
        }

        /* Visible but not front → raise + activate. */
        [self raiseAndFocusWindowForItem:item];
        [self activateApplicationForItem:item];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf raiseAndFocusWindowForItem:item];
                           [weakSelf activateApplicationForItem:item];
                       });
        if (item.pid > 0) {
            NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:item.pid];
            if (app && !app.isTerminated) {
                return;
            }
        }
        if ([self isApplicationRunningAtPath:item.path]) {
            return;
        }
    }

    [self openApplicationAtPath:item.path];
}
- (void)taskbarView:(MLTaskbarView *)view didClickItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    [self activateOrLaunchItem:view.items[(NSUInteger)index]];
}
- (BOOL)readFullscreenForAXWindow:(AXUIElementRef)win {
    if (!win) {
        return NO;
    }
    CFTypeRef fsRef = NULL;
    if (AXUIElementCopyAttributeValue(win, CFSTR("AXFullScreen"), &fsRef) != kAXErrorSuccess || !fsRef) {
        return NO;
    }
    BOOL on = NO;
    if (CFGetTypeID(fsRef) == CFBooleanGetTypeID()) {
        on = CFBooleanGetValue((CFBooleanRef)fsRef);
    }
    CFRelease(fsRef);
    return on;
}
- (BOOL)canReadFullscreenForAXWindow:(AXUIElementRef)win {
    if (!win) {
        return NO;
    }
    CFTypeRef fsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(win, CFSTR("AXFullScreen"), &fsRef);
    if (fsRef) {
        CFRelease(fsRef);
    }
    return err == kAXErrorSuccess;
}
- (void)taskbarView:(MLTaskbarView *)view
         menuFlags:(MLTaskbarMenuFlags *)flags
          forIndex:(NSInteger)index {
    (void)view;
    if (!flags) {
        return;
    }
    flags.hasWindow = NO;
    flags.minimized = NO;
    flags.fullscreen = NO;
    flags.fullscreenSupported = NO;
    flags.pinned = NO;
    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    MLTaskbarItem *item = view.items[(NSUInteger)index];
    flags.pinned = item.pinned;
    flags.hasWindow = (item.kind == MLTaskbarItemRunningWindow && item.windowID != 0);
    flags.minimized = [self isItemSoftHiddenOrMinimized:item];
    if (!flags.hasWindow || !AXIsProcessTrusted()) {
        return;
    }
    AXUIElementRef win = [self copyAXWindowForItem:item];
    if (!win) {
        /* Soft-hidden may still have retained AX. */
        MLWindowSoftRecord *soft =
            item.windowID != 0 ? [self.monitor.softState recordForWindowID:item.windowID] : nil;
        if (soft.axWindow) {
            win = (AXUIElementRef)CFRetain(soft.axWindow);
        }
    }
    if (win) {
        flags.fullscreenSupported = [self canReadFullscreenForAXWindow:win];
        flags.fullscreen = flags.fullscreenSupported ? [self readFullscreenForAXWindow:win] : NO;
        CFRelease(win);
    }
}
- (void)closeWindowForItem:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0 || !AXIsProcessTrusted()) {
        return;
    }
    BOOL wasSoft = [self isItemSoftHiddenOrMinimized:item];
    if (wasSoft) {
        [self raiseAndFocusWindowForItem:item];
    }

    AXUIElementRef win = [self copyAXWindowForItem:item];
    if (!win) {
        MLWindowSoftRecord *soft = [self.monitor.softState recordForWindowID:item.windowID];
        if (soft.axWindow) {
            win = (AXUIElementRef)CFRetain(soft.axWindow);
        }
    }
    if (!win) {
        NSLog(@"[Taskbar] close failed — no AX window wid=%u", (unsigned)item.windowID);
        return;
    }

    /* Prefer close button press (widely supported). */
    BOOL closed = NO;
    CFTypeRef btnRef = NULL;
    if (AXUIElementCopyAttributeValue(win, kAXCloseButtonAttribute, &btnRef) == kAXErrorSuccess &&
        btnRef) {
        if (CFGetTypeID(btnRef) == AXUIElementGetTypeID()) {
            AXError err = AXUIElementPerformAction((AXUIElementRef)btnRef, kAXPressAction);
            closed = (err == kAXErrorSuccess);
        }
        CFRelease(btnRef);
    }
    if (!closed) {
        /* Fallback: some apps expose AXClose on the window. */
        AXUIElementPerformAction(win, CFSTR("AXPress"));
    }
    CFRelease(win);

    if (item.windowID != 0) {
        [self.monitor.softState removeClosedWindowID:item.windowID];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf.monitor pollNow];
                       [weakSelf rebuildItemsImmediate:YES];
                   });
}
- (void)toggleMinimizeForItem:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0) {
        return;
    }
    if ([self isItemSoftHiddenOrMinimized:item]) {
        [self activateApplicationForItem:item];
        [self raiseAndFocusWindowForItem:item];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf raiseAndFocusWindowForItem:item];
                           [weakSelf activateApplicationForItem:item];
                       });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf raiseAndFocusWindowForItem:item];
                       });
    } else {
        [self softMinimizeItem:item];
    }
}
- (void)toggleFullscreenForItem:(MLTaskbarItem *)item {
    if (!item || item.windowID == 0 || !AXIsProcessTrusted()) {
        return;
    }
    if ([self isItemSoftHiddenOrMinimized:item]) {
        [self raiseAndFocusWindowForItem:item];
    }
    AXUIElementRef win = [self copyAXWindowForItem:item];
    if (!win) {
        return;
    }
    if (![self canReadFullscreenForAXWindow:win]) {
        CFRelease(win);
        return;
    }
    BOOL on = [self readFullscreenForAXWindow:win];
    AXUIElementSetAttributeValue(win, CFSTR("AXFullScreen"), on ? kCFBooleanFalse : kCFBooleanTrue);
    CFRelease(win);
    [self activateApplicationForItem:item];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf refreshFullscreenVisibility];
                   });
}
- (void)taskbarView:(MLTaskbarView *)view
    didSelectAction:(MLTaskbarMenuAction)action
            atIndex:(NSInteger)index {
    (void)view;
    switch (action) {
        case MLTaskbarMenuActionAbout:
            [self.appActions taskbarShowAbout];
            return;
        case MLTaskbarMenuActionPreferences:
            [self.appActions taskbarShowPreferences];
            return;
        case MLTaskbarMenuActionQuit:
            [self.appActions taskbarQuitApp];
            return;
        default:
            break;
    }

    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    MLTaskbarItem *item = view.items[(NSUInteger)index];
    switch (action) {
        case MLTaskbarMenuActionClose:
            [self closeWindowForItem:item];
            break;
        case MLTaskbarMenuActionMinimizeToggle:
            [self toggleMinimizeForItem:item];
            break;
        case MLTaskbarMenuActionFullscreenToggle:
            [self toggleFullscreenForItem:item];
            break;
        case MLTaskbarMenuActionPinToggle:
            if (item.path.length == 0) {
                break;
            }
            if (item.pinned) {
                [self.pinStore unpinPath:item.path];
            } else {
                [self.pinStore pinPath:item.path];
            }
            break;
        default:
            break;
    }
}

@end
