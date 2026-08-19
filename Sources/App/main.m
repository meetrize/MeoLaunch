#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

static void MLUncaughtException(NSException *exception) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"MeoLaunch-exception.log"];
    NSString *body = [NSString stringWithFormat:@"%@\n%@: %@\n%@\n\n",
                      [NSDate date],
                      exception.name,
                      exception.reason,
                      [exception.callStackSymbols componentsJoinedByString:@"\n"]];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[body dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    NSLog(@"[MeoLaunch] UNCAUGHT %@: %@", exception.name, exception.reason);
}

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    NSSetUncaughtExceptionHandler(&MLUncaughtException);
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
