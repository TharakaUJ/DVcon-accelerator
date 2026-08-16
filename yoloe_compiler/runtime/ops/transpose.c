#include "../runtime.h"
#include <stdio.h>

int execute_transpose(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;

    int ndim = in->ndim;
    int64_t perm[IR_MAX_DIMS];
    if (instr->perm_n == ndim) {
        for (int i = 0; i < ndim; i++) perm[i] = instr->perm[i];
    } else {
        /* ONNX default when perm is omitted: reverse all axes */
        for (int i = 0; i < ndim; i++) perm[i] = ndim - 1 - i;
    }

    int64_t in_strides[IR_MAX_DIMS], out_strides[IR_MAX_DIMS];
    int64_t s = 1;
    for (int i = ndim - 1; i >= 0; i--) { in_strides[i] = s; s *= in->shape[i]; }
    s = 1;
    for (int i = ndim - 1; i >= 0; i--) { out_strides[i] = s; s *= out->shape[i]; }

    int64_t total = 1;
    for (int i = 0; i < ndim; i++) total *= out->shape[i];

    int64_t out_coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < total; lin++) {
        int64_t rem = lin;
        for (int i = 0; i < ndim; i++) { out_coords[i] = rem / out_strides[i]; rem %= out_strides[i]; }
        int64_t in_idx = 0;
        for (int i = 0; i < ndim; i++) in_idx += out_coords[i] * in_strides[perm[i]];
        out->data[lin] = in->data[in_idx];
    }
    return 0;
}
