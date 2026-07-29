/* CLI smoke test for ml_app_index_scan (M1a acceptance). */
#include "ml_app_index.h"

#include <stdio.h>
#include <stdlib.h>

int main(void) {
    MLAppIndex idx;
    const char *roots[] = {
        "~/Applications",
        "/Applications",
        "/System/Applications",
    };
    size_t i, n;

    idx.items = NULL;
    idx.count = 0;
    idx.capacity = 0;

    if (ml_app_index_scan(&idx, roots, 3) != 0) {
        fprintf(stderr, "scan failed\n");
        return 1;
    }

    printf("count=%zu\n", idx.count);
    n = idx.count < 8 ? idx.count : 8;
    for (i = 0; i < n; i++) {
        printf("  %s\n", idx.items[i].display_name);
    }

    if (idx.count == 0) {
        fprintf(stderr, "expected count > 0\n");
        ml_app_index_clear(&idx);
        return 2;
    }

    ml_app_index_clear(&idx);
    return 0;
}
