#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Decompresses a single Zstandard frame (as written by Zed's thread store).
 * Returns nil for invalid input or output larger than 64 MiB.
 */
FOUNDATION_EXPORT NSData *_Nullable MLZstdDecompressData(NSData *compressed);

NS_ASSUME_NONNULL_END
