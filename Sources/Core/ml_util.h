#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Heap-allocate a copy of s. Caller frees with free(). NULL if s is NULL or OOM. */
char *ml_strdup(const char *s);

/* Lowercase ASCII copy for search folding. Caller frees. NULL on failure. */
char *ml_str_fold(const char *s);

/* Expand leading ~/ to $HOME. Caller frees. Returns copy of path if no tilde. */
char *ml_path_expand_tilde(const char *path);

#ifdef __cplusplus
}
#endif
