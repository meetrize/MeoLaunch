#include "ml_app_index.h"

#include "ml_util.h"

#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int ends_with_ci(const char *s, const char *suffix) {
    size_t n, m, i;

    if (!s || !suffix) {
        return 0;
    }
    n = strlen(s);
    m = strlen(suffix);
    if (m > n) {
        return 0;
    }
    for (i = 0; i < m; i++) {
        unsigned char a = (unsigned char)s[n - m + i];
        unsigned char b = (unsigned char)suffix[i];
        if (tolower(a) != tolower(b)) {
            return 0;
        }
    }
    return 1;
}

static char *join_path(const char *dir, const char *name) {
    size_t dlen, nlen;
    char *out;
    int need_slash;

    if (!dir || !name) {
        return NULL;
    }
    dlen = strlen(dir);
    nlen = strlen(name);
    need_slash = (dlen > 0 && dir[dlen - 1] != '/');
    out = (char *)malloc(dlen + (need_slash ? 1 : 0) + nlen + 1);
    if (!out) {
        return NULL;
    }
    memcpy(out, dir, dlen);
    if (need_slash) {
        out[dlen++] = '/';
    }
    memcpy(out + dlen, name, nlen + 1);
    return out;
}

/* Lowercase basename without trailing .app — used as dedupe key. */
static char *app_stem_fold(const char *path) {
    const char *base;
    const char *slash;
    size_t len;
    char *tmp;
    char *fold;

    if (!path) {
        return NULL;
    }
    slash = strrchr(path, '/');
    base = slash ? slash + 1 : path;
    len = strlen(base);
    if (len >= 4 && ends_with_ci(base, ".app")) {
        len -= 4;
    }
    tmp = (char *)malloc(len + 1);
    if (!tmp) {
        return NULL;
    }
    memcpy(tmp, base, len);
    tmp[len] = '\0';
    fold = ml_str_fold(tmp);
    free(tmp);
    return fold;
}

static char *cfstring_to_utf8(CFStringRef s) {
    CFIndex len;
    CFIndex used = 0;
    char *buf;

    if (!s) {
        return NULL;
    }
    len = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    if (len <= 1) {
        return NULL;
    }
    buf = (char *)malloc((size_t)len);
    if (!buf) {
        return NULL;
    }
    if (!CFStringGetBytes(s,
                          CFRangeMake(0, CFStringGetLength(s)),
                          kCFStringEncodingUTF8,
                          '?',
                          false,
                          (UInt8 *)buf,
                          len - 1,
                          &used)) {
        free(buf);
        return NULL;
    }
    buf[used] = '\0';
    return buf;
}

static char *bundle_display_name(const char *app_path) {
    CFURLRef url;
    CFBundleRef bundle;
    CFStringRef name_cf = NULL;
    CFTypeRef ls_name = NULL;
    char *name = NULL;
    char *stem;

    url = CFURLCreateFromFileSystemRepresentation(kCFAllocatorDefault,
                                                  (const UInt8 *)app_path,
                                                  (CFIndex)strlen(app_path),
                                                  true);
    if (!url) {
        goto fallback;
    }

    /* Same localized name Finder/Launchpad use (follows system language). */
    if (CFURLCopyResourcePropertyForKey(url, kCFURLLocalizedNameKey, &ls_name, NULL) &&
        ls_name && CFGetTypeID(ls_name) == CFStringGetTypeID()) {
        name = cfstring_to_utf8((CFStringRef)ls_name);
        CFRelease(ls_name);
        if (name && name[0] != '\0') {
            CFRelease(url);
            return name;
        }
        free(name);
        name = NULL;
    } else if (ls_name) {
        CFRelease(ls_name);
    }

    bundle = CFBundleCreate(kCFAllocatorDefault, url);
    CFRelease(url);
    if (!bundle) {
        goto fallback;
    }

    name_cf = CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleDisplayName"));
    if (!name_cf || CFGetTypeID(name_cf) != CFStringGetTypeID()) {
        name_cf = CFBundleGetValueForInfoDictionaryKey(bundle, CFSTR("CFBundleName"));
    }
    if (name_cf && CFGetTypeID(name_cf) == CFStringGetTypeID()) {
        name = cfstring_to_utf8(name_cf);
    }
    CFRelease(bundle);

    if (name && name[0] != '\0') {
        return name;
    }
    free(name);

fallback:
    stem = app_stem_fold(app_path);
    if (!stem) {
        return ml_strdup(app_path);
    }
    /* Return a non-folded display stem: re-read basename without fold */
    {
        const char *slash = strrchr(app_path, '/');
        const char *base = slash ? slash + 1 : app_path;
        size_t len = strlen(base);
        char *disp;

        if (len >= 4 && ends_with_ci(base, ".app")) {
            len -= 4;
        }
        disp = (char *)malloc(len + 1);
        if (!disp) {
            free(stem);
            return NULL;
        }
        memcpy(disp, base, len);
        disp[len] = '\0';
        free(stem);
        return disp;
    }
}

static int ensure_capacity(MLAppIndex *idx, size_t need) {
    MLAppEntry *nitems;
    size_t cap;

    if (idx->capacity >= need) {
        return 0;
    }
    cap = idx->capacity ? idx->capacity : 32;
    while (cap < need) {
        cap *= 2;
    }
    nitems = (MLAppEntry *)realloc(idx->items, cap * sizeof(MLAppEntry));
    if (!nitems) {
        return -1;
    }
    idx->items = nitems;
    idx->capacity = cap;
    return 0;
}

static size_t find_by_stem(const MLAppIndex *idx, const char *stem_fold) {
    size_t i;
    char *existing;

    for (i = 0; i < idx->count; i++) {
        existing = app_stem_fold(idx->items[i].path);
        if (existing && strcmp(existing, stem_fold) == 0) {
            free(existing);
            return i;
        }
        free(existing);
    }
    return (size_t)-1;
}

static void free_entry_fields(MLAppEntry *e) {
    if (!e) {
        return;
    }
    free(e->path);
    free(e->display_name);
    free(e->name_fold);
    e->path = NULL;
    e->display_name = NULL;
    e->name_fold = NULL;
}

/*
 * Add or replace entry. Caller passes roots in preference order (first wins):
 * typically ~/Applications, /Applications, /System/Applications.
 */
static int add_app(MLAppIndex *idx, const char *app_path) {
    char *stem;
    char *path_copy;
    char *display;
    char *fold;
    size_t existing;
    MLAppEntry *slot;

    if (!idx || !app_path) {
        return -1;
    }

    stem = app_stem_fold(app_path);
    if (!stem || stem[0] == '\0' || stem[0] == '.') {
        free(stem);
        return 0; /* skip hidden / invalid */
    }

    existing = find_by_stem(idx, stem);
    if (existing != (size_t)-1) {
        /* Prefer first-seen (caller orders roots by priority). */
        free(stem);
        return 0;
    }
    free(stem);

    path_copy = ml_strdup(app_path);
    display = bundle_display_name(app_path);
    fold = ml_str_fold(display);
    if (!path_copy || !display || !fold) {
        free(path_copy);
        free(display);
        free(fold);
        return -1;
    }

    if (ensure_capacity(idx, idx->count + 1) != 0) {
        free(path_copy);
        free(display);
        free(fold);
        return -1;
    }

    slot = &idx->items[idx->count++];
    slot->path = path_copy;
    slot->display_name = display;
    slot->name_fold = fold;
    return 0;
}

static int is_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) {
        return 0;
    }
    return S_ISDIR(st.st_mode);
}

static int scan_dir_for_apps(MLAppIndex *idx, const char *dir, int allow_nested) {
    DIR *d;
    struct dirent *ent;

    if (!dir || !is_dir(dir)) {
        return 0; /* missing root is OK */
    }

    d = opendir(dir);
    if (!d) {
        return 0;
    }

    while ((ent = readdir(d)) != NULL) {
        char *full;
        const char *name = ent->d_name;

        if (name[0] == '.') {
            continue;
        }

        full = join_path(dir, name);
        if (!full) {
            closedir(d);
            return -1;
        }

        if (ends_with_ci(name, ".app") && is_dir(full)) {
            if (add_app(idx, full) != 0) {
                free(full);
                closedir(d);
                return -1;
            }
            free(full);
            continue;
        }

        /* One-level nest for folders like Applications/Utilities */
        if (allow_nested && is_dir(full) && !ends_with_ci(name, ".app")) {
            if (scan_dir_for_apps(idx, full, 0) != 0) {
                free(full);
                closedir(d);
                return -1;
            }
        }
        free(full);
    }

    closedir(d);
    return 0;
}

int ml_app_index_scan(MLAppIndex *idx, const char **roots, size_t root_count) {
    size_t i;

    if (!idx) {
        return -1;
    }
    ml_app_index_clear(idx);

    if (!roots || root_count == 0) {
        return 0;
    }

    for (i = 0; i < root_count; i++) {
        char *expanded;

        if (!roots[i]) {
            continue;
        }
        expanded = ml_path_expand_tilde(roots[i]);
        if (!expanded) {
            return -1;
        }
        if (scan_dir_for_apps(idx, expanded, 1) != 0) {
            free(expanded);
            return -1;
        }
        free(expanded);
    }

    return 0;
}

void ml_app_index_clear(MLAppIndex *idx) {
    size_t i;

    if (!idx) {
        return;
    }
    if (idx->items) {
        for (i = 0; i < idx->count; i++) {
            free_entry_fields(&idx->items[i]);
        }
        free(idx->items);
    }
    idx->items = NULL;
    idx->count = 0;
    idx->capacity = 0;
}
