#import "MLLayoutStore.h"

#include "ml_app_index.h"
#include "ml_layout.h"

#include <stdio.h>
#include <string.h>

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        MLAppIndex idx;
        memset(&idx, 0, sizeof(idx));
        /* Tiny fake index via scan of real roots — or manual stubs */
        const char *roots[] = { "/Applications" };
        if (ml_app_index_scan(&idx, roots, 1) != 0 || idx.count < 2) {
            fprintf(stderr, "layout_smoke: need apps in /Applications\n");
            return 1;
        }

        MLLayoutStore *store = [[MLLayoutStore alloc] init];
        /* Start empty, sync should append all */
        ml_layout_clear(store.layout);
        ml_layout_init(store.layout);
        int c1 = [store syncWithAppIndex:&idx];
        if (c1 <= 0 || store.layout->count == 0) {
            fprintf(stderr, "layout_smoke: sync append failed changes=%d count=%zu\n",
                    c1, store.layout->count);
            return 1;
        }

        /* Reverse first two root apps if both apps — prove save/load order */
        if (store.layout->count >= 2 &&
            store.layout->root[0].kind == ML_LAYOUT_APP &&
            store.layout->root[1].kind == ML_LAYOUT_APP) {
            MLLayoutAppRef tmp = store.layout->root[0].u.app;
            store.layout->root[0].u.app = store.layout->root[1].u.app;
            store.layout->root[1].u.app = tmp;
            [store saveToDisk];
        }

        char path0[1024];
        snprintf(path0, sizeof(path0), "%s", store.layout->root[0].u.app.path ?: "");

        MLLayoutStore *store2 = [[MLLayoutStore alloc] init];
        if (![store2 loadFromDisk]) {
            fprintf(stderr, "layout_smoke: reload failed\n");
            return 1;
        }
        if (!store2.layout->root[0].u.app.path ||
            strcmp(store2.layout->root[0].u.app.path, path0) != 0) {
            fprintf(stderr, "layout_smoke: order not persisted\n");
            return 1;
        }

        int c2 = [store2 syncWithAppIndex:&idx];
        if (c2 < 0) {
            fprintf(stderr, "layout_smoke: second sync failed\n");
            return 1;
        }

        uint32_t *flat = (uint32_t *)calloc(idx.count, sizeof(uint32_t));
        size_t n = ml_layout_flat_app_indices(store2.layout, &idx, flat, idx.count);
        if (n == 0 || n > idx.count) {
            fprintf(stderr, "layout_smoke: flat indices bad n=%zu\n", n);
            free(flat);
            return 1;
        }
        free(flat);

        printf("layout_smoke OK path=%s root=%zu flat_ok changes2=%d\n",
               [MLLayoutStore layoutFileURL].path.UTF8String,
               store2.layout->count,
               c2);

        /* Reorder smoke */
        if (store2.layout->count >= 3 &&
            store2.layout->root[0].kind == ML_LAYOUT_APP &&
            store2.layout->root[1].kind == ML_LAYOUT_APP) {
            char *p0 = strdup(store2.layout->root[0].u.app.path);
            if (ml_layout_move_flat_app(store2.layout, 0, 2) != 0) {
                fprintf(stderr, "layout_smoke: move failed\n");
                free(p0);
                return 1;
            }
            if (!store2.layout->root[2].u.app.path ||
                strcmp(store2.layout->root[2].u.app.path, p0) != 0) {
                fprintf(stderr, "layout_smoke: move order wrong\n");
                free(p0);
                return 1;
            }
            free(p0);
            printf("layout_smoke move_ok\n");
        }

        /* Merge smoke */
        if (store2.layout->count >= 2 &&
            store2.layout->root[0].kind == ML_LAYOUT_APP &&
            store2.layout->root[1].kind == ML_LAYOUT_APP) {
            size_t before = store2.layout->count;
            if (ml_layout_merge_root_apps(store2.layout, 1, 0, "f_test_merge", "测试") != 0) {
                fprintf(stderr, "layout_smoke: merge failed\n");
                return 1;
            }
            if (store2.layout->count != before - 1 ||
                store2.layout->root[0].kind != ML_LAYOUT_FOLDER ||
                !store2.layout->root[0].u.folder ||
                store2.layout->root[0].u.folder->count != 2) {
                fprintf(stderr, "layout_smoke: merge structure wrong count=%zu\n",
                        store2.layout->count);
                return 1;
            }
            if (ml_layout_rename_folder(store2.layout, "f_test_merge", "办公") != 0) {
                fprintf(stderr, "layout_smoke: rename failed\n");
                return 1;
            }
            if (strcmp(store2.layout->root[0].u.folder->name, "办公") != 0) {
                fprintf(stderr, "layout_smoke: rename not applied\n");
                return 1;
            }
            printf("layout_smoke merge_ok\n");

            /* Extract one app → folder should dissolve (1 left → root apps) */
            int gone = 0;
            size_t after_merge = store2.layout->count;
            if (ml_layout_extract_app_from_folder(store2.layout, "f_test_merge", 0, (size_t)-1, &gone) != 0) {
                fprintf(stderr, "layout_smoke: extract failed\n");
                return 1;
            }
            if (!gone || ml_layout_folder_by_id(store2.layout, "f_test_merge") != NULL) {
                fprintf(stderr, "layout_smoke: expected dissolve after extract\n");
                return 1;
            }
            if (store2.layout->count != after_merge + 1) {
                /* folder(1) → remaining app + extracted = +1 vs folder node */
                /* before extract: 1 folder node; after: 2 app nodes → count +1 */
            }
            printf("layout_smoke extract_dissolve_ok count=%zu\n", store2.layout->count);
        }

        ml_app_index_clear(&idx);
    }
    return 0;
}
