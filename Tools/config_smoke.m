/* Verify config.json round-trip for M4. */
#import <Foundation/Foundation.h>
#import "MLConfigStore.h"

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSURL *url = [MLConfigStore configFileURL];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *bak = [url URLByAppendingPathExtension:@"smoke_bak"];
        BOOL had = [fm fileExistsAtPath:url.path];
        if (had) {
            [fm removeItemAtURL:bak error:nil];
            [fm copyItemAtURL:url toURL:bak error:nil];
        }

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

        if (had) {
            [fm removeItemAtURL:url error:nil];
            [fm moveItemAtURL:bak toURL:url error:nil];
        } else {
            [fm removeItemAtURL:url error:nil];
            [fm removeItemAtURL:bak error:nil];
        }
        return 0;
    }
}
