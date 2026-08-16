#include "../runtime.h"
#include <stdio.h>

/* Generic ONNX Gather(axis): out.shape = data.shape[:axis] + indices.shape
 * + data.shape[axis+1:]. Supports both int64 and float32 data. */
int execute_gather(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *data = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *idx = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!data || !idx || !out) { fprintf(stderr, "GATHER: missing tensor\n"); return -1; }

    int64_t axis = instr->axis;
    if (axis < 0) axis += data->ndim;

    int64_t outer = 1;
    for (int i = 0; i < axis; i++) outer *= data->shape[i];
    int64_t axis_dim = data->shape[axis];
    int64_t inner = 1;
    for (int i = axis + 1; i < data->ndim; i++) inner *= data->shape[i];

    int64_t idx_n = 1;
    for (int i = 0; i < idx->ndim; i++) idx_n *= idx->shape[i];

    int is_int = (data->dtype == DT_INT64);

    for (int64_t o = 0; o < outer; o++) {
        for (int64_t j = 0; j < idx_n; j++) {
            int64_t index = idx->idata[j];
            if (index < 0) index += axis_dim;
            for (int64_t in_ = 0; in_ < inner; in_++) {
                int64_t src = (o * axis_dim + index) * inner + in_;
                int64_t dst = (o * idx_n + j) * inner + in_;
                if (is_int) out->idata[dst] = data->idata[src];
                else out->data[dst] = data->data[src];
            }
        }
    }
    return 0;
}

/* ONNX GatherElements(axis): out has the SAME shape as the index tensor.
 * out[...,i_axis,...] = data[..., index[...,i_axis,...], ...] where every
 * other coordinate matches between out and data. */
int execute_gatherelements(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *data = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *idx = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!data || !idx || !out) { fprintf(stderr, "GATHERELEMENTS: missing tensor\n"); return -1; }

    int64_t axis = instr->axis;
    if (axis < 0) axis += data->ndim;
    int ndim = idx->ndim;

    int64_t idx_strides[IR_MAX_DIMS], data_strides[IR_MAX_DIMS];
    int64_t s = 1;
    for (int i = ndim - 1; i >= 0; i--) { idx_strides[i] = s; s *= idx->shape[i]; }
    s = 1;
    for (int i = ndim - 1; i >= 0; i--) { data_strides[i] = s; s *= data->shape[i]; }

    int64_t total = 1;
    for (int i = 0; i < ndim; i++) total *= idx->shape[i];

    int is_int = (data->dtype == DT_INT64);
    int64_t coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < total; lin++) {
        int64_t rem = lin;
        for (int i = 0; i < ndim; i++) { coords[i] = rem / idx_strides[i]; rem %= idx_strides[i]; }
        int64_t index_val = idx->idata[lin];
        if (index_val < 0) index_val += data->shape[axis];

        int64_t src = 0;
        for (int i = 0; i < ndim; i++) {
            int64_t c = (i == axis) ? index_val : coords[i];
            src += c * data_strides[i];
        }
        if (is_int) out->idata[lin] = data->idata[src];
        else out->data[lin] = data->data[src];
    }
    return 0;
}

/* Mod with a compile-time-folded scalar divisor (fmod=0: integer modulus,
 * result takes the sign of the divisor, matching ONNX/numpy semantics -
 * sufficient here since the divisor (grid width) is always positive). */
int execute_mod(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;

    int64_t n = 1;
    for (int i = 0; i < in->ndim; i++) n *= in->shape[i];
    int64_t d = instr->mod_divisor;

    for (int64_t i = 0; i < n; i++) {
        int64_t a = in->idata[i];
        int64_t r = a % d;
        if (r != 0 && ((r < 0) != (d < 0))) r += d;  /* match Python/numpy % sign convention */
        out->idata[i] = r;
    }
    return 0;
}
