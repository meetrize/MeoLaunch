#import "MLCursorActivityMonitor.h"

#import <AppKit/AppKit.h>
#include <libproc.h>
#include <math.h>
#include <sys/stat.h>
#include <sys/sysctl.h>

NSNotificationName const MLCursorActivityDidChangeNotification =
    @"MLCursorActivityDidChangeNotification";

static NSString *const MLCursorBundleIdentifier = @"com.todesktop.230313mzl4w4u92";
static NSString *const MLCursorWorkspaceLabelKey = @"CURSOR_WORKSPACE_LABEL";
static NSString *const MLCursorExtensionHostRoleKey = @"CURSOR_EXTENSION_HOST_ROLE";

static const NSTimeInterval MLCursorScanInterval = 1.0;
static const NSTimeInterval MLCursorProcessCache = 3.0;
static const NSTimeInterval MLCursorGrowingWindow = 3.0;
static const NSTimeInterval MLCursorCatchUpGap = 2.5;
static const NSTimeInterval MLCursorAssistantGrace = 25.0;
static const NSTimeInterval MLCursorAgentExecWindow = 10.0 * 60.0;
static const NSTimeInterval MLCursorUserAwaitWindow = 45.0 * 60.0;
static const NSTimeInterval MLCursorSideWindow = 60.0;
static const NSTimeInterval MLCursorTerminalWindow = 30.0;
static const NSTimeInterval MLCursorTerminalFreshStart = 120.0;
static const NSTimeInterval MLCursorAgentStoreWindow = 20.0;
static const long long MLCursorAgentStoreGrowth = 2048;
static const NSTimeInterval MLCursorParentlessWindow = 180.0;
static const NSTimeInterval MLCursorActiveTurnWindow = 45.0 * 60.0;
static const NSUInteger MLCursorCandidateLimit = 12;
static const NSUInteger MLCursorSessionDirLimit = 20;
static const NSUInteger MLCursorTailBytes = 64 * 1024;

static NSString *MLCursorPathOverride(const char *name, NSString *fallback) {
    const char *value = getenv(name);
    if (value && value[0] != '\0') {
        return @(value);
    }
    return fallback;
}

static NSTimeInterval MLCursorNow(void) {
    return [NSDate date].timeIntervalSince1970;
}

static BOOL MLCursorReadStat(NSString *path, int64_t *size, NSTimeInterval *mtime) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) {
        return NO;
    }
    if (size) {
        *size = (int64_t)st.st_size;
    }
    if (mtime) {
        *mtime = (NSTimeInterval)st.st_mtimespec.tv_sec +
                 (NSTimeInterval)st.st_mtimespec.tv_nsec / 1000000000.0;
    }
    return YES;
}

static BOOL MLCursorIsASCIISpace(uint8_t c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

@class MLCursorTail;

@interface MLCursorFileSample : NSObject
@property (nonatomic, assign) int64_t size;
@property (nonatomic, assign) NSTimeInterval mtime;
@property (nonatomic, assign) NSTimeInterval sampledAt;
/** -1 when there is no active turn_ended anchor. */
@property (nonatomic, assign) int64_t sizeAtTurnEnded;
/** Cached tail so unchanged files are not re-read every second. */
@property (nonatomic, strong) MLCursorTail *tail;
@end

@implementation MLCursorFileSample
@end

@interface MLCursorTail : NSObject
@property (nonatomic, assign) BOOL sawTurnEnded;
@property (nonatomic, copy) NSString *endedStatus;
@property (nonatomic, copy) NSString *lastLineKind;
@property (nonatomic, assign) BOOL hasIncompleteTrailer;
@end

@implementation MLCursorTail
@end

@interface MLCursorActivityMonitor ()
@property (nonatomic, strong) dispatch_queue_t scanQueue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (atomic, assign) BOOL running;

@property (copy, readwrite) NSSet<NSString *> *busyLabels;
@property (copy, readwrite) NSSet<NSString *> *openLabels;

/** lowercased label -> roles (agent-exec / user / …). Scan queue only. */
@property (nonatomic, strong) NSDictionary<NSString *, NSSet<NSString *> *> *rolesByLabel;
@property (nonatomic, assign) NSTimeInterval lastProcessScan;
@property (nonatomic, assign) NSTimeInterval lastGoodLabelsAt;

@property (nonatomic, strong) NSMutableDictionary<NSString *, MLCursorFileSample *> *samples;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *agentStoreSizes;
@property (nonatomic, assign) NSTimeInterval lastPrune;

@property (nonatomic, copy) NSString *projectsRoot;
@property (nonatomic, copy) NSString *agentStoresRoot;
@end

@implementation MLCursorActivityMonitor

@synthesize busyLabels = _busyLabels;
@synthesize openLabels = _openLabels;

- (instancetype)init {
    self = [super init];
    if (self) {
        _scanQueue = dispatch_queue_create("com.meetrice.meolaunch.cursor-activity",
                                           DISPATCH_QUEUE_SERIAL);
        _busyLabels = [NSSet set];
        _openLabels = [NSSet set];
        _rolesByLabel = @{};
        _samples = [NSMutableDictionary dictionary];
        _agentStoreSizes = [NSMutableDictionary dictionary];
        _projectsRoot = MLCursorPathOverride(
            "ML_CURSOR_PROJECTS_ROOT",
            [NSHomeDirectory() stringByAppendingPathComponent:@".cursor/projects"]);
        _agentStoresRoot = MLCursorPathOverride(
            "ML_CURSOR_AGENT_STORES_ROOT",
            [NSHomeDirectory() stringByAppendingPathComponent:
                @"Library/Application Support/Cursor/AgentStores/cursor_agent_stores"]);
        _running = NO;
    }
    return self;
}

- (void)dealloc {
    dispatch_source_t timer = _timer;
    if (timer) {
        dispatch_source_cancel(timer);
        _timer = nil;
    }
}

- (void)start {
    if (self.running) {
        return;
    }
    self.running = YES;
    self.lastProcessScan = 0;
    self.lastGoodLabelsAt = 0;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     self.scanQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(MLCursorScanInterval * NSEC_PER_SEC),
                              (uint64_t)(0.2 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.running) {
            return;
        }
        [self scan];
    });
    self.timer = timer;
    dispatch_resume(timer);
}

- (void)stop {
    self.running = NO;
    dispatch_source_t timer = self.timer;
    if (timer) {
        dispatch_source_cancel(timer);
        self.timer = nil;
    }
    [self updateBusyLabels:[NSSet set] openLabels:[NSSet set]];
}

#pragma mark - Public state

- (BOOL)hasAnyBusy {
    return self.busyLabels.count > 0;
}

- (BOOL)isBusyForWindowTitle:(NSString *)title {
    if (title.length == 0) {
        return NO;
    }
    NSString *prefix = [self projectPrefixFromTitle:title];
    NSString *normalized =
        [[title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            lowercaseString];
    NSSet<NSString *> *busy = self.busyLabels;
    if (busy.count == 0) {
        return NO;
    }
    if (prefix.length > 0 && [busy containsObject:prefix]) {
        return YES;
    }
    for (NSString *label in busy) {
        if (label.length == 0) {
            continue;
        }
        if ((prefix.length > 0 &&
             ([self title:prefix startsWithLabel:label] ||
              [self title:prefix containsLabel:label])) ||
            [self title:normalized containsLabel:label]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)projectPrefixFromTitle:(NSString *)title {
    NSString *normalized =
        [[title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
            lowercaseString];
    NSArray<NSString *> *separators =
        @[ @" - ", @" — ", @" – ", @" | ", @" · ", @" —", @" –" ];
    NSUInteger best = NSNotFound;
    for (NSString *sep in separators) {
        NSRange range = [normalized rangeOfString:sep];
        if (range.location != NSNotFound &&
            (best == NSNotFound || range.location < best)) {
            best = range.location;
        }
    }
    if (best != NSNotFound) {
        return [[normalized substringToIndex:best]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return normalized;
}

- (BOOL)isLabelBoundary:(unichar)ch {
    return ch == ' ' || ch == '\t' || ch == '-' || ch == 0x2014 || ch == 0x2013 ||
           ch == 0x00B7 || ch == '|' || ch == '/' || ch == ':' || ch == '(' || ch == '[';
}

- (BOOL)title:(NSString *)title startsWithLabel:(NSString *)label {
    if (title.length <= label.length || ![title hasPrefix:label]) {
        return NO;
    }
    return [self isLabelBoundary:[title characterAtIndex:label.length]];
}

- (BOOL)title:(NSString *)title containsLabel:(NSString *)label {
    NSRange range = [title rangeOfString:label];
    if (range.location == NSNotFound || range.length == 0) {
        return NO;
    }
    BOOL leftOK = (range.location == 0) ||
                  [self isLabelBoundary:[title characterAtIndex:range.location - 1]];
    NSUInteger end = NSMaxRange(range);
    BOOL rightOK = (end >= title.length) ||
                   [self isLabelBoundary:[title characterAtIndex:end]];
    return leftOK && rightOK;
}

- (void)updateBusyLabels:(NSSet<NSString *> *)busy openLabels:(NSSet<NSString *> *)open {
    NSSet<NSString *> *old = self.busyLabels;
    BOOL changed = ![old isEqualToSet:busy];
    if (changed) {
        self.busyLabels = busy ?: [NSSet set];
    }
    self.openLabels = open ?: [NSSet set];
    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:MLCursorActivityDidChangeNotification
                              object:self];
        });
    }
}

#pragma mark - Scan

- (void)scan {
    if (!self.running) {
        return;
    }
    @autoreleasepool {
        NSArray<NSRunningApplication *> *apps =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:MLCursorBundleIdentifier];
        if (apps.count == 0) {
            self.rolesByLabel = @{};
            NSSet *empty = [NSSet set];
            [self updateBusyLabels:empty openLabels:empty];
            [self writeDebugSignalsWithOpen:empty busy:empty infos:@{}];
            return;
        }

        NSTimeInterval now = MLCursorNow();
        [self refreshProcessesIfNeededAt:now];
        NSSet<NSString *> *open = self.openLabels;
        if (open.count == 0) {
            NSSet *empty = [NSSet set];
            [self updateBusyLabels:empty openLabels:empty];
            [self writeDebugSignalsWithOpen:empty busy:empty infos:@{}];
            return;
        }

        NSDictionary<NSString *, NSArray<NSString *> *> *dirsByLabel =
            [self projectDirsByLabelWithOpenLabels:open];
        NSMutableSet<NSString *> *busy = [NSMutableSet set];
        NSMutableDictionary<NSString *, NSDictionary *> *infos = [NSMutableDictionary dictionary];
        for (NSString *label in dirsByLabel) {
            NSDictionary *info = nil;
            if ([self labelIsBusy:label projectDirs:dirsByLabel[label] now:now info:&info]) {
                [busy addObject:label];
            }
            if (info) {
                infos[label] = info;
            }
        }
        [self updateBusyLabels:busy openLabels:open];
        [self writeDebugSignalsWithOpen:open busy:busy infos:infos];
        [self pruneAt:now];
    }
}

- (void)refreshProcessesIfNeededAt:(NSTimeInterval)now {
    if (self.rolesByLabel.count > 0 && (now - self.lastProcessScan) < MLCursorProcessCache) {
        return;
    }
    self.lastProcessScan = now;
    NSDictionary<NSString *, NSSet<NSString *> *> *roles = [self scanCursorHosts];
    if (roles.count > 0) {
        self.rolesByLabel = roles;
        self.lastGoodLabelsAt = now;
        [self updateBusyLabels:self.busyLabels
                    openLabels:[NSSet setWithArray:roles.allKeys]];
        return;
    }
    /* A transient /proc read failure should not hide an open workspace. */
    if (self.rolesByLabel.count > 0 && (now - self.lastGoodLabelsAt) < 5.0) {
        return;
    }
    self.rolesByLabel = @{};
    [self updateBusyLabels:[NSSet set] openLabels:[NSSet set]];
}

- (NSDictionary<NSString *, NSArray<NSString *> *> *)projectDirsByLabelWithOpenLabels:
    (NSSet<NSString *> *)open {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *out =
        [NSMutableDictionary dictionary];
    NSArray<NSString *> *names =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.projectsRoot error:NULL];
    for (NSString *slug in names ?: @[]) {
        if ([slug hasPrefix:@"."]) {
            continue;
        }
        NSString *label = [self labelForSlug:slug openLabels:open];
        if (label.length == 0 || ![open containsObject:label]) {
            continue;
        }
        NSString *path = [self.projectsRoot stringByAppendingPathComponent:slug];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
            continue;
        }
        NSMutableArray *arr = out[label];
        if (!arr) {
            arr = [NSMutableArray array];
            out[label] = arr;
        }
        [arr addObject:path];
    }
    return out;
}

- (NSString *)labelForSlug:(NSString *)slug openLabels:(NSSet<NSString *> *)open {
    NSString *lowerSlug = slug.lowercaseString;
    NSString *best = nil;
    for (NSString *label in open) {
        if ([lowerSlug isEqualToString:label]) {
            return label;
        }
        NSString *needle = [@"-" stringByAppendingString:label];
        if ([lowerSlug hasSuffix:needle] &&
            (best.length == 0 || label.length > best.length)) {
            best = label;
        }
    }
    if (best.length > 0) {
        return best;
    }
    NSString *last = [[slug componentsSeparatedByString:@"-"] lastObject];
    return last.lowercaseString;
}

#pragma mark - Per-label busy fusion

- (BOOL)labelIsBusy:(NSString *)label
        projectDirs:(NSArray<NSString *> *)projectDirs
                now:(NSTimeInterval)now
               info:(NSDictionary **)info {
    NSMutableArray<NSString *> *sessionIDs = [NSMutableArray array];
    BOOL sideHot = NO;
    NSArray<NSDictionary *> *candidates =
        [self transcriptCandidatesForProjectDirs:projectDirs
                                         now:now
                                  sessionIDs:sessionIDs
                                     sideHot:&sideHot];

    __block BOOL anyGrowing = NO;
    __block NSDictionary *newest = nil;
    __block MLCursorTail *newestTail = nil;
    __block NSTimeInterval newestAge = INFINITY;
    __block BOOL newestOpenTurn = NO;

    for (NSDictionary *cand in candidates) {
        NSString *path = cand[@"path"];
        int64_t size = [cand[@"size"] longLongValue];
        NSTimeInterval mtime = [cand[@"mtime"] doubleValue];
        MLCursorTail *tail = cand[@"tail"];
        NSTimeInterval age = now - mtime;
        MLCursorFileSample *prev = self.samples[path];
        BOOL delta = prev && (size > prev.size || mtime > prev.mtime);
        NSTimeInterval sampleGap = prev ? (now - prev.sampledAt) : INFINITY;
        BOOL inspectOK = ![tail.lastLineKind isEqualToString:@"error"] &&
                         ![tail.lastLineKind isEqualToString:@"missing"];
        BOOL ended = tail.sawTurnEnded;
        BOOL incomplete = tail.hasIncompleteTrailer;
        BOOL assistant = [tail.lastLineKind isEqualToString:@"assistant"];
        BOOL user = [tail.lastLineKind isEqualToString:@"user"];

        BOOL softQuietAssistant = inspectOK && !ended && !incomplete && !delta && assistant &&
                                   age > MLCursorAssistantGrace;
        BOOL recentAssistant = inspectOK && !ended && !softQuietAssistant && assistant &&
                               age <= MLCursorAssistantGrace;
        BOOL awaitingReply = inspectOK && !ended && user && age <= MLCursorUserAwaitWindow;
        BOOL sideSustainsOpen = sideHot && inspectOK && !ended && !incomplete &&
                                (user || assistant) && age <= MLCursorAgentExecWindow;
        BOOL openTurn = inspectOK && !ended &&
                        (awaitingReply || recentAssistant || incomplete || sideSustainsOpen);
        BOOL hotGrowth = inspectOK && !ended && delta && age <= MLCursorGrowingWindow;
        BOOL catchUpGrowth = inspectOK && !ended && delta && sampleGap >= MLCursorCatchUpGap &&
                             age <= MLCursorActiveTurnWindow;
        BOOL postEndedGrowth = ended &&
                               (incomplete ||
                                (delta && prev && prev.sizeAtTurnEnded >= 0 &&
                                 size > prev.sizeAtTurnEnded &&
                                 age <= MLCursorGrowingWindow));
        BOOL bufferingAfterEnd = ended && incomplete;

        BOOL growing;
        if (softQuietAssistant && !sideSustainsOpen) {
            growing = NO;
        } else if (ended) {
            growing = postEndedGrowth || bufferingAfterEnd;
        } else if (!inspectOK) {
            growing = NO;
        } else {
            growing = openTurn || hotGrowth || catchUpGrowth || incomplete;
        }
        if (growing) {
            anyGrowing = YES;
        }

        int64_t nextEndedSize = -1;
        if (ended && !incomplete) {
            nextEndedSize = size;
        } else if (ended && prev && prev.sizeAtTurnEnded >= 0) {
            nextEndedSize = prev.sizeAtTurnEnded;
        }
        MLCursorFileSample *sample = [[MLCursorFileSample alloc] init];
        sample.size = size;
        sample.mtime = mtime;
        sample.sampledAt = now;
        sample.sizeAtTurnEnded = nextEndedSize;
        sample.tail = tail;
        self.samples[path] = sample;

        if (!newest || mtime > [newest[@"mtime"] doubleValue]) {
            newest = cand;
            newestTail = tail;
            newestAge = age;
            newestOpenTurn = openTurn;
        }
    }

    BOOL hasAgentExec =
        [self.rolesByLabel[label] containsObject:@"agent-exec"];
    BOOL agentExecSupport = NO;
    if (hasAgentExec && newest && newestTail) {
        BOOL newestEnded = newestTail.sawTurnEnded && !newestTail.hasIncompleteTrailer;
        if (!newestEnded) {
            if ([newestTail.lastLineKind isEqualToString:@"user"]) {
                agentExecSupport = newestAge <= MLCursorUserAwaitWindow;
            } else if ([newestTail.lastLineKind isEqualToString:@"assistant"]) {
                agentExecSupport = newestAge <= MLCursorAgentExecWindow;
            } else {
                agentExecSupport = newestOpenTurn && newestAge <= MLCursorAgentExecWindow;
            }
        }
    }

    BOOL emptyWarmup = (candidates.count == 0 && sideHot);
    BOOL busy = anyGrowing || agentExecSupport || emptyWarmup;
    if (info) {
        NSString *reason = anyGrowing ? @"transcript"
                         : (agentExecSupport ? @"agent-exec"
                                             : (emptyWarmup ? @"side-empty" : @"idle"));
        NSString *kind = newestTail.lastLineKind ?: @"none";
        double age = isfinite(newestAge) ? newestAge : -1.0;
        *info = @{
            @"reason" : reason,
            @"kind" : kind,
            @"age" : @(age),
            @"side" : @(sideHot),
            @"candidates" : @(candidates.count),
        };
    }
    return busy;
}

- (void)writeDebugSignalsWithOpen:(NSSet<NSString *> *)open
                             busy:(NSSet<NSString *> *)busy
                            infos:(NSDictionary<NSString *, NSDictionary *> *)infos {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"# %@ open=%lu busy=%lu\n",
                      [NSDate date], (unsigned long)open.count, (unsigned long)busy.count];
    [out appendString:@"label\tstate\treason\tkind\tage\tside\tcandidates\troles\n"];
    NSArray<NSString *> *labels =
        [[open allObjects] sortedArrayUsingSelector:@selector(compare:)];
    if (labels.count == 0) {
        [out appendString:@"(no open Cursor workspaces)\n"];
    }
    for (NSString *label in labels) {
        NSDictionary *info = infos[label];
        NSSet<NSString *> *roles = self.rolesByLabel[label];
        NSString *roleText =
            [[[roles allObjects] sortedArrayUsingSelector:@selector(compare:)]
                componentsJoinedByString:@"+"];
        [out appendFormat:@"%@\t%@\t%@\t%@\t%.0fs\t%d\t%lu\t%@\n",
                          label,
                          [busy containsObject:label] ? @"busy" : @"idle",
                          info[@"reason"] ?: @"-",
                          info[@"kind"] ?: @"none",
                          [info[@"age"] doubleValue],
                          [info[@"side"] boolValue] ? 1 : 0,
                          (unsigned long)[info[@"candidates"] unsignedIntegerValue],
                          roleText.length ? roleText : @"-"];
    }
    [out writeToFile:@"/tmp/meolaunch-cursor-signals.txt"
          atomically:YES
            encoding:NSUTF8StringEncoding
               error:NULL];
}

#pragma mark - Transcript / side-channel scan

- (NSArray<NSDictionary *> *)transcriptCandidatesForProjectDirs:(NSArray<NSString *> *)projectDirs
                                                             now:(NSTimeInterval)now
                                                      sessionIDs:(NSMutableArray<NSString *> *)sessionIDs
                                                         sideHot:(BOOL *)sideHot {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *projectDir in projectDirs) {
        if ([self agentToolsHotForProjectDir:projectDir now:now]) {
            *sideHot = YES;
        }
        if ([self terminalHotForProjectDir:projectDir now:now]) {
            *sideHot = YES;
        }

        NSString *transcriptsDir =
            [projectDir stringByAppendingPathComponent:@"agent-transcripts"];
        NSArray<NSString *> *sessionDirs =
            [fm contentsOfDirectoryAtPath:transcriptsDir error:NULL];
        NSMutableArray<NSDictionary *> *sessions = [NSMutableArray array];
        for (NSString *sid in sessionDirs ?: @[]) {
            if ([sid hasPrefix:@"."]) {
                continue;
            }
            NSString *sessionDir = [transcriptsDir stringByAppendingPathComponent:sid];
            int64_t dirSize = 0;
            NSTimeInterval dirMtime = 0;
            if (!MLCursorReadStat(sessionDir, &dirSize, &dirMtime)) {
                continue;
            }
            [sessions addObject:@{
                @"sid" : sid,
                @"dir" : sessionDir,
                @"mtime" : @(dirMtime),
            }];
        }
        [sessions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double am = [a[@"mtime"] doubleValue];
            double bm = [b[@"mtime"] doubleValue];
            if (am == bm) {
                return NSOrderedSame;
            }
            return am > bm ? NSOrderedAscending : NSOrderedDescending;
        }];
        NSUInteger sessionCount = MIN(sessions.count, MLCursorSessionDirLimit);
        for (NSUInteger i = 0; i < sessionCount; i++) {
            NSDictionary *sess = sessions[i];
            NSString *sid = sess[@"sid"];
            NSString *sessionDir = sess[@"dir"];
            NSTimeInterval sessionMtime = [sess[@"mtime"] doubleValue];
            [sessionIDs addObject:sid];

            NSString *parentPath =
                [sessionDir stringByAppendingPathComponent:
                    [sid stringByAppendingPathExtension:@"jsonl"]];
            int64_t parentSize = 0;
            NSTimeInterval parentMtime = 0;
            BOOL hasParent = MLCursorReadStat(parentPath, &parentSize, &parentMtime);
            if (!hasParent) {
                if ([self parentlessSessionHot:sessionDir
                                            sid:sid
                                           now:now]) {
                    *sideHot = YES;
                }
            } else {
                MLCursorTail *tail = [self tailForPath:parentPath
                                                  size:parentSize
                                                 mtime:parentMtime];
                [out addObject:@{
                    @"path" : parentPath,
                    @"size" : @(parentSize),
                    @"mtime" : @(parentMtime),
                    @"tail" : tail,
                    @"session" : sid,
                }];
            }

            /* Subagent transcripts are Busy-only inputs, never their own chip. */
            if (now - sessionMtime <= 60.0 * 60.0) {
                NSString *subagentsDir =
                    [sessionDir stringByAppendingPathComponent:@"subagents"];
                NSArray<NSString *> *subFiles =
                    [fm contentsOfDirectoryAtPath:subagentsDir error:NULL];
                for (NSString *sub in subFiles ?: @[]) {
                    if (![[sub pathExtension].lowercaseString isEqualToString:@"jsonl"]) {
                        continue;
                    }
                    NSString *subPath = [subagentsDir stringByAppendingPathComponent:sub];
                    int64_t subSize = 0;
                    NSTimeInterval subMtime = 0;
                    if (!MLCursorReadStat(subPath, &subSize, &subMtime)) {
                        continue;
                    }
                    MLCursorTail *subTail = [self tailForPath:subPath
                                                         size:subSize
                                                        mtime:subMtime];
                    [out addObject:@{
                        @"path" : subPath,
                        @"size" : @(subSize),
                        @"mtime" : @(subMtime),
                        @"tail" : subTail,
                        @"session" : sid,
                    }];
                }
            }

            if (hasParent && [self agentStoreHotForSessionID:sid
                                                  parentPath:parentPath
                                                         now:now]) {
                *sideHot = YES;
            }
        }
    }

    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double am = [a[@"mtime"] doubleValue];
        double bm = [b[@"mtime"] doubleValue];
        if (am == bm) {
            return NSOrderedSame;
        }
        return am > bm ? NSOrderedAscending : NSOrderedDescending;
    }];
    if (out.count > MLCursorCandidateLimit) {
        return [out subarrayWithRange:NSMakeRange(0, MLCursorCandidateLimit)];
    }
    return out;
}

- (BOOL)agentToolsHotForProjectDir:(NSString *)projectDir now:(NSTimeInterval)now {
    NSString *dir = [projectDir stringByAppendingPathComponent:@"agent-tools"];
    NSArray<NSString *> *names =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    for (NSString *name in names ?: @[]) {
        if ([name hasPrefix:@"."]) {
            continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSTimeInterval mtime = 0;
        if (MLCursorReadStat(path, NULL, &mtime) && (now - mtime) <= MLCursorSideWindow) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)terminalHotForProjectDir:(NSString *)projectDir now:(NSTimeInterval)now {
    NSString *dir = [projectDir stringByAppendingPathComponent:@"terminals"];
    NSArray<NSString *> *names =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    for (NSString *name in names ?: @[]) {
        if (![[name pathExtension].lowercaseString isEqualToString:@"txt"]) {
            continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSTimeInterval mtime = 0;
        if (!MLCursorReadStat(path, NULL, &mtime)) {
            continue;
        }
        NSTimeInterval age = now - mtime;
        if (age > MLCursorTerminalWindow) {
            continue;
        }
        if ([self terminalLooksRunningAtPath:path mtimeAge:age now:now]) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)terminalLooksRunningAtPath:(NSString *)path
                         mtimeAge:(NSTimeInterval)mtimeAge
                              now:(NSTimeInterval)now {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) {
        return NO;
    }
    NSData *head = [fh readDataOfLength:1024];
    [fh closeFile];
    NSString *text = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
    if (text.length == 0 || ![text hasPrefix:@"---"]) {
        return NO;
    }
    NSRange bodyRange = NSMakeRange(3, text.length - 3);
    NSRange endRange = [text rangeOfString:@"\n---" options:0 range:bodyRange];
    if (endRange.location == NSNotFound) {
        return NO;
    }
    NSString *header = [text substringWithRange:
        NSMakeRange(3, endRange.location - 3)];
    BOOL hasPid = NO;
    BOOL hasExit = NO;
    NSString *status = nil;
    NSDate *startedAt = nil;
    static NSISO8601DateFormatter *iso = nil;
    static NSISO8601DateFormatter *isoBasic = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iso = [[NSISO8601DateFormatter alloc] init];
        iso.formatOptions =
            NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        isoBasic = [[NSISO8601DateFormatter alloc] init];
        isoBasic.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    for (NSString *line in [header componentsSeparatedByString:@"\n"]) {
        NSString *trimmed =
            [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"pid:"]) {
            hasPid = YES;
        } else if ([trimmed hasPrefix:@"last_exit_code:"]) {
            hasExit = YES;
        } else if ([trimmed hasPrefix:@"status:"]) {
            status = [[trimmed substringFromIndex:@"status:".length]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                .lowercaseString;
        } else if ([trimmed hasPrefix:@"started_at:"]) {
            NSString *raw = [[trimmed substringFromIndex:@"started_at:".length]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            startedAt = [iso dateFromString:raw] ?: [isoBasic dateFromString:raw];
        }
    }
    if (status.length > 0) {
        if ([status isEqualToString:@"succeeded"] || [status isEqualToString:@"failed"] ||
            [status isEqualToString:@"cancelled"] || [status isEqualToString:@"canceled"]) {
            return NO;
        }
        if ([status isEqualToString:@"running"]) {
            if (startedAt) {
                NSTimeInterval startAge = now - startedAt.timeIntervalSince1970;
                if (startAge > MLCursorTerminalFreshStart &&
                    mtimeAge > MLCursorGrowingWindow) {
                    return NO;
                }
            }
            return hasPid;
        }
    }
    return hasPid && !hasExit;
}

- (BOOL)parentlessSessionHot:(NSString *)sessionDir
                         sid:(NSString *)sid
                         now:(NSTimeInterval)now {
    NSString *parent = [sessionDir stringByAppendingPathComponent:
        [sid stringByAppendingPathExtension:@"jsonl"]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:parent]) {
        return NO;
    }
    int64_t size = 0;
    NSTimeInterval mtime = 0;
    if (MLCursorReadStat(sessionDir, &size, &mtime) &&
        (now - mtime) <= MLCursorParentlessWindow) {
        return YES;
    }
    NSDirectoryEnumerator<NSString *> *en =
        [[NSFileManager defaultManager] enumeratorAtPath:sessionDir];
    NSUInteger checked = 0;
    for (NSString *rel in en) {
        if (++checked > 40) {
            break;
        }
        NSString *path = [sessionDir stringByAppendingPathComponent:rel];
        NSTimeInterval fileMtime = 0;
        if (MLCursorReadStat(path, NULL, &fileMtime) &&
            (now - fileMtime) <= MLCursorParentlessWindow) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)agentStoreHotForSessionID:(NSString *)sid
                       parentPath:(NSString *)parentPath
                              now:(NSTimeInterval)now {
    NSString *wal = [self.agentStoresRoot
        stringByAppendingPathComponent:
            [sid stringByAppendingPathComponent:@".sync/index.sqlite-wal"]];
    int64_t size = 0;
    NSTimeInterval mtime = 0;
    if (!MLCursorReadStat(wal, &size, &mtime)) {
        return NO;
    }
    NSNumber *prev = self.agentStoreSizes[sid];
    BOOL grew = prev && size >= prev.longLongValue + MLCursorAgentStoreGrowth;
    self.agentStoreSizes[sid] = @(size);
    if (!grew || (now - mtime) > MLCursorAgentStoreWindow) {
        return NO;
    }
    MLCursorTail *tail = [self inspectTranscriptTailAtPath:parentPath];
    if (tail.sawTurnEnded && !tail.hasIncompleteTrailer) {
        return NO;
    }
    return YES;
}

- (MLCursorTail *)tailForPath:(NSString *)path
                         size:(int64_t)size
                        mtime:(NSTimeInterval)mtime {
    MLCursorFileSample *prev = self.samples[path];
    if (prev && prev.tail && prev.size == size && prev.mtime == mtime) {
        return prev.tail;
    }
    return [self inspectTranscriptTailAtPath:path];
}

#pragma mark - Transcript tail

- (MLCursorTail *)inspectTranscriptTailAtPath:(NSString *)path {
    MLCursorTail *result = [[MLCursorTail alloc] init];
    result.lastLineKind = @"error";
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) {
        result.lastLineKind = @"missing";
        return result;
    }
    unsigned long long size = [fh seekToEndOfFile];
    if (size == 0) {
        [fh closeFile];
        result.lastLineKind = @"empty";
        return result;
    }
    NSUInteger readLen = MIN(size, (unsigned long long)MLCursorTailBytes);
    BOOL tailTruncated = (size > (unsigned long long)readLen);
    [fh seekToFileOffset:size - readLen];
    NSData *data = [fh readDataOfLength:(NSUInteger)readLen];
    [fh closeFile];
    if (data.length == 0) {
        return result;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger n = data.length;
    NSInteger last = (NSInteger)n - 1;
    while (last >= 0 && MLCursorIsASCIISpace(bytes[last])) {
        last--;
    }
    result.hasIncompleteTrailer = (last >= 0 && bytes[last] != '}');

    /* A line can end with '}' yet still be an incomplete outer object. Treat the
       final line as buffering when it cannot be parsed as complete JSON. */
    if (last >= 0) {
        NSInteger s = last;
        while (s >= 0 && bytes[s] != '\n') {
            s--;
        }
        NSUInteger start = (NSUInteger)(s + 1);
        NSUInteger length = (NSUInteger)(last - s);
        BOOL complete = NO;
        if (length >= 2 && bytes[start] == '{' && bytes[last] == '}') {
            NSData *line = [data subdataWithRange:NSMakeRange(start, length)];
            complete = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL] != nil;
        }
        if (!complete) {
            /* If the window started inside this line, the parse failure may just
               mean the line is larger than our 64 KiB tail; do not stick Busy. */
            if (start > 0 || !tailTruncated) {
                result.hasIncompleteTrailer = YES;
            }
        }
    }

    NSUInteger end = n;
    while (end > 0) {
        NSInteger e = (NSInteger)end - 1;
        while (e >= 0 && MLCursorIsASCIISpace(bytes[e])) {
            e--;
        }
        if (e < 0) {
            break;
        }
        NSInteger s = e;
        while (s >= 0 && bytes[s] != '\n') {
            s--;
        }
        NSUInteger start = (NSUInteger)(s + 1);
        NSUInteger length = (NSUInteger)(e - s);
        if (length >= 2 && bytes[start] == '{' && bytes[e] == '}') {
            NSData *line = [data subdataWithRange:NSMakeRange(start, length)];
            id obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
            if ([obj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dict = (NSDictionary *)obj;
                id type = dict[@"type"];
                if ([type isKindOfClass:[NSString class]]) {
                    if ([type isEqualToString:@"turn_ended"]) {
                        result.sawTurnEnded = YES;
                        id status = dict[@"status"];
                        result.endedStatus =
                            [status isKindOfClass:[NSString class]] ? status : nil;
                        result.lastLineKind = @"turn_ended";
                        return result;
                    }
                    result.lastLineKind = type;
                    return result;
                }
                id role = dict[@"role"];
                if ([role isKindOfClass:[NSString class]]) {
                    result.lastLineKind = role;
                    return result;
                }
                result.lastLineKind = @"other";
                return result;
            }
        }
        end = (s >= 0) ? (NSUInteger)s : 0;
    }
    result.lastLineKind = @"unknown";
    return result;
}

#pragma mark - Cursor extension-host process scan

- (NSDictionary<NSString *, NSSet<NSString *> *> *)scanCursorHosts {
    NSMutableDictionary<NSString *, NSMutableSet<NSString *> *> *roles =
        [NSMutableDictionary dictionary];

    int bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes <= 0) {
        return @{};
    }
    int capacity = bytes / (int)sizeof(pid_t) + 32;
    pid_t *pids = calloc((size_t)capacity, sizeof(pid_t));
    if (!pids) {
        return @{};
    }
    int used = proc_listpids(PROC_ALL_PIDS, 0, pids, capacity * (int)sizeof(pid_t));
    int count = used > 0 ? used / (int)sizeof(pid_t) : 0;

    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) {
            continue;
        }
        char name[1024] = {0};
        if (proc_name(pid, name, (uint32_t)sizeof(name)) <= 0) {
            continue;
        }
        NSString *processName = [NSString stringWithUTF8String:name];
        if ([processName rangeOfString:@"cursor" options:NSCaseInsensitiveSearch].location ==
            NSNotFound) {
            continue;
        }
        NSArray<NSString *> *strings = [self processArgumentStrings:pid];
        if (strings.count == 0) {
            continue;
        }
        NSDictionary *env = [self cursorEnvFromStrings:strings];
        if (!env) {
            continue;
        }
        NSString *label = env[@"label"];
        NSString *role = env[@"role"] ?: @"unknown";
        if (label.length == 0) {
            continue;
        }
        NSString *key = label.lowercaseString;
        NSMutableSet *set = roles[key];
        if (!set) {
            set = [NSMutableSet set];
            roles[key] = set;
        }
        [set addObject:role.lowercaseString];
    }
    free(pids);

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in roles) {
        out[key] = [roles[key] copy];
    }
    return out;
}

- (NSArray<NSString *> *)processArgumentStrings:(pid_t)pid {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size == 0) {
        size = 256 * 1024;
    }
    if (size > 4 * 1024 * 1024) {
        size = 256 * 1024;
    }
    NSMutableData *data = [NSMutableData dataWithLength:size];
    size_t actual = size;
    if (sysctl(mib, 3, data.mutableBytes, &actual, NULL, 0) != 0 || actual <= 4) {
        return @[];
    }

    const uint8_t *bytes = data.bytes;
    NSMutableArray<NSString *> *strings = [NSMutableArray array];
    NSUInteger index = 4; /* argc */
    NSUInteger nuls = 0;
    BOOL sawLabel = NO;
    BOOL sawRole = NO;
    while (index < actual) {
        if (bytes[index] == 0) {
            nuls += 1;
            index += 1;
            if (nuls > 8 && strings.count > 4) {
                break;
            }
            continue;
        }
        nuls = 0;
        NSUInteger start = index;
        while (index < actual && bytes[index] != 0) {
            index++;
        }
        NSUInteger length = index - start;
        if (length > 0) {
            NSString *s = [[NSString alloc] initWithBytes:bytes + start
                                                    length:length
                                                  encoding:NSUTF8StringEncoding];
            if (s.length > 0 && ![self looksSecret:s]) {
                [strings addObject:s];
                if ([s hasPrefix:[MLCursorWorkspaceLabelKey stringByAppendingString:@"="]]) {
                    sawLabel = YES;
                }
                if ([s hasPrefix:[MLCursorExtensionHostRoleKey stringByAppendingString:@"="]]) {
                    sawRole = YES;
                }
            }
        }
        index += 1;
        if (strings.count > 120) {
            break;
        }
        if (sawLabel && sawRole) {
            break;
        }
    }
    return strings;
}

- (BOOL)looksSecret:(NSString *)s {
    NSString *lower = s.lowercaseString;
    if ([lower containsString:@"api-key"] || [lower containsString:@"apikey"]) {
        return YES;
    }
    if ([lower containsString:@"crsr_"]) {
        return YES;
    }
    if ([lower containsString:@"secret="] || [lower containsString:@"token="]) {
        return YES;
    }
    if ([lower hasPrefix:@"openai_"] || [lower hasPrefix:@"anthropic_"]) {
        return YES;
    }
    return NO;
}

- (nullable NSDictionary<NSString *, NSString *> *)cursorEnvFromStrings:
    (NSArray<NSString *> *)strings {
    BOOL isExtensionHost = NO;
    for (NSString *s in strings) {
        if ([s containsString:@"extension-host"] ||
            [s hasPrefix:[MLCursorExtensionHostRoleKey stringByAppendingString:@"="]] ||
            [s hasPrefix:@"VSCODE_PROCESS_TITLE=extension-host"]) {
            isExtensionHost = YES;
            break;
        }
    }
    if (!isExtensionHost) {
        return nil;
    }

    NSString *label = nil;
    NSString *role = nil;
    for (NSString *s in strings) {
        NSString *labelPrefix = [MLCursorWorkspaceLabelKey stringByAppendingString:@"="];
        NSString *rolePrefix = [MLCursorExtensionHostRoleKey stringByAppendingString:@"="];
        if ([s hasPrefix:labelPrefix]) {
            label = [s substringFromIndex:labelPrefix.length];
        } else if ([s hasPrefix:rolePrefix]) {
            role = [s substringFromIndex:rolePrefix.length];
        }
    }
    if (label.length == 0 || role.length == 0) {
        NSDictionary *fallback = [self parseProcessTitle:strings];
        if (label.length == 0) {
            label = fallback[@"label"];
        }
        if (role.length == 0) {
            role = fallback[@"role"];
        }
    }
    label = [label stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (label.length == 0) {
        return nil;
    }
    return @{@"label" : label, @"role" : role ?: @"unknown"};
}

- (nullable NSDictionary<NSString *, NSString *> *)parseProcessTitle:
    (NSArray<NSString *> *)strings {
    for (NSString *s in strings) {
        NSString *candidate = s;
        if ([s hasPrefix:@"VSCODE_PROCESS_TITLE="]) {
            candidate = [s substringFromIndex:@"VSCODE_PROCESS_TITLE=".length];
        }
        NSRange roleOpen = [candidate rangeOfString:@"extension-host ("];
        if (roleOpen.location == NSNotFound) {
            continue;
        }
        NSString *afterRole = [candidate substringFromIndex:NSMaxRange(roleOpen)];
        NSRange roleClose = [afterRole rangeOfString:@")"];
        if (roleClose.location == NSNotFound) {
            continue;
        }
        NSString *role = [afterRole substringToIndex:roleClose.location];
        NSString *rest = [[afterRole substringFromIndex:NSMaxRange(roleClose)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSRange bracket = [rest rangeOfString:@"["];
        if (bracket.location != NSNotFound) {
            rest = [rest substringToIndex:bracket.location];
        }
        rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (rest.length > 0) {
            return @{@"label" : rest, @"role" : role ?: @"unknown"};
        }
    }
    return nil;
}

#pragma mark - Housekeeping

- (void)pruneAt:(NSTimeInterval)now {
    if (now - self.lastPrune < 60.0) {
        return;
    }
    self.lastPrune = now;
    NSMutableArray<NSString *> *dead = [NSMutableArray array];
    for (NSString *path in self.samples) {
        MLCursorFileSample *sample = self.samples[path];
        if (now - sample.sampledAt > 2.0 * 60.0 * 60.0 ||
            ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [dead addObject:path];
        }
    }
    [self.samples removeObjectsForKeys:dead];
    if (self.agentStoreSizes.count > 2000) {
        [self.agentStoreSizes removeAllObjects];
    }
}

@end
