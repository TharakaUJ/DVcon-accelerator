/*
 * yoloe_runtime - reference C interpreter for the compiled IR.
 *
 * Usage:
 *   yoloe_runtime --instructions build/instructions.json \
 *                 --tensors build/tensors.json \
 *                 --weights build/weights.bin \
 *                 --input reference/input.bin \
 *                 --dump-dir out/
 *
 * weights.bin / input.bin are raw float32 dumps produced by
 * verification/dump_reference.py, in the same order as tensors.json lists
 * WEIGHT/BIAS and INPUT tensors respectively (id-sorted, matching
 * json_writer.py's sort order).
 */
#include "runtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int load_raw_into(ir_tensor_t *t, FILE *f) {
    /* dtype-agnostic: just read this tensor's exact byte count. `data` and
     * `idata` alias the same memory (see runtime_bind_memory), so this
     * works whether the tensor is float32 or int64. */
    size_t read = fread(t->data, 1, t->size_bytes, f);
    return read == t->size_bytes ? 0 : -1;
}

static int load_weights(ir_program_t *prog, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open weights file %s\n", path); return -1; }
    for (int i = 0; i < prog->num_tensors; i++) {
        ir_tensor_t *t = &prog->tensors[i];
        if (t->region == REGION_WEIGHT) {
            if (load_raw_into(t, f) != 0) {
                fprintf(stderr, "Unexpected EOF reading weight tensor %s\n", t->id);
                fclose(f);
                return -1;
            }
        }
    }
    fclose(f);
    return 0;
}

static int load_input(ir_program_t *prog, const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open input file %s\n", path); return -1; }
    for (int i = 0; i < prog->num_tensors; i++) {
        ir_tensor_t *t = &prog->tensors[i];
        if (t->region == REGION_INPUT) {
            if (load_raw_into(t, f) != 0) {
                fprintf(stderr, "Unexpected EOF reading input tensor %s\n", t->id);
                fclose(f);
                return -1;
            }
        }
    }
    fclose(f);
    return 0;
}

/* Streaming per-instruction dump: writes each instruction's output
 * tensor(s) to <dump_dir>/<tensor_id>.bin immediately after it is produced.
 * This MUST happen before later instructions can reuse the tensor's
 * memory (see runtime_post_instr_cb doc in runtime.h). Dumping only after
 * the whole program finishes silently captures stale/overwritten data for
 * any tensor whose memory got reused - a real bug caught during
 * development of this runtime (see project notes). */
static void dump_instr_outputs_cb(ir_program_t *prog, ir_instruction_t *instr, void *user_data) {
    const char *dump_dir = (const char *)user_data;
    char path[512];
    for (int i = 0; i < instr->num_outputs; i++) {
        ir_tensor_t *t = runtime_find_tensor(prog, instr->outputs[i]);
        if (!t || !t->data) continue;
        snprintf(path, sizeof(path), "%s/%s.bin", dump_dir, t->id);
        FILE *f = fopen(path, "wb");
        if (!f) continue;
        fwrite(t->data, 1, t->size_bytes, f);
        fclose(f);
    }
}

int main(int argc, char **argv) {
    const char *instructions_path = NULL, *tensors_path = NULL;
    const char *weights_path = NULL, *input_path = NULL, *dump_dir = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--instructions") && i + 1 < argc) instructions_path = argv[++i];
        else if (!strcmp(argv[i], "--tensors") && i + 1 < argc) tensors_path = argv[++i];
        else if (!strcmp(argv[i], "--weights") && i + 1 < argc) weights_path = argv[++i];
        else if (!strcmp(argv[i], "--input") && i + 1 < argc) input_path = argv[++i];
        else if (!strcmp(argv[i], "--dump-dir") && i + 1 < argc) dump_dir = argv[++i];
    }
    if (!instructions_path || !tensors_path) {
        fprintf(stderr, "Usage: %s --instructions I.json --tensors T.json "
                "[--weights W.bin] [--input in.bin] [--dump-dir out/]\n", argv[0]);
        return 1;
    }

    ir_program_t prog;
    if (runtime_load(&prog, instructions_path, tensors_path) != 0) return 1;
    printf("Loaded %d instructions, %d tensors\n", prog.num_instructions, prog.num_tensors);

    if (runtime_bind_memory(&prog) != 0) return 1;

    if (weights_path && load_weights(&prog, weights_path) != 0) return 1;
    if (input_path && load_input(&prog, input_path) != 0) return 1;

    int rc = dump_dir
        ? runtime_execute_cb(&prog, dump_instr_outputs_cb, (void *)dump_dir)
        : runtime_execute(&prog);

    if (rc != 0) {
        fprintf(stderr, "Execution failed.\n");
        runtime_free(&prog);
        return 1;
    }
    printf("Execution complete.\n");

    runtime_free(&prog);
    return 0;
}
