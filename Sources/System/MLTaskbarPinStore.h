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

@end
