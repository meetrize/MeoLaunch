#import <Cocoa/Cocoa.h>

#include "ml_app_index.h"
#include "ml_layout.h"

FOUNDATION_EXPORT NSNotificationName const MLLayoutStoreDidChangeNotification;

@interface MLLayoutStore : NSObject

@property (nonatomic, assign, readonly) MLLayout *layout; /* owned; never NULL after init */

+ (NSURL *)layoutFileURL;

- (instancetype)init;

- (BOOL)loadFromDisk;
- (BOOL)saveToDisk;
- (void)scheduleSave;

/// Prune missing / append new apps. Saves if changed. Returns change count.
- (int)syncWithAppIndex:(const MLAppIndex *)index;

/// Reorder flat app list (legacy; dissolves folders). Prefer moveRootFrom:to:.
- (BOOL)moveFlatAppFrom:(NSInteger)from to:(NSInteger)to;

- (BOOL)moveRootFrom:(NSInteger)from to:(NSInteger)to;

/// Merge two root apps into a folder. Returns new folder id or nil.
- (NSString *)mergeRootAppFrom:(NSInteger)drag onto:(NSInteger)target;

/// Add root app into existing folder at folderRootIndex.
- (BOOL)addRootAppFrom:(NSInteger)drag toFolderAt:(NSInteger)folderRootIndex;

- (BOOL)renameFolderId:(NSString *)folderId name:(NSString *)name;

/// Reorder apps inside an open folder.
- (BOOL)reorderFolderId:(NSString *)folderId from:(NSInteger)from to:(NSInteger)to;

/// Drag an app out of a folder onto the root grid. Returns whether the folder was dissolved.
- (BOOL)extractAppAt:(NSInteger)itemIndex
         fromFolderId:(NSString *)folderId
          folderGone:(BOOL *)folderGone;

@end
