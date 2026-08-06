#import <Foundation/Foundation.h>

enum {
    MLTaskbarBarHeight = 40,
    MLTaskbarPeekOffset = 28,
    MLTaskbarHideConfirmCount = 2,
};

/** Quiet period before painting live candidates — absorbs Show Desktop / Exposé churn. */
FOUNDATION_EXPORT const NSTimeInterval MLTaskbarItemsCommitDelay;
/** After leaving peek, wait for window list to settle before one atomic paint. */
FOUNDATION_EXPORT const NSTimeInterval MLTaskbarExitSettleDelay;

typedef NS_ENUM(NSInteger, MLTaskbarBarMode) {
    MLTaskbarBarModeNormal = 0,
    MLTaskbarBarModePeek = 1,   /* Show Desktop: keep bar, slide down slightly */
    MLTaskbarBarModeHidden = 2, /* Immersive / Space fullscreen */
};
