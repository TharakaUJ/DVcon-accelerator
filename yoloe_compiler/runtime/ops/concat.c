#include "../runtime.h"
#include <string.h>
#include <stdio.h>

int execute_concat(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!out) return -1;
    int64_t axis = instr->axis;
    if (axis < 0) axis += out->ndim;

    /* outer = product of dims before axis, inner = product of dims after axis */
    int64_t outer = 1;
    for (int i = 0; i < axis; i++) outer *= out->shape[i];
    int64_t inner = 1;
    for (int i = axis + 1; i < out->ndim; i++) inner *= out->shape[i];

    int64_t out_axis_dim = out->shape[axis];
    int64_t axis_offset = 0;

    for (int t = 0; t < instr->num_inputs; t++) {
        ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[t]);
        if (!in) { fprintf(stderr, "CONCAT: missing input %d\n", t); return -1; }
        int64_t in_axis_dim = in->shape[axis];

        for (int64_t o = 0; o < outer; o++) {
            for (int64_t a = 0; a < in_axis_dim; a++) {
                const float *src = in->data + (o * in_axis_dim + a) * inner;
                float *dst = out->data + (o * out_axis_dim + (axis_offset + a)) * inner;
                memcpy(dst, src, sizeof(float) * inner);
            }
        }
        axis_offset += in_axis_dim;
    }
    return 0;
}

/* Reshape: pure metadata operation in ONNX (same underlying data, new
 * shape). Since tensors are contiguous row-major, this is a memcpy when
 * input/output occupy different memory offsets, or a no-op if the memory
 * planner already aliased them (it currently does not alias across
 * different tensor ids, so we memcpy defensively). */
int execute_reshape(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;
    if (in->data != out->data) {
        memcpy(out->data, in->data, out->size_bytes);
    }
    return 0;
}
