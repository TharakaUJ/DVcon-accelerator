#include "../runtime.h"
#include <string.h>
#include <stdio.h>

/*
 * Generic einsum over any number of inputs, explicit ("ab,bc->ac") or
 * implicit ("ab,bc", output = letters used once, alphabetical) form.
 * Repeated letters within one operand (diagonals) work; ellipsis ("...")
 * is not implemented and fails loudly. Plain loop over every combination of
 * output + summed indices - a correctness reference, not fast.
 */
static int einsum_generic(ir_program_t *prog, ir_instruction_t *instr) {
    const char *eq = instr->einsum_equation;
    if (strstr(eq, "...")) {
        fprintf(stderr, "EINSUM: ellipsis is not implemented ('%s')\n", eq);
        return -1;
    }
    char operands[IR_MAX_INPUTS][IR_MAX_DIMS + 1] = {{0}};
    char out_letters[IR_MAX_DIMS + 1] = {0};
    int n_ops = 0, pos = 0;
    const char *p = eq;
    for (; *p && *p != '-'; p++) {
        if (*p == ' ') continue;
        if (*p == ',') { n_ops++; pos = 0; continue; }
        if (n_ops >= IR_MAX_INPUTS || pos >= IR_MAX_DIMS) { fprintf(stderr, "EINSUM: equation too large\n"); return -1; }
        operands[n_ops][pos++] = *p;
    }
    n_ops++;
    if (n_ops != instr->num_inputs) {
        fprintf(stderr, "EINSUM: '%s' has %d operands but %d inputs\n", eq, n_ops, instr->num_inputs);
        return -1;
    }

    /* letter -> extent, plus how often each letter is used */
    int64_t extent[128] = {0};
    int count[128] = {0};
    ir_tensor_t *ins[IR_MAX_INPUTS];
    for (int i = 0; i < n_ops; i++) {
        ins[i] = runtime_find_tensor(prog, instr->inputs[i]);
        if (!ins[i] || (int)strlen(operands[i]) != ins[i]->ndim) {
            fprintf(stderr, "EINSUM: operand %d does not match its tensor rank\n", i);
            return -1;
        }
        for (int d = 0; operands[i][d]; d++) {
            extent[(int)operands[i][d]] = ins[i]->shape[d];
            count[(int)operands[i][d]]++;
        }
    }
    if (*p == '-') {
        int o = 0;
        for (p += 2; *p; p++) if (*p != ' ') out_letters[o++] = *p;
    } else {
        int o = 0;
        for (int c = 0; c < 128; c++) if (count[c] == 1) out_letters[o++] = (char)c;
    }

    /* loop letters: output letters first, then summed letters */
    char letters[2 * IR_MAX_DIMS + 1] = {0};
    int n_letters = 0;
    for (int i = 0; out_letters[i]; i++) letters[n_letters++] = out_letters[i];
    for (int c = 0; c < 128; c++)
        if (count[c] && !strchr(out_letters, c)) letters[n_letters++] = (char)c;
    int n_out = (int)strlen(out_letters);

    ir_tensor_t *out = runtime_find_tensor(prog, instr->outputs[0]);
    if (!out) { fprintf(stderr, "EINSUM: missing output\n"); return -1; }
    int64_t out_total = tensor_numel(out);
    int64_t sum_total = 1;
    for (int i = n_out; i < n_letters; i++) sum_total *= extent[(int)letters[i]];

    int64_t value[128] = {0};
    for (int64_t oi = 0; oi < out_total; oi++) {
        int64_t rem = oi;
        for (int i = n_out - 1; i >= 0; i--) { value[(int)letters[i]] = rem % extent[(int)letters[i]]; rem /= extent[(int)letters[i]]; }
        double acc = 0.0;
        for (int64_t si = 0; si < sum_total; si++) {
            rem = si;
            for (int i = n_letters - 1; i >= n_out; i--) { value[(int)letters[i]] = rem % extent[(int)letters[i]]; rem /= extent[(int)letters[i]]; }
            double prod = 1.0;
            for (int k = 0; k < n_ops; k++) {
                int64_t idx = 0;
                for (int d = 0; operands[k][d]; d++) idx = idx * ins[k]->shape[d] + value[(int)operands[k][d]];
                prod *= ins[k]->data[idx];
            }
            acc += prod;
        }
        out->data[oi] = (float)acc;
    }
    return 0;
}

/*
 * Fast path for the equation used by YOLOE's detect head:
 *   "bchw,bkc->bkhw"
 * out[b,k,h,w] = sum_c in0[b,c,h,w] * in1[b,k,c]
 *
 * This is the per-pixel dot product between the visual feature map and the
 * K text/visual prompt embeddings (open-vocabulary classification score
 * before sigmoid). Any other equation goes through einsum_generic.
 */
int execute_einsum(ir_program_t *prog, ir_instruction_t *instr) {
    if (strcmp(instr->einsum_equation, "bchw,bkc->bkhw") != 0) {
        return einsum_generic(prog, instr);
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
