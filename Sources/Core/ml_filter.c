#include "ml_filter.h"

#include "ml_util.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

static int query_is_empty(const char *q) {
    size_t i;
    if (!q) {
        return 1;
    }
    for (i = 0; q[i] != '\0'; i++) {
        if (!isspace((unsigned char)q[i])) {
            return 0;
        }
    }
    return 1;
}

size_t ml_filter_apply(const MLAppIndex *idx,
                       const char *query_utf8,
                       uint32_t *out_indices,
                       size_t out_cap) {
    size_t i, matches = 0;
    char *qfold = NULL;
    int empty;

    if (!idx || !out_indices || out_cap == 0) {
        return 0;
    }

    empty = query_is_empty(query_utf8);
    if (!empty) {
        qfold = ml_str_fold(query_utf8);
        if (!qfold) {
            return 0;
        }
    }

    for (i = 0; i < idx->count; i++) {
        int match = empty;

        if (!empty) {
            const char *hay = idx->items[i].name_fold;
            match = (hay && strstr(hay, qfold) != NULL);
        }

        if (!match) {
            continue;
        }
        if (matches < out_cap) {
            out_indices[matches] = (uint32_t)i;
        }
        matches++;
    }

    free(qfold);
    return matches < out_cap ? matches : out_cap;
}
