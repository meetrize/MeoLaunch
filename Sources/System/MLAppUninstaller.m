#import "MLAppUninstaller.h"

#import <AppKit/AppKit.h>

@implementation MLAppUninstaller

+ (NSString *)standardizedPath:(NSString *)path {
    if (path.length == 0) {
        return @"";
    }
    return path.stringByExpandingTildeInPath.stringByStandardizingPath;
}

+ (BOOL)isProtectedAppPath:(NSString *)path {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return YES;
    }

    NSArray<NSString *> *prefixes = @[
        @"/System",
        @"/Library/Apple",
        @"/usr",
        @"/bin",
        @"/sbin",
    ];
    for (NSString *prefix in prefixes) {
        if ([std isEqualToString:prefix] || [std hasPrefix:[prefix stringByAppendingString:@"/"]]) {
            return YES;
        }
    }

    NSString *selfPath = [NSBundle mainBundle].bundlePath.stringByStandardizingPath;
    if (selfPath.length && [std isEqualToString:selfPath]) {
        return YES;
    }
    return NO;
}

+ (BOOL)canAttemptUninstallAtPath:(NSString *)path {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return NO;
    }
    if ([self isProtectedAppPath:std]) {
        return NO;
    }
    if (![std.pathExtension.lowercaseString isEqualToString:@"app"]) {
        return NO;
    }
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:std isDirectory:&isDir] || !isDir) {
        return NO;
    }
    return YES;
}

+ (NSString *)displayNameAtPath:(NSString *)path {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return @"";
    }
    NSBundle *bundle = [NSBundle bundleWithPath:std];
    NSString *name = bundle.infoDictionary[(NSString *)kCFBundleNameKey];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        name = bundle.infoDictionary[@"CFBundleDisplayName"];
    }
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        name = std.lastPathComponent.stringByDeletingPathExtension;
    }
    return name ?: @"";
}

+ (NSString *)bundleIdentifierAtPath:(NSString *)path {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return @"";
    }
    NSString *bid = [NSBundle bundleWithPath:std].bundleIdentifier;
    return bid.length ? bid : @"";
}

+ (BOOL)isAppRunningAtPath:(NSString *)path {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return NO;
    }
    NSURL *url = [NSURL fileURLWithPath:std isDirectory:YES];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        NSURL *bundleURL = app.bundleURL;
        if (!bundleURL) {
            continue;
        }
        if ([bundleURL.URLByStandardizingPath.path isEqualToString:std] ||
            [bundleURL.path isEqualToString:std] ||
            [bundleURL isEqual:url]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)nameLooksLikeUninstaller:(NSString *)name {
    if (name.length == 0) {
        return NO;
    }
    NSString *fold = name.lowercaseString;
    if ([fold containsString:@"uninstall"]) {
        return YES;
    }
    if ([name containsString:@"卸载"]) {
        return YES;
    }
    return NO;
}

+ (nullable NSString *)pickUninstallerInDirectory:(NSString *)dir
                                   excludingPath:(NSString *)exclude {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *children = [fm contentsOfDirectoryAtPath:dir error:nil];
    if (!children) {
        return nil;
    }
    NSString *excludeStd = [self standardizedPath:exclude];
    for (NSString *child in children) {
        if (![child.pathExtension.lowercaseString isEqualToString:@"app"]) {
            continue;
        }
        if (![self nameLooksLikeUninstaller:child.stringByDeletingPathExtension] &&
            ![self nameLooksLikeUninstaller:child]) {
            continue;
        }
        NSString *full = [dir stringByAppendingPathComponent:child].stringByStandardizingPath;
        if (excludeStd.length && [full isEqualToString:excludeStd]) {
            continue;
        }
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            return full;
        }
    }
    return nil;
}

+ (nullable NSString *)findUninstallerNearAppAtPath:(NSString *)path {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return nil;
    }

    NSString *parent = std.stringByDeletingLastPathComponent;
    NSString *found = [self pickUninstallerInDirectory:parent excludingPath:std];
    if (found) {
        return found;
    }

    /* Common nested locations inside the bundle */
    NSArray<NSString *> *nested = @[
        @"Contents/Resources",
        @"Contents/Helpers",
        @"Contents/MacOS",
        @"",
    ];
    for (NSString *rel in nested) {
        NSString *dir = rel.length ? [std stringByAppendingPathComponent:rel] : std;
        found = [self pickUninstallerInDirectory:dir excludingPath:std];
        if (found) {
            return found;
        }
    }
    return nil;
}

+ (void)addLeftoverIfExists:(NSString *)candidate
                        into:(NSMutableArray<NSString *> *)out
                   excluding:(NSString *)appPath {
    if (candidate.length == 0) {
        return;
    }
    NSString *std = candidate.stringByExpandingTildeInPath.stringByStandardizingPath;
    if (std.length == 0 || [std isEqualToString:appPath]) {
        return;
    }
    if ([std hasPrefix:[appPath stringByAppendingString:@"/"]]) {
        return;
    }
    BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:std];
    if (!exists) {
        return;
    }
    if (![out containsObject:std]) {
        [out addObject:std];
    }
}

+ (NSArray<NSString *> *)discoverLeftoversAtPath:(NSString *)path {
    NSString *std = [self standardizedPath:path];
    if (std.length == 0) {
        return @[];
    }
    NSString *bid = [self bundleIdentifierAtPath:std];
    NSString *name = [self displayNameAtPath:std];
    NSString *homeLib = [@"~/Library" stringByExpandingTildeInPath];
    NSMutableArray<NSString *> *out = [NSMutableArray array];

    if (bid.length) {
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"Preferences/%@.plist", bid]]
                             into:out
                        excluding:std];
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"Caches/%@", bid]]
                             into:out
                        excluding:std];
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"Containers/%@", bid]]
                             into:out
                        excluding:std];
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"Saved Application State/%@.savedState", bid]]
                             into:out
                        excluding:std];
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"Application Support/%@", bid]]
                             into:out
                        excluding:std];
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"Logs/%@", bid]]
                             into:out
                        excluding:std];
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"WebKit/%@", bid]]
                             into:out
                        excluding:std];
    }

    if (name.length) {
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"Application Support/%@", name]]
                             into:out
                        excluding:std];
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"Caches/%@", name]]
                             into:out
                        excluding:std];
        [self addLeftoverIfExists:[homeLib stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"Logs/%@", name]]
                             into:out
                        excluding:std];
    }

    return out;
}

+ (BOOL)moveAppToTrashAtPath:(NSString *)path error:(NSError **)error {
    NSString *std = [self standardizedPath:path];
    if (![self canAttemptUninstallAtPath:std]) {
        if (error) {
            *error = [NSError errorWithDomain:@"MLAppUninstaller"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey : @"Protected or invalid app path"}];
        }
        return NO;
    }
    NSURL *url = [NSURL fileURLWithPath:std isDirectory:YES];
    NSError *local = nil;
    BOOL ok = [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:&local];
    if (!ok && error) {
        *error = local;
    }
    return ok;
}

+ (NSUInteger)movePathsToTrash:(NSArray<NSString *> *)paths {
    NSUInteger okCount = 0;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in paths) {
        NSString *std = [self standardizedPath:path];
        if (std.length == 0 || ![fm fileExistsAtPath:std]) {
            continue;
        }
        NSURL *url = [NSURL fileURLWithPath:std];
        if ([fm trashItemAtURL:url resultingItemURL:nil error:nil]) {
            okCount += 1;
        }
    }
    return okCount;
}

@end
