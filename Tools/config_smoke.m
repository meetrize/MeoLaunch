/* Verify config.json round-trip for M4. Uses MEOLAUNCH_CONFIG_PATH (set by Scripts/config_smoke.sh). */
#import <Foundation/Foundation.h>
#import "MLConfigStore.h"

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSURL *url = [MLConfigStore configFileURL];
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];

        MLConfigStore *store = [[MLConfigStore alloc] init];
        [store loadDefaults];
        [store updateGridCols:6 rows:4];
        [store updateHotCornerEnabled:YES
                             position:MLHotCornerPositionTopRight
                               sizePt:8
                              delayMs:50];
        /* flush debounce */
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        if (![store saveToDisk]) {
            fprintf(stderr, "save failed\n");
            return 1;
        }

        MLConfigStore *loaded = [[MLConfigStore alloc] init];
        if (![loaded loadFromDisk]) {
            fprintf(stderr, "expected loadFromDisk YES after save\n");
            return 2;
        }
        if (loaded.gridConfig.cols != 6 || loaded.gridConfig.rows != 4) {
            fprintf(stderr, "grid mismatch: %dx%d\n", loaded.gridConfig.cols, loaded.gridConfig.rows);
            return 3;
        }
        if (loaded.hotCornerPosition != MLHotCornerPositionTopRight) {
            fprintf(stderr, "corner mismatch\n");
            return 4;
        }
        if (loaded.hotCornerSizePt < 7.9 || loaded.hotCornerSizePt > 8.1) {
            fprintf(stderr, "size mismatch %f\n", loaded.hotCornerSizePt);
            return 5;
        }

        printf("config_smoke OK path=%s cols=%d rows=%d\n",
               url.fileSystemRepresentation,
               loaded.gridConfig.cols,
               loaded.gridConfig.rows);

        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 0;
    }
}
