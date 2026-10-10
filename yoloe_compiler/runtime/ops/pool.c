#include "../runtime.h"
#include <float.h>
#include <stdio.h>

static int execute_pool(ir_program_t *prog, ir_instruction_t *instr, int is_max) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) { fprintf(stderr, "POOL: missing tensor\n"); return -1; }

    int64_t N = in->shape[0], C = in->shape[1], H = in->shape[2], W = in->shape[3];
    int64_t OH = out->shape[2], OW = out->shape[3];
    int64_t KH = instr->kernel[0], KW = instr->kernel[1];
    int64_t stride_h = instr->stride[0] ? instr->stride[0] : 1;
    int64_t stride_w = instr->stride[1] ? instr->stride[1] : 1;
    int64_t pad_top = instr->padding[0], pad_left = instr->padding[1];

    for (int64_t n = 0; n < N; n++) {
        for (int64_t c = 0; c < C; c++) {
            for (int64_t oh = 0; oh < OH; oh++) {
                for (int64_t ow = 0; ow < OW; ow++) {
                    double acc = is_max ? -DBL_MAX : 0.0;
                    int64_t count = 0;
                    for (int64_t kh = 0; kh < KH; kh++) {
                        int64_t ih = oh * stride_h - pad_top + kh;
                        if (ih < 0 || ih >= H) continue;
                        for (int64_t kw = 0; kw < KW; kw++) {
                            int64_t iw = ow * stride_w - pad_left + kw;
                            if (iw < 0 || iw >= W) continue;
                            float v = in->data[((n * C + c) * H + ih) * W + iw];
                            if (is_max) { if (v > acc) acc = v; }
                            else { acc += v; }
                            count++;
                        }
                    }
                    double result = is_max ? acc : (count > 0 ? acc / count : 0.0);
                    out->data[((n * C + c) * OH + oh) * OW + ow] = (float)result;
                }
            }
        }
    }
    return 0;
}

int execute_maxpool(ir_program_t *prog, ir_instruction_t *instr) { return execute_pool(prog, instr, 1); }
int execute_avgpool(ir_program_t *prog, ir_instruction_t *instr) { return execute_pool(prog, instr, 0); }
