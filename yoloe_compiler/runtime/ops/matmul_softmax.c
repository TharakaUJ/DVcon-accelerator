#include "../runtime.h"
#include <math.h>
#include <stdio.h>

/* MatMul with ONNX batch-broadcasting semantics: the last two dims of each
 * input are treated as matrices, all leading dims batch-broadcast numpy
 * style (missing or size-1 batch dims broadcast). Both inputs must be at
 * least 2-D. YOLOE's attention blocks use 4D [N, heads, seq, dim]. */
int execute_matmul(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *a = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *b = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!a || !b || !out) return -1;
    if (a->ndim < 2 || b->ndim < 2) {
        fprintf(stderr, "MATMUL: 1-D operands are not implemented\n");
        return -1;
    }

    int ndim = out->ndim;
    int64_t M = a->shape[a->ndim - 2], K = a->shape[a->ndim - 1];
    int64_t K2 = b->shape[b->ndim - 2], N = b->shape[b->ndim - 1];
    if (K != K2) { fprintf(stderr, "MATMUL: inner dim mismatch (%lld vs %lld)\n", (long long)K, (long long)K2); return -1; }

    int batch_ndim = ndim - 2;
    int64_t batch = 1;
    for (int i = 0; i < batch_ndim; i++) batch *= out->shape[i];

    int64_t coords[IR_MAX_DIMS];
    for (int64_t bi = 0; bi < batch; bi++) {
        unravel_index(bi, out->shape, batch_ndim, coords);
        /* flat batch offset into a/b over their own batch dims, broadcasting size-1 dims */
        int64_t a_off = 0, b_off = 0, stride;
        stride = 1;
        for (int i = a->ndim - 3; i >= 0; i--) {
            int64_t c = coords[batch_ndim - (a->ndim - 2) + i];
            if (a->shape[i] != 1) a_off += c * stride;
            stride *= a->shape[i];
        }
        stride = 1;
        for (int i = b->ndim - 3; i >= 0; i--) {
            int64_t c = coords[batch_ndim - (b->ndim - 2) + i];
            if (b->shape[i] != 1) b_off += c * stride;
            stride *= b->shape[i];
        }
        const float *ap = a->data + a_off * M * K;
        const float *bp = b->data + b_off * K * N;
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

/* Gemm: Y = alpha * A' * B' + beta * C, with A' / B' optionally transposed
 * and C (optional) unidirectionally broadcast to [M, N]. */
int execute_gemm(ir_program_t *prog, ir_instruction_t *instr) {
    ir_tensor_t *a = runtime_find_tensor(prog, instr->inputs[0]);
    ir_tensor_t *b = runtime_find_tensor(prog, instr->inputs[1]);
    ir_tensor_t *c = (instr->num_inputs >= 3) ? runtime_find_tensor(prog, instr->inputs[2]) : NULL;
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!a || !b || !out) { fprintf(stderr, "GEMM: missing tensor\n"); return -1; }

    int64_t M = out->shape[0], N = out->shape[1];
    int64_t K = instr->trans_a ? a->shape[0] : a->shape[1];
    int64_t coords[2];
    for (int64_t m = 0; m < M; m++) {
        for (int64_t n = 0; n < N; n++) {
            double acc = 0.0;
            for (int64_t k = 0; k < K; k++) {
                float av = instr->trans_a ? a->data[k * M + m] : a->data[m * K + k];
                float bv = instr->trans_b ? b->data[n * K + k] : b->data[k * N + n];
                acc += (double)av * (double)bv;
            }
            acc *= instr->alpha;
            if (c) {
                coords[0] = m; coords[1] = n;
                acc += instr->beta * c->data[broadcast_index(c, coords, 2)];
            }
            out->data[m * N + n] = (float)acc;
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
