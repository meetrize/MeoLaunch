#pragma once

#include "ml_app_index.h"

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum MLLayoutKind {
    ML_LAYOUT_APP = 1,
    ML_LAYOUT_FOLDER = 2
} MLLayoutKind;

typedef struct MLLayoutAppRef {
    char *path; /* owned UTF-8 */
} MLLayoutAppRef;

typedef struct MLLayoutFolder {
    char *id;   /* owned */
    char *name; /* owned; may be empty */
    MLLayoutAppRef *items;
    size_t count;
    size_t capacity;
} MLLayoutFolder;

typedef struct MLLayoutNode {
    MLLayoutKind kind;
    union {
        MLLayoutAppRef app;
        MLLayoutFolder *folder; /* owned heap folder */
    } u;
} MLLayoutNode;

typedef struct MLLayout {
    MLLayoutNode *root;
    size_t count;
    size_t capacity;
} MLLayout;

void ml_layout_init(MLLayout *layout);
void ml_layout_clear(MLLayout *layout);

/* Append app path to root. Returns 0 on success, -1 on OOM / bad args. */
int ml_layout_append_app(MLLayout *layout, const char *path);

/*
 * Append a folder node to root. Returns pointer to folder on success, NULL on failure.
 * id/name are copied; name may be NULL/empty.
 */
MLLayoutFolder *ml_layout_append_folder(MLLayout *layout, const char *id, const char *name);

/* Append app into an existing folder. Returns 0 on success. */
int ml_layout_folder_append_app(MLLayoutFolder *folder, const char *path);

/*
 * Sync with scanned index:
 *  - drop apps whose path is missing from idx (root + inside folders)
 *  - drop empty folders after prune
 *  - append new idx apps not present anywhere to root end
 * Returns number of structural changes (prune + append), or -1 on OOM.
 */
int ml_layout_sync_with_index(MLLayout *layout, const MLAppIndex *idx);

/*
 * Build flat list of app indices for main-grid display (M6):
 * walks root; APP → index; FOLDER → each child app index (expanded, no folder chrome yet).
 * out_indices must hold at least out_cap entries.
 * Returns number written (may be < total if out_cap too small).
 */
size_t ml_layout_flat_app_indices(const MLLayout *layout,
                                  const MLAppIndex *idx,
                                  uint32_t *out_indices,
                                  size_t out_cap);

/* True if path appears in root or any folder. */
int ml_layout_contains_path(const MLLayout *layout, const char *path);

/*
 * Move an app within the flat display order (root apps + folder children, same as
 * ml_layout_flat_app_indices). Rebuilds root as an app-only list (folders dissolved).
 * Returns 0 on success / no-op, -1 on bad args or OOM.
 */
int ml_layout_move_flat_app(MLLayout *layout, size_t from, size_t to);

/* Move a root node (app or folder). Returns 0 on success / no-op. */
int ml_layout_move_root(MLLayout *layout, size_t from, size_t to);

/*
 * Merge two root APP nodes into a new folder at `target` (replaces target).
 * Removes `drag`. folder_id required; folder_name may be empty.
 */
int ml_layout_merge_root_apps(MLLayout *layout,
                              size_t drag,
                              size_t target,
                              const char *folder_id,
                              const char *folder_name);

/* Append root APP at drag into existing FOLDER at folder_idx; removes drag node. */
int ml_layout_add_root_app_to_folder(MLLayout *layout, size_t drag, size_t folder_idx);

int ml_layout_rename_folder(MLLayout *layout, const char *folder_id, const char *name);

MLLayoutFolder *ml_layout_folder_by_id(MLLayout *layout, const char *folder_id);

/* Returns root index or (size_t)-1 if not found. */
size_t ml_layout_root_index_of_folder(const MLLayout *layout, const char *folder_id);

/* Reorder apps inside a folder. */
int ml_layout_reorder_folder_apps(MLLayout *layout,
                                  const char *folder_id,
                                  size_t from,
                                  size_t to);

/*
 * Move app at item_index out of folder onto root.
 * insert_root: where to place among root nodes (clamped); typically after the folder.
 * If folder ends with <=1 app, it is dissolved (0 → removed, 1 → replaced by remaining app).
 * Returns 0 on success. Sets *out_folder_gone=1 if folder no longer exists.
 */
int ml_layout_extract_app_from_folder(MLLayout *layout,
                                      const char *folder_id,
                                      size_t item_index,
                                      size_t insert_root,
                                      int *out_folder_gone);

/*
 * If folder has 0 items, remove it. If exactly 1, replace folder node with that app.
 * Returns 1 if folder was dissolved/removed, 0 if unchanged, -1 on error.
 */
int ml_layout_dissolve_folder_if_small(MLLayout *layout, const char *folder_id);

#ifdef __cplusplus
}
#endif
