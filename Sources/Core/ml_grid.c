#include "ml_grid.h"

void ml_grid_metrics_compute(MLGridMetrics *out,
                             float view_w,
                             float view_h,
                             int cols,
                             int rows,
                             float padding,
                             float spacing) {
    float inner_w, inner_h, cell_w, cell_h, icon;

    if (!out) {
        return;
    }

    if (cols < 1) {
        cols = 7;
    }
    if (rows < 1) {
        rows = 5;
    }
    if (padding < 0.f) {
        padding = 0.f;
    }
    if (spacing < 0.f) {
        spacing = 0.f;
    }

    inner_w = view_w - 2.f * padding - (float)(cols - 1) * spacing;
    inner_h = view_h - 2.f * padding - (float)(rows - 1) * spacing;
    if (inner_w < 1.f) {
        inner_w = 1.f;
    }
    if (inner_h < 1.f) {
        inner_h = 1.f;
    }

    cell_w = inner_w / (float)cols;
    cell_h = inner_h / (float)rows;
    /* Prefer larger icons (was 0.55); leave room for label under icon */
    icon = cell_w < cell_h ? cell_w * 0.78f : cell_h * 0.70f;
    if (icon < 48.f) {
        icon = 48.f;
    }
    {
        float max_w = cell_w * 0.92f;
        float max_h = cell_h * 0.72f;
        if (icon > max_w) {
            icon = max_w;
        }
        if (icon > max_h) {
            icon = max_h;
        }
    }

    out->cols = cols;
    out->rows = rows;
    out->origin_x = padding;
    out->origin_y = padding;
    out->cell_w = cell_w;
    out->cell_h = cell_h;
    out->icon_size = icon;
}

void ml_grid_cell_frame(const MLGridConfig *cfg,
                        float view_w,
                        float view_h,
                        int index_in_page,
                        MLCellFrame *out) {
    MLGridMetrics m;
    int cols, rows, row, col;
    float icon_s, cx, cy;

    if (!out) {
        return;
    }

    cols = cfg && cfg->cols > 0 ? cfg->cols : 7;
    rows = cfg && cfg->rows > 0 ? cfg->rows : 5;

    ml_grid_metrics_compute(&m,
                            view_w,
                            view_h,
                            cols,
                            rows,
                            cfg ? cfg->padding : 48.f,
                            cfg ? cfg->spacing : 28.f);

    /* Explicit icon_size is absolute — rows/cols only change density, not icon pt. */
    if (cfg && cfg->icon_size > 0.f) {
        m.icon_size = cfg->icon_size;
    }

    if (index_in_page < 0) {
        index_in_page = 0;
    }
    col = index_in_page % cols;
    row = index_in_page / cols;

    out->x = m.origin_x + (float)col * (m.cell_w + (cfg ? cfg->spacing : 28.f));
    out->y = m.origin_y + (float)row * (m.cell_h + (cfg ? cfg->spacing : 28.f));
    out->w = m.cell_w;
    out->h = m.cell_h;

    icon_s = m.icon_size;
    cx = out->x + out->w * 0.5f;
    cy = out->y + out->h * 0.40f;
    out->icon_x = cx - icon_s * 0.5f;
    out->icon_y = cy - icon_s * 0.5f;
    out->icon_s = icon_s;
    out->label_y = cy + icon_s * 0.5f + 6.f;
}
