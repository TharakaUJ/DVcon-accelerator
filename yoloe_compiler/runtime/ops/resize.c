#include "../runtime.h"
#include <string.h>
#include <stdio.h>
#include <math.h>

/* Nearest-neighbor Resize supporting the coordinate_transformation_mode /
 * nearest_mode combinations actually seen in YOLOE's export
 * (asymmetric + floor, half_pixel + round_prefer_floor as a fallback).
 * Only 4D NCHW resize (scaling H,W) is supported - fails loudly otherwise. */
int execute_resize(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;

    if (strcmp(instr->resize_mode, "nearest") != 0 && instr->resize_mode[0] != '\0') {
        fprintf(stderr, "RESIZE: only 'nearest' mode is implemented (got '%s')\n", instr->resize_mode);
        return -1;
    }

    int64_t N = in->shape[0], C = in->shape[1], H = in->shape[2], W = in->shape[3];
    int64_t OH = out->shape[2], OW = out->shape[3];
    double scale_h = (double)OH / (double)H;
    double scale_w = (double)OW / (double)W;

    int is_asymmetric = (strcmp(instr->resize_coordinate_transformation_mode, "asymmetric") == 0);

    for (int64_t n = 0; n < N; n++) {
        for (int64_t c = 0; c < C; c++) {
            for (int64_t oh = 0; oh < OH; oh++) {
                double src_h = is_asymmetric ? (oh / scale_h) : ((oh + 0.5) / scale_h - 0.5);
                int64_t ih = (int64_t)floor(src_h);
                if (ih < 0) ih = 0;
                if (ih >= H) ih = H - 1;
                for (int64_t ow = 0; ow < OW; ow++) {
                    double src_w = is_asymmetric ? (ow / scale_w) : ((ow + 0.5) / scale_w - 0.5);
                    int64_t iw = (int64_t)floor(src_w);
                    if (iw < 0) iw = 0;
                    if (iw >= W) iw = W - 1;
                    out->data[((n * C + c) * OH + oh) * OW + ow] =
                        in->data[((n * C + c) * H + ih) * W + iw];
                }
            }
        }
    }
    return 0;
}
