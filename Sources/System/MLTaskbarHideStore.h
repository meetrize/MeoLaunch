#import <Cocoa/Cocoa.h>

FOUNDATION_EXPORT NSNotificationName const MLTaskbarHideDidChangeNotification;

@interface MLTaskbarHideStore : NSObject

@property (nonatomic, copy, readonly) NSArray<NSString *> *hiddenPaths;

+ (NSURL *)hiddenChipsFileURL;

- (instancetype)init;

- (BOOL)loadFromDisk;
- (BOOL)saveToDisk;
- (void)scheduleSave;

- (BOOL)hidePath:(NSString *)path;
- (BOOL)unhidePath:(NSString *)path;
- (BOOL)isHidden:(NSString *)path;

@end
