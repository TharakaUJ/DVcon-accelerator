#ifndef YOLOE_IMAGE_H
#define YOLOE_IMAGE_H

#include <stdint.h>

typedef struct {
    int w, h, channels;   /* channels is always forced to 3 (RGB) on load */
    uint8_t *pixels;       /* HWC, row-major, RGB */
} image_t;

/* Records how an image was letterboxed into a square model-input canvas,
 * so detection boxes can be mapped back to original image coordinates. */
typedef struct {
    int orig_w, orig_h;
    int canvas_size;   /* e.g. 640 */
    double scale;        /* orig -> canvas scale factor (uniform, aspect-preserving) */
    int pad_x, pad_y;      /* top-left padding added in canvas space */
} letterbox_t;

image_t *image_load(const char *path);
void image_free(image_t *img);
int image_save_png(const image_t *img, const char *path);

/* Resizes+pads `img` into a canvas_size x canvas_size square (aspect ratio
 * preserved, gray padding), writes it into `out_chw` as float32 CHW
 * normalized to [0,1] (out_chw must hold 3*canvas_size*canvas_size floats).
 * Fills `lb` with the transform so boxes can be mapped back afterward. */
void letterbox_preprocess(const image_t *img, int canvas_size, float *out_chw, letterbox_t *lb);

/* Maps a box in canvas (model-input) pixel space back to original image
 * pixel space, clamped to image bounds. */
void letterbox_unmap_box(const letterbox_t *lb, double cx1, double cy1, double cx2, double cy2,
                          int *ox1, int *oy1, int *ox2, int *oy2);

void draw_rect(image_t *img, int x1, int y1, int x2, int y2, uint8_t r, uint8_t g, uint8_t b, int thickness);

/* Alpha-blends `color` into img inside [x1,x2)x[y1,y2) wherever mask[y*mw+x] > threshold.
 * mask is mw x mh, sampled with nearest-neighbor scaling to the box region. */
void blend_mask(image_t *img, int x1, int y1, int x2, int y2,
                 const float *mask, int mw, int mh,
                 uint8_t r, uint8_t g, uint8_t b, float alpha);

#endif
