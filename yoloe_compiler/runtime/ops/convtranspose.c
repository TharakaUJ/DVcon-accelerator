#include "../runtime.h"
#include <stdio.h>

/*
 * Straightforward (unoptimized) transposed convolution. Implemented as the
 * mathematical adjoint of Conv: scatter each input pixel, scaled by the
 * kernel, into the (larger) output.
 *
 * input:  [N, Cin, H, W]
 * weight: [Cin, Cout/group, KH, KW]   (note: ONNX ConvTranspose weight
 *                                       layout is [Cin, Cout/group, KH, KW],
 *                                       NOT [Cout, Cin, KH, KW] like Conv)
 * output: [N, Cout, OH, OW]
 */
int execute_convtranspose(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *w = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *bias = (instr->num_inputs >= 3) ? runtime_find_tensor(prog, instr->inputs[2]) : NULL;
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !w || !out) { fprintf(stderr, "CONVTRANSPOSE: missing tensor\n"); return -1; }

    int64_t N = in->shape[0], Cin = in->shape[1], H = in->shape[2], W = in->shape[3];
    int64_t CoutPerGroup = w->shape[1], KH = w->shape[2], KW = w->shape[3];
    int64_t group = instr->group > 0 ? instr->group : 1;
    int64_t CinPerGroup = Cin / group;
    int64_t Cout = CoutPerGroup * group;

    int64_t stride_h = instr->stride[0] ? instr->stride[0] : 1;
    int64_t stride_w = instr->stride[1] ? instr->stride[1] : 1;
    int64_t pad_top = instr->padding[0], pad_left = instr->padding[1];
    int64_t OH = out->shape[2], OW = out->shape[3];

    for (int64_t i = 0; i < N * Cout * OH * OW; i++) out->data[i] = 0.0f;

    if (bias) {
        for (int64_t n = 0; n < N; n++)
            for (int64_t oc = 0; oc < Cout; oc++)
                for (int64_t oh = 0; oh < OH; oh++)
                    for (int64_t ow = 0; ow < OW; ow++)
                        out->data[((n * Cout + oc) * OH + oh) * OW + ow] = bias->data[oc];
    }

    for (int64_t n = 0; n < N; n++) {
        for (int64_t g = 0; g < group; g++) {
            for (int64_t ic_local = 0; ic_local < CinPerGroup; ic_local++) {
                int64_t ic = g * CinPerGroup + ic_local;
                for (int64_t h = 0; h < H; h++) {
                    for (int64_t wcol = 0; wcol < W; wcol++) {
                        float in_v = in->data[((n * Cin + ic) * H + h) * W + wcol];
                        for (int64_t oc_local = 0; oc_local < CoutPerGroup; oc_local++) {
                            int64_t oc = g * CoutPerGroup + oc_local;
                            for (int64_t kh = 0; kh < KH; kh++) {
                                int64_t oh = h * stride_h - pad_top + kh;
                                if (oh < 0 || oh >= OH) continue;
                                for (int64_t kw = 0; kw < KW; kw++) {
                                    int64_t ow = wcol * stride_w - pad_left + kw;
                                    if (ow < 0 || ow >= OW) continue;
                                    float w_v = w->data[((ic * CoutPerGroup + oc_local) * KH + kh) * KW + kw];
                                    out->data[((n * Cout + oc) * OH + oh) * OW + ow] += in_v * w_v;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    return 0;
}
