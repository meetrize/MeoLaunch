#import <CoreGraphics/CoreGraphics.h>
#import <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Instantly hide/show another app's window without Dock minimize animation. */
bool MLCGSSetWindowAlpha(CGWindowID windowID, float alpha);
bool MLCGSWindowAlphaAvailable(void);

#ifdef __cplusplus
}
#endif
