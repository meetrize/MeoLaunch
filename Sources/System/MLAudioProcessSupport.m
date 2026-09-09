#import "MLAudioProcessSupport.h"

#import <AppKit/AppKit.h>
#import <libproc.h>
#import <sys/sysctl.h>

@implementation MLAudioProcessInfo

- (instancetype)initWithObjectID:(AudioObjectID)objectID
                             pid:(pid_t)pid
                        bundleID:(NSString *)bundleID
                isRunningOutput:(BOOL)isRunningOutput {
    self = [super init];
    if (!self) {
        return nil;
    }
    _objectID = objectID;
    _pid = pid;
    _bundleID = [bundleID copy];
    _isRunningOutput = isRunningOutput;
    return self;
}

@end

@implementation MLAudioProcessSupport

+ (BOOL)isAvailable {
    if (@available(macOS 14.2, *)) {
        return YES;
    }
    return NO;
}

static BOOL MLAudioGetUInt32(AudioObjectID object,
                             AudioObjectPropertySelector selector,
                             UInt32 *outValue) {
    if (!outValue) {
        return NO;
    }
    AudioObjectPropertyAddress addr = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(UInt32);
    UInt32 value = 0;
    OSStatus st = AudioObjectGetPropertyData(object, &addr, 0, NULL, &size, &value);
    if (st != noErr) {
        return NO;
    }
    *outValue = value;
    return YES;
}

static BOOL MLAudioGetPID(AudioObjectID object, pid_t *outPid) {
    if (!outPid) {
        return NO;
    }
    AudioObjectPropertyAddress addr = {
        kAudioProcessPropertyPID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(pid_t);
    pid_t pid = 0;
    OSStatus st = AudioObjectGetPropertyData(object, &addr, 0, NULL, &size, &pid);
    if (st != noErr) {
        return NO;
    }
    *outPid = pid;
    return YES;
}

static NSString * _Nullable MLAudioCopyBundleID(AudioObjectID object) {
    AudioObjectPropertyAddress addr = {
        kAudioProcessPropertyBundleID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    CFStringRef cf = NULL;
    UInt32 size = sizeof(CFStringRef);
    OSStatus st = AudioObjectGetPropertyData(object, &addr, 0, NULL, &size, &cf);
    if (st != noErr || !cf) {
        return nil;
    }
    return CFBridgingRelease(cf);
}

static pid_t MLParentPID(pid_t pid) {
    if (pid <= 0) {
        return 0;
    }
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) {
        return 0;
    }
    return info.kp_eproc.e_ppid;
}

static NSString * _Nullable MLExecutablePathForPID(pid_t pid) {
    char path[PROC_PIDPATHINFO_MAXSIZE];
    memset(path, 0, sizeof(path));
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) {
        return nil;
    }
    return [NSString stringWithUTF8String:path];
}

/** Extract Foo.app path from …/Foo.app/Contents/… */
static NSString * _Nullable MLAppPathContainingExecutable(NSString *exePath) {
    if (exePath.length == 0) {
        return nil;
    }
    NSRange r = [exePath rangeOfString:@".app/"];
    if (r.location == NSNotFound) {
        return nil;
    }
    return [exePath substringToIndex:r.location + 4]; /* include .app */
}

static BOOL MLBundleIDLooksLikeHelper(NSString *bid) {
    if (bid.length == 0) {
        return YES;
    }
    if ([bid hasPrefix:@"com.apple.WebKit"]) {
        return YES;
    }
    if ([bid containsString:@".helper"] || [bid containsString:@".Helper"]) {
        return YES;
    }
    if ([bid hasSuffix:@".xpc"] || [bid containsString:@".xpc."]) {
        return YES;
    }
    if ([bid hasPrefix:@"com.github.Electron"]) {
        return YES;
    }
    return NO;
}

/** WebKit XPC localizedName is often "<Host> Graphics and Media". */
static NSString * _Nullable MLHostNameFromHelperLocalizedName(NSString *name) {
    if (name.length == 0) {
        return nil;
    }
    static NSArray<NSString *> *suffixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        suffixes = @[
            @" Graphics and Media",
            @" Web Content",
            @" Networking",
            @" 图形与媒体",
            @" 网页内容",
            @" 网络",
            @"网页内容", /* zh: “App”网页内容 — no leading space */
            @"图形与媒体",
            @"网络",
        ];
    });
    for (NSString *suf in suffixes) {
        if ([name hasSuffix:suf] && name.length > suf.length) {
            NSString *host = [name substringToIndex:name.length - suf.length];
            /* Strip curly/straight quotes used by zh Web Content titles. */
            host = [host stringByTrimmingCharactersInSet:
                    [NSCharacterSet characterSetWithCharactersInString:@"\"“”"]];
            host = [host stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (host.length > 0) {
                return host;
            }
        }
    }
    return nil;
}

static NSRunningApplication * _Nullable MLRegularAppMatchingHostName(NSString *hostName) {
    if (hostName.length == 0) {
        return nil;
    }
    for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
        if (app.activationPolicy != NSApplicationActivationPolicyRegular) {
            continue;
        }
        if (app.terminated || app.processIdentifier <= 0) {
            continue;
        }
        if ([app.localizedName isEqualToString:hostName]) {
            return app;
        }
        NSString *path = app.bundleURL.path;
        if (path.length > 0) {
            NSString *base = path.lastPathComponent.stringByDeletingPathExtension;
            if ([base isEqualToString:hostName]) {
                return app;
            }
        }
    }
    return nil;
}

/**
 * Resolve owning Regular app for an audio client pid.
 * Handles in-app helpers (path), WebKit XPC (localizedName), and parent walk.
 */
static void MLResolveOwnerForPID(pid_t pid,
                                 NSString * _Nullable caBundleID,
                                 NSString * _Nullable *outBundleID,
                                 NSString * _Nullable *outAppPath) {
    if (outBundleID) {
        *outBundleID = nil;
    }
    if (outAppPath) {
        *outAppPath = nil;
    }
    if (pid <= 0) {
        return;
    }

    NSRunningApplication *direct =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSString *bid = caBundleID.length > 0 ? caBundleID : direct.bundleIdentifier;
    NSString *exe = MLExecutablePathForPID(pid);
    NSString *embeddedApp = MLAppPathContainingExecutable(exe);

    /* 1) Executable lives inside Host.app (Chrome Helper, etc.) */
    if (embeddedApp.length > 0 &&
        ![embeddedApp containsString:@"/XPCServices/"] &&
        ![embeddedApp containsString:@"/Frameworks/"]) {
        NSBundle *bundle = [NSBundle bundleWithPath:embeddedApp];
        NSString *hostBid = bundle.bundleIdentifier;
        if (hostBid.length > 0) {
            if (outBundleID) {
                *outBundleID = hostBid;
            }
            if (outAppPath) {
                *outAppPath = embeddedApp;
            }
            return;
        }
    }

    /* 2) Regular app speaking as itself */
    if (direct && direct.activationPolicy == NSApplicationActivationPolicyRegular &&
        bid.length > 0 && !MLBundleIDLooksLikeHelper(bid)) {
        if (outBundleID) {
            *outBundleID = bid;
        }
        if (outAppPath) {
            *outAppPath = direct.bundleURL.path;
        }
        return;
    }

    /* 3) WebKit / helper localizedName → host Regular app */
    NSString *hostName = MLHostNameFromHelperLocalizedName(direct.localizedName);
    if (hostName.length > 0) {
        NSRunningApplication *host = MLRegularAppMatchingHostName(hostName);
        if (host) {
            if (outBundleID) {
                *outBundleID = host.bundleIdentifier;
            }
            if (outAppPath) {
                *outAppPath = host.bundleURL.path;
            }
            return;
        }
    }

    /* 4) Walk parents for a Regular app (Electron child procs). */
    pid_t cur = MLParentPID(pid);
    for (int i = 0; i < 8 && cur > 1; i++) {
        NSRunningApplication *parent =
            [NSRunningApplication runningApplicationWithProcessIdentifier:cur];
        if (parent && parent.activationPolicy == NSApplicationActivationPolicyRegular &&
            parent.bundleIdentifier.length > 0) {
            if (outBundleID) {
                *outBundleID = parent.bundleIdentifier;
            }
            if (outAppPath) {
                *outAppPath = parent.bundleURL.path;
            }
            return;
        }
        cur = MLParentPID(cur);
    }

    /* 5) Last resort: non-helper bundle id on the process itself */
    if (bid.length > 0 && !MLBundleIDLooksLikeHelper(bid)) {
        if (outBundleID) {
            *outBundleID = bid;
        }
        if (outAppPath && direct.bundleURL.path.length > 0) {
            *outAppPath = direct.bundleURL.path;
        }
    }
}

+ (AudioObjectID)processObjectIDForPID:(pid_t)pid {
    if (![self isAvailable] || pid <= 0) {
        return kAudioObjectUnknown;
    }
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID objectID = kAudioObjectUnknown;
    UInt32 size = sizeof(AudioObjectID);
    pid_t qualifier = pid;
    OSStatus st = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                             &addr,
                                             sizeof(pid_t),
                                             &qualifier,
                                             &size,
                                             &objectID);
    if (st != noErr) {
        return kAudioObjectUnknown;
    }
    return objectID;
}

+ (NSArray<MLAudioProcessInfo *> *)copyProcessInfos {
    if (![self isAvailable]) {
        return @[];
    }

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyProcessObjectList,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    OSStatus st = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize);
    if (st != noErr || dataSize == 0) {
        return @[];
    }

    UInt32 count = dataSize / sizeof(AudioObjectID);
    AudioObjectID *ids = (AudioObjectID *)calloc(count, sizeof(AudioObjectID));
    if (!ids) {
        return @[];
    }
    st = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &dataSize, ids);
    if (st != noErr) {
        free(ids);
        return @[];
    }
    count = dataSize / sizeof(AudioObjectID);

    NSMutableArray<MLAudioProcessInfo *> *out = [NSMutableArray arrayWithCapacity:count];
    for (UInt32 i = 0; i < count; i++) {
        AudioObjectID oid = ids[i];
        pid_t pid = 0;
        if (!MLAudioGetPID(oid, &pid) || pid <= 0) {
            continue;
        }
        UInt32 runningOut = 0;
        BOOL isOut = MLAudioGetUInt32(oid, kAudioProcessPropertyIsRunningOutput, &runningOut) && runningOut != 0;
        NSString *bundle = MLAudioCopyBundleID(oid);
        MLAudioProcessInfo *info =
            [[MLAudioProcessInfo alloc] initWithObjectID:oid
                                                     pid:pid
                                                bundleID:bundle
                                        isRunningOutput:isOut];
        [out addObject:info];
    }
    free(ids);
    return out;
}

+ (NSArray<NSNumber *> *)copyRunningOutputPIDsExcluding:(pid_t)selfPid {
    NSArray<MLAudioProcessInfo *> *infos = [self copyProcessInfos];
    NSMutableArray<NSNumber *> *pids = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];
    for (MLAudioProcessInfo *info in infos) {
        if (!info.isRunningOutput) {
            continue;
        }
        if (selfPid > 0 && info.pid == selfPid) {
            continue;
        }
        NSNumber *n = @(info.pid);
        if ([seen containsObject:n]) {
            continue;
        }
        [seen addObject:n];
        [pids addObject:n];
    }
    return pids;
}

+ (NSSet<NSString *> *)copyRunningOutputOwnerBundleIDsExcluding:(pid_t)selfPid {
    NSMutableSet<NSString *> *bids = [NSMutableSet set];
    for (MLAudioProcessInfo *info in [self copyProcessInfos]) {
        if (!info.isRunningOutput) {
            continue;
        }
        if (selfPid > 0 && info.pid == selfPid) {
            continue;
        }
        NSString *ownerBid = nil;
        NSString *ownerPath = nil;
        MLResolveOwnerForPID(info.pid, info.bundleID, &ownerBid, &ownerPath);
        if (ownerBid.length > 0) {
            [bids addObject:ownerBid];
        }
    }
    return bids;
}

+ (NSSet<NSString *> *)copyRunningOutputOwnerAppPathsExcluding:(pid_t)selfPid {
    NSMutableSet<NSString *> *paths = [NSMutableSet set];
    for (MLAudioProcessInfo *info in [self copyProcessInfos]) {
        if (!info.isRunningOutput) {
            continue;
        }
        if (selfPid > 0 && info.pid == selfPid) {
            continue;
        }
        NSString *ownerBid = nil;
        NSString *ownerPath = nil;
        MLResolveOwnerForPID(info.pid, info.bundleID, &ownerBid, &ownerPath);
        if (ownerPath.length > 0) {
            [paths addObject:ownerPath];
        }
    }
    return paths;
}

+ (NSArray<NSString *> *)copyOwnerBundleIDsForPID:(pid_t)pid bundleID:(NSString *)bundleID {
    NSString *ownerBid = nil;
    NSString *ownerPath = nil;
    MLResolveOwnerForPID(pid, bundleID, &ownerBid, &ownerPath);
    if (ownerBid.length > 0) {
        return @[ ownerBid ];
    }
    if (bundleID.length > 0 && !MLBundleIDLooksLikeHelper(bundleID)) {
        return @[ bundleID ];
    }
    return @[];
}

+ (NSArray<NSNumber *> *)copyProcessObjectIDsToMuteForPID:(pid_t)pid
                                                 bundleID:(NSString *)bundleID {
    NSMutableArray<NSNumber *> *objs = [NSMutableArray array];
    NSMutableSet<NSNumber *> *seen = [NSMutableSet set];

    NSString *targetBid = bundleID;
    NSString *targetPath = nil;
    if (pid > 0) {
        NSString *ob = nil;
        NSString *op = nil;
        MLResolveOwnerForPID(pid, bundleID, &ob, &op);
        if (ob.length > 0) {
            targetBid = ob;
        }
        targetPath = op;
    }
    if (targetPath.length == 0 && targetBid.length > 0) {
        for (NSRunningApplication *app in [NSWorkspace sharedWorkspace].runningApplications) {
            if ([app.bundleIdentifier isEqualToString:targetBid] &&
                app.activationPolicy == NSApplicationActivationPolicyRegular) {
                targetPath = app.bundleURL.path;
                break;
            }
        }
    }

    for (MLAudioProcessInfo *info in [self copyProcessInfos]) {
        BOOL match = NO;
        if (pid > 0 && info.pid == pid) {
            match = YES;
        } else {
            NSString *ownerBid = nil;
            NSString *ownerPath = nil;
            MLResolveOwnerForPID(info.pid, info.bundleID, &ownerBid, &ownerPath);
            if (targetBid.length > 0 && [ownerBid isEqualToString:targetBid]) {
                match = YES;
            } else if (targetPath.length > 0 && ownerPath.length > 0 &&
                       [ownerPath isEqualToString:targetPath]) {
                match = YES;
            } else if (targetBid.length > 0 && info.bundleID.length > 0 &&
                       [info.bundleID isEqualToString:targetBid]) {
                match = YES;
            }
        }
        if (!match) {
            continue;
        }
        NSNumber *n = @(info.objectID);
        if (![seen containsObject:n]) {
            [seen addObject:n];
            [objs addObject:n];
        }
    }

    if (objs.count == 0 && pid > 0) {
        AudioObjectID oid = [self processObjectIDForPID:pid];
        if (oid != kAudioObjectUnknown) {
            [objs addObject:@(oid)];
        }
    }
    return objs;
}

@end
