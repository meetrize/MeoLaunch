#include "ml_util.h"

#include <ctype.h>
#include <stdlib.h>
#include <string.h>

char *ml_strdup(const char *s) {
    size_t n;
    char *out;

    if (!s) {
        return NULL;
    }
    n = strlen(s);
    out = (char *)malloc(n + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, s, n + 1);
    return out;
}

char *ml_str_fold(const char *s) {
    size_t i, n;
    char *out;

    if (!s) {
        return NULL;
    }
    n = strlen(s);
    out = (char *)malloc(n + 1);
    if (!out) {
        return NULL;
    }
    for (i = 0; i < n; i++) {
        out[i] = (char)tolower((unsigned char)s[i]);
    }
    out[n] = '\0';
    return out;
}

char *ml_path_expand_tilde(const char *path) {
    const char *home;
    size_t home_len, rest_len;
    char *out;

    if (!path) {
        return NULL;
    }
    if (path[0] != '~' || (path[1] != '\0' && path[1] != '/')) {
        return ml_strdup(path);
    }

    home = getenv("HOME");
    if (!home || home[0] == '\0') {
        return ml_strdup(path);
    }

    home_len = strlen(home);
    rest_len = strlen(path + 1); /* includes leading '/' or empty */
    out = (char *)malloc(home_len + rest_len + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, home, home_len);
    memcpy(out + home_len, path + 1, rest_len + 1);
    return out;
}
