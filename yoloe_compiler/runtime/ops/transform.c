#include "../runtime.h"
#include <string.h>
#include <stdio.h>

static int64_t numel_of(ir_tensor_t *t) {
    int64_t n = 1;
    for (int i = 0; i < t->ndim; i++) n *= t->shape[i];
    return n;
}

/* ONNX TensorProto.DataType values we care about: 1=FLOAT, 7=INT64 */
int execute_cast(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;
    int64_t n = numel_of(in);

    if (in->dtype == DT_INT64 && out->dtype == DT_FLOAT32) {
        for (int64_t i = 0; i < n; i++) out->data[i] = (float)in->idata[i];
    } else if (in->dtype == DT_FLOAT32 && out->dtype == DT_INT64) {
        for (int64_t i = 0; i < n; i++) out->idata[i] = (int64_t)in->data[i];
    } else if (in->dtype == out->dtype) {
        memcpy(out->data, in->data, in->size_bytes);
    } else {
        fprintf(stderr, "CAST: unsupported dtype conversion (%d -> %d)\n", in->dtype, out->dtype);
        return -1;
    }
    return 0;
}

/* Flatten / Unsqueeze / Squeeze / Reshape are all pure metadata reshapes
 * for a contiguous row-major tensor: same element count and ordering,
 * different shape. A straight byte copy is correct and simple; the
 * accelerator backend can later replace this with true in-place aliasing
 * once the memory planner supports tensor aliasing (spec section 22 keeps
 * that decision out of this reference pass). */
static int copy_reshape(ir_tensor_t *in, ir_tensor_t *out) {
    if (in->data == out->data) return 0;
    memcpy(out->data, in->data, in->size_bytes);
    return 0;
}

int execute_flatten(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;
    return copy_reshape(in, out);
}

int execute_unsqueeze(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;
    return copy_reshape(in, out);
}

int execute_squeeze(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;
    return copy_reshape(in, out);
}
