#import <Cocoa/Cocoa.h>

@interface MLTaskbarIconCache : NSObject

@property (nonatomic, assign) NSUInteger maxEntries; /* default 48 */
@property (nonatomic, assign) CGFloat iconPointSize; /* default 32 */

- (NSImage *)cachedIconForPath:(NSString *)path;
- (void)loadIconForPath:(NSString *)path
               onLoaded:(void (^)(NSString *path, NSImage *image))onLoaded;
- (void)purge;
- (NSUInteger)cachedCount;

@end
