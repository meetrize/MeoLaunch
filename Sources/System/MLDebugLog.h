#import <Foundation/Foundation.h>

/*
 * Hot-path logging. Default OFF in normal builds (Scripts/build.sh).
 * Enable: clang -DML_ENABLE_DEBUG_LOG=1
 */
#ifndef ML_ENABLE_DEBUG_LOG
#define ML_ENABLE_DEBUG_LOG 0
#endif

#if ML_ENABLE_DEBUG_LOG
#define MLDebugLog(...) NSLog(__VA_ARGS__)
#else
#define MLDebugLog(...) ((void)0)
#endif
