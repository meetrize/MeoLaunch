#import <Foundation/Foundation.h>

@interface MLAppLauncher : NSObject

/** Launch a .app bundle at path and bring it to the foreground. */
+ (void)openApplicationAtPath:(NSString *)path;

@end
