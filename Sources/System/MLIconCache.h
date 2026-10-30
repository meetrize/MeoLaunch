#import <Cocoa/Cocoa.h>

/** Prefs / menu: clear icon RAM+disk and reload from app bundles. */
FOUNDATION_EXPORT NSNotificationName const MLIconCacheRefreshRequestedNotification;

@interface MLIconCache : NSObject

@property (nonatomic, assign) NSUInteger maxEntries; /* default 128 */
@property (nonatomic, assign) CGFloat iconPointSize; /* default 128 */

/**
 * When YES, successful loads also write slim PNG thumbnails under Caches
 * (single bitmap at display pixel size). RAM purge keeps disk; reopen reads
 * disk before iconForFile. Default NO (Taskbar); Overlay should enable.
 */
@property (nonatomic, assign) BOOL diskCacheEnabled;

/** Max on-disk thumbnails when diskCacheEnabled (default 256). */
@property (nonatomic, assign) NSUInteger diskCacheMaxEntries;

/// Returns cached image or nil if not yet loaded.
- (NSImage *)cachedIconForPath:(NSString *)path;

/**
 * Synchronously return a Slim icon (cache hit or rasterize once).
 * Prefer async loadIconForPath for grid fill; use this for rare UI paths
 * (e.g. launch animation) that must not hold a multi-rep Workspace image.
 */
- (NSImage *)slimIconForPath:(NSString *)path pointSize:(CGFloat)pointSize;

/// Load icon on a background queue; invokes onLoaded on the main queue when ready.
- (void)loadIconForPath:(NSString *)path onLoaded:(void (^)(NSString *path, NSImage *image))onLoaded;

/** Drop RAM entries only (disk thumbnails kept if enabled). */
- (void)purge;

/** Remove on-disk thumbnails (no-op if diskCacheEnabled is NO). */
- (void)purgeDiskCache;

/**
 * Drop RAM and on-disk thumbnails so the next load re-reads app icons
 * (e.g. after an app replaced its icon).
 */
- (void)purgeAllCaches;

- (NSUInteger)cachedCount;

@end
