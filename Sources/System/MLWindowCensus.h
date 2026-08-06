#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

/** Lightweight CGWindowList fingerprint for open/close / cross-display detection. */
@interface MLWindowCensus : NSObject

+ (NSInteger)screenIndexForCocoaPoint:(CGPoint)point;

/** Token string; skips soft-hidden window IDs when provided. */
- (NSString *)computeTokenSkippingSoftHidden:(NSSet<NSNumber *> *)softHiddenIDs;

@end
