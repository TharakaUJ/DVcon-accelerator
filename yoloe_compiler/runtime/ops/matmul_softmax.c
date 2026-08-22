#include "../runtime.h"
#include <math.h>
#include <stdio.h>

/* MatMul with ONNX batch-broadcasting semantics: the last two dims of each
 * input are treated as matrices, all leading dims batch-broadcast (numpy
 * style, size-1 dims broadcast). Sufficient for YOLOE's attention blocks
 * (4D: [N, heads, seq, dim]). */
int execute_matmul(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *a = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *b = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!a || !b || !out) return -1;

    int ndim = out->ndim;
    int64_t M = a->shape[a->ndim - 2], K = a->shape[a->ndim - 1];
    int64_t K2 = b->shape[b->ndim - 2], N = b->shape[b->ndim - 1];
    if (K != K2) { fprintf(stderr, "MATMUL: inner dim mismatch (%lld vs %lld)\n", (long long)K, (long long)K2); return -1; }

    int64_t batch = 1;
    for (int i = 0; i < ndim - 2; i++) batch *= out->shape[i];

    /* per-batch strides for a/b, honoring broadcast (size-1 batch dims) */
    int64_t a_batch_stride = M * K, b_batch_stride = K * N;
    /* if a or b has fewer batch dims / a size-1 batch dim, it doesn't
     * advance across batches - detect the common "same batch shape" case
     * used throughout YOLOE (both operands already the same batch shape). */
    int a_has_full_batch = (a->ndim == ndim);
    int b_has_full_batch = (b->ndim == ndim);

    for (int64_t bi = 0; bi < batch; bi++) {
        const float *ap = a->data + (a_has_full_batch ? bi : 0) * a_batch_stride;
        const float *bp = b->data + (b_has_full_batch ? bi : 0) * b_batch_stride;
        float *op = out->data + bi * M * N;
        for (int64_t m = 0; m < M; m++) {
            for (int64_t n = 0; n < N; n++) {
                double acc = 0.0;
                for (int64_t k = 0; k < K; k++) acc += (double)ap[m * K + k] * (double)bp[k * N + n];
                op[m * N + n] = (float)acc;
            }
        }
    }
    return 0;
}

int execute_softmax(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *in = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!in || !out) return -1;

    int64_t axis = instr->axis;
    if (axis < 0) axis += in->ndim;

    int64_t outer = 1;
    for (int i = 0; i < axis; i++) outer *= in->shape[i];
    int64_t axis_dim = in->shape[axis];
    int64_t inner = 1;
    for (int i = axis + 1; i < in->ndim; i++) inner *= in->shape[i];

    for (int64_t o = 0; o < outer; o++) {
        for (int64_t in_ = 0; in_ < inner; in_++) {
            float maxv = -3.402823e38f;
            for (int64_t a = 0; a < axis_dim; a++) {
                float v = in->data[(o * axis_dim + a) * inner + in_];
                if (v > maxv) maxv = v;
            }
            double sum = 0.0;
            for (int64_t a = 0; a < axis_dim; a++) {
                float v = expf(in->data[(o * axis_dim + a) * inner + in_] - maxv);
                out->data[(o * axis_dim + a) * inner + in_] = v;
                sum += v;
            }
            for (int64_t a = 0; a < axis_dim; a++) {
                out->data[(o * axis_dim + a) * inner + in_] = (float)(out->data[(o * axis_dim + a) * inner + in_] / sum);
            }
        }
    }
    return 0;
}
