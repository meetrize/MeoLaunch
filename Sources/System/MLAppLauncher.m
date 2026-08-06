#import "MLAppLauncher.h"

#import <AppKit/AppKit.h>

@implementation MLAppLauncher

+ (void)openApplicationAtPath:(NSString *)path {
    if (path.length == 0) {
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path isDirectory:YES];
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.activates = YES;
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url
                                          configuration:cfg
                                      completionHandler:^(NSRunningApplication *app, NSError *error) {
                                          if (error) {
                                              NSLog(@"[MeoLaunch] launch failed (%@): %@", path, error);
                                          } else {
                                              NSLog(@"[MeoLaunch] launched %@", app.bundleIdentifier ?: path);
                                          }
                                      }];
}

@end
