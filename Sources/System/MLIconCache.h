#import <Cocoa/Cocoa.h>

@interface MLIconCache : NSObject

@property (nonatomic, assign) NSUInteger maxEntries; /* default 128 */
@property (nonatomic, assign) CGFloat iconPointSize; /* default 128 */

/// Returns cached image or nil if not yet loaded.
- (NSImage *)cachedIconForPath:(NSString *)path;

/// Load icon on a background queue; invokes onLoaded on the main queue when ready.
- (void)loadIconForPath:(NSString *)path onLoaded:(void (^)(NSString *path, NSImage *image))onLoaded;

- (void)purge;
- (NSUInteger)cachedCount;

@end
