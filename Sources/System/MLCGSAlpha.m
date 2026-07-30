#import "MLCGSAlpha.h"

#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <stdio.h>

typedef uint32_t MLCGSConnectionID;

typedef MLCGSConnectionID (*MLCGSMainConnectionIDFunc)(void);
typedef int32_t (*MLCGSSetWindowAlphaFunc)(MLCGSConnectionID cid, uint32_t wid, float alpha);
typedef int32_t (*MLCGSGetWindowAlphaFunc)(MLCGSConnectionID cid, uint32_t wid, float *outAlpha);

static MLCGSMainConnectionIDFunc sMainConn;
static MLCGSSetWindowAlphaFunc sSetAlpha;
static MLCGSGetWindowAlphaFunc sGetAlpha;
static dispatch_once_t sOnce;
static bool sResolved;

static void MLCGSResolve(void) {
    dispatch_once(&sOnce, ^{
        void *handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
        if (!handle) {
            handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
        }
        if (!handle) {
            return;
        }
        sMainConn = (MLCGSMainConnectionIDFunc)dlsym(handle, "CGSMainConnectionID");
        sSetAlpha = (MLCGSSetWindowAlphaFunc)dlsym(handle, "CGSSetWindowAlpha");
        sGetAlpha = (MLCGSGetWindowAlphaFunc)dlsym(handle, "CGSGetWindowAlpha");
        sResolved = (sMainConn != NULL && sSetAlpha != NULL);
        if (!sResolved) {
            fprintf(stderr, "[MeoLaunch] CGSSetWindowAlpha unavailable\n");
        }
    });
}

bool MLCGSWindowAlphaAvailable(void) {
    MLCGSResolve();
    return sResolved;
}

/** Read alpha from public CGWindowList (works cross-process). */
static float MLCGWindowListAlpha(CGWindowID windowID) {
    if (windowID == 0) {
        return -1.0f;
    }
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow, windowID);
    if (!list) {
        return -1.0f;
    }
    float alpha = -1.0f;
    if (CFArrayGetCount(list) > 0) {
        CFDictionaryRef info = (CFDictionaryRef)CFArrayGetValueAtIndex(list, 0);
        CFNumberRef alphaRef = info ? CFDictionaryGetValue(info, kCGWindowAlpha) : NULL;
        if (alphaRef) {
            double v = 1.0;
            CFNumberGetValue(alphaRef, kCFNumberDoubleType, &v);
            alpha = (float)v;
        } else {
            alpha = 1.0f;
        }
    }
    CFRelease(list);
    return alpha;
}

bool MLCGSSetWindowAlpha(CGWindowID windowID, float alpha) {
    MLCGSResolve();
    if (!sResolved || windowID == kCGNullWindowID || windowID == 0) {
        return false;
    }
    MLCGSConnectionID cid = sMainConn();
    int32_t err = sSetAlpha(cid, (uint32_t)windowID, alpha);
    if (err != 0) {
        fprintf(stderr, "[MeoLaunch] CGSSetWindowAlpha(%u, %.2f) err=%d\n",
                (unsigned)windowID, alpha, (int)err);
        return false;
    }

    /* Cross-process alpha often no-ops without Dock privilege — verify. */
    float got = MLCGWindowListAlpha(windowID);
    if (got < 0.0f && sGetAlpha) {
        float priv = 1.0f;
        if (sGetAlpha(cid, (uint32_t)windowID, &priv) == 0) {
            got = priv;
        }
    }
    if (alpha <= 0.05f) {
        if (got < 0.0f) {
            /* Window vanished from list — treat as hidden. */
            return true;
        }
        if (got > 0.15f) {
            fprintf(stderr,
                    "[MeoLaunch] CGSSetWindowAlpha(%u) returned OK but alpha=%.2f (no privilege?)\n",
                    (unsigned)windowID, got);
            return false;
        }
        return true;
    }
    if (got >= 0.0f && got < 0.5f) {
        return false;
    }
    return true;
}
