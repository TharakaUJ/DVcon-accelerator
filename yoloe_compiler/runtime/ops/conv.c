#include "../runtime.h"
#include <stdio.h>

/*
 * Straightforward nested-loop Conv2D. NOT optimized (spec section 11:
 * correctness first). Supports groups, stride, padding, dilation.
 *
 * input:  [N, Cin, H, W]           (NCHW)
 * weight: [Cout, Cin/group, KH, KW] (OIHW)
 * bias:   [Cout]  (optional)
 * output: [N, Cout, OH, OW]
 */
int execute_conv(ir_program_t *prog, ir_instruction_t *instr) {
    if (instr->num_inputs < 2) {
        fprintf(stderr, "CONV: expected >=2 inputs (input, weight[, bias])\n");
        return -1;
    }
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *w = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *bias = (instr->num_inputs >= 3) ? runtime_find_tensor(prog, instr->inputs[2]) : NULL;
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !w || !out) { fprintf(stderr, "CONV: missing tensor\n"); return -1; }

    int64_t N = in->shape[0], Cin = in->shape[1], H = in->shape[2], W = in->shape[3];
    int64_t Cout = w->shape[0], CinPerGroup = w->shape[1], KH = w->shape[2], KW = w->shape[3];
    int64_t group = instr->group > 0 ? instr->group : 1;

    int64_t stride_h = instr->stride[0] ? instr->stride[0] : 1;
    int64_t stride_w = instr->stride[1] ? instr->stride[1] : 1;
    int64_t pad_top = instr->padding[0], pad_left = instr->padding[1];
    int64_t pad_bottom = instr->padding[2], pad_right = instr->padding[3];
    int64_t dil_h = instr->dilation[0] ? instr->dilation[0] : 1;
    int64_t dil_w = instr->dilation[1] ? instr->dilation[1] : 1;

    int64_t OH = out->shape[2], OW = out->shape[3];
    int64_t CoutPerGroup = Cout / group;

    for (int64_t n = 0; n < N; n++) {
        for (int64_t g = 0; g < group; g++) {
            for (int64_t oc_local = 0; oc_local < CoutPerGroup; oc_local++) {
                int64_t oc = g * CoutPerGroup + oc_local;
                for (int64_t oh = 0; oh < OH; oh++) {
                    for (int64_t ow = 0; ow < OW; ow++) {
                        double acc = bias ? bias->data[oc] : 0.0;
                        for (int64_t ic_local = 0; ic_local < CinPerGroup; ic_local++) {
                            int64_t ic = g * CinPerGroup + ic_local;
                            for (int64_t kh = 0; kh < KH; kh++) {
                                int64_t ih = oh * stride_h - pad_top + kh * dil_h;
                                if (ih < 0 || ih >= H) continue;
                                for (int64_t kw = 0; kw < KW; kw++) {
                                    int64_t iw = ow * stride_w - pad_left + kw * dil_w;
                                    if (iw < 0 || iw >= W) continue;
                                    float in_v = in->data[((n * Cin + ic) * H + ih) * W + iw];
                                    float w_v = w->data[((oc * CinPerGroup + ic_local) * KH + kh) * KW + kw];
                                    acc += (double)in_v * (double)w_v;
                                }
                            }
                        }
                        out->data[((n * Cout + oc) * OH + oh) * OW + ow] = (float)acc;
                    }
                }
            }
        }
    }
    (void)pad_bottom; (void)pad_right; /* used implicitly via OH/OW from shape inference */
    return 0;
}
