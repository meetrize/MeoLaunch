#import <Cocoa/Cocoa.h>

FOUNDATION_EXPORT NSNotificationName const MLTaskbarPinsDidChangeNotification;

@interface MLTaskbarPinStore : NSObject

@property (nonatomic, copy, readonly) NSArray<NSString *> *pinnedPaths;

+ (NSURL *)pinsFileURL;

- (instancetype)init;

- (BOOL)loadFromDisk;
- (BOOL)saveToDisk;
- (void)scheduleSave;

- (BOOL)pinPath:(NSString *)path;
- (BOOL)unpinPath:(NSString *)path;
- (BOOL)isPinned:(NSString *)path;
- (BOOL)movePinFrom:(NSInteger)from to:(NSInteger)to;
/**
 * Move `path` in the global pin list so it sits immediately before `beforePath`.
 * Pass nil `beforePath` to move to the end. No-op / NO if path unknown.
 */
- (BOOL)movePinPath:(NSString *)path beforePath:(NSString *)beforePath;

@end
