#pragma once

#include "ml_app_index.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Filter index by UTF-8 query (case-insensitive substring on name_fold).
 * Empty / whitespace query matches all entries.
 * out_indices must hold at least out_cap entries (pass idx->count).
 * Returns number of matches written, capped by out_cap.
 */
size_t ml_filter_apply(const MLAppIndex *idx,
                       const char *query_utf8,
                       uint32_t *out_indices,
                       size_t out_cap);

#ifdef __cplusplus
}
#endif
