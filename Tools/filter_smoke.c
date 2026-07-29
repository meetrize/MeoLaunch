/* CLI smoke for ml_filter_apply (M2a). */
#include "ml_app_index.h"
#include "ml_filter.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    MLAppIndex idx;
    const char *roots[] = {
        "~/Applications",
        "/Applications",
        "/System/Applications",
    };
    uint32_t *indices;
    size_t all_n, filt_n;

    idx.items = NULL;
    idx.count = 0;
    idx.capacity = 0;

    if (ml_app_index_scan(&idx, roots, 3) != 0 || idx.count == 0) {
        fprintf(stderr, "scan failed or empty\n");
        return 1;
    }

    indices = (uint32_t *)malloc(idx.count * sizeof(uint32_t));
    if (!indices) {
        ml_app_index_clear(&idx);
        return 1;
    }

    all_n = ml_filter_apply(&idx, "", indices, idx.count);
    if (all_n != idx.count) {
        fprintf(stderr, "empty query expected %zu got %zu\n", idx.count, all_n);
        free(indices);
        ml_app_index_clear(&idx);
        return 2;
    }

    filt_n = ml_filter_apply(&idx, "zzz_no_such_app_meolaunch", indices, idx.count);
    if (filt_n != 0) {
        fprintf(stderr, "nonsense query expected 0 got %zu\n", filt_n);
        free(indices);
        ml_app_index_clear(&idx);
        return 3;
    }

    /* Use first app's display name stem as query if possible */
    {
        const char *name = idx.items[0].display_name;
        char q[8];
        size_t i;
        if (!name || name[0] == '\0') {
            fprintf(stderr, "no display name\n");
            free(indices);
            ml_app_index_clear(&idx);
            return 4;
        }
        q[0] = name[0];
        q[1] = '\0';
        /* For UTF-8 multibyte first char, just take first byte — may fail; try name_fold prefix */
        if ((unsigned char)name[0] >= 0x80 && idx.items[0].name_fold) {
            /* take up to 3 bytes of fold for CJK */
            for (i = 0; i < 3 && idx.items[0].name_fold[i]; i++) {
                q[i] = idx.items[0].name_fold[i];
            }
            q[i] = '\0';
        }
        filt_n = ml_filter_apply(&idx, q, indices, idx.count);
        printf("count=%zu empty=%zu query='%s' matches=%zu\n", idx.count, all_n, q, filt_n);
        if (filt_n == 0 || filt_n > idx.count) {
            fprintf(stderr, "expected some matches for prefix\n");
            free(indices);
            ml_app_index_clear(&idx);
            return 5;
        }
        if (filt_n >= all_n && all_n > 1 && strlen(q) > 0) {
            /* prefix of first app should usually be <= all; equality possible if all share char */
        }
    }

    free(indices);
    ml_app_index_clear(&idx);
    printf("filter_smoke OK\n");
    return 0;
}
