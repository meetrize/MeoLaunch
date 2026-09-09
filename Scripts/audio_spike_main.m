#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>
#import "MLAudioProcessSupport.h"
#import "MLAppAudioMuteController.h"

/**
 * Headless spike for doc/19 A0.
 * Usage:
 *   audio_spike                 # list process objects + running-output PIDs
 *   audio_spike --mute <pid>    # mute 2s then unmute (requires audio TCC if prompted)
 */
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        printf("MLAudioProcessSupport available: %s\n",
               [MLAudioProcessSupport isAvailable] ? "YES" : "NO");
        if (![MLAudioProcessSupport isAvailable]) {
            printf("SKIP: need macOS 14.2+\n");
            return 0;
        }

        NSArray<MLAudioProcessInfo *> *infos = [MLAudioProcessSupport copyProcessInfos];
        printf("process objects: %lu\n", (unsigned long)infos.count);
        NSUInteger running = 0;
        for (MLAudioProcessInfo *info in infos) {
            if (!info.isRunningOutput) {
                continue;
            }
            running++;
            printf("  OUT pid=%d obj=%u bundle=%s\n",
                   (int)info.pid,
                   (unsigned)info.objectID,
                   info.bundleID ? info.bundleID.UTF8String : "(none)");
        }
        printf("running output: %lu\n", (unsigned long)running);

        pid_t mutePid = 0;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--mute") == 0 && i + 1 < argc) {
                mutePid = (pid_t)atoi(argv[++i]);
            }
        }

        if (mutePid > 0) {
            MLAppAudioMuteController *mute = [[MLAppAudioMuteController alloc] init];
            NSError *err = nil;
            printf("mute pid=%d ...\n", (int)mutePid);
            if (![mute mutePID:mutePid error:&err]) {
                fprintf(stderr, "mute failed: %s\n", err.localizedDescription.UTF8String ?: "?");
                if (err.userInfo[@"osStatus"]) {
                    fprintf(stderr, "  osStatus=%d\n", [err.userInfo[@"osStatus"] intValue]);
                }
                return 2;
            }
            printf("muted OK; sleeping 2s\n");
            sleep(2);
            if (![mute unmutePID:mutePid error:&err]) {
                fprintf(stderr, "unmute failed: %s\n", err.localizedDescription.UTF8String ?: "?");
                return 3;
            }
            printf("unmuted OK\n");
        } else {
            printf("(pass --mute <pid> to exercise Process Tap mute)\n");
        }
        return 0;
    }
}
