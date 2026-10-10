#include "../runtime.h"
#include <stdio.h>

int execute_tile(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;

    int ndim = in->ndim;
    int64_t in_strides[IR_MAX_DIMS], out_strides[IR_MAX_DIMS];
    int64_t s = 1;
    for (int i = ndim - 1; i >= 0; i--) { in_strides[i] = s; s *= in->shape[i]; }
    s = 1;
    for (int i = ndim - 1; i >= 0; i--) { out_strides[i] = s; s *= out->shape[i]; }

    int64_t total = 1;
    for (int i = 0; i < ndim; i++) total *= out->shape[i];

    int64_t coords[IR_MAX_DIMS];
    int is_int = (in->dtype == DT_INT64);
    for (int64_t lin = 0; lin < total; lin++) {
        int64_t rem = lin;
        for (int i = 0; i < ndim; i++) { coords[i] = rem / out_strides[i]; rem %= out_strides[i]; }
        int64_t in_idx = 0;
        for (int i = 0; i < ndim; i++) in_idx += (coords[i] % in->shape[i]) * in_strides[i];
        if (is_int) out->idata[lin] = in->idata[in_idx];
        else out->data[lin] = in->data[in_idx];
    }
    return 0;
}

/* ReduceMax over the axes given in instr->reduce_axes. Only the pattern
 * actually used by YOLOE's detect head (reduce over the last axis, i.e.
 * per-anchor max class score) is exercised, but this implementation
 * supports an arbitrary axis subset. */
int execute_reducemax(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;

    int ndim = in->ndim;
    int reduce_mask[IR_MAX_DIMS] = {0};
    for (int i = 0; i < instr->reduce_n; i++) {
        int64_t ax = instr->reduce_axes[i];
        if (ax < 0) ax += ndim;
        reduce_mask[ax] = 1;
    }

    int64_t in_strides[IR_MAX_DIMS];
    int64_t s = 1;
    for (int i = ndim - 1; i >= 0; i--) { in_strides[i] = s; s *= in->shape[i]; }

    /* out has the reduced axes either dropped (keepdims=0) or size-1
     * (keepdims=1); tensors.json (from ONNX shape inference) already tells
     * us the correct out->shape/out->ndim either way, so we just need to
     * map an output linear index back to the correct set of input coords
     * (with reduced axes ranging over their full extent). */
    int out_ndim = out->ndim;
    int64_t out_strides[IR_MAX_DIMS];
    s = 1;
    for (int i = out_ndim - 1; i >= 0; i--) { out_strides[i] = s; s *= out->shape[i]; }

    int64_t out_total = 1;
    for (int i = 0; i < out_ndim; i++) out_total *= out->shape[i];

    /* Build mapping from output-dim index -> input-dim index (skipping
     * reduced dims when keepdims==0). */
    int out_to_in_dim[IR_MAX_DIMS];
    if (instr->keepdims) {
        for (int i = 0; i < ndim; i++) out_to_in_dim[i] = i;
    } else {
        int o = 0;
        for (int i = 0; i < ndim; i++) if (!reduce_mask[i]) out_to_in_dim[o++] = i;
    }

    int64_t out_coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < out_total; lin++) {
        int64_t rem = lin;
        for (int i = 0; i < out_ndim; i++) { out_coords[i] = rem / out_strides[i]; rem %= out_strides[i]; }

        int64_t base_coords[IR_MAX_DIMS] = {0};
        for (int i = 0; i < out_ndim; i++) {
            int in_dim = out_to_in_dim[i];
            base_coords[in_dim] = instr->keepdims && reduce_mask[in_dim] ? 0 : out_coords[i];
        }

        /* iterate over the reduced axes' full extent, tracking the max */
        float best = -3.402823e38f;
        int64_t idx_coords[IR_MAX_DIMS];
        for (int i = 0; i < ndim; i++) idx_coords[i] = base_coords[i];

        /* simple recursive-free enumeration over reduced dims via odometer */
        int red_dims[IR_MAX_DIMS], n_red = 0;
        for (int i = 0; i < ndim; i++) if (reduce_mask[i]) red_dims[n_red++] = i;

        int64_t red_total = 1;
        for (int i = 0; i < n_red; i++) red_total *= in->shape[red_dims[i]];

        for (int64_t r = 0; r < red_total; r++) {
            int64_t rr = r;
            for (int i = 0; i < n_red; i++) {
                int64_t dim_size = in->shape[red_dims[i]];
                idx_coords[red_dims[i]] = rr % dim_size;
                rr /= dim_size;
            }
            int64_t in_idx = 0;
            for (int i = 0; i < ndim; i++) in_idx += idx_coords[i] * in_strides[i];
            float v = in->data[in_idx];
            if (v > best) best = v;
        }
        out->data[lin] = best;
    }
    return 0;
}
