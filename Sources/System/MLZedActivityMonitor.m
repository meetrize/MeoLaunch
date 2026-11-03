#import "MLZedActivityMonitor.h"

#import "MLZstd.h"

#import <AppKit/AppKit.h>
#import <sqlite3.h>
#import <sys/stat.h>

NSNotificationName const MLZedActivityDidChangeNotification = @"MLZedActivityDidChangeNotification";

static NSString *const MLZedBundleIdentifier = @"dev.zed.Zed";

static NSString *MLZedPathOverride(const char *name, NSString *fallback) {
    const char *value = getenv(name);
    if (value && value[0] != '\0') {
        return @(value);
    }
    return fallback;
}

/** Poll cadence; Zed writes its thread DB once per completed model response. */
static const NSTimeInterval MLZedScanInterval = 1.0;
/** A user prompt with no assistant save for this long is treated as abandoned. */
static const NSTimeInterval MLZedPromptMaxIdle = 45.0 * 60.0;
/** Tool calls (builds, test suites) can legitimately run for a long time. */
static const NSTimeInterval MLZedToolMaxIdle = 2.0 * 60.0 * 60.0;
/** Keep cancellation markers long enough to clear stale busy threads. */
static const NSTimeInterval MLZedCancelRetention = 3.0 * 60.0 * 60.0;
/** Full DB re-read even when mtime/size look unchanged (timeouts still apply). */
static const NSTimeInterval MLZedForceRescan = 5.0;
static const NSUInteger MLZedThreadLimit = 40;
/** Bound zstd work per DB change; active threads are always the newest. */
static const NSUInteger MLZedCandidateLimit = 12;

typedef NS_ENUM(NSInteger, MLZedBusyKind) {
    MLZedBusyKindPrompt = 0, /* last message is User */
    MLZedBusyKindTool = 1,   /* last Agent message has at least one ToolUse */
};

@interface MLZedActivityMonitor ()
@property (nonatomic, strong) dispatch_queue_t scanQueue;
@property (nonatomic, strong) dispatch_source_t timer;
@property (atomic, assign) BOOL running;

@property (nonatomic, copy, readwrite) NSSet<NSString *> *busyFolderNames;
/** Snapshot of threads whose last persisted message is mid-turn. */
@property (nonatomic, strong) NSArray<NSDictionary *> *openThreads;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *cancelTimes;
@property (nonatomic, assign) unsigned long long logOffset;
@property (nonatomic, copy) NSString *lastPromptSession;
@property (nonatomic, strong) NSDate *lastPromptAt;
@property (nonatomic, assign) time_t dbMtime;
@property (nonatomic, assign) off_t dbSize;
@property (nonatomic, assign) NSTimeInterval lastDbRead;
@end

@implementation MLZedActivityMonitor

@synthesize busyFolderNames = _busyFolderNames;

- (instancetype)init {
    self = [super init];
    if (self) {
        _scanQueue = dispatch_queue_create("com.meetrice.meolaunch.zed-activity",
                                           DISPATCH_QUEUE_SERIAL);
        _busyFolderNames = [NSSet set];
        _openThreads = @[];
        _cancelTimes = [NSMutableDictionary dictionary];
        _logOffset = 0;
        _dbMtime = 0;
        _dbSize = 0;
        _lastDbRead = 0;
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

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                     self.scanQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(MLZedScanInterval * NSEC_PER_SEC),
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
    [self updateBusyFolderNames:[NSSet set]];
}

#pragma mark - Public state

- (NSSet<NSString *> *)busyFolderNames {
    @synchronized (self) {
        return _busyFolderNames ?: [NSSet set];
    }
}

- (BOOL)hasAnyBusy {
    return self.busyFolderNames.count > 0;
}

- (BOOL)isBusyForWindowTitle:(NSString *)title {
    if (title.length == 0) {
        return NO;
    }
    NSString *normalized = [self normalizedTitle:title];
    NSSet<NSString *> *busy = self.busyFolderNames;
    if (busy.count == 0 || normalized.length == 0) {
        return NO;
    }
    if ([busy containsObject:normalized]) {
        return YES;
    }
    for (NSString *key in busy) {
        if (key.length == 0) {
            continue;
        }
        if ([self title:normalized startsWithFolderKey:key] ||
            [self title:normalized containsFolderKey:key]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)normalizedTitle:(NSString *)title {
    NSString *trimmed =
        [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.lowercaseString;
}

- (BOOL)isTitleBoundary:(unichar)ch {
    if (ch == ' ' || ch == '\t' || ch == '-' || ch == 0x2014 || ch == 0x2013 ||
        ch == 0x00B7 || ch == '|' || ch == '/' || ch == ':' || ch == '(' || ch == '[') {
        return YES;
    }
    return NO;
}

- (BOOL)title:(NSString *)title startsWithFolderKey:(NSString *)key {
    if (title.length <= key.length || ![title hasPrefix:key]) {
        return NO;
    }
    return [self isTitleBoundary:[title characterAtIndex:key.length]];
}

- (BOOL)title:(NSString *)title containsFolderKey:(NSString *)key {
    NSRange range = [title rangeOfString:key];
    if (range.location == NSNotFound || range.length == 0) {
        return NO;
    }
    BOOL leftOK = (range.location == 0) ||
                  [self isTitleBoundary:[title characterAtIndex:range.location - 1]];
    NSUInteger end = NSMaxRange(range);
    BOOL rightOK = (end >= title.length) ||
                   [self isTitleBoundary:[title characterAtIndex:end]];
    return leftOK && rightOK;
}

- (void)updateBusyFolderNames:(NSSet<NSString *> *)folders {
    BOOL changed = NO;
    @synchronized (self) {
        if (![_busyFolderNames isEqualToSet:folders]) {
            _busyFolderNames = [folders copy] ?: [NSSet set];
            changed = YES;
        }
    }
    if (changed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:MLZedActivityDidChangeNotification
                                                                object:self];
        });
    }
}

#pragma mark - Scanning

- (void)scan {
    if (!self.running) {
        return;
    }
    @autoreleasepool {
        NSArray<NSRunningApplication *> *apps =
            [NSRunningApplication runningApplicationsWithBundleIdentifier:MLZedBundleIdentifier];
        if (apps.count == 0) {
            self.openThreads = @[];
            self.lastDbRead = 0;
            self.dbMtime = 0;
            self.dbSize = 0;
            [self updateBusyFolderNames:[NSSet set]];
            return;
        }

        [self readNewCancelLogEntries];

        NSString *dbPath = MLZedPathOverride("ML_ZED_THREADS_DB",
            [NSHomeDirectory()
                stringByAppendingPathComponent:@"Library/Application Support/Zed/threads/threads.db"]);
        struct stat st;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        BOOL needRead = NO;
        if (stat(dbPath.fileSystemRepresentation, &st) != 0) {
            self.openThreads = @[];
            self.dbMtime = 0;
            self.dbSize = 0;
        } else {
            BOOL changed = (st.st_mtime != self.dbMtime || st.st_size != self.dbSize);
            BOOL stale = (now - self.lastDbRead) >= MLZedForceRescan;
            if (changed || stale) {
                needRead = YES;
                self.dbMtime = st.st_mtime;
                self.dbSize = st.st_size;
                self.lastDbRead = now;
            }
        }

        if (needRead) {
            NSArray<NSDictionary *> *loaded = [self loadOpenThreadsFromDatabaseAtPath:dbPath now:now];
            /* Keep the previous snapshot on a transient SQLite lock/read error. */
            if (loaded) {
                self.openThreads = loaded;
            }
        }
        [self updateBusyFolderNames:[self busyFoldersFromOpenThreadsAt:now]];
    }
}

- (nullable NSArray<NSDictionary *> *)loadOpenThreadsFromDatabaseAtPath:(NSString *)path
                                                                   now:(NSTimeInterval)now {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.fileSystemRepresentation, &db,
                        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (db) {
            sqlite3_close(db);
        }
        return nil;
    }
    sqlite3_busy_timeout(db, 150);

    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    const char *sql =
        "SELECT id, folder_paths, updated_at, data_type FROM threads "
        "WHERE folder_paths IS NOT NULL AND folder_paths <> '' "
        "ORDER BY updated_at DESC LIMIT ?";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return nil;
    }
    if (stmt) {
        sqlite3_bind_int(stmt, 1, (int)MLZedThreadLimit);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *sid = sqlite3_column_text(stmt, 0);
            const unsigned char *folders = sqlite3_column_text(stmt, 1);
            const unsigned char *updated = sqlite3_column_text(stmt, 2);
            const unsigned char *dataType = sqlite3_column_text(stmt, 3);
            if (!sid || !folders) {
                continue;
            }
            NSDate *date = [self dateFromZedTimestamp:
                updated ? [NSString stringWithUTF8String:(const char *)updated] : nil];
            if (!date) {
                continue;
            }
            NSTimeInterval age = now - date.timeIntervalSince1970;
            if (age > MLZedToolMaxIdle) {
                /* Sorted newest first, so every remaining row is older. */
                break;
            }
            NSString *session = [NSString stringWithUTF8String:(const char *)sid];
            NSString *folderText = [NSString stringWithUTF8String:(const char *)folders];
            NSString *type = dataType ? [NSString stringWithUTF8String:(const char *)dataType]
                                      : @"zstd";
            [candidates addObject:@{
                @"session" : session ?: @"",
                @"folders" : [self folderPathsFromSerializedString:folderText],
                @"updated" : date,
                @"type" : type ?: @"zstd",
            }];
            if (candidates.count >= MLZedCandidateLimit) {
                break;
            }
        }
    }
    sqlite3_finalize(stmt);

    NSMutableArray<NSDictionary *> *open = [NSMutableArray array];
    sqlite3_stmt *dataStmt = NULL;
    if (sqlite3_prepare_v2(db, "SELECT data FROM threads WHERE id = ? LIMIT 1", -1, &dataStmt,
                           NULL) != SQLITE_OK) {
        sqlite3_close(db);
        return nil;
    }
    if (dataStmt) {
        for (NSDictionary *cand in candidates) {
            NSString *session = cand[@"session"];
            if (session.length == 0) {
                continue;
            }
            sqlite3_reset(dataStmt);
            sqlite3_clear_bindings(dataStmt);
            sqlite3_bind_text(dataStmt, 1, session.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(dataStmt) != SQLITE_ROW) {
                continue;
            }
            const void *bytes = sqlite3_column_blob(dataStmt, 0);
            int length = sqlite3_column_bytes(dataStmt, 0);
            if (!bytes || length <= 0) {
                continue;
            }
            NSData *raw = [NSData dataWithBytes:bytes length:(NSUInteger)length];
            NSData *jsonData = raw;
            if ([cand[@"type"] isEqualToString:@"zstd"]) {
                jsonData = MLZstdDecompressData(raw);
            }
            if (jsonData.length == 0) {
                continue;
            }
            NSDictionary *state = [self openThreadStateFromJSONData:jsonData
                                                            session:session
                                                             folders:cand[@"folders"]
                                                             updated:cand[@"updated"]];
            if (state) {
                [open addObject:state];
            }
        }
    }
    sqlite3_finalize(dataStmt);
    sqlite3_close(db);
    return open;
}

- (NSArray<NSString *> *)folderPathsFromSerializedString:(NSString *)text {
    if (text.length == 0) {
        return @[];
    }
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed =
            [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            [paths addObject:trimmed];
        }
    }
    return paths;
}

- (nullable NSDictionary *)openThreadStateFromJSONData:(NSData *)jsonData
                                                session:(NSString *)session
                                                 folders:(NSArray<NSString *> *)folders
                                                 updated:(NSDate *)updated {
    if (folders.count == 0) {
        return nil;
    }
    id root = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:NULL];
    if (![root isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSArray *messages = ((NSDictionary *)root)[@"messages"];
    if (![messages isKindOfClass:[NSArray class]] || messages.count == 0) {
        return nil;
    }
    id last = messages.lastObject;
    if (![last isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    NSDictionary *message = (NSDictionary *)last;

    MLZedBusyKind kind;
    if (message[@"User"]) {
        kind = MLZedBusyKindPrompt;
    } else if (message[@"Agent"]) {
        id agent = message[@"Agent"];
        if (![agent isKindOfClass:[NSDictionary class]]) {
            return nil;
        }
        id content = ((NSDictionary *)agent)[@"content"];
        if (![content isKindOfClass:[NSArray class]]) {
            /* A plain-text final response has no tool calls. */
            return nil;
        }
        BOOL hasToolUse = NO;
        for (id item in (NSArray *)content) {
            if ([item isKindOfClass:[NSDictionary class]] && ((NSDictionary *)item)[@"ToolUse"]) {
                hasToolUse = YES;
                break;
            }
        }
        if (!hasToolUse) {
            return nil;
        }
        kind = MLZedBusyKindTool;
    } else {
        return nil;
    }

    return @{
        @"session" : session,
        @"folders" : folders,
        @"updated" : updated,
        @"kind" : @(kind),
    };
}

- (NSSet<NSString *> *)busyFoldersFromOpenThreadsAt:(NSTimeInterval)now {
    NSMutableSet<NSString *> *busy = [NSMutableSet set];
    NSArray<NSDictionary *> *open = self.openThreads;
    for (NSDictionary *state in open) {
        NSDate *updated = state[@"updated"];
        if (![updated isKindOfClass:[NSDate class]]) {
            continue;
        }
        NSTimeInterval age = now - updated.timeIntervalSince1970;
        MLZedBusyKind kind = (MLZedBusyKind)[state[@"kind"] integerValue];
        NSTimeInterval maxIdle = (kind == MLZedBusyKindPrompt) ? MLZedPromptMaxIdle : MLZedToolMaxIdle;
        if (age < 0 || age > maxIdle) {
            continue;
        }
        NSString *session = state[@"session"];
        NSDate *cancelled = self.cancelTimes[session];
        if (cancelled && cancelled.timeIntervalSince1970 >= updated.timeIntervalSince1970) {
            continue;
        }
        NSArray<NSString *> *folders = state[@"folders"];
        for (NSString *path in folders) {
            NSString *key = path.lastPathComponent.lowercaseString;
            if (key.length > 0) {
                [busy addObject:key];
            }
        }
    }
    return busy;
}

- (nullable NSDate *)dateFromZedTimestamp:(nullable NSString *)text {
    if (text.length == 0) {
        return nil;
    }
    static NSISO8601DateFormatter *fractional = nil;
    static NSISO8601DateFormatter *plain = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fractional = [[NSISO8601DateFormatter alloc] init];
        fractional.formatOptions =
            NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [[NSISO8601DateFormatter alloc] init];
        plain.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [fractional dateFromString:text] ?: [plain dateFromString:text];
}

#pragma mark - Zed log (cancellation / failure markers)

- (void)readNewCancelLogEntries {
    NSString *path = MLZedPathOverride("ML_ZED_LOG",
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Zed/Zed.log"]);
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) {
        return;
    }
    unsigned long long size = [fh seekToEndOfFile];
    if (self.logOffset == 0 || size < self.logOffset) {
        /* First scan (or rotation): replay a small tail so recent cancels apply. */
        self.logOffset = (size > 256ULL * 1024ULL) ? (size - 256ULL * 1024ULL) : 0;
    }
    if (size <= self.logOffset) {
        return;
    }
    unsigned long long available = size - self.logOffset;
    unsigned long long toRead = MIN(available, 4ULL * 1024ULL * 1024ULL);
    [fh seekToFileOffset:self.logOffset];
    NSData *data = [fh readDataOfLength:(NSUInteger)toRead];
    if (data.length == 0) {
        return;
    }
    self.logOffset += data.length;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text.length == 0) {
        return;
    }

    NSString *cancelNeedle = @"Cancelling on session: ";
    NSString *promptNeedle = @"Received prompt request for session: ";
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line rangeOfString:cancelNeedle].location != NSNotFound) {
            NSString *session = [self sessionFromLogLine:line after:cancelNeedle];
            if (session.length > 0) {
                self.cancelTimes[session] = [self timestampFromLogLine:line] ?: [NSDate date];
            }
            continue;
        }
        if ([line rangeOfString:promptNeedle].location != NSNotFound) {
            NSString *session = [self sessionFromLogLine:line after:promptNeedle];
            if (session.length > 0) {
                self.lastPromptSession = session;
                self.lastPromptAt = [self timestampFromLogLine:line] ?: [NSDate date];
            }
            continue;
        }
        BOOL failed = [line rangeOfString:@"Turn execution failed:"].location != NSNotFound ||
                      [line rangeOfString:@"Error in model response stream:"].location != NSNotFound;
        if (!failed || self.lastPromptSession.length == 0) {
            continue;
        }
        NSDate *when = [self timestampFromLogLine:line] ?: [NSDate date];
        if (self.lastPromptAt &&
            [when timeIntervalSinceDate:self.lastPromptAt] > 30.0 * 60.0) {
            continue;
        }
        self.cancelTimes[self.lastPromptSession] = when;
    }

    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-MLZedCancelRetention];
    for (NSString *key in self.cancelTimes.allKeys) {
        NSDate *when = self.cancelTimes[key];
        if ([when compare:cutoff] == NSOrderedAscending) {
            [self.cancelTimes removeObjectForKey:key];
        }
    }
}

- (NSString *)sessionFromLogLine:(NSString *)line after:(NSString *)needle {
    NSRange range = [line rangeOfString:needle];
    if (range.location == NSNotFound) {
        return @"";
    }
    NSString *tail =
        [[line substringFromIndex:NSMaxRange(range)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    /* Session ids are UUIDs; stop at whitespace or punctuation. */
    NSRange space = [tail rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    if (space.location != NSNotFound) {
        tail = [tail substringToIndex:space.location];
    }
    return [tail stringByTrimmingCharactersInSet:
                     [NSCharacterSet characterSetWithCharactersInString:@".,;)'\""]];
}

- (nullable NSDate *)timestampFromLogLine:(NSString *)line {
    if (line.length < 25) {
        return nil;
    }
    static NSDateFormatter *stamp = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [[NSDateFormatter alloc] init];
        stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        stamp.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    });
    return [stamp dateFromString:[line substringToIndex:25]];
}

@end
