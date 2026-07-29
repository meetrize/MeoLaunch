#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MLAppEntry {
    char *path;         /* UTF-8 */
    char *display_name; /* UTF-8 */
    char *name_fold;    /* folded for search */
} MLAppEntry;

typedef struct MLAppIndex {
    MLAppEntry *items;
    size_t count;
    size_t capacity;
} MLAppIndex;

/*
 * Scan application roots for *.app packages (one nested level, e.g. Utilities).
 * Pass roots in preference order — first match wins on stem dedupe
 * (recommend: ~/Applications, /Applications, /System/Applications).
 * Fills path / display_name / name_fold. Returns 0 on success, -1 on OOM.
 */
int ml_app_index_scan(MLAppIndex *idx, const char **roots, size_t root_count);

void ml_app_index_clear(MLAppIndex *idx);

#ifdef __cplusplus
}
#endif
