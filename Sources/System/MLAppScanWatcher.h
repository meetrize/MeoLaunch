#import <Foundation/Foundation.h>

/** Watches scan-root directories via FSEvents and notifies on .app install/uninstall. */
@interface MLAppScanWatcher : NSObject

@property (nonatomic, copy, nullable) void (^onChange)(void);

- (void)watchPaths:(NSArray<NSString *> * _Nonnull)paths;
- (void)stop;

@end
