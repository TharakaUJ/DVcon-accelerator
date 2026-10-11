#include "../runtime.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

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

    int64_t total = tensor_numel(out);
    int64_t coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < total; lin++) {
        unravel_index(lin, out->shape, out->ndim, coords);
        int64_t ai = broadcast_index(a, coords, out->ndim);
        int64_t bi = broadcast_index(b, coords, out->ndim);
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

/* Pow allows mixed dtypes in ONNX (e.g. float base, int exponent), so it goes
 * through the dtype-generic accessors. */
int execute_pow(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *a = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *b = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!a || !b || !out) { fprintf(stderr, "POW: missing tensor\n"); return -1; }
    int64_t total = tensor_numel(out);
    int64_t coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < total; lin++) {
        unravel_index(lin, out->shape, out->ndim, coords);
        double base = tensor_get(a, broadcast_index(a, coords, out->ndim));
        double ex = tensor_get(b, broadcast_index(b, coords, out->ndim));
        tensor_set(out, lin, out->dtype == DT_FLOAT32 ? (double)powf((float)base, (float)ex) : pow(base, ex));
    }
    return 0;
}

/* Equal: bool output, inputs of any (matching) dtype, with broadcasting. */
int execute_equal(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *a = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *b = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!a || !b || !out) { fprintf(stderr, "EQUAL: missing tensor\n"); return -1; }
    int64_t total = tensor_numel(out);
    int64_t coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < total; lin++) {
        unravel_index(lin, out->shape, out->ndim, coords);
        int64_t ai = broadcast_index(a, coords, out->ndim);
        int64_t bi = broadcast_index(b, coords, out->ndim);
        int eq = (a->dtype == DT_INT64 && b->dtype == DT_INT64)
            ? a->idata[ai] == b->idata[bi]
            : tensor_get(a, ai) == tensor_get(b, bi);
        ((uint8_t *)out->data)[lin] = (uint8_t)eq;
    }
    return 0;
}

/* Where(cond, X, Y): broadcast select, copied bytewise so int64 stays exact. */
int execute_where(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *c = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *x = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *y = runtime_find_tensor(prog, instr->inputs[2]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!c || !x || !y || !out) { fprintf(stderr, "WHERE: missing tensor\n"); return -1; }
    size_t es = tensor_elem_size(out);
    int64_t total = tensor_numel(out);
    int64_t coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < total; lin++) {
        unravel_index(lin, out->shape, out->ndim, coords);
        int take_x = tensor_get(c, broadcast_index(c, coords, out->ndim)) != 0.0;
        ir_tensor_t *src = take_x ? x : y;
        int64_t si = broadcast_index(src, coords, out->ndim);
        memcpy((uint8_t *)out->data + lin * es, (uint8_t *)src->data + si * es, es);
    }
    return 0;
}

/* Expand: broadcast the input to the (shape-inferred) output shape. */
int execute_expand(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) { fprintf(stderr, "EXPAND: missing tensor\n"); return -1; }
    size_t es = tensor_elem_size(out);
    int64_t total = tensor_numel(out);
    int64_t coords[IR_MAX_DIMS];
    for (int64_t lin = 0; lin < total; lin++) {
        unravel_index(lin, out->shape, out->ndim, coords);
        int64_t si = broadcast_index(in, coords, out->ndim);
        memcpy((uint8_t *)out->data + lin * es, (uint8_t *)in->data + si * es, es);
    }
    return 0;
}

/* ---- float32 unary ops ----------------------------------------------------- */

typedef float (*unary_fn)(float x, const ir_instruction_t *instr);

static int execute_unary(ir_program_t *prog, ir_instruction_t *instr, unary_fn fn) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;
    if (in->dtype != DT_FLOAT32) {
        fprintf(stderr, "%s: only float32 is implemented\n", opcode_to_string(instr->op));
        return -1;
    }
    int64_t n = tensor_numel(in);
    for (int64_t i = 0; i < n; i++) out->data[i] = fn(in->data[i], instr);
    return 0;
}

static float u_sigmoid(float x, const ir_instruction_t *ins) { return 1.0f / (1.0f + expf(-x)); }
static float u_relu(float x, const ir_instruction_t *ins) { return x > 0.0f ? x : 0.0f; }
/* SiLU(x) = x * sigmoid(x). Used when the ONNX graph exports Silu directly
 * (rather than as separate Sigmoid+Mul nodes, which are handled by the
 * existing SIGMOID/MUL kernels without needing this at all). */
static float u_silu(float x, const ir_instruction_t *ins) { return x / (1.0f + expf(-x)); }
static float u_leakyrelu(float x, const ir_instruction_t *ins) { return x >= 0.0f ? x : (float)ins->alpha * x; }
static float u_exp(float x, const ir_instruction_t *ins) { return expf(x); }
static float u_tanh(float x, const ir_instruction_t *ins) { return tanhf(x); }
static float u_sqrt(float x, const ir_instruction_t *ins) { return sqrtf(x); }
static float u_hardsigmoid(float x, const ir_instruction_t *ins) {
    float v = (float)ins->alpha * x + (float)ins->beta;
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}
static float u_clip(float x, const ir_instruction_t *ins) {
    if (ins->has_clip_min && x < (float)ins->clip_min) x = (float)ins->clip_min;
    if (ins->has_clip_max && x > (float)ins->clip_max) x = (float)ins->clip_max;
    return x;
}

int execute_sigmoid(ir_program_t *prog, ir_instruction_t *instr) { return execute_unary(prog, instr, u_sigmoid); }
int execute_relu(ir_program_t *prog, ir_instruction_t *instr) { return execute_unary(prog, instr, u_relu); }
int execute_silu(ir_program_t *prog, ir_instruction_t *instr) { return execute_unary(prog, instr, u_silu); }
int execute_leakyrelu(ir_program_t *prog, ir_instruction_t *instr) { return execute_unary(prog, instr, u_leakyrelu); }
int execute_exp(ir_program_t *prog, ir_instruction_t *instr) { return execute_unary(prog, instr, u_exp); }
int execute_tanh(ir_program_t *prog, ir_instruction_t *instr) { return execute_unary(prog, instr, u_tanh); }
int execute_sqrt(ir_program_t *prog, ir_instruction_t *instr) { return execute_unary(prog, instr, u_sqrt); }
int execute_hardsigmoid(ir_program_t *prog, ir_instruction_t *instr) { return execute_unary(prog, instr, u_hardsigmoid); }
int execute_clip(ir_program_t *prog, ir_instruction_t *instr) { return execute_unary(prog, instr, u_clip); }
