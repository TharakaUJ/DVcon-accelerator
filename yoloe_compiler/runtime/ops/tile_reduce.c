#include "../runtime.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

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

typedef enum { REDUCE_MAX, REDUCE_SUM, REDUCE_MEAN } reduce_kind_t;

/* ReduceMax/Sum/Mean over the axes given in instr->reduce_axes (all axes
 * when none are given, per ONNX). YOLOE's detect head only reduces over the
 * last axis (per-anchor max class score), but any axis subset works. */
static int execute_reduce(ir_program_t *prog, ir_instruction_t *instr, reduce_kind_t kind) {
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
    if (instr->reduce_n == 0) {
        for (int i = 0; i < ndim; i++) reduce_mask[i] = 1;
    }

    /* Walk the input once, accumulating each element into the output slot
     * whose coordinates match on the kept axes. Output index is computed
     * over the kept axes only, which is the same flat order for keepdims=0
     * (dims dropped) and keepdims=1 (dims of size 1). */
    int64_t out_total = tensor_numel(out);
    int64_t red_count = 1;
    for (int i = 0; i < ndim; i++) if (reduce_mask[i]) red_count *= in->shape[i];

    double *acc = (double *)malloc(sizeof(double) * (out_total ? out_total : 1));
    if (!acc) return -1;
    for (int64_t o = 0; o < out_total; o++) acc[o] = (kind == REDUCE_MAX) ? -INFINITY : 0.0;

    int64_t in_total = tensor_numel(in);
    int64_t coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < in_total; lin++) {
        unravel_index(lin, in->shape, ndim, coords);
        int64_t o = 0;
        for (int i = 0; i < ndim; i++) if (!reduce_mask[i]) o = o * in->shape[i] + coords[i];
        double v = in->data[lin];
        if (kind == REDUCE_MAX) { if (v > acc[o]) acc[o] = v; }
        else acc[o] += v;
    }
    for (int64_t o = 0; o < out_total; o++)
        out->data[o] = (float)(kind == REDUCE_MEAN ? acc[o] / red_count : acc[o]);
    free(acc);
    return 0;
}

int execute_reducemax(ir_program_t *prog, ir_instruction_t *instr) { return execute_reduce(prog, instr, REDUCE_MAX); }
int execute_reducesum(ir_program_t *prog, ir_instruction_t *instr) { return execute_reduce(prog, instr, REDUCE_SUM); }
int execute_reducemean(ir_program_t *prog, ir_instruction_t *instr) { return execute_reduce(prog, instr, REDUCE_MEAN); }
