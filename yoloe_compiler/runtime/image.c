#define STB_IMAGE_IMPLEMENTATION
#include "thirdparty/stb_image.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "thirdparty/stb_image_write.h"

#include "image.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

image_t *image_load(const char *path) {
    image_t *img = (image_t *)malloc(sizeof(image_t));
    int w, h, ch;
    uint8_t *data = stbi_load(path, &w, &h, &ch, 3);  /* force 3 channels (RGB) */
    if (!data) {
        fprintf(stderr, "image_load: failed to load '%s': %s\n", path, stbi_failure_reason());
        free(img);
        return NULL;
    }
    img->w = w; img->h = h; img->channels = 3;
    img->pixels = data;
    return img;
}

void image_free(image_t *img) {
    if (!img) return;
    stbi_image_free(img->pixels);
    free(img);
}

int image_save_png(const image_t *img, const char *path) {
    return stbi_write_png(path, img->w, img->h, 3, img->pixels, img->w * 3) != 0 ? 0 : -1;
}

/* Simple nearest-neighbor resize (sufficient for the coarse box-mask
 * upsampling and preprocessing here; correctness of the *decode logic* -
 * not pixel-perfect resampling quality - is the priority for this
 * reference pipeline). */
static void resize_nn_rgb(const uint8_t *src, int sw, int sh,
                           uint8_t *dst, int dw, int dh) {
    for (int y = 0; y < dh; y++) {
        int sy = (int)((double)y * sh / dh);
        if (sy >= sh) sy = sh - 1;
        for (int x = 0; x < dw; x++) {
            int sx = (int)((double)x * sw / dw);
            if (sx >= sw) sx = sw - 1;
            for (int c = 0; c < 3; c++)
                dst[(y * dw + x) * 3 + c] = src[(sy * sw + sx) * 3 + c];
        }
    }
}

void letterbox_preprocess(const image_t *img, int canvas_size, float *out_chw, letterbox_t *lb) {
    double scale = (double)canvas_size / (img->w > img->h ? img->w : img->h);
    int new_w = (int)round(img->w * scale);
    int new_h = (int)round(img->h * scale);
    int pad_x = (canvas_size - new_w) / 2;
    int pad_y = (canvas_size - new_h) / 2;

    lb->orig_w = img->w; lb->orig_h = img->h;
    lb->canvas_size = canvas_size;
    lb->scale = scale;
    lb->pad_x = pad_x; lb->pad_y = pad_y;

    uint8_t *resized = (uint8_t *)malloc((size_t)new_w * new_h * 3);
    resize_nn_rgb(img->pixels, img->w, img->h, resized, new_w, new_h);

    /* fill canvas with YOLO's standard gray padding (114,114,114), then
     * paste the resized image at (pad_x, pad_y), then convert HWC uint8 ->
     * CHW float32 normalized to [0,1]. */
    int64_t plane = (int64_t)canvas_size * canvas_size;
    for (int64_t i = 0; i < plane; i++) {
        out_chw[i] = 114.0f / 255.0f;
        out_chw[plane + i] = 114.0f / 255.0f;
        out_chw[2 * plane + i] = 114.0f / 255.0f;
    }
    for (int y = 0; y < new_h; y++) {
        int cy = y + pad_y;
        if (cy < 0 || cy >= canvas_size) continue;
        for (int x = 0; x < new_w; x++) {
            int cx = x + pad_x;
            if (cx < 0 || cx >= canvas_size) continue;
            const uint8_t *px = &resized[(y * new_w + x) * 3];
            int64_t idx = (int64_t)cy * canvas_size + cx;
            out_chw[idx] = px[0] / 255.0f;
            out_chw[plane + idx] = px[1] / 255.0f;
            out_chw[2 * plane + idx] = px[2] / 255.0f;
        }
    }
    free(resized);
}

void letterbox_unmap_box(const letterbox_t *lb, double cx1, double cy1, double cx2, double cy2,
                          int *ox1, int *oy1, int *ox2, int *oy2) {
    double x1 = (cx1 - lb->pad_x) / lb->scale;
    double y1 = (cy1 - lb->pad_y) / lb->scale;
    double x2 = (cx2 - lb->pad_x) / lb->scale;
    double y2 = (cy2 - lb->pad_y) / lb->scale;
    if (x1 < 0) x1 = 0; if (y1 < 0) y1 = 0;
    if (x2 > lb->orig_w) x2 = lb->orig_w;
    if (y2 > lb->orig_h) y2 = lb->orig_h;
    *ox1 = (int)round(x1); *oy1 = (int)round(y1);
    *ox2 = (int)round(x2); *oy2 = (int)round(y2);
}

static void put_pixel(image_t *img, int x, int y, uint8_t r, uint8_t g, uint8_t b) {
    if (x < 0 || y < 0 || x >= img->w || y >= img->h) return;
    uint8_t *p = &img->pixels[(y * img->w + x) * 3];
    p[0] = r; p[1] = g; p[2] = b;
}

void draw_rect(image_t *img, int x1, int y1, int x2, int y2, uint8_t r, uint8_t g, uint8_t b, int thickness) {
    for (int t = 0; t < thickness; t++) {
        for (int x = x1; x <= x2; x++) { put_pixel(img, x, y1 + t, r, g, b); put_pixel(img, x, y2 - t, r, g, b); }
        for (int y = y1; y <= y2; y++) { put_pixel(img, x1 + t, y, r, g, b); put_pixel(img, x2 - t, y, r, g, b); }
    }
}

void blend_mask(image_t *img, int x1, int y1, int x2, int y2,
                 const float *mask, int mw, int mh,
                 uint8_t r, uint8_t g, uint8_t b, float alpha) {
    int bw = x2 - x1, bh = y2 - y1;
    if (bw <= 0 || bh <= 0) return;
    for (int y = 0; y < bh; y++) {
        int my = (int)((double)y * mh / bh);
        if (my >= mh) my = mh - 1;
        for (int x = 0; x < bw; x++) {
            int mx = (int)((double)x * mw / bw);
            if (mx >= mw) mx = mw - 1;
            if (mask[my * mw + mx] <= 0.5f) continue;
            uint8_t *p = &img->pixels[((y1 + y) * img->w + (x1 + x)) * 3];
            p[0] = (uint8_t)(p[0] * (1 - alpha) + r * alpha);
            p[1] = (uint8_t)(p[1] * (1 - alpha) + g * alpha);
            p[2] = (uint8_t)(p[2] * (1 - alpha) + b * alpha);
        }
    }
}
