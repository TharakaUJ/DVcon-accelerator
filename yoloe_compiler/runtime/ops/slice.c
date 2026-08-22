#include "../runtime.h"
#include <stdio.h>

int execute_slice(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;

    int ndim = in->ndim;
    int64_t start[IR_MAX_DIMS], step[IR_MAX_DIMS];
    for (int i = 0; i < ndim; i++) { start[i] = 0; step[i] = 1; }

    for (int k = 0; k < instr->slice_n; k++) {
        int64_t axis = instr->slice_axes[k];
        if (axis < 0) axis += ndim;
        int64_t s = instr->slice_starts[k];
        if (s < 0) s += in->shape[axis];
        start[axis] = s;
        step[axis] = instr->slice_steps[k] ? instr->slice_steps[k] : 1;
    }

    int64_t in_strides[IR_MAX_DIMS], out_strides[IR_MAX_DIMS];
    int64_t s = 1;
    for (int i = ndim - 1; i >= 0; i--) { in_strides[i] = s; s *= in->shape[i]; }
    s = 1;
    for (int i = ndim - 1; i >= 0; i--) { out_strides[i] = s; s *= out->shape[i]; }

    int64_t total = 1;
    for (int i = 0; i < ndim; i++) total *= out->shape[i];

    int64_t coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < total; lin++) {
        int64_t rem = lin;
        for (int i = 0; i < ndim; i++) { coords[i] = rem / out_strides[i]; rem %= out_strides[i]; }
        int64_t in_idx = 0;
        for (int i = 0; i < ndim; i++) in_idx += (start[i] + coords[i] * step[i]) * in_strides[i];
        if (in->dtype == DT_INT64) out->idata[lin] = in->idata[in_idx];
        else out->data[lin] = in->data[in_idx];
    }
    return 0;
}
