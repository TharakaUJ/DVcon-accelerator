#include "../runtime.h"
#include <string.h>
#include <stdio.h>

/* Split: axis attribute + either explicit split sizes (2nd input, an
 * initializer -> already materialized as a WEIGHT-region tensor with real
 * data) or an even split across num_outputs when omitted. */
int execute_split(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    if (!in) return -1;
    int64_t axis = instr->axis;
    if (axis < 0) axis += in->ndim;

    int64_t outer = 1;
    for (int i = 0; i < axis; i++) outer *= in->shape[i];
    int64_t inner = 1;
    for (int i = axis + 1; i < in->ndim; i++) inner *= in->shape[i];

    /* Optional split-sizes tensor (2nd input, if present) */
    int64_t sizes[IR_MAX_OUTPUTS];
    int has_sizes_input = (instr->num_inputs >= 2);
    if (has_sizes_input) {
        ir_tensor_t *sz = runtime_find_tensor(prog, instr->inputs[1]);
        if (!sz) { fprintf(stderr, "SPLIT: missing split-sizes tensor\n"); return -1; }
        for (int i = 0; i < instr->num_outputs; i++) {
            sizes[i] = (sz->dtype == DT_INT64) ? sz->idata[i] : (int64_t)sz->data[i];
        }
    } else {
        int64_t even = in->shape[axis] / instr->num_outputs;
        for (int i = 0; i < instr->num_outputs; i++) sizes[i] = even;
    }

    int64_t axis_offset = 0;
    for (int o = 0; o < instr->num_outputs; o++) {
        ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[o]);
        if (!out) { fprintf(stderr, "SPLIT: missing output %d\n", o); return -1; }
        int64_t out_axis_dim = sizes[o];

        for (int64_t oo = 0; oo < outer; oo++) {
            for (int64_t a = 0; a < out_axis_dim; a++) {
                const float *src = in->data + (oo * in->shape[axis] + (axis_offset + a)) * inner;
                float *dst = out->data + (oo * out_axis_dim + a) * inner;
                memcpy(dst, src, sizeof(float) * inner);
            }
        }
        axis_offset += out_axis_dim;
    }
    return 0;
}
