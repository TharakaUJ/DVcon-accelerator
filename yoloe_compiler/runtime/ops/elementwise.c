#include "../runtime.h"
#include <math.h>
#include <stdio.h>

/* Numpy-style broadcasting: align shapes from the right, size-1 dims broadcast. */
static int64_t broadcast_index(ir_tensor_t *t, int64_t *out_coords, int out_ndim) {
    int64_t idx = 0;
    for (int i = 0; i < t->ndim; i++) {
        int out_dim_pos = out_ndim - t->ndim + i;
        int64_t coord = out_coords[out_dim_pos];
        int64_t dim = t->shape[i];
        int64_t use_coord = (dim == 1) ? 0 : coord;
        int64_t s = 1;
        for (int j = i + 1; j < t->ndim; j++) s *= t->shape[j];
        idx += use_coord * s;
    }
    return idx;
}

static void unravel(int64_t linear, int64_t *shape, int ndim, int64_t *coords) {
    for (int i = ndim - 1; i >= 0; i--) {
        coords[i] = linear % shape[i];
        linear /= shape[i];
    }
}

typedef float (*binop_f32_fn)(float, float);
typedef int64_t (*binop_i64_fn)(int64_t, int64_t);

static float f_add(float a, float b) { return a + b; }
static float f_sub(float a, float b) { return a - b; }
static float f_mul(float a, float b) { return a * b; }
static float f_div(float a, float b) { return a / b; }

static int64_t i_add(int64_t a, int64_t b) { return a + b; }
static int64_t i_sub(int64_t a, int64_t b) { return a - b; }
static int64_t i_mul(int64_t a, int64_t b) { return a * b; }
/* Integer Div in ONNX truncates toward zero (C's native `/` semantics for
 * int64), matching numpy's `//` only for same-sign operands - sufficient
 * here since these are non-negative index/count computations. */
static int64_t i_div(int64_t a, int64_t b) { return a / b; }

/*
 * Elementwise binary op, dispatching on dtype. YOLOE's detect head performs
 * genuine integer arithmetic (e.g. /model.23/Div_1, dividing flattened
 * anchor indices by the class count) on int64 tensors - treating that as
 * float32 bit-reinterpretation would silently corrupt the values (this was
 * caught via a real segfault during bring-up: garbage int64 "indices"
 * computed this way fed an out-of-bounds Gather downstream).
 */
static int execute_binop(ir_program_t *prog, ir_instruction_t *instr, binop_f32_fn f32fn, binop_i64_fn i64fn) {
    ir_tensor_t *a = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *b = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!a || !b || !out) { fprintf(stderr, "binop: missing tensor\n"); return -1; }

    int is_int = (out->dtype == DT_INT64);
    if (is_int && (a->dtype != DT_INT64 || b->dtype != DT_INT64)) {
        fprintf(stderr, "binop: output is int64 but an input is not (mixed-dtype "
                "elementwise op not implemented)\n");
        return -1;
    }

    int64_t total = 1;
    for (int i = 0; i < out->ndim; i++) total *= out->shape[i];

    int64_t coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < total; lin++) {
        unravel(lin, out->shape, out->ndim, coords);
        int64_t ai = (a->ndim == 0) ? 0 : broadcast_index(a, coords, out->ndim);
        int64_t bi = (b->ndim == 0) ? 0 : broadcast_index(b, coords, out->ndim);
        if (is_int) {
            out->idata[lin] = i64fn(a->idata[ai], b->idata[bi]);
        } else {
            out->data[lin] = f32fn(a->data[ai], b->data[bi]);
        }
    }
    return 0;
}

int execute_add(ir_program_t *prog, ir_instruction_t *instr) { return execute_binop(prog, instr, f_add, i_add); }
int execute_sub(ir_program_t *prog, ir_instruction_t *instr) { return execute_binop(prog, instr, f_sub, i_sub); }
int execute_mul(ir_program_t *prog, ir_instruction_t *instr) { return execute_binop(prog, instr, f_mul, i_mul); }
int execute_div(ir_program_t *prog, ir_instruction_t *instr) { return execute_binop(prog, instr, f_div, i_div); }

static int64_t numel_of(ir_tensor_t *t) {
    int64_t n = 1;
    for (int i = 0; i < t->ndim; i++) n *= t->shape[i];
    return n;
}

int execute_sigmoid(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;
    int64_t n = numel_of(in);
    for (int64_t i = 0; i < n; i++) out->data[i] = 1.0f / (1.0f + expf(-in->data[i]));
    return 0;
}

int execute_relu(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;
    int64_t n = numel_of(in);
    for (int64_t i = 0; i < n; i++) out->data[i] = in->data[i] > 0.0f ? in->data[i] : 0.0f;
    return 0;
}

/* SiLU(x) = x * sigmoid(x). Used when the ONNX graph exports Silu directly
 * (rather than as separate Sigmoid+Mul nodes, which are handled by the
 * existing SIGMOID/MUL kernels without needing this at all). */
int execute_silu(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;
    int64_t n = numel_of(in);
    for (int64_t i = 0; i < n; i++) {
        float x = in->data[i];
        out->data[i] = x / (1.0f + expf(-x));
    }
    return 0;
}
