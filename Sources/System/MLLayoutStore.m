#import "MLLayoutStore.h"

NSNotificationName const MLLayoutStoreDidChangeNotification = @"MLLayoutStoreDidChangeNotification";

@interface MLLayoutStore ()
@property (nonatomic, assign, readwrite) MLLayout *layout;
@property (nonatomic, strong) NSTimer *saveTimer;
@end

@implementation MLLayoutStore

+ (NSURL *)layoutFileURL {
    NSString *override = NSProcessInfo.processInfo.environment[@"MEOLAUNCH_LAYOUT_PATH"];
    if (override.length > 0) {
        return [NSURL fileURLWithPath:override];
    }
    NSArray<NSURL *> *urls = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                                    inDomains:NSUserDomainMask];
    NSURL *base = urls.firstObject;
    return [base URLByAppendingPathComponent:@"meoLaunch/layout.json"];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _layout = (MLLayout *)calloc(1, sizeof(MLLayout));
        if (_layout) {
            ml_layout_init(_layout);
        }
    }
    return self;
}

- (void)dealloc {
    [self.saveTimer invalidate];
    if (_layout) {
        ml_layout_clear(_layout);
        free(_layout);
        _layout = NULL;
    }
}

- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:MLLayoutStoreDidChangeNotification
                                                        object:self];
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *root = [NSMutableArray arrayWithCapacity:self.layout->count];
    for (size_t i = 0; i < self.layout->count; i++) {
        const MLLayoutNode *node = &self.layout->root[i];
        if (node->kind == ML_LAYOUT_APP && node->u.app.path) {
            [root addObject:@{
                @"type" : @"app",
                @"path" : [NSString stringWithUTF8String:node->u.app.path]
            }];
        } else if (node->kind == ML_LAYOUT_FOLDER && node->u.folder) {
            const MLLayoutFolder *f = node->u.folder;
            NSMutableArray *items = [NSMutableArray arrayWithCapacity:f->count];
            for (size_t j = 0; j < f->count; j++) {
                if (!f->items[j].path) {
                    continue;
                }
                [items addObject:@{
                    @"type" : @"app",
                    @"path" : [NSString stringWithUTF8String:f->items[j].path]
                }];
            }
            [root addObject:@{
                @"type" : @"folder",
                @"id" : f->id ? [NSString stringWithUTF8String:f->id] : @"",
                @"name" : f->name ? [NSString stringWithUTF8String:f->name] : @"",
                @"items" : items
            }];
        }
    }
    return @{
        @"version" : @1,
        @"root" : root
    };
}

- (void)applyDictionary:(NSDictionary *)rootDict {
    ml_layout_clear(self.layout);
    ml_layout_init(self.layout);

    NSArray *root = rootDict[@"root"];
    if (![root isKindOfClass:[NSArray class]]) {
        return;
    }

    for (id item in root) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *dict = (NSDictionary *)item;
        NSString *type = dict[@"type"];
        if ([type isEqualToString:@"app"]) {
            NSString *path = dict[@"path"];
            if (path.length > 0) {
                ml_layout_append_app(self.layout, path.UTF8String);
            }
        } else if ([type isEqualToString:@"folder"]) {
            NSString *fid = dict[@"id"];
            NSString *name = dict[@"name"] ?: @"";
            if (fid.length == 0) {
                continue;
            }
            MLLayoutFolder *folder = ml_layout_append_folder(self.layout, fid.UTF8String, name.UTF8String);
            if (!folder) {
                continue;
            }
            NSArray *items = dict[@"items"];
            if (![items isKindOfClass:[NSArray class]]) {
                continue;
            }
            for (id child in items) {
                if (![child isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                NSDictionary *cd = (NSDictionary *)child;
                if (![cd[@"type"] isEqualToString:@"app"]) {
                    continue;
                }
                NSString *path = cd[@"path"];
                if (path.length > 0) {
                    ml_layout_folder_append_app(folder, path.UTF8String);
                }
            }
        }
    }
}

- (BOOL)loadFromDisk {
    if (!self.layout) {
        return NO;
    }
    NSURL *url = [[self class] layoutFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:url.path]) {
        return NO;
    }

    NSError *err = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&err];
    if (!data) {
        NSLog(@"[MeoLaunch] layout read failed: %@", err);
        return NO;
    }

    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![json isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[MeoLaunch] layout corrupt, ignoring: %@", err);
        NSURL *bak = [url URLByAppendingPathExtension:@"bak"];
        [fm removeItemAtURL:bak error:nil];
        [fm moveItemAtURL:url toURL:bak error:nil];
        ml_layout_clear(self.layout);
        ml_layout_init(self.layout);
        return NO;
    }

    [self applyDictionary:(NSDictionary *)json];
    NSLog(@"[MeoLaunch] layout loaded %@ (%zu root nodes)", url.path, self.layout->count);
    return YES;
}

- (BOOL)saveToDisk {
    if (!self.layout) {
        return NO;
    }
    NSURL *url = [[self class] layoutFileURL];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *err = nil;
    if (![fm createDirectoryAtURL:[url URLByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&err]) {
        NSLog(@"[MeoLaunch] layout dir failed: %@", err);
        return NO;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:[self dictionaryRepresentation]
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:&err];
    if (!data) {
        NSLog(@"[MeoLaunch] layout encode failed: %@", err);
        return NO;
    }
    if (![data writeToURL:url options:NSDataWritingAtomic error:&err]) {
        NSLog(@"[MeoLaunch] layout write failed: %@", err);
        return NO;
    }
    NSLog(@"[MeoLaunch] layout saved %@ (%zu root nodes)", url.path, self.layout->count);
    return YES;
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

- (int)syncWithAppIndex:(const MLAppIndex *)index {
    if (!self.layout || !index) {
        return -1;
    }
    int changes = ml_layout_sync_with_index(self.layout, index);
    if (changes < 0) {
        return -1;
    }
    /* Always persist after sync so first launch creates layout.json */
    if (changes > 0 || ![[NSFileManager defaultManager] fileExistsAtPath:[[self class] layoutFileURL].path]) {
        [self saveToDisk];
    }
    if (changes > 0) {
        [self notifyChanged];
    }
    return changes;
}

- (BOOL)moveFlatAppFrom:(NSInteger)from to:(NSInteger)to {
    if (!self.layout || from < 0 || to < 0) {
        return NO;
    }
    if (from == to) {
        return YES;
    }
    if (ml_layout_move_flat_app(self.layout, (size_t)from, (size_t)to) != 0) {
        return NO;
    }
    [self scheduleSave];
    NSLog(@"[MeoLaunch] layout reorder %ld -> %ld", (long)from, (long)to);
    return YES;
}

- (BOOL)moveRootFrom:(NSInteger)from to:(NSInteger)to {
    if (!self.layout || from < 0 || to < 0) {
        return NO;
    }
    if (from == to) {
        return YES;
    }
    if (ml_layout_move_root(self.layout, (size_t)from, (size_t)to) != 0) {
        return NO;
    }
    [self scheduleSave];
    NSLog(@"[MeoLaunch] layout root move %ld -> %ld", (long)from, (long)to);
    return YES;
}

- (NSString *)mergeRootAppFrom:(NSInteger)drag onto:(NSInteger)target {
    if (!self.layout || drag < 0 || target < 0) {
        return nil;
    }
    NSString *fid = [NSString stringWithFormat:@"f_%@", NSUUID.UUID.UUIDString];
    if (ml_layout_merge_root_apps(self.layout,
                                  (size_t)drag,
                                  (size_t)target,
                                  fid.UTF8String,
                                  "") != 0) {
        return nil;
    }
    [self scheduleSave];
    NSLog(@"[MeoLaunch] layout merge %ld+%ld -> %@", (long)drag, (long)target, fid);
    return fid;
}

- (BOOL)addRootAppFrom:(NSInteger)drag toFolderAt:(NSInteger)folderRootIndex {
    if (!self.layout || drag < 0 || folderRootIndex < 0) {
        return NO;
    }
    if (ml_layout_add_root_app_to_folder(self.layout, (size_t)drag, (size_t)folderRootIndex) != 0) {
        return NO;
    }
    [self scheduleSave];
    NSLog(@"[MeoLaunch] layout add %ld into folder@%ld", (long)drag, (long)folderRootIndex);
    return YES;
}

- (BOOL)renameFolderId:(NSString *)folderId name:(NSString *)name {
    if (!self.layout || folderId.length == 0) {
        return NO;
    }
    if (ml_layout_rename_folder(self.layout, folderId.UTF8String, name.UTF8String ?: "") != 0) {
        return NO;
    }
    [self scheduleSave];
    return YES;
}

- (BOOL)reorderFolderId:(NSString *)folderId from:(NSInteger)from to:(NSInteger)to {
    if (!self.layout || folderId.length == 0 || from < 0 || to < 0) {
        return NO;
    }
    if (from == to) {
        return YES;
    }
    if (ml_layout_reorder_folder_apps(self.layout, folderId.UTF8String, (size_t)from, (size_t)to) != 0) {
        return NO;
    }
    [self scheduleSave];
    return YES;
}

- (BOOL)extractAppAt:(NSInteger)itemIndex
        fromFolderId:(NSString *)folderId
          folderGone:(BOOL *)folderGone {
    if (!self.layout || folderId.length == 0 || itemIndex < 0) {
        return NO;
    }
    int gone = 0;
    if (ml_layout_extract_app_from_folder(self.layout,
                                          folderId.UTF8String,
                                          (size_t)itemIndex,
                                          (size_t)-1,
                                          &gone) != 0) {
        return NO;
    }
    if (folderGone) {
        *folderGone = gone ? YES : NO;
    }
    [self scheduleSave];
    NSLog(@"[MeoLaunch] layout extract item %ld from %@ gone=%d",
          (long)itemIndex, folderId, gone);
    return YES;
}

@end
