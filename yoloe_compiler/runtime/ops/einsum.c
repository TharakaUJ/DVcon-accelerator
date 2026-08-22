#include "../runtime.h"
#include <string.h>
#include <stdio.h>

/*
 * Only supports the specific equation used by YOLOE's detect head:
 *   "bchw,bkc->bkhw"
 * out[b,k,h,w] = sum_c in0[b,c,h,w] * in1[b,k,c]
 *
 * This is the per-pixel dot product between the visual feature map and the
 * K text/visual prompt embeddings (open-vocabulary classification score
 * before sigmoid). Fails loudly for any other equation rather than
 * attempting a generic einsum evaluator, per the "don't silently
 * approximate" project rule - a generic einsum isn't needed for this model.
 */
int execute_einsum(ir_program_t *prog, ir_instruction_t *instr) {
    if (strcmp(instr->einsum_equation, "bchw,bkc->bkhw") != 0) {
        fprintf(stderr, "EINSUM: unsupported equation '%s' (only 'bchw,bkc->bkhw' is implemented)\n",
                instr->einsum_equation);
        return -1;
    }
    ir_tensor_t *x = runtime_find_tensor(prog, instr->inputs[0]);   /* [B,C,H,W] */
    ir_tensor_t *e = runtime_find_tensor(prog, instr->inputs[1]);   /* [B,K,C]   */
    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]); /* [B,K,H,W] */
    if (!x || !e || !out) { fprintf(stderr, "EINSUM: missing tensor\n"); return -1; }

    int64_t B = x->shape[0], C = x->shape[1], H = x->shape[2], W = x->shape[3];
    int64_t K = e->shape[1];

    for (int64_t b = 0; b < B; b++) {
        for (int64_t k = 0; k < K; k++) {
            for (int64_t h = 0; h < H; h++) {
                for (int64_t w = 0; w < W; w++) {
                    double acc = 0.0;
                    for (int64_t c = 0; c < C; c++) {
                        float xv = x->data[((b * C + c) * H + h) * W + w];
                        float ev = e->data[(b * K + k) * C + c];
                        acc += (double)xv * (double)ev;
                    }
                    out->data[((b * K + k) * H + h) * W + w] = (float)acc;
                }
            }
        }
    }
    return 0;
}
