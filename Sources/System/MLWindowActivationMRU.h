#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Session-only MRU of window activations (doc/22 Chip Locator).
 * Newest first; not persisted. Path-level list covers NoWindow / Pin chips.
 */
@interface MLWindowActivationMRU : NSObject

/** Max window entries retained (default 64). */
@property (nonatomic, assign) NSUInteger windowCapacity;
/** Max path entries retained (default 64). */
@property (nonatomic, assign) NSUInteger pathCapacity;
/** Max screen-level MRU entries (default 16). */
@property (nonatomic, assign) NSUInteger screenCapacity;

- (void)touchWindowID:(CGWindowID)windowID
                 path:(nullable NSString *)path
             screenID:(nullable NSNumber *)screenID;
- (void)touchPath:(NSString *)path screenID:(nullable NSNumber *)screenID;
- (void)removeWindowID:(CGWindowID)windowID;
- (void)removePath:(NSString *)path;

/**
 * Rank for sorting within a section: 0 = most recent.
 * Returns NSIntegerMax when never touched (sort after MRU hits).
 */
- (NSInteger)rankForWindowID:(CGWindowID)windowID;
- (NSInteger)rankForPath:(NSString *)path;
/** Screen-level MRU: 0 = most recently activated screen. NSIntegerMax if unknown. */
- (NSInteger)rankForScreenID:(NSNumber *)screenID;

/** Drop windowIDs / paths that are no longer live. */
- (void)pruneToLiveWindowIDs:(NSSet<NSNumber *> *)liveWindowIDs
                   livePaths:(nullable NSSet<NSString *> *)livePaths;

@end

NS_ASSUME_NONNULL_END
