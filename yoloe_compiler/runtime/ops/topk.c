#include "../runtime.h"
#include <stdlib.h>
#include <stdio.h>

typedef struct { float value; int64_t index; } vi_pair_t;

/* Ties: lower original index first, matching ONNX's sorted=1 behavior for
 * equal values (for both largest and smallest). */
static int cmp_desc(const void *a, const void *b) {
    float va = ((const vi_pair_t *)a)->value, vb = ((const vi_pair_t *)b)->value;
    if (va < vb) return 1;
    if (va > vb) return -1;
    int64_t ia = ((const vi_pair_t *)a)->index, ib = ((const vi_pair_t *)b)->index;
    return (ia < ib) ? -1 : (ia > ib ? 1 : 0);
}

static int cmp_asc(const void *a, const void *b) {
    float va = ((const vi_pair_t *)a)->value, vb = ((const vi_pair_t *)b)->value;
    if (va < vb) return -1;
    if (va > vb) return 1;
    int64_t ia = ((const vi_pair_t *)a)->index, ib = ((const vi_pair_t *)b)->index;
    return (ia < ib) ? -1 : (ia > ib ? 1 : 0);
}

/* TopK along `axis` (largest or smallest). Two outputs: values (float32),
 * indices (int64). */
int execute_topk(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *vals = runtime_find_tensor(prog, instr->outputs[0]);
    ir_tensor_t *idxs = (instr->num_outputs >= 2) ? runtime_find_tensor(prog, instr->outputs[1]) : NULL;
    if (!in || !vals) { fprintf(stderr, "TOPK: missing tensor\n"); return -1; }

    int64_t axis = instr->axis;
    if (axis < 0) axis += in->ndim;
    int64_t axis_dim = in->shape[axis];
    int64_t outer = 1, inner = 1;
    for (int i = 0; i < axis; i++) outer *= in->shape[i];
    for (int i = axis + 1; i < in->ndim; i++) inner *= in->shape[i];
    int64_t k = instr->topk_k;

    vi_pair_t *buf = (vi_pair_t *)malloc(sizeof(vi_pair_t) * axis_dim);
    if (!buf) return -1;

    for (int64_t o = 0; o < outer; o++) {
        for (int64_t in_ = 0; in_ < inner; in_++) {
            for (int64_t i = 0; i < axis_dim; i++) {
                buf[i].value = in->data[(o * axis_dim + i) * inner + in_];
                buf[i].index = i;
            }
            qsort(buf, axis_dim, sizeof(vi_pair_t), instr->topk_largest ? cmp_desc : cmp_asc);
            for (int64_t i = 0; i < k; i++) {
                int64_t dst = (o * k + i) * inner + in_;
                vals->data[dst] = buf[i].value;
                if (idxs) idxs->idata[dst] = buf[i].index;
            }
        }
    }
    free(buf);
    return 0;
}
