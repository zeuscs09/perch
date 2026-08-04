#include "pch_rects.h"

void pch_rects_move_from(pch_rects_t *rs, int from, float dx, float dy)
{
    for (int i = from; i < rs->count; i++) {
        rs->items[i].x += dx;
        rs->items[i].y += dy;
    }
}

void pch_rects_scale_from(pch_rects_t *rs, int from, float sx, float sy, float ox, float oy)
{
    for (int i = from; i < rs->count; i++) {
        pch_rect_t *r = &rs->items[i];
        r->x = ox + (r->x - ox) * sx;
        r->y = oy + (r->y - oy) * sy;
        r->w *= sx;
        r->h *= sy;
    }
}

void pch_rects_bounds(const pch_rects_t *rs, float *x0, float *y0, float *x1, float *y1)
{
    if (rs->count == 0) {
        *x0 = *y0 = *x1 = *y1 = 0.0f;
        return;
    }
    float ax0 = rs->items[0].x, ay0 = rs->items[0].y;
    float ax1 = ax0 + rs->items[0].w, ay1 = ay0 + rs->items[0].h;
    for (int i = 1; i < rs->count; i++) {
        const pch_rect_t *r = &rs->items[i];
        if (r->x < ax0) ax0 = r->x;
        if (r->y < ay0) ay0 = r->y;
        if (r->x + r->w > ax1) ax1 = r->x + r->w;
        if (r->y + r->h > ay1) ay1 = r->y + r->h;
    }
    *x0 = ax0;
    *y0 = ay0;
    *x1 = ax1;
    *y1 = ay1;
}
