#include "../runtime.h"
#include <string.h>
#include <stdio.h>
#include <math.h>

/* 4D NCHW Resize over H and W ('nearest' or 'linear' i.e. bilinear), with
 * the ONNX coordinate_transformation_mode and nearest_mode options. YOLOE's
 * export uses nearest + asymmetric + floor. Fails loudly for anything else
 * (cubic, or scaling N/C). */

/* output coordinate -> input coordinate (ONNX coordinate_transformation_mode) */
static double source_coord(const char *mode, int64_t o, double scale, int64_t in_len, int64_t out_len) {
    if (!strcmp(mode, "asymmetric")) return o / scale;
    if (!strcmp(mode, "align_corners")) return out_len == 1 ? 0.0 : (double)o * (in_len - 1) / (out_len - 1);
    if (!strcmp(mode, "pytorch_half_pixel")) return out_len > 1 ? (o + 0.5) / scale - 0.5 : 0.0;
    if (!strcmp(mode, "tf_half_pixel_for_nn")) return (o + 0.5) / scale;
    return (o + 0.5) / scale - 0.5;  /* half_pixel (ONNX default) */
}

static int64_t nearest_index(const char *mode, double x, int64_t in_len) {
    int64_t i;
    if (!strcmp(mode, "floor")) i = (int64_t)floor(x);
    else if (!strcmp(mode, "ceil")) i = (int64_t)ceil(x);
    else if (!strcmp(mode, "round_prefer_ceil")) i = (int64_t)floor(x + 0.5);
    else i = (x == floor(x) + 0.5) ? (int64_t)floor(x) : (int64_t)round(x);  /* round_prefer_floor (default) */
    if (i < 0) i = 0;
    if (i >= in_len) i = in_len - 1;
    return i;
}

int execute_resize(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;

    int is_linear = !strcmp(instr->resize_mode, "linear");
    if (!is_linear && strcmp(instr->resize_mode, "nearest") != 0 && instr->resize_mode[0] != '\0') {
        fprintf(stderr, "RESIZE: mode '%s' is not implemented (nearest / linear only)\n", instr->resize_mode);
        return -1;
    }
    if (in->ndim != 4 || out->shape[0] != in->shape[0] || out->shape[1] != in->shape[1]) {
        fprintf(stderr, "RESIZE: only 4D NCHW resizing of H and W is implemented\n");
        return -1;
    }

    int64_t N = in->shape[0], C = in->shape[1], H = in->shape[2], W = in->shape[3];
    int64_t OH = out->shape[2], OW = out->shape[3];
    /* ONNX uses the given scales directly; with `sizes` the scale is out/in */
    double scale_h = (!instr->resize_has_sizes && instr->resize_scales[2] > 0) ? instr->resize_scales[2] : (double)OH / H;
    double scale_w = (!instr->resize_has_sizes && instr->resize_scales[3] > 0) ? instr->resize_scales[3] : (double)OW / W;

    const char *ctm = instr->resize_coordinate_transformation_mode[0]
        ? instr->resize_coordinate_transformation_mode : "half_pixel";
    const char *nm = instr->resize_nearest_mode[0] ? instr->resize_nearest_mode : "round_prefer_floor";

    for (int64_t nc = 0; nc < N * C; nc++) {
        const float *src = in->data + nc * H * W;
        float *dst = out->data + nc * OH * OW;
        for (int64_t oh = 0; oh < OH; oh++) {
            double y = source_coord(ctm, oh, scale_h, H, OH);
            for (int64_t ow = 0; ow < OW; ow++) {
                double x = source_coord(ctm, ow, scale_w, W, OW);
                if (!is_linear) {
                    dst[oh * OW + ow] = src[nearest_index(nm, y, H) * W + nearest_index(nm, x, W)];
                    continue;
                }
                double yc = y < 0 ? 0 : (y > H - 1 ? H - 1 : y);
                double xc = x < 0 ? 0 : (x > W - 1 ? W - 1 : x);
                int64_t y0 = (int64_t)floor(yc), x0 = (int64_t)floor(xc);
                int64_t y1 = y0 + 1 < H ? y0 + 1 : H - 1, x1 = x0 + 1 < W ? x0 + 1 : W - 1;
                double dy = yc - y0, dx = xc - x0;
                double v = (1 - dy) * ((1 - dx) * src[y0 * W + x0] + dx * src[y0 * W + x1])
                         + dy * ((1 - dx) * src[y1 * W + x0] + dx * src[y1 * W + x1]);
                dst[oh * OW + ow] = (float)v;
            }
        }
    }
    return 0;
}
