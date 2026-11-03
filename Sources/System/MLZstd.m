#import "MLZstd.h"

#include "zstddeclib.h"

#import <stdlib.h>

static const NSUInteger MLZstdMaxOutputBytes = 64u * 1024u * 1024u;

NSData *MLZstdDecompressData(NSData *compressed) {
    if (compressed.length == 0) {
        return nil;
    }

    const void *src = compressed.bytes;
    size_t srcLen = compressed.length;
    unsigned long long declared = ZSTD_getFrameContentSize(src, srcLen);
    if (declared != ZSTD_CONTENTSIZE_UNKNOWN && declared != ZSTD_CONTENTSIZE_ERROR) {
        if (declared > MLZstdMaxOutputBytes) {
            return nil;
        }
        NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)declared];
        size_t result = ZSTD_decompress(out.mutableBytes, out.length, src, srcLen);
        if (ZSTD_isError(result) || result != (size_t)declared) {
            return nil;
        }
        out.length = result;
        return out;
    }

    /* Frame header omitted the content size (Zed's encoder does this). Grow
       until the decoder is happy, with a hard cap to avoid decompression bombs. */
    NSUInteger capacity = MAX((NSUInteger)64 * 1024, compressed.length * 8);
    while (capacity <= MLZstdMaxOutputBytes) {
        NSMutableData *out = [NSMutableData dataWithLength:capacity];
        size_t result = ZSTD_decompress(out.mutableBytes, out.length, src, srcLen);
        if (!ZSTD_isError(result)) {
            out.length = result;
            return out;
        }
        /* The only recoverable failure here is an undersized output buffer. */
        capacity *= 2;
    }
    return nil;
}
