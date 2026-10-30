#import "MLTaskbarController+Private.h"

#import "MLAppAudioMuteController.h"
#import "MLAppLauncher.h"
#import "MLAXWindowHelper.h"
#import "MLCGSAlpha.h"
#import "MLDebugLog.h"
#import "MLRunningAppsMonitor.h"
#import "MLScreenGeometry.h"
#import "MLStrings.h"
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
    [self raiseAndFocusWindowForItem:item makeAppFrontmost:YES];
}

- (void)raiseAndFocusWindowForItem:(MLTaskbarItem *)item makeAppFrontmost:(BOOL)makeAppFrontmost {
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
            if ((hideMethod == MLWindowHideMethodAlpha || hideMethod == MLWindowHideMethodParked) &&
                wid != 0) {
                MLCGSSetWindowAlpha(wid, 1.0f);
            }
            AXUIElementSetAttributeValue(softAX, kAXMinimizedAttribute, kCFBooleanFalse);
            AXUIElementPerformAction(softAX, kAXRaiseAction);
            if (makeAppFrontmost) {
                AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
            }
            if (needsGeometry) {
                [self applyRestoreFrame:restoreFrame toAXWindow:softAX windowID:wid clearIfMatched:YES];
            }
        } else if (makeAppFrontmost) {
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
        if (wasSoft &&
            (hideMethod == MLWindowHideMethodAlpha || hideMethod == MLWindowHideMethodParked) &&
            wid != 0) {
            MLCGSSetWindowAlpha(wid, 1.0f);
        }

        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute, kCFBooleanFalse);
        AXUIElementPerformAction(target, kAXRaiseAction);
        AXUIElementSetAttributeValue(target, kAXMainAttribute, kCFBooleanTrue);
        /* Avoid kAXFocused on the foreign window during locator preview — steals key. */
        if (makeAppFrontmost) {
            AXUIElementSetAttributeValue(target, kAXFocusedAttribute, kCFBooleanTrue);
            AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
        }

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
        if (makeAppFrontmost) {
            AXUIElementSetAttributeValue(appRef, kAXFrontmostAttribute, kCFBooleanTrue);
        }
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
    if (item.kind == MLTaskbarItemPinnedOnly ||
        item.kind == MLTaskbarItemRunningNoWindow) {
        [self activateApplicationForItem:item];
        [self openApplicationAtPath:item.path];
        [self touchActivationMRUForItem:item];
        return;
    }

    if (item.pid > 0 || item.path.length > 0) {
        /* Dead/ghost window chip: AX has no windows → open a new one (Activity Monitor etc.). */
        if (item.kind == MLTaskbarItemRunningWindow &&
            item.pid > 0 &&
            AXIsProcessTrusted() &&
            ![self processHasAXWindows:item.pid]) {
            [self activateApplicationForItem:item];
            [self openApplicationAtPath:item.path];
            [self touchActivationMRUForItem:item];
            return;
        }

        BOOL softRestore = [self isItemSoftHiddenOrMinimized:item];
        if (softRestore) {
            if (self.itemsFrozenForDesktopReveal || self.desktopPeekUserArmed) {
                [self unfreezeDesktopRevealAndRefresh];
            }
            /* Minimized / soft-hidden → restore geometry + activate. */
            [self activateApplicationForItem:item];
            [self raiseAndFocusWindowForItem:item];
            [self touchActivationMRUForItem:item];
            if (item.windowID != 0) {
                [self noteShowDesktopSessionRestoredWindowID:item.windowID];
            }
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
            /* Manual soft-min while in Show Desktop session: leave session as-is. */
            return;
        }

        /* Visible but not front → raise + activate. */
        [self raiseAndFocusWindowForItem:item];
        [self activateApplicationForItem:item];
        [self touchActivationMRUForItem:item];
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

/**
 * Chip Locator confirm: raise + activate, never soft-min toggle.
 * Soft-min / peek restore paths match chip click when needed.
 */
- (void)raiseOnlyItem:(MLTaskbarItem *)item {
    if (!item) {
        return;
    }
    if (item.kind == MLTaskbarItemPinnedOnly ||
        item.kind == MLTaskbarItemRunningNoWindow) {
        [self activateApplicationForItem:item];
        [self openApplicationAtPath:item.path];
        [self touchActivationMRUForItem:item];
        return;
    }

    if (item.kind == MLTaskbarItemRunningWindow &&
        item.pid > 0 &&
        AXIsProcessTrusted() &&
        ![self processHasAXWindows:item.pid]) {
        [self activateApplicationForItem:item];
        [self openApplicationAtPath:item.path];
        [self touchActivationMRUForItem:item];
        return;
    }

    BOOL softRestore = [self isItemSoftHiddenOrMinimized:item];
    if (softRestore) {
        if (self.itemsFrozenForDesktopReveal || self.desktopPeekUserArmed) {
            [self unfreezeDesktopRevealAndRefresh];
        }
        [self activateApplicationForItem:item];
        [self raiseAndFocusWindowForItem:item makeAppFrontmost:YES];
        [self touchActivationMRUForItem:item];
        if (item.windowID != 0) {
            [self noteShowDesktopSessionRestoredWindowID:item.windowID];
        }
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf raiseAndFocusWindowForItem:item makeAppFrontmost:YES];
                           [weakSelf activateApplicationForItem:item];
                       });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
                           [weakSelf raiseAndFocusWindowForItem:item makeAppFrontmost:YES];
                       });
        return;
    }

    /* Never soft-minimize even when already frontmost. */
    [self raiseAndFocusWindowForItem:item makeAppFrontmost:YES];
    [self activateApplicationForItem:item];
    [self touchActivationMRUForItem:item];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       [weakSelf raiseAndFocusWindowForItem:item makeAppFrontmost:YES];
                       [weakSelf activateApplicationForItem:item];
                   });
}

/**
 * Locator live preview: bring the window forward without activating its app,
 * so the locator panel keeps key focus / typing stays smooth.
 */
- (void)previewRaiseItem:(MLTaskbarItem *)item {
    if (!item || item.kind != MLTaskbarItemRunningWindow) {
        return;
    }
    if (item.pid <= 0) {
        return;
    }
    /* Do not touch MRU here — locator list order stays frozen while the panel is open. */
    BOOL softRestore = [self isItemSoftHiddenOrMinimized:item];
    if (softRestore) {
        if (self.itemsFrozenForDesktopReveal || self.desktopPeekUserArmed) {
            [self unfreezeDesktopRevealAndRefresh];
        }
        [self raiseAndFocusWindowForItem:item makeAppFrontmost:NO];
        return;
    }
    [self raiseAndFocusWindowForItem:item makeAppFrontmost:NO];
}

- (BOOL)processHasAXWindows:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return YES; /* unknown — don't force open */
    }
    AXUIElementRef appRef = AXUIElementCreateApplication(pid);
    if (!appRef) {
        return YES;
    }
    CFTypeRef windowsRef = NULL;
    AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
    CFRelease(appRef);
    if (err != kAXErrorSuccess || !windowsRef || CFGetTypeID(windowsRef) != CFArrayGetTypeID()) {
        if (windowsRef) {
            CFRelease(windowsRef);
        }
        return YES;
    }
    CFIndex count = CFArrayGetCount((CFArrayRef)windowsRef);
    CFRelease(windowsRef);
    return count > 0;
}
- (void)taskbarView:(MLTaskbarView *)view didClickItemAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    [self activateOrLaunchItem:view.items[(NSUInteger)index]];
}

- (void)taskbarView:(MLTaskbarView *)view didClickAudioBadgeAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    [self toggleAudioMuteForItem:view.items[(NSUInteger)index]];
}

- (void)toggleAudioMuteForItem:(MLTaskbarItem *)item {
    if (!self.audioIndicatorEnabled) {
        return;
    }
    if (!item || item.pid <= 0) {
        return;
    }
    if (item.kind != MLTaskbarItemRunningWindow &&
        item.kind != MLTaskbarItemRunningNoWindow) {
        return;
    }
    if (!self.audioMute || ![MLAppAudioMuteController isAvailable]) {
        return;
    }
    if (item.bundleID.length == 0) {
        item.bundleID = [[NSBundle bundleWithPath:item.path ?: @""] bundleIdentifier];
    }
    NSError *err = nil;
    BOOL muted = NO;
    if (![self.audioMute toggleMutePID:item.pid
                              bundleID:item.bundleID
                              outMuted:&muted
                                 error:&err]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [MLStrings t:@"taskbar.audio.mute_failed"];
        alert.informativeText = err.localizedDescription.length > 0
                                    ? err.localizedDescription
                                    : [MLStrings t:@"taskbar.audio.mute_failed_detail"];
        [alert addButtonWithTitle:[MLStrings t:@"taskbar.audio.ok"]];
        [alert runModal];
        return;
    }
    [self applyAudioBadgesFromMonitor];
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
    flags.canQuitProcess = NO;
    flags.minimized = NO;
    flags.fullscreen = NO;
    flags.fullscreenSupported = NO;
    flags.pinned = NO;
    flags.taskChipHidden = NO;
    flags.canToggleHideChip = NO;
    flags.audioMuteAvailable = NO;
    flags.audioMuted = NO;
    if (index < 0 || index >= (NSInteger)view.items.count) {
        return;
    }
    MLTaskbarItem *item = view.items[(NSUInteger)index];
    flags.pinned = item.pinned;
    flags.canToggleHideChip = (item.path.length > 0);
    flags.taskChipHidden = (self.hideStore != nil && [self.hideStore isHidden:item.path]);
    flags.hasWindow = (item.kind == MLTaskbarItemRunningWindow && item.windowID != 0);
    flags.canQuitProcess = (item.kind == MLTaskbarItemRunningNoWindow && item.pid > 0);
    flags.minimized = [self isItemSoftHiddenOrMinimized:item];
    BOOL audioCapable = (item.kind == MLTaskbarItemRunningWindow ||
                         item.kind == MLTaskbarItemRunningNoWindow);
    if (audioCapable && item.pid > 0 &&
        self.audioIndicatorEnabled &&
        self.audioMute && [MLAppAudioMuteController isAvailable]) {
        flags.audioMuteAvailable = (item.audioState != MLTaskbarAudioNone) ||
                                   [self.audioMute isMutedPID:item.pid bundleID:item.bundleID];
        flags.audioMuted = [self.audioMute isMutedPID:item.pid bundleID:item.bundleID];
    }
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
    if (!item) {
        return;
    }
    if (item.kind == MLTaskbarItemRunningNoWindow) {
        [self terminateProcessForItem:item];
        return;
    }
    if (item.windowID == 0 || !AXIsProcessTrusted()) {
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

- (void)terminateProcessForItem:(MLTaskbarItem *)item {
    if (!item || item.pid <= 0) {
        return;
    }
    NSRunningApplication *app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:item.pid];
    if ((!app || app.terminated) && item.path.length > 0) {
        NSString *bid = [[NSBundle bundleWithPath:item.path] bundleIdentifier];
        if (bid.length > 0) {
            NSString *std = item.path.stringByStandardizingPath;
            for (NSRunningApplication *candidate in
                 [NSRunningApplication runningApplicationsWithBundleIdentifier:bid]) {
                if (candidate.terminated) {
                    continue;
                }
                NSString *cpath = candidate.bundleURL.path.stringByStandardizingPath;
                if (std.length > 0 && [cpath isEqualToString:std]) {
                    app = candidate;
                    break;
                }
                if (!app || app.terminated) {
                    app = candidate;
                }
            }
        }
    }
    if (!app || app.terminated) {
        NSLog(@"[Taskbar] quit process failed — no running app pid=%d path=%@",
              (int)item.pid, item.path ?: @"");
        return;
    }
    if (![app terminate]) {
        [app forceTerminate];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
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
        if (item.windowID != 0) {
            [self noteShowDesktopSessionRestoredWindowID:item.windowID];
        }
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
- (void)taskbarViewDidClickSearchButton:(MLTaskbarView *)view {
    (void)view;
    if ([self.appActions respondsToSelector:@selector(taskbarToggleChipLocator)]) {
        [self.appActions taskbarToggleChipLocator];
    }
}

- (MLTaskbarItem *)copyItemForShowDesktopSession:(MLTaskbarItem *)src {
    if (!src) {
        return nil;
    }
    MLTaskbarItem *c = [[MLTaskbarItem alloc] init];
    c.path = src.path;
    c.bundleID = src.bundleID;
    c.pid = src.pid;
    c.windowID = src.windowID;
    c.title = src.title;
    c.kind = src.kind;
    c.pinned = src.pinned;
    c.minimized = src.minimized;
    c.active = NO;
    c.seenOrder = src.seenOrder;
    c.audioState = MLTaskbarAudioNone;
    return c;
}

- (void)syncShowDesktopButtonAppearance {
    BOOL on = self.showDesktopButtonEnabled && self.showDesktopSessionActive;
    for (MLTaskbarScreenBar *bar in self.bars) {
        bar.barView.showsShowDesktopButton = self.showDesktopButtonEnabled;
        bar.barView.showDesktopButtonActive = on;
    }
}

- (void)clearShowDesktopSession {
    self.showDesktopSessionActive = NO;
    [self.showDesktopSessionItems removeAllObjects];
    [self syncShowDesktopButtonAppearance];
}

- (void)noteShowDesktopSessionRestoredWindowID:(CGWindowID)windowID {
    if (!self.showDesktopSessionActive || windowID == 0) {
        return;
    }
    NSMutableArray<MLTaskbarItem *> *kept = [NSMutableArray array];
    for (MLTaskbarItem *it in self.showDesktopSessionItems) {
        if (it.windowID != windowID) {
            [kept addObject:it];
        }
    }
    [self.showDesktopSessionItems setArray:kept];
    if (self.showDesktopSessionItems.count == 0) {
        [self clearShowDesktopSession];
    }
}

/** One CGWindowList pass → cocoa frames for the given window IDs. */
- (NSDictionary<NSNumber *, NSValue *> *)cocoaFramesByWindowIDs:(NSSet<NSNumber *> *)windowIDs {
    NSMutableDictionary<NSNumber *, NSValue *> *out = [NSMutableDictionary dictionary];
    if (windowIDs.count == 0) {
        return out;
    }
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                     kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    if (!list) {
        return out;
    }
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        CFNumberRef widRef = info ? CFDictionaryGetValue(info, kCGWindowNumber) : NULL;
        if (!widRef) {
            continue;
        }
        CGWindowID wid = 0;
        CFNumberGetValue(widRef, kCFNumberIntType, &wid);
        if (wid == 0 || ![windowIDs containsObject:@(wid)]) {
            continue;
        }
        CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
        CGRect q = CGRectZero;
        if (boundsDict && CGRectMakeWithDictionaryRepresentation(boundsDict, &q)) {
            NSRect cocoa = [MLScreenGeometry cocoaRectFromQuartzBounds:q];
            if (cocoa.size.width >= 2.0 && cocoa.size.height >= 2.0) {
                out[@(wid)] = [NSValue valueWithRect:cocoa];
            }
        }
    }
    CFRelease(list);
    return out;
}

/**
 * Resolve AX windows for many PIDs in one pass each.
 * Values are ARC-retained AXUIElementRefs (bridged id).
 */
- (NSDictionary<NSNumber *, id> *)axWindowsByWindowIDForItems:(NSArray<MLTaskbarItem *> *)items {
    NSMutableDictionary<NSNumber *, id> *out = [NSMutableDictionary dictionary];
    if (items.count == 0 || !AXIsProcessTrusted()) {
        return out;
    }
    NSMutableSet<NSNumber *> *pids = [NSMutableSet set];
    NSMutableSet<NSNumber *> *wantWids = [NSMutableSet set];
    for (MLTaskbarItem *it in items) {
        if (it.pid > 0) {
            [pids addObject:@(it.pid)];
        }
        if (it.windowID != 0) {
            [wantWids addObject:@(it.windowID)];
        }
    }
    for (NSNumber *pidNum in pids) {
        AXUIElementRef appRef = AXUIElementCreateApplication((pid_t)pidNum.intValue);
        if (!appRef) {
            continue;
        }
        CFTypeRef windowsRef = NULL;
        AXError err = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute, &windowsRef);
        CFRelease(appRef);
        if (err != kAXErrorSuccess || !windowsRef || CFGetTypeID(windowsRef) != CFArrayGetTypeID()) {
            if (windowsRef) {
                CFRelease(windowsRef);
            }
            continue;
        }
        CFArrayRef windows = (CFArrayRef)windowsRef;
        CFIndex count = CFArrayGetCount(windows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
            if (wid == 0 || ![wantWids containsObject:@(wid)] || out[@(wid)]) {
                continue;
            }
            out[@(wid)] = CFBridgingRelease(CFRetain(win));
        }
        CFRelease(windowsRef);
    }
    return out;
}

/** Park far off-screen (same size) — instantaneous, no Dock minimize animation. */
- (void)parkAXWindowOffScreen:(AXUIElementRef)win keepingSize:(NSSize)size {
    if (!win) {
        return;
    }
    CGFloat w = size.width >= 2.0 ? size.width : 100.0;
    CGFloat h = size.height >= 2.0 ? size.height : 100.0;
    NSRect park = NSMakeRect(-28000.0, -28000.0, w, h);
    [MLScreenGeometry applyCocoaFrame:park toAXWindow:win];
}

/**
 * Show Desktop: hide ALL windows in one burst via alpha + off-screen park.
 * Never uses AXMinimized (that animates one-by-one). Restore is the inverse burst.
 */
- (void)enterShowDesktopSession {
    if (self.itemsFrozenForDesktopReveal || self.desktopPeekUserArmed) {
        [self unfreezeDesktopRevealAndRefresh];
    }

    pid_t selfPid = (pid_t)NSProcessInfo.processInfo.processIdentifier;
    NSMutableArray<MLTaskbarItem *> *targets = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (MLTaskbarScreenBar *bar in self.bars) {
        for (MLTaskbarItem *item in bar.barView.items) {
            if (item.kind != MLTaskbarItemRunningWindow || item.windowID == 0) {
                continue;
            }
            if (item.pid == selfPid || [seen containsObject:@(item.windowID)]) {
                continue;
            }
            if ([self isItemSoftHiddenOrMinimized:item]) {
                continue;
            }
            [seen addObject:@(item.windowID)];
            MLTaskbarItem *copy = [self copyItemForShowDesktopSession:item];
            if (copy) {
                [targets addObject:copy];
            }
        }
    }

    if (targets.count == 0) {
        [self clearShowDesktopSession];
        return;
    }

    NSDictionary<NSNumber *, NSValue *> *framesByWid = [self cocoaFramesByWindowIDs:seen];
    NSDictionary<NSNumber *, id> *axByWid = [self axWindowsByWindowIDForItems:targets];
    BOOL alphaAvail = MLCGSWindowAlphaAvailable();

    [self.showDesktopSessionItems removeAllObjects];
    [self.monitor.softState beginBatchUpdates];

    /* Pass 1: mark every window soft (chips stay) before mutating geometry. */
    for (MLTaskbarItem *item in targets) {
        NSRect frame = NSZeroRect;
        NSValue *frameVal = framesByWid[@(item.windowID)];
        if (frameVal) {
            frame = frameVal.rectValue;
        }
        AXUIElementRef win = (__bridge AXUIElementRef)axByWid[@(item.windowID)];
        if ((frame.size.width < 2.0 || frame.size.height < 2.0) && win) {
            [MLScreenGeometry readCocoaFrame:&frame fromAXWindow:win];
        }
        if (frame.size.width < 2.0 || frame.size.height < 2.0) {
            continue;
        }

        CGWindowID wid = item.windowID;
        [self rememberWindowForCustomMinimizePID:item.pid
                                           title:item.title ?: @""
                                          bounds:NSRectToCGRect(frame)
                                        windowID:wid];

        NSScreen *screen = [MLScreenGeometry screenForCocoaRect:frame];
        NSNumber *screenID = [MLScreenGeometry screenIDForScreen:screen];
        NSString *path = item.path;
        if (path.length == 0 && item.pid > 0) {
            NSRunningApplication *app =
                [NSRunningApplication runningApplicationWithProcessIdentifier:item.pid];
            path = app.bundleURL.path;
        }

        [self.monitor markSoftHiddenWindowID:wid
                                         pid:item.pid
                                        path:path
                                       title:item.title ?: @""
                               restoreFrame:frame
                                   screenID:screenID
                                   axWindow:win];
        [self.monitor.softState updateHideMethod:MLWindowHideMethodParked forWindowID:wid];
        [self.showDesktopSessionItems addObject:item];
    }

    /* Pass 2: alpha + park in one tight loop — all windows vanish together. */
    for (MLTaskbarItem *item in self.showDesktopSessionItems) {
        CGWindowID wid = item.windowID;
        if (wid == 0) {
            continue;
        }
        if (alphaAvail) {
            MLCGSSetWindowAlphaUnverified(wid, 0.0f);
        }
        AXUIElementRef win = (__bridge AXUIElementRef)axByWid[@(wid)];
        if (!win) {
            continue;
        }
        MLWindowSoftRecord *rec = [self.monitor.softState recordForWindowID:wid];
        NSSize sz = rec ? rec.restoreFrameCocoa.size : NSMakeSize(100, 100);
        [self parkAXWindowOffScreen:win keepingSize:sz];
    }

    [self.monitor.softState endBatchUpdates];

    if (self.showDesktopSessionItems.count == 0) {
        [self clearShowDesktopSession];
        return;
    }

    self.showDesktopSessionActive = YES;
    [self syncShowDesktopButtonAppearance];
}

- (void)restoreShowDesktopSession {
    NSArray<MLTaskbarItem *> *items = [self.showDesktopSessionItems copy];
    [self clearShowDesktopSession];

    if (self.itemsFrozenForDesktopReveal || self.desktopPeekUserArmed) {
        [self unfreezeDesktopRevealAndRefresh];
    }

    if (items.count == 0) {
        return;
    }

    NSDictionary<NSNumber *, id> *axByWid = [self axWindowsByWindowIDForItems:items];
    BOOL alphaAvail = MLCGSWindowAlphaAvailable();

    [self.monitor.softState beginBatchUpdates];

    /* Pass 1: restore alpha + frames for every window in one burst (no per-app activate). */
    for (MLTaskbarItem *item in items) {
        CGWindowID wid = item.windowID;
        if (wid == 0) {
            continue;
        }
        MLWindowSoftRecord *rec = [self.monitor.softState recordForWindowID:wid];
        NSRect restore = rec ? rec.restoreFrameCocoa : NSZeroRect;

        if (alphaAvail) {
            MLCGSSetWindowAlphaUnverified(wid, 1.0f);
        }

        AXUIElementRef win = (__bridge AXUIElementRef)axByWid[@(wid)];
        if (!win && rec.axWindow) {
            win = rec.axWindow;
        }
        if (win && restore.size.width >= 2.0 && restore.size.height >= 2.0) {
            [MLScreenGeometry applyCocoaFrame:restore toAXWindow:win];
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanFalse);
        } else if (win) {
            AXUIElementSetAttributeValue(win, kAXMinimizedAttribute, kCFBooleanFalse);
        }
    }

    /* Pass 2: raise all (still no activate thrash). */
    for (MLTaskbarItem *item in [items reverseObjectEnumerator]) {
        CGWindowID wid = item.windowID;
        AXUIElementRef win = (__bridge AXUIElementRef)axByWid[@(wid)];
        MLWindowSoftRecord *rec = wid != 0 ? [self.monitor.softState recordForWindowID:wid] : nil;
        if (!win && rec.axWindow) {
            win = rec.axWindow;
        }
        if (win) {
            AXUIElementPerformAction(win, kAXRaiseAction);
        }
    }

    /* Pass 3: drop soft marks together — one notify / rebuild. */
    for (MLTaskbarItem *item in items) {
        if (item.windowID != 0) {
            [self.monitor.softState clearVerifiedWindowID:item.windowID];
        }
    }
    [self.monitor.softState endBatchUpdates];

    /* Focus only one app so restore does not cascade activates. */
    MLTaskbarItem *front = items.lastObject;
    if (front) {
        [self activateApplicationForItem:front];
        [self touchActivationMRUForItem:front];
    }

    [self rebuildItemsImmediate:YES];
}

- (void)taskbarViewDidClickShowDesktopButton:(MLTaskbarView *)view {
    (void)view;
    if (self.showDesktopSessionActive) {
        [self restoreShowDesktopSession];
    } else {
        [self enterShowDesktopSession];
    }
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
        case MLTaskbarMenuActionSearchButtonToggle:
            if ([self.appActions respondsToSelector:@selector(taskbarToggleSearchButtonVisibility)]) {
                [self.appActions taskbarToggleSearchButtonVisibility];
            }
            return;
        case MLTaskbarMenuActionShowDesktopButtonToggle:
            if ([self.appActions respondsToSelector:@selector(taskbarToggleShowDesktopButtonVisibility)]) {
                [self.appActions taskbarToggleShowDesktopButtonVisibility];
            }
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
        case MLTaskbarMenuActionHideChipToggle:
            if (item.path.length == 0 || !self.hideStore) {
                break;
            }
            if ([self.hideStore isHidden:item.path]) {
                [self.hideStore unhidePath:item.path];
            } else {
                [self.hideStore hidePath:item.path];
            }
            break;
        case MLTaskbarMenuActionAudioMuteToggle:
            [self toggleAudioMuteForItem:item];
            break;
        default:
            break;
    }
}

@end
