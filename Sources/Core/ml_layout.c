#include "ml_layout.h"

#include "ml_util.h"

#include <stdlib.h>
#include <string.h>

void ml_layout_init(MLLayout *layout) {
    if (!layout) {
        return;
    }
    memset(layout, 0, sizeof(*layout));
}

static void free_app_ref(MLLayoutAppRef *ref) {
    if (!ref) {
        return;
    }
    free(ref->path);
    ref->path = NULL;
}

static void free_folder(MLLayoutFolder *folder) {
    size_t i;
    if (!folder) {
        return;
    }
    for (i = 0; i < folder->count; i++) {
        free_app_ref(&folder->items[i]);
    }
    free(folder->items);
    free(folder->id);
    free(folder->name);
    free(folder);
}

static void free_node(MLLayoutNode *node) {
    if (!node) {
        return;
    }
    if (node->kind == ML_LAYOUT_APP) {
        free_app_ref(&node->u.app);
    } else if (node->kind == ML_LAYOUT_FOLDER) {
        free_folder(node->u.folder);
        node->u.folder = NULL;
    }
    node->kind = 0;
}

void ml_layout_clear(MLLayout *layout) {
    size_t i;
    if (!layout) {
        return;
    }
    for (i = 0; i < layout->count; i++) {
        free_node(&layout->root[i]);
    }
    free(layout->root);
    layout->root = NULL;
    layout->count = 0;
    layout->capacity = 0;
}

static int ensure_root_cap(MLLayout *layout, size_t need) {
    MLLayoutNode *nbuf;
    size_t cap;
    if (layout->capacity >= need) {
        return 0;
    }
    cap = layout->capacity == 0 ? 32 : layout->capacity;
    while (cap < need) {
        cap *= 2;
    }
    nbuf = (MLLayoutNode *)realloc(layout->root, cap * sizeof(MLLayoutNode));
    if (!nbuf) {
        return -1;
    }
    layout->root = nbuf;
    layout->capacity = cap;
    return 0;
}

int ml_layout_append_app(MLLayout *layout, const char *path) {
    MLLayoutNode *node;
    char *copy;
    if (!layout || !path || path[0] == '\0') {
        return -1;
    }
    if (ensure_root_cap(layout, layout->count + 1) != 0) {
        return -1;
    }
    copy = ml_strdup(path);
    if (!copy) {
        return -1;
    }
    node = &layout->root[layout->count];
    memset(node, 0, sizeof(*node));
    node->kind = ML_LAYOUT_APP;
    node->u.app.path = copy;
    layout->count += 1;
    return 0;
}

static int ensure_folder_cap(MLLayoutFolder *folder, size_t need) {
    MLLayoutAppRef *nbuf;
    size_t cap;
    if (folder->capacity >= need) {
        return 0;
    }
    cap = folder->capacity == 0 ? 8 : folder->capacity;
    while (cap < need) {
        cap *= 2;
    }
    nbuf = (MLLayoutAppRef *)realloc(folder->items, cap * sizeof(MLLayoutAppRef));
    if (!nbuf) {
        return -1;
    }
    folder->items = nbuf;
    folder->capacity = cap;
    return 0;
}

int ml_layout_folder_append_app(MLLayoutFolder *folder, const char *path) {
    char *copy;
    if (!folder || !path || path[0] == '\0') {
        return -1;
    }
    if (ensure_folder_cap(folder, folder->count + 1) != 0) {
        return -1;
    }
    copy = ml_strdup(path);
    if (!copy) {
        return -1;
    }
    folder->items[folder->count].path = copy;
    folder->count += 1;
    return 0;
}

MLLayoutFolder *ml_layout_append_folder(MLLayout *layout, const char *id, const char *name) {
    MLLayoutNode *node;
    MLLayoutFolder *folder;
    if (!layout || !id || id[0] == '\0') {
        return NULL;
    }
    if (ensure_root_cap(layout, layout->count + 1) != 0) {
        return NULL;
    }
    folder = (MLLayoutFolder *)calloc(1, sizeof(MLLayoutFolder));
    if (!folder) {
        return NULL;
    }
    folder->id = ml_strdup(id);
    folder->name = ml_strdup(name ? name : "");
    if (!folder->id || !folder->name) {
        free_folder(folder);
        return NULL;
    }
    node = &layout->root[layout->count];
    memset(node, 0, sizeof(*node));
    node->kind = ML_LAYOUT_FOLDER;
    node->u.folder = folder;
    layout->count += 1;
    return folder;
}

static int path_eq(const char *a, const char *b) {
    if (!a || !b) {
        return 0;
    }
    return strcmp(a, b) == 0;
}

int ml_layout_contains_path(const MLLayout *layout, const char *path) {
    size_t i, j;
    if (!layout || !path) {
        return 0;
    }
    for (i = 0; i < layout->count; i++) {
        const MLLayoutNode *node = &layout->root[i];
        if (node->kind == ML_LAYOUT_APP) {
            if (path_eq(node->u.app.path, path)) {
                return 1;
            }
        } else if (node->kind == ML_LAYOUT_FOLDER && node->u.folder) {
            const MLLayoutFolder *f = node->u.folder;
            for (j = 0; j < f->count; j++) {
                if (path_eq(f->items[j].path, path)) {
                    return 1;
                }
            }
        }
    }
    return 0;
}

static int index_has_path(const MLAppIndex *idx, const char *path) {
    size_t i;
    if (!idx || !path) {
        return 0;
    }
    for (i = 0; i < idx->count; i++) {
        if (idx->items[i].path && path_eq(idx->items[i].path, path)) {
            return 1;
        }
    }
    return 0;
}

static int find_app_index(const MLAppIndex *idx, const char *path, uint32_t *out) {
    size_t i;
    if (!idx || !path || !out) {
        return 0;
    }
    for (i = 0; i < idx->count; i++) {
        if (idx->items[i].path && path_eq(idx->items[i].path, path)) {
            *out = (uint32_t)i;
            return 1;
        }
    }
    return 0;
}

static int folder_prune_missing(MLLayoutFolder *folder, const MLAppIndex *idx) {
    size_t r = 0;
    size_t w = 0;
    int changed = 0;
    if (!folder) {
        return 0;
    }
    for (r = 0; r < folder->count; r++) {
        if (index_has_path(idx, folder->items[r].path)) {
            if (w != r) {
                folder->items[w] = folder->items[r];
                memset(&folder->items[r], 0, sizeof(folder->items[r]));
            }
            w++;
        } else {
            free_app_ref(&folder->items[r]);
            changed = 1;
        }
    }
    folder->count = w;
    return changed;
}

int ml_layout_sync_with_index(MLLayout *layout, const MLAppIndex *idx) {
    size_t r = 0;
    size_t w = 0;
    size_t i;
    int changes = 0;

    if (!layout || !idx) {
        return -1;
    }

    /* Prune missing apps; drop empty folders */
    for (r = 0; r < layout->count; r++) {
        MLLayoutNode *node = &layout->root[r];
        if (node->kind == ML_LAYOUT_APP) {
            if (index_has_path(idx, node->u.app.path)) {
                if (w != r) {
                    layout->root[w] = *node;
                    memset(node, 0, sizeof(*node));
                }
                w++;
            } else {
                free_node(node);
                changes++;
            }
        } else if (node->kind == ML_LAYOUT_FOLDER && node->u.folder) {
            if (folder_prune_missing(node->u.folder, idx)) {
                changes++;
            }
            if (node->u.folder->count == 0) {
                free_node(node);
                changes++;
            } else {
                if (w != r) {
                    layout->root[w] = *node;
                    memset(node, 0, sizeof(*node));
                }
                w++;
            }
        } else {
            free_node(node);
            changes++;
        }
    }
    layout->count = w;

    /* Append new apps to root end */
    for (i = 0; i < idx->count; i++) {
        const char *path = idx->items[i].path;
        if (!path || path[0] == '\0') {
            continue;
        }
        if (ml_layout_contains_path(layout, path)) {
            continue;
        }
        if (ml_layout_append_app(layout, path) != 0) {
            return -1;
        }
        changes++;
    }

    /* Dissolve folders that shrank to 0/1 after prune */
    for (i = 0; i < layout->count; ) {
        if (layout->root[i].kind == ML_LAYOUT_FOLDER &&
            layout->root[i].u.folder &&
            layout->root[i].u.folder->id &&
            layout->root[i].u.folder->count <= 1) {
            char idbuf[128];
            size_t len = strlen(layout->root[i].u.folder->id);
            if (len >= sizeof(idbuf)) {
                len = sizeof(idbuf) - 1;
            }
            memcpy(idbuf, layout->root[i].u.folder->id, len);
            idbuf[len] = '\0';
            if (ml_layout_dissolve_folder_if_small(layout, idbuf) > 0) {
                changes++;
                continue; /* re-check index i */
            }
        }
        i++;
    }

    return changes;
}

size_t ml_layout_flat_app_indices(const MLLayout *layout,
                                  const MLAppIndex *idx,
                                  uint32_t *out_indices,
                                  size_t out_cap) {
    size_t i, j, n = 0;
    uint32_t app_i;

    if (!layout || !idx || !out_indices || out_cap == 0) {
        return 0;
    }

    for (i = 0; i < layout->count && n < out_cap; i++) {
        const MLLayoutNode *node = &layout->root[i];
        if (node->kind == ML_LAYOUT_APP) {
            if (find_app_index(idx, node->u.app.path, &app_i)) {
                out_indices[n++] = app_i;
            }
        } else if (node->kind == ML_LAYOUT_FOLDER && node->u.folder) {
            const MLLayoutFolder *f = node->u.folder;
            for (j = 0; j < f->count && n < out_cap; j++) {
                if (find_app_index(idx, f->items[j].path, &app_i)) {
                    out_indices[n++] = app_i;
                }
            }
        }
    }
    return n;
}

static size_t flat_path_count(const MLLayout *layout) {
    size_t i, j, n = 0;
    for (i = 0; i < layout->count; i++) {
        const MLLayoutNode *node = &layout->root[i];
        if (node->kind == ML_LAYOUT_APP) {
            if (node->u.app.path) {
                n++;
            }
        } else if (node->kind == ML_LAYOUT_FOLDER && node->u.folder) {
            for (j = 0; j < node->u.folder->count; j++) {
                if (node->u.folder->items[j].path) {
                    n++;
                }
            }
        }
    }
    return n;
}

int ml_layout_move_flat_app(MLLayout *layout, size_t from, size_t to) {
    size_t n, i, j, k = 0;
    char **paths = NULL;
    char *moved;

    if (!layout) {
        return -1;
    }
    n = flat_path_count(layout);
    if (n == 0 || from >= n || to >= n) {
        return -1;
    }
    if (from == to) {
        return 0;
    }

    paths = (char **)calloc(n, sizeof(char *));
    if (!paths) {
        return -1;
    }

    for (i = 0; i < layout->count; i++) {
        const MLLayoutNode *node = &layout->root[i];
        if (node->kind == ML_LAYOUT_APP) {
            if (node->u.app.path) {
                paths[k++] = ml_strdup(node->u.app.path);
                if (!paths[k - 1]) {
                    goto oom;
                }
            }
        } else if (node->kind == ML_LAYOUT_FOLDER && node->u.folder) {
            for (j = 0; j < node->u.folder->count; j++) {
                if (node->u.folder->items[j].path) {
                    paths[k++] = ml_strdup(node->u.folder->items[j].path);
                    if (!paths[k - 1]) {
                        goto oom;
                    }
                }
            }
        }
    }
    if (k != n) {
        goto oom;
    }

    moved = paths[from];
    if (from < to) {
        for (i = from; i < to; i++) {
            paths[i] = paths[i + 1];
        }
        paths[to] = moved;
    } else {
        for (i = from; i > to; i--) {
            paths[i] = paths[i - 1];
        }
        paths[to] = moved;
    }

    ml_layout_clear(layout);
    ml_layout_init(layout);
    for (i = 0; i < n; i++) {
        if (ml_layout_append_app(layout, paths[i]) != 0) {
            goto oom;
        }
        free(paths[i]);
        paths[i] = NULL;
    }
    free(paths);
    return 0;

oom:
    if (paths) {
        for (i = 0; i < n; i++) {
            free(paths[i]);
        }
        free(paths);
    }
    return -1;
}

int ml_layout_move_root(MLLayout *layout, size_t from, size_t to) {
    MLLayoutNode moved;
    size_t i;

    if (!layout || from >= layout->count || to >= layout->count) {
        return -1;
    }
    if (from == to) {
        return 0;
    }

    moved = layout->root[from];
    if (from < to) {
        for (i = from; i < to; i++) {
            layout->root[i] = layout->root[i + 1];
        }
        layout->root[to] = moved;
    } else {
        for (i = from; i > to; i--) {
            layout->root[i] = layout->root[i - 1];
        }
        layout->root[to] = moved;
    }
    return 0;
}

static void remove_root_at(MLLayout *layout, size_t index) {
    size_t i;
    if (!layout || index >= layout->count) {
        return;
    }
    free_node(&layout->root[index]);
    for (i = index; i + 1 < layout->count; i++) {
        layout->root[i] = layout->root[i + 1];
    }
    memset(&layout->root[layout->count - 1], 0, sizeof(MLLayoutNode));
    layout->count -= 1;
}

int ml_layout_merge_root_apps(MLLayout *layout,
                              size_t drag,
                              size_t target,
                              const char *folder_id,
                              const char *folder_name) {
    char *path_target = NULL;
    char *path_drag = NULL;
    MLLayoutFolder *folder;
    size_t folder_at;

    if (!layout || !folder_id || folder_id[0] == '\0') {
        return -1;
    }
    if (drag >= layout->count || target >= layout->count || drag == target) {
        return -1;
    }
    if (layout->root[drag].kind != ML_LAYOUT_APP ||
        layout->root[target].kind != ML_LAYOUT_APP) {
        return -1;
    }
    if (!layout->root[drag].u.app.path || !layout->root[target].u.app.path) {
        return -1;
    }

    path_target = ml_strdup(layout->root[target].u.app.path);
    path_drag = ml_strdup(layout->root[drag].u.app.path);
    if (!path_target || !path_drag) {
        free(path_target);
        free(path_drag);
        return -1;
    }

    /* Remove higher index first so the lower index stays valid. */
    if (drag > target) {
        remove_root_at(layout, drag);
        remove_root_at(layout, target);
        folder_at = target;
    } else {
        remove_root_at(layout, target);
        remove_root_at(layout, drag);
        folder_at = drag;
    }

    /* Insert folder at folder_at by appending then moving — or splice in. */
    folder = ml_layout_append_folder(layout, folder_id, folder_name ? folder_name : "");
    if (!folder) {
        free(path_target);
        free(path_drag);
        return -1;
    }
    if (ml_layout_folder_append_app(folder, path_target) != 0 ||
        ml_layout_folder_append_app(folder, path_drag) != 0) {
        free(path_target);
        free(path_drag);
        return -1;
    }
    free(path_target);
    free(path_drag);

    /* New folder is at end; move to folder_at */
    if (ml_layout_move_root(layout, layout->count - 1, folder_at) != 0) {
        return -1;
    }
    return 0;
}

int ml_layout_add_root_app_to_folder(MLLayout *layout, size_t drag, size_t folder_idx) {
    char *path = NULL;
    MLLayoutFolder *folder;

    if (!layout || drag >= layout->count || folder_idx >= layout->count || drag == folder_idx) {
        return -1;
    }
    if (layout->root[drag].kind != ML_LAYOUT_APP ||
        layout->root[folder_idx].kind != ML_LAYOUT_FOLDER ||
        !layout->root[folder_idx].u.folder) {
        return -1;
    }
    if (!layout->root[drag].u.app.path) {
        return -1;
    }

    path = ml_strdup(layout->root[drag].u.app.path);
    if (!path) {
        return -1;
    }
    folder = layout->root[folder_idx].u.folder;
    if (ml_layout_folder_append_app(folder, path) != 0) {
        free(path);
        return -1;
    }
    free(path);
    remove_root_at(layout, drag);
    return 0;
}

MLLayoutFolder *ml_layout_folder_by_id(MLLayout *layout, const char *folder_id) {
    size_t i;
    if (!layout || !folder_id) {
        return NULL;
    }
    for (i = 0; i < layout->count; i++) {
        if (layout->root[i].kind == ML_LAYOUT_FOLDER &&
            layout->root[i].u.folder &&
            layout->root[i].u.folder->id &&
            strcmp(layout->root[i].u.folder->id, folder_id) == 0) {
            return layout->root[i].u.folder;
        }
    }
    return NULL;
}

size_t ml_layout_root_index_of_folder(const MLLayout *layout, const char *folder_id) {
    size_t i;
    if (!layout || !folder_id) {
        return (size_t)-1;
    }
    for (i = 0; i < layout->count; i++) {
        if (layout->root[i].kind == ML_LAYOUT_FOLDER &&
            layout->root[i].u.folder &&
            layout->root[i].u.folder->id &&
            strcmp(layout->root[i].u.folder->id, folder_id) == 0) {
            return i;
        }
    }
    return (size_t)-1;
}

int ml_layout_rename_folder(MLLayout *layout, const char *folder_id, const char *name) {
    MLLayoutFolder *folder;
    char *copy;
    if (!layout || !folder_id) {
        return -1;
    }
    folder = ml_layout_folder_by_id(layout, folder_id);
    if (!folder) {
        return -1;
    }
    copy = ml_strdup(name ? name : "");
    if (!copy) {
        return -1;
    }
    free(folder->name);
    folder->name = copy;
    return 0;
}

int ml_layout_reorder_folder_apps(MLLayout *layout,
                                  const char *folder_id,
                                  size_t from,
                                  size_t to) {
    MLLayoutFolder *folder;
    MLLayoutAppRef moved;
    size_t i;

    if (!layout || !folder_id) {
        return -1;
    }
    folder = ml_layout_folder_by_id(layout, folder_id);
    if (!folder || from >= folder->count || to >= folder->count) {
        return -1;
    }
    if (from == to) {
        return 0;
    }
    moved = folder->items[from];
    if (from < to) {
        for (i = from; i < to; i++) {
            folder->items[i] = folder->items[i + 1];
        }
        folder->items[to] = moved;
    } else {
        for (i = from; i > to; i--) {
            folder->items[i] = folder->items[i - 1];
        }
        folder->items[to] = moved;
    }
    return 0;
}

int ml_layout_dissolve_folder_if_small(MLLayout *layout, const char *folder_id) {
    size_t idx;
    MLLayoutFolder *folder;
    char *path = NULL;
    MLLayoutNode node;

    if (!layout || !folder_id) {
        return -1;
    }
    idx = ml_layout_root_index_of_folder(layout, folder_id);
    if (idx == (size_t)-1) {
        return 0;
    }
    folder = layout->root[idx].u.folder;
    if (!folder) {
        remove_root_at(layout, idx);
        return 1;
    }
    if (folder->count > 1) {
        return 0;
    }
    if (folder->count == 1 && folder->items[0].path) {
        path = ml_strdup(folder->items[0].path);
        if (!path) {
            return -1;
        }
    }
    remove_root_at(layout, idx);
    if (path) {
        /* Insert app where the folder was */
        if (ensure_root_cap(layout, layout->count + 1) != 0) {
            free(path);
            return -1;
        }
        memmove(&layout->root[idx + 1],
                &layout->root[idx],
                (layout->count - idx) * sizeof(MLLayoutNode));
        memset(&node, 0, sizeof(node));
        node.kind = ML_LAYOUT_APP;
        node.u.app.path = path;
        layout->root[idx] = node;
        layout->count += 1;
    }
    return 1;
}

int ml_layout_extract_app_from_folder(MLLayout *layout,
                                      const char *folder_id,
                                      size_t item_index,
                                      size_t insert_root,
                                      int *out_folder_gone) {
    MLLayoutFolder *folder;
    size_t folder_idx, i;
    char *path = NULL;
    MLLayoutNode node;
    size_t place;
    size_t remaining_before_dissolve;

    if (out_folder_gone) {
        *out_folder_gone = 0;
    }
    if (!layout || !folder_id) {
        return -1;
    }
    folder_idx = ml_layout_root_index_of_folder(layout, folder_id);
    if (folder_idx == (size_t)-1) {
        return -1;
    }
    folder = layout->root[folder_idx].u.folder;
    if (!folder || item_index >= folder->count || !folder->items[item_index].path) {
        return -1;
    }

    path = ml_strdup(folder->items[item_index].path);
    if (!path) {
        return -1;
    }

    free_app_ref(&folder->items[item_index]);
    for (i = item_index; i + 1 < folder->count; i++) {
        folder->items[i] = folder->items[i + 1];
    }
    if (folder->count > 0) {
        memset(&folder->items[folder->count - 1], 0, sizeof(MLLayoutAppRef));
        folder->count -= 1;
    }

    remaining_before_dissolve = folder->count;
    place = folder_idx + 1;
    if (insert_root != (size_t)-1 && insert_root <= layout->count) {
        place = insert_root;
    }

    if (remaining_before_dissolve <= 1) {
        int d = ml_layout_dissolve_folder_if_small(layout, folder_id);
        if (d < 0) {
            free(path);
            return -1;
        }
        if (out_folder_gone) {
            *out_folder_gone = 1;
        }
        if (remaining_before_dissolve == 1) {
            /* Remaining app sits at folder_idx; put extracted after it. */
            place = folder_idx + 1;
        } else {
            /* Folder removed; put extracted where folder was. */
            place = folder_idx;
        }
    }

    if (ensure_root_cap(layout, layout->count + 1) != 0) {
        free(path);
        return -1;
    }
    if (place > layout->count) {
        place = layout->count;
    }
    memmove(&layout->root[place + 1],
            &layout->root[place],
            (layout->count - place) * sizeof(MLLayoutNode));
    memset(&node, 0, sizeof(node));
    node.kind = ML_LAYOUT_APP;
    node.u.app.path = path;
    layout->root[place] = node;
    layout->count += 1;
    return 0;
}
