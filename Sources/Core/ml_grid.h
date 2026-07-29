#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MLGridConfig {
    int cols;
    int rows;
    float padding;
    float spacing;
    float icon_size; /* 0 = auto */
} MLGridConfig;

typedef struct MLGridMetrics {
    int cols;
    int rows;
    float origin_x;
    float origin_y;
    float cell_w;
    float cell_h;
    float icon_size;
} MLGridMetrics;

typedef struct MLCellFrame {
    float x;
    float y;
    float w;
    float h;
    float icon_x;
    float icon_y;
    float icon_s;
    float label_y;
} MLCellFrame;

static inline int ml_grid_page_capacity(const MLGridConfig *c) {
    if (!c || c->cols <= 0 || c->rows <= 0) {
        return 0;
    }
    return c->cols * c->rows;
}

void ml_grid_metrics_compute(MLGridMetrics *out,
                             float view_w,
                             float view_h,
                             int cols,
                             int rows,
                             float padding,
                             float spacing);

void ml_grid_cell_frame(const MLGridConfig *cfg,
                        float view_w,
                        float view_h,
                        int index_in_page,
                        MLCellFrame *out);

#ifdef __cplusplus
}
#endif
