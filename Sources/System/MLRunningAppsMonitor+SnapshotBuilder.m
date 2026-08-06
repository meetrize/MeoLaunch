#import "MLRunningAppsMonitor+Private.h"

#import "MLAXWindowHelper.h"
#import "MLScreenGeometry.h"

#import <ApplicationServices/ApplicationServices.h>

@implementation MLRunningAppsMonitor (SnapshotBuilder)

- (BOOL)isIgnoredOwnerName:(NSString *)owner {
    if (owner.length == 0) {
        return NO;
    }
    static NSSet<NSString *> *ignored;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ignored = [NSSet setWithArray:@[
            @"Window Server",
            @"Dock",
            @"SystemUIServer",
            @"Control Center",
            @"Notification Center",
            @"Spotlight",
            @"loginwindow",
        ]];
    });
    return [ignored containsObject:owner];
}
- (MLTaskbarWindowInfo *)windowInfoFromCGDict:(CFDictionaryRef)info {
    if (!info) {
        return nil;
    }

    CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
    int layer = 0;
    if (layerRef) {
        CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
    }
    if (layer != 0) {
        return nil;
    }

    CGRect bounds = CGRectZero;
    CFDictionaryRef boundsDict = CFDictionaryGetValue(info, kCGWindowBounds);
    if (!boundsDict || !CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)) {
        return nil;
    }
    /* Drop tiny chrome / status scraps — not real taskbar windows */
    if (bounds.size.width < 100.0 || bounds.size.height < 80.0) {
        return nil;
    }

    CFNumberRef alphaRef = CFDictionaryGetValue(info, kCGWindowAlpha);
    if (alphaRef) {
        double alpha = 1.0;
        CFNumberGetValue(alphaRef, kCFNumberDoubleType, &alpha);
        if (alpha < 0.1) {
            return nil;
        }
    }

    CFStringRef ownerNameRef = CFDictionaryGetValue(info, kCGWindowOwnerName);
    if (ownerNameRef) {
        NSString *ownerName = (__bridge NSString *)ownerNameRef;
        if ([self isIgnoredOwnerName:ownerName]) {
            return nil;
        }
    }

    CFNumberRef pidRef = CFDictionaryGetValue(info, kCGWindowOwnerPID);
    pid_t pid = 0;
    if (pidRef) {
        CFNumberGetValue(pidRef, kCFNumberIntType, &pid);
    }
    if (pid <= 0) {
        return nil;
    }

    NSString *path = self.pidPathMap[@(pid)];
    if (path.length == 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (![self shouldTrackApplication:app]) {
            return nil;
        }
        path = app.bundleURL.path;
        if (path.length > 0) {
            self.pidPathMap[@(pid)] = path;
        }
    }
    if (path.length == 0) {
        return nil;
    }

    CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
    CGWindowID wid = 0;
    if (winRef) {
        CFNumberGetValue(winRef, kCFNumberIntType, &wid);
    }

    NSString *title = @"";
    CFStringRef nameRef = CFDictionaryGetValue(info, kCGWindowName);
    if (nameRef) {
        title = [self truncateTitle:(__bridge NSString *)nameRef];
    }
    /* Nameless small-ish panels are rarely useful; large nameless windows still count
       (titles often empty without Screen Recording). */
    if (title.length == 0 && (bounds.size.width < 200.0 || bounds.size.height < 150.0)) {
        return nil;
    }

    MLTaskbarWindowInfo *w = [[MLTaskbarWindowInfo alloc] init];
    w.path = path;
    w.pid = pid;
    w.windowID = wid;
    w.title = title;
    w.bundleID = nil;
    w.bounds = bounds;
    w.minimized = NO;
    return w;
}
- (void)appendOnScreenWindowsFromList:(CFArrayRef)list
                                 into:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                        seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                          withWindows:(NSMutableSet<NSString *> *)withWindows
                                  cap:(NSUInteger)cap {
    if (!list) {
        return;
    }
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count && windows.count < cap; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, i);
        MLTaskbarWindowInfo *w = [self windowInfoFromCGDict:info];
        if (!w) {
            continue;
        }
        if (w.windowID != 0 && [seen containsObject:@(w.windowID)]) {
            continue;
        }
        if (w.windowID != 0) {
            [seen addObject:@(w.windowID)];
            MLTaskbarWindowInfo *prev = self.lastSeenWindows[@(w.windowID)];
            if (prev && prev.seenOrder > 0) {
                w.seenOrder = prev.seenOrder;
            }
            if (w.title.length == 0 && prev.title.length > 0) {
                w.title = prev.title;
            }
        }
        [windows addObject:w];
        if (w.path.length > 0) {
            [withWindows addObject:w.path];
        }
    }
}
- (MLTaskbarWindowInfo *)copyWindowInfo:(MLTaskbarWindowInfo *)src minimized:(BOOL)minimized {
    MLTaskbarWindowInfo *w = [[MLTaskbarWindowInfo alloc] init];
    w.path = src.path;
    w.bundleID = src.bundleID;
    w.pid = src.pid;
    w.windowID = src.windowID;
    w.title = src.title;
    w.bounds = src.bounds;
    w.minimized = minimized;
    w.seenOrder = src.seenOrder;
    return w;
}
- (NSString *)appDisplayNameForPid:(pid_t)pid path:(NSString *)path {
    if (pid > 0) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (app.localizedName.length > 0) {
            return app.localizedName;
        }
    }
    if (path.length > 0) {
        return path.lastPathComponent.stringByDeletingPathExtension;
    }
    return @"";
}
- (BOOL)title:(NSString *)title isGenericForAppName:(NSString *)appName {
    if (title.length == 0) {
        return YES;
    }
    if (appName.length == 0) {
        return NO;
    }
    if ([title caseInsensitiveCompare:appName] == NSOrderedSame) {
        return YES;
    }
    /* "Google Chrome", "Cursor", "Code" etc. as sole title */
    return NO;
}
- (NSString *)preferredTaskTitleFromWindowTitle:(NSString *)title appName:(NSString *)appName {
    if (title.length == 0) {
        return @"";
    }
    NSString *t = title;
    if (appName.length > 0) {
        for (NSString *sep in @[ @" — ", @" – ", @" - " ]) {
            NSString *suffix = [sep stringByAppendingString:appName];
            if ([t hasSuffix:suffix] && t.length > suffix.length) {
                t = [t substringToIndex:t.length - suffix.length];
                break;
            }
        }
    }
    return t;
}
- (void)beginPollAXWindowsCache {
    [self endPollAXWindowsCache];
    self.pollAXWindowsByPid = [NSMutableDictionary dictionary];
}
- (void)endPollAXWindowsCache {
    for (NSValue *v in self.pollAXWindowsByPid.allValues) {
        CFArrayRef arr = (CFArrayRef)v.pointerValue;
        if (arr) {
            CFRelease(arr);
        }
    }
    [self.pollAXWindowsByPid removeAllObjects];
    self.pollAXWindowsByPid = nil;
}
- (CFArrayRef)axWindowsArrayForPID:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return NULL;
    }
    if (!self.pollAXWindowsByPid) {
        self.pollAXWindowsByPid = [NSMutableDictionary dictionary];
    }
    NSNumber *key = @(pid);
    NSValue *hit = self.pollAXWindowsByPid[key];
    if (hit) {
        return (CFArrayRef)hit.pointerValue;
    }
    AXUIElementRef appRef = AXUIElementCreateApplication(pid);
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
    CFArrayRef arr = (CFArrayRef)windowsRef;
    CFRetain(arr);
    CFRelease(windowsRef);
    self.pollAXWindowsByPid[key] = [NSValue valueWithPointer:(const void *)arr];
    return arr;
}
- (void)enrichTitlesFromAccessibility:(NSMutableArray<MLTaskbarWindowInfo *> *)windows {
    if (!windows.count || !AXIsProcessTrusted()) {
        return;
    }

    NSMutableDictionary<NSNumber *, NSMutableArray<MLTaskbarWindowInfo *> *> *needByPid =
        [NSMutableDictionary dictionary];
    for (MLTaskbarWindowInfo *w in windows) {
        if (w.windowID == 0 || w.pid <= 0) {
            continue;
        }
        NSString *appName = [self appDisplayNameForPid:w.pid path:w.path];
        if (![self title:w.title isGenericForAppName:appName]) {
            continue;
        }
        NSNumber *key = @(w.pid);
        NSMutableArray<MLTaskbarWindowInfo *> *arr = needByPid[key];
        if (!arr) {
            arr = [NSMutableArray array];
            needByPid[key] = arr;
        }
        [arr addObject:w];
    }
    if (needByPid.count == 0) {
        return;
    }

    for (NSNumber *pidNum in needByPid) {
        pid_t pid = (pid_t)pidNum.intValue;
        CFArrayRef axWindows = [self axWindowsArrayForPID:pid];
        if (!axWindows) {
            continue;
        }

        NSMutableDictionary<NSNumber *, NSString *> *titleByWid = [NSMutableDictionary dictionary];
        CFIndex count = CFArrayGetCount(axWindows);
        for (CFIndex i = 0; i < count; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
            if (wid == 0) {
                continue;
            }
            CFTypeRef titleRef = NULL;
            if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &titleRef) != kAXErrorSuccess ||
                !titleRef) {
                continue;
            }
            if (CFGetTypeID(titleRef) == CFStringGetTypeID()) {
                NSString *raw = [(__bridge NSString *)titleRef copy];
                if (raw.length > 0) {
                    titleByWid[@(wid)] = raw;
                }
            }
            CFRelease(titleRef);
        }

        NSArray<MLTaskbarWindowInfo *> *need = needByPid[pidNum];
        NSString *appName = [self appDisplayNameForPid:pid path:need.firstObject.path];
        for (MLTaskbarWindowInfo *w in need) {
            NSString *ax = titleByWid[@(w.windowID)];
            if (ax.length == 0) {
                continue;
            }
            NSString *doc = [self preferredTaskTitleFromWindowTitle:ax appName:appName];
            if (doc.length == 0) {
                doc = ax;
            }
            w.title = [self truncateTitle:doc];
            MLTaskbarWindowInfo *cached = self.lastSeenWindows[@(w.windowID)];
            if (cached) {
                cached.title = w.title;
            }
        }
    }
}
- (BOOL)title:(NSString *)a matchesTitle:(NSString *)b {
    if (a.length == 0 && b.length == 0) {
        return YES;
    }
    if (a.length == 0 || b.length == 0) {
        return NO;
    }
    if ([a isEqualToString:b]) {
        return YES;
    }
    return [a hasPrefix:b] || [b hasPrefix:a];
}
- (NSString *)dedupeKeyForWindow:(MLTaskbarWindowInfo *)w {
    if (w.windowID != 0) {
        return [NSString stringWithFormat:@"id:%u", (unsigned)w.windowID];
    }
    return [NSString stringWithFormat:@"p:%d|%@|%@", (int)w.pid, w.path ?: @"", w.title ?: @""];
}
- (NSArray<MLTaskbarWindowInfo *> *)dedupeWindows:(NSArray<MLTaskbarWindowInfo *> *)windows {
    NSMutableDictionary<NSString *, MLTaskbarWindowInfo *> *byKey = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *order = [NSMutableArray array];

    for (MLTaskbarWindowInfo *w in windows) {
        if (!w) {
            continue;
        }
        NSString *key = [self dedupeKeyForWindow:w];
        /* Also collapse AX (windowID=0) onto a cached id entry with same path+title */
        if (w.windowID == 0 && w.path.length > 0) {
            for (MLTaskbarWindowInfo *seen in self.lastSeenWindows.allValues) {
                if (![seen.path isEqualToString:w.path]) {
                    continue;
                }
                if (![self title:seen.title matchesTitle:w.title] && w.title.length > 0 && seen.title.length > 0) {
                    continue;
                }
                if (seen.windowID != 0) {
                    key = [NSString stringWithFormat:@"id:%u", (unsigned)seen.windowID];
                    if (w.seenOrder == 0) {
                        w.seenOrder = seen.seenOrder;
                    }
                    if (CGRectIsEmpty(w.bounds) || CGRectEqualToRect(w.bounds, CGRectZero)) {
                        w.bounds = seen.bounds;
                    }
                    w.windowID = seen.windowID;
                    break;
                }
            }
        }

        MLTaskbarWindowInfo *existing = byKey[key];
        if (!existing) {
            byKey[key] = w;
            [order addObject:key];
            continue;
        }
        /* Prefer non-minimized; otherwise keep existing (stable). */
        if (existing.minimized && !w.minimized) {
            NSUInteger ord = existing.seenOrder > 0 ? existing.seenOrder : w.seenOrder;
            w.seenOrder = ord;
            byKey[key] = w;
        } else if (existing.seenOrder == 0 && w.seenOrder > 0) {
            existing.seenOrder = w.seenOrder;
        } else if (w.seenOrder > 0 && existing.seenOrder > 0) {
            existing.seenOrder = MIN(existing.seenOrder, w.seenOrder);
        }
    }

    NSMutableArray<MLTaskbarWindowInfo *> *out = [NSMutableArray arrayWithCapacity:order.count];
    for (NSString *key in order) {
        MLTaskbarWindowInfo *w = byKey[key];
        if (w) {
            [out addObject:w];
        }
    }
    return out;
}
- (MLTaskbarWindowInfo *)cachedWindowMatchingPath:(NSString *)path title:(NSString *)title {
    MLTaskbarWindowInfo *best = nil;
    for (MLTaskbarWindowInfo *seen in self.lastSeenWindows.allValues) {
        if (path.length > 0 && ![seen.path isEqualToString:path]) {
            continue;
        }
        if (title.length == 0) {
            if (!best) {
                best = seen;
            }
            continue;
        }
        if ([seen.title isEqualToString:title] ||
            (seen.title.length > 0 && [title hasPrefix:seen.title]) ||
            (title.length > 0 && [seen.title hasPrefix:title])) {
            return seen;
        }
        if (!best) {
            best = seen;
        }
    }
    return best;
}
- (void)rememberOnScreenWindows:(NSArray<MLTaskbarWindowInfo *> *)windows {
    for (MLTaskbarWindowInfo *w in windows) {
        if (w.minimized || w.windowID == 0) {
            continue;
        }
        NSNumber *key = @(w.windowID);
        /* While soft-hidden, keep the frozen pre-minimize frame (screen + restore). */
        if ([self.softState isSoftHiddenWindowID:w.windowID]) {
            continue;
        }
        MLTaskbarWindowInfo *prev = self.lastSeenWindows[key];
        MLTaskbarWindowInfo *stored = [self copyWindowInfo:w minimized:NO];
        if (prev && prev.seenOrder > 0) {
            stored.seenOrder = prev.seenOrder;
        } else if (w.seenOrder > 0) {
            stored.seenOrder = w.seenOrder;
        } else {
            stored.seenOrder = self.nextSeenOrder++;
        }
        w.seenOrder = stored.seenOrder;
        self.lastSeenWindows[key] = stored;
    }
    NSArray<NSNumber *> *keys = self.lastSeenWindows.allKeys;
    for (NSNumber *key in keys) {
        if ([self.softState isSoftHiddenWindowID:(CGWindowID)key.unsignedIntValue]) {
            continue; /* soft chips survive pid-map blips */
        }
        MLTaskbarWindowInfo *seen = self.lastSeenWindows[key];
        if (seen.pid > 0 && !self.pidPathMap[@(seen.pid)]) {
            [self.lastSeenWindows removeObjectForKey:key];
        }
    }
}
- (void)appendMinimizedFromCacheAndOffscreenList:(CFArrayRef)all
                                            into:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                                   seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                                     withWindows:(NSMutableSet<NSString *> *)withWindows
                                             cap:(NSUInteger)cap {
    if (!all || self.lastSeenWindows.count == 0) {
        return;
    }

    NSMutableSet<NSNumber *> *offscreenIDs = [NSMutableSet set];
    CFIndex count = CFArrayGetCount(all);
    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(all, i);
        if (!info) {
            continue;
        }
        CFBooleanRef onScreenRef = CFDictionaryGetValue(info, kCGWindowIsOnscreen);
        if (onScreenRef && CFGetTypeID(onScreenRef) == CFBooleanGetTypeID() &&
            CFBooleanGetValue(onScreenRef)) {
            continue;
        }
        CFNumberRef layerRef = CFDictionaryGetValue(info, kCGWindowLayer);
        int layer = 0;
        if (layerRef) {
            CFNumberGetValue(layerRef, kCFNumberIntType, &layer);
        }
        if (layer != 0) {
            continue;
        }
        CFNumberRef winRef = CFDictionaryGetValue(info, kCGWindowNumber);
        CGWindowID wid = 0;
        if (winRef) {
            CFNumberGetValue(winRef, kCFNumberIntType, &wid);
        }
        if (wid == 0) {
            continue;
        }
        [offscreenIDs addObject:@(wid)];
    }

    NSMutableDictionary<NSNumber *, NSSet<NSNumber *> *> *axMinByPid = [NSMutableDictionary dictionary];

    for (NSNumber *widNum in self.lastSeenWindows.allKeys) {
        if (windows.count >= cap) {
            break;
        }
        if ([seen containsObject:widNum]) {
            continue; /* still on-screen */
        }
        if (![offscreenIDs containsObject:widNum]) {
            continue; /* not in CG off-screen list */
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[widNum];
        if (!cached || cached.path.length == 0) {
            continue;
        }
        if (cached.pid > 0 && !self.pidPathMap[@(cached.pid)]) {
            [self.lastSeenWindows removeObjectForKey:widNum];
            continue;
        }

        if ([self.softState isSoftHiddenWindowID:(CGWindowID)widNum.unsignedIntValue]) {
            MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
            NSRect rf = [self.softState restoreFrameForWindowID:(CGWindowID)widNum.unsignedIntValue];
            if (rf.size.width > 2.0 && rf.size.height > 2.0) {
                w.bounds = NSRectToCGRect(rf);
            }
            [windows addObject:w];
            [seen addObject:widNum];
            [withWindows addObject:w.path];
            continue;
        }

        NSNumber *pidKey = @(cached.pid);
        NSSet<NSNumber *> *axMin = axMinByPid[pidKey];
        if (!axMin) {
            axMin = [self axMinimizedWindowIDsForPID:cached.pid];
            axMinByPid[pidKey] = axMin ?: [NSSet set];
            axMin = axMinByPid[pidKey];
        }
        if (![axMin containsObject:widNum]) {
            /* Off-screen ghost (closed WeChat chat, etc.) — drop. */
            continue;
        }

        MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
        [windows addObject:w];
        [seen addObject:widNum];
        [withWindows addObject:w.path];
    }
}
- (void)appendMinimizedWindowsFromAccessibility:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                                    withWindows:(NSMutableSet<NSString *> *)withWindows
                                            cap:(NSUInteger)cap {
    if (!AXIsProcessTrusted()) {
        return;
    }

    CGRect fallbackBounds = NSRectToCGRect(NSScreen.mainScreen.frame);
    NSMutableSet<NSString *> *alreadyPathTitle = [NSMutableSet set];
    for (MLTaskbarWindowInfo *existing in windows) {
        if (existing.minimized) {
            [alreadyPathTitle addObject:[NSString stringWithFormat:@"%@\n%@", existing.path ?: @"", existing.title ?: @""]];
        }
    }

    NSArray<NSNumber *> *pids = self.pidPathMap.allKeys;
    for (NSNumber *pidNum in pids) {
        if (windows.count >= cap) {
            break;
        }
        pid_t pid = (pid_t)pidNum.intValue;
        NSString *path = self.pidPathMap[pidNum];
        if (path.length == 0 || pid <= 0) {
            continue;
        }

        CFArrayRef axWindows = [self axWindowsArrayForPID:pid];
        if (!axWindows) {
            continue;
        }

        CFIndex count = CFArrayGetCount(axWindows);
        for (CFIndex i = 0; i < count && windows.count < cap; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
            CFTypeRef minRef = NULL;
            Boolean isMin = false;
            if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess && minRef) {
                if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                    isMin = CFBooleanGetValue((CFBooleanRef)minRef);
                }
                CFRelease(minRef);
            }
            if (!isMin) {
                continue;
            }

            NSString *title = @"";
            CFTypeRef titleRef = NULL;
            if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, &titleRef) == kAXErrorSuccess && titleRef) {
                if (CFGetTypeID(titleRef) == CFStringGetTypeID()) {
                    title = [self truncateTitle:(__bridge NSString *)titleRef];
                }
                CFRelease(titleRef);
            }

            NSString *dedupe = [NSString stringWithFormat:@"%@\n%@", path, title];
            if ([alreadyPathTitle containsObject:dedupe]) {
                continue;
            }

            CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
            /* Prefer cache by real window id — never glue a closed chat's stale id onto another window. */
            MLTaskbarWindowInfo *cached = (wid != 0) ? self.lastSeenWindows[@(wid)] : nil;
            if (!cached) {
                cached = [self cachedWindowMatchingPath:path title:title];
                /* Title-only match is for bounds hint only; don't reuse a different windowID. */
                if (cached && wid != 0 && cached.windowID != 0 && cached.windowID != wid) {
                    cached = nil;
                }
            }
            CGRect bounds = cached ? cached.bounds : fallbackBounds;
            if (wid == 0 && cached) {
                wid = cached.windowID;
            }

            if ((!cached || CGRectIsEmpty(bounds)) && (CGRectEqualToRect(bounds, fallbackBounds) || !cached)) {
                CFTypeRef posRef = NULL;
                CFTypeRef sizeRef = NULL;
                CGPoint pos = CGPointZero;
                CGSize size = CGSizeZero;
                BOOL havePos = NO;
                BOOL haveSize = NO;
                if (AXUIElementCopyAttributeValue(win, kAXPositionAttribute, &posRef) == kAXErrorSuccess && posRef) {
                    havePos = AXValueGetValue((AXValueRef)posRef, (AXValueType)kAXValueCGPointType, &pos);
                    CFRelease(posRef);
                }
                if (AXUIElementCopyAttributeValue(win, kAXSizeAttribute, &sizeRef) == kAXErrorSuccess && sizeRef) {
                    haveSize = AXValueGetValue((AXValueRef)sizeRef, (AXValueType)kAXValueCGSizeType, &size);
                    CFRelease(sizeRef);
                }
                if (havePos && haveSize && size.width >= 2.0 && size.height >= 2.0) {
                    NSRect main = NSScreen.mainScreen.frame;
                    CGFloat cocoaY = NSMaxY(main) - pos.y - size.height;
                    bounds = CGRectMake(pos.x, cocoaY, size.width, size.height);
                }
            }

            MLTaskbarWindowInfo *w = [[MLTaskbarWindowInfo alloc] init];
            w.path = path;
            w.pid = pid;
            w.windowID = wid;
            w.title = title.length > 0 ? title : (cached.title ?: @"");
            w.bounds = bounds;
            w.minimized = YES;
            w.seenOrder = cached && cached.seenOrder > 0 ? cached.seenOrder : self.nextSeenOrder++;
            [windows addObject:w];
            [alreadyPathTitle addObject:dedupe];
            [withWindows addObject:path];
        }
    }
}
- (NSSet<NSNumber *> *)axAllWindowIDsForPID:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return [NSSet set];
    }
    CFArrayRef axWindows = [self axWindowsArrayForPID:pid];
    if (!axWindows) {
        return [NSSet set];
    }
    NSMutableSet<NSNumber *> *out = [NSMutableSet set];
    CFIndex count = CFArrayGetCount(axWindows);
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
        CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
        if (wid != 0) {
            [out addObject:@(wid)];
        }
    }
    return out;
}
- (void)removeCGGhostWindowsNotInAccessibility:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                                 seenWindowIDs:(NSMutableSet<NSNumber *> *)seen {
    if (!windows.count || !AXIsProcessTrusted()) {
        return;
    }
    NSMutableDictionary<NSNumber *, NSMutableArray<MLTaskbarWindowInfo *> *> *byPid =
        [NSMutableDictionary dictionary];
    for (MLTaskbarWindowInfo *w in windows) {
        if (w.windowID == 0 || w.pid <= 0 || w.minimized) {
            continue;
        }
        if ([self.softState isSoftHiddenWindowID:w.windowID]) {
            continue;
        }
        NSNumber *key = @(w.pid);
        NSMutableArray *arr = byPid[key];
        if (!arr) {
            arr = [NSMutableArray array];
            byPid[key] = arr;
        }
        [arr addObject:w];
    }
    if (byPid.count == 0) {
        return;
    }

    NSMutableSet<MLTaskbarWindowInfo *> *drop = [NSMutableSet set];
    for (NSNumber *pidNum in byPid) {
        NSSet<NSNumber *> *axIDs = [self axAllWindowIDsForPID:(pid_t)pidNum.intValue];
        if (axIDs.count == 0) {
            continue; /* AX gave nothing — don't purge */
        }
        for (MLTaskbarWindowInfo *w in byPid[pidNum]) {
            if (![axIDs containsObject:@(w.windowID)]) {
                [drop addObject:w];
                [seen removeObject:@(w.windowID)];
                /* Never clear soft-hidden here — chip survival is SoftState's job. */
                if (![self.softState isSoftHiddenWindowID:w.windowID]) {
                    [self.lastSeenWindows removeObjectForKey:@(w.windowID)];
                }
            }
        }
    }
    if (drop.count > 0) {
        [windows removeObjectsInArray:drop.allObjects];
    }
}
- (NSSet<NSNumber *> *)axMinimizedWindowIDsForPID:(pid_t)pid {
    if (pid <= 0 || !AXIsProcessTrusted()) {
        return [NSSet set];
    }
    CFArrayRef axWindows = [self axWindowsArrayForPID:pid];
    if (!axWindows) {
        return [NSSet set];
    }
    NSMutableSet<NSNumber *> *out = [NSMutableSet set];
    CFIndex count = CFArrayGetCount(axWindows);
    for (CFIndex i = 0; i < count; i++) {
        AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(axWindows, i);
        CFTypeRef minRef = NULL;
        Boolean isMin = false;
        if (AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute, &minRef) == kAXErrorSuccess &&
            minRef) {
            if (CFGetTypeID(minRef) == CFBooleanGetTypeID()) {
                isMin = CFBooleanGetValue((CFBooleanRef)minRef);
            }
            CFRelease(minRef);
        }
        if (!isMin) {
            continue;
        }
        CGWindowID wid = [MLAXWindowHelper windowIDForAXWindow:win];
        if (wid != 0) {
            [out addObject:@(wid)];
        }
    }
    return out;
}
- (void)appendMinimizedFromCacheWhenVanished:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                               seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                                 withWindows:(NSMutableSet<NSString *> *)withWindows
                                         cap:(NSUInteger)cap
                                    aliveIDs:(NSSet<NSNumber *> *)aliveIDs {
    NSMutableDictionary<NSNumber *, NSSet<NSNumber *> *> *axMinByPid = [NSMutableDictionary dictionary];

    for (NSNumber *widNum in self.lastSeenWindows.allKeys) {
        if (windows.count >= cap) {
            break;
        }
        if ([seen containsObject:widNum]) {
            continue;
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[widNum];
        if (!cached || cached.pid <= 0 || !self.pidPathMap[@(cached.pid)]) {
            continue;
        }
        /* Still present off-screen in CG — handled earlier */
        if ([aliveIDs containsObject:widNum]) {
            continue;
        }

        /* Our custom soft-minimize always keeps the chip. */
        if ([self.softState isSoftHiddenWindowID:(CGWindowID)widNum.unsignedIntValue]) {
            MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
            NSRect rf = [self.softState restoreFrameForWindowID:(CGWindowID)widNum.unsignedIntValue];
            if (rf.size.width > 2.0 && rf.size.height > 2.0) {
                w.bounds = NSRectToCGRect(rf);
            }
            [windows addObject:w];
            [seen addObject:widNum];
            if (w.path.length > 0) {
                [withWindows addObject:w.path];
            }
            continue;
        }

        /* Closed windows vanish from CG — do NOT revive them just because another
           window of the same app (e.g. WeChat) is minimized. */
        NSNumber *pidKey = @(cached.pid);
        NSSet<NSNumber *> *axMin = axMinByPid[pidKey];
        if (!axMin) {
            axMin = [self axMinimizedWindowIDsForPID:cached.pid];
            axMinByPid[pidKey] = axMin ?: [NSSet set];
            axMin = axMinByPid[pidKey];
        }
        if (![axMin containsObject:widNum]) {
            continue;
        }

        MLTaskbarWindowInfo *w = [self copyWindowInfo:cached minimized:YES];
        [windows addObject:w];
        [seen addObject:widNum];
        if (w.path.length > 0) {
            [withWindows addObject:w.path];
        }
    }
}
- (void)pruneClosedCachedWindows:(NSSet<NSNumber *> *)aliveIDs
                     onScreenIDs:(NSSet<NSNumber *> *)onScreenIDs {
    (void)aliveIDs;
    NSMutableDictionary<NSNumber *, NSSet<NSNumber *> *> *axMinByPid = [NSMutableDictionary dictionary];
    NSArray<NSNumber *> *keys = self.lastSeenWindows.allKeys;
    for (NSNumber *key in keys) {
        if ([self.softState isSoftHiddenWindowID:(CGWindowID)key.unsignedIntValue]) {
            continue; /* absolute soft protection */
        }
        if (onScreenIDs && [onScreenIDs containsObject:key]) {
            continue;
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[key];
        if (!cached || cached.pid <= 0 || !self.pidPathMap[@(cached.pid)]) {
            [self.lastSeenWindows removeObjectForKey:key];
            continue;
        }
        NSNumber *pidKey = @(cached.pid);
        NSSet<NSNumber *> *axMin = axMinByPid[pidKey];
        if (!axMin) {
            axMin = [self axMinimizedWindowIDsForPID:cached.pid];
            axMinByPid[pidKey] = axMin ?: [NSSet set];
            axMin = axMinByPid[pidKey];
        }
        if ([axMin containsObject:key]) {
            continue;
        }
        [self.lastSeenWindows removeObjectForKey:key];
    }
}
- (void)pollWindows {
    [self pollWindowsWithOptions:MLPollOptionNone];
}
- (void)pollWindowsWithOptions:(MLPollOptions)options {
    /* Always scope AX windows cache for this poll so Fast-path helpers cannot retain forever. */
    [self beginPollAXWindowsCache];
    if ((options & MLPollOptionSkipPidRebuild) == 0) {
        [self rebuildPidMapFromWorkspace];
    }
    NSArray<NSString *> *runningPaths = [self orderedRunningPaths];

    NSMutableArray<MLTaskbarWindowInfo *> *windows = [NSMutableArray array];
    NSMutableSet<NSString *> *withWindows = [NSMutableSet set];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];

    NSUInteger screenCount = MAX(1u, (NSUInteger)NSScreen.screens.count);
    NSUInteger perScreen = self.maxWindowEntries > 0 ? self.maxWindowEntries : MLTaskbarMaxWindowEntries;
    NSUInteger cap = perScreen * screenCount;

    CFArrayRef onScreen = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
                                                         kCGWindowListExcludeDesktopElements,
                                                     kCGNullWindowID);
    [self appendOnScreenWindowsFromList:onScreen
                                   into:windows
                          seenWindowIDs:seen
                            withWindows:withWindows
                                    cap:cap];
    if (onScreen) {
        CFRelease(onScreen);
    }

    if ((options & MLPollOptionSkipGhostSweep) == 0) {
        [self removeCGGhostWindowsNotInAccessibility:windows seenWindowIDs:seen];
    }

    NSSet<NSNumber *> *onScreenIDs = [seen copy];

    if ((options & MLPollOptionSkipTitleEnrich) == 0) {
        [self enrichTitlesFromAccessibility:windows];
    }

    [self rememberOnScreenWindows:windows];

    CFArrayRef all = CGWindowListCopyWindowInfo(kCGWindowListOptionAll |
                                                    kCGWindowListExcludeDesktopElements,
                                                kCGNullWindowID);
    [self appendMinimizedFromCacheAndOffscreenList:all
                                              into:windows
                                     seenWindowIDs:seen
                                       withWindows:withWindows
                                               cap:cap];

    NSMutableSet<NSNumber *> *aliveIDs = [NSMutableSet setWithSet:seen];
    if (all) {
        CFIndex count = CFArrayGetCount(all);
        for (CFIndex i = 0; i < count; i++) {
            CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(all, i);
            CFNumberRef winRef = info ? CFDictionaryGetValue(info, kCGWindowNumber) : NULL;
            CGWindowID wid = 0;
            if (winRef) {
                CFNumberGetValue(winRef, kCFNumberIntType, &wid);
            }
            if (wid != 0) {
                [aliveIDs addObject:@(wid)];
            }
        }
        CFRelease(all);
    }

    [self appendSoftMinimizedWindows:windows
                       seenWindowIDs:seen
                         withWindows:withWindows
                                 cap:cap];

    [self appendMinimizedFromCacheWhenVanished:windows
                                 seenWindowIDs:seen
                                   withWindows:withWindows
                                           cap:cap
                                      aliveIDs:aliveIDs];

    if ((options & MLPollOptionSkipAXMinimizedBackup) == 0) {
        [self appendMinimizedWindowsFromAccessibility:windows withWindows:withWindows cap:cap];
        if ((options & MLPollOptionSkipTitleEnrich) == 0) {
            [self enrichTitlesFromAccessibility:windows];
        }
    }

    [self pruneClosedCachedWindows:aliveIDs onScreenIDs:onScreenIDs];

    NSArray<MLTaskbarWindowInfo *> *deduped = [self dedupeWindows:windows];

    MLRunningAppsSnapshot *snap = [[MLRunningAppsSnapshot alloc] init];
    snap.runningAppPaths = runningPaths;
    snap.pathsWithVisibleWindows = [withWindows copy];
    snap.windows = deduped;
    snap.pidToPath = [self.pidPathMap copy];

    NSString *fp = [self fingerprintForPaths:runningPaths windows:deduped];
    if ([fp isEqualToString:self.lastFingerprint]) {
        self.snapshot = snap;
        /* Keep census in sync even when snapshot fingerprint is unchanged. */
        self.lastCensusToken = [self computeWindowCensusToken];
        [self endPollAXWindowsCache];
        [self updateFocusPollTimer];
        return;
    }
    [self publishSnapshot:snap fingerprint:fp];
    self.lastCensusToken = [self computeWindowCensusToken];
    [self endPollAXWindowsCache];
}
- (void)appendSoftMinimizedWindows:(NSMutableArray<MLTaskbarWindowInfo *> *)windows
                     seenWindowIDs:(NSMutableSet<NSNumber *> *)seen
                       withWindows:(NSMutableSet<NSString *> *)withWindows
                               cap:(NSUInteger)cap {
    for (MLWindowSoftRecord *rec in self.softState.allRecords) {
        if (windows.count >= cap) {
            break;
        }
        NSNumber *widNum = @(rec.windowID);
        if ([seen containsObject:widNum]) {
            continue;
        }
        MLTaskbarWindowInfo *cached = self.lastSeenWindows[widNum];
        MLTaskbarWindowInfo *w = nil;
        if (cached) {
            w = [self copyWindowInfo:cached minimized:YES];
        } else {
            w = [[MLTaskbarWindowInfo alloc] init];
            w.windowID = rec.windowID;
            w.pid = rec.pid;
            w.path = rec.path;
            w.title = rec.title ?: @"";
            w.seenOrder = rec.seenOrder;
            w.minimized = YES;
        }
        if (w.path.length == 0) {
            continue;
        }
        if (rec.restoreFrameCocoa.size.width > 2.0) {
            w.bounds = NSRectToCGRect(rec.restoreFrameCocoa);
        }
        if (rec.seenOrder > 0) {
            w.seenOrder = rec.seenOrder;
        }
        w.minimized = YES;
        [windows addObject:w];
        [seen addObject:widNum];
        [withWindows addObject:w.path];
        /* Ensure lastSeen keeps affinity for later polls. */
        if (!self.lastSeenWindows[widNum]) {
            self.lastSeenWindows[widNum] = [self copyWindowInfo:w minimized:YES];
        }
    }
}

@end
