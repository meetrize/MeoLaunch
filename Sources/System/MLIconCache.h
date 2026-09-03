#import <Cocoa/Cocoa.h>

@interface MLIconCache : NSObject

@property (nonatomic, assign) NSUInteger maxEntries; /* default 128 */
@property (nonatomic, assign) CGFloat iconPointSize; /* default 128 */

/**
 * When YES, successful loads also write PNG thumbnails under Caches.
 * RAM purge keeps disk; reopen reads disk before iconForFile.
 * Default NO (Taskbar); Overlay should enable.
 */
@property (nonatomic, assign) BOOL diskCacheEnabled;

/** Max on-disk thumbnails when diskCacheEnabled (default 256). */
@property (nonatomic, assign) NSUInteger diskCacheMaxEntries;

/// Returns cached image or nil if not yet loaded.
- (NSImage *)cachedIconForPath:(NSString *)path;

/// Load icon on a background queue; invokes onLoaded on the main queue when ready.
- (void)loadIconForPath:(NSString *)path onLoaded:(void (^)(NSString *path, NSImage *image))onLoaded;

/** Drop RAM entries only (disk thumbnails kept if enabled). */
- (void)purge;

/** Remove on-disk thumbnails (no-op if diskCacheEnabled is NO). */
- (void)purgeDiskCache;

- (NSUInteger)cachedCount;

@end
