#include "runtime.h"
#include "thirdparty/cJSON.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *OPCODE_NAMES[OP_COUNT] = {
    "UNKNOWN", "CONV", "ADD", "SUB", "MUL", "DIV", "SIGMOID", "RELU", "SILU",
    "LEAKYRELU", "CONCAT", "SPLIT", "RESHAPE", "TRANSPOSE", "RESIZE",
    "MAXPOOL", "AVGPOOL", "MATMUL", "GEMM", "SOFTMAX", "BATCHNORM",
    "SLICE", "CAST", "GATHER", "UNSQUEEZE", "SQUEEZE", "FLATTEN",
    "REDUCEMAX", "TILE", "TOPK", "CONVTRANSPOSE", "EINSUM",
    "GATHERELEMENTS", "MOD"
};

ir_opcode_t opcode_from_string(const char *s) {
    for (int i = 0; i < OP_COUNT; i++) {
        if (strcmp(s, OPCODE_NAMES[i]) == 0) return (ir_opcode_t)i;
    }
    return OP_UNKNOWN;
}

const char *opcode_to_string(ir_opcode_t op) {
    if (op < 0 || op >= OP_COUNT) return "UNKNOWN";
    return OPCODE_NAMES[op];
}

/* ---- forward decls for op kernels (in ops/*.c) ---------------------------- */
int execute_conv(ir_program_t *prog, ir_instruction_t *instr);
int execute_add(ir_program_t *prog, ir_instruction_t *instr);
int execute_sub(ir_program_t *prog, ir_instruction_t *instr);
int execute_mul(ir_program_t *prog, ir_instruction_t *instr);
int execute_div(ir_program_t *prog, ir_instruction_t *instr);
int execute_sigmoid(ir_program_t *prog, ir_instruction_t *instr);
int execute_relu(ir_program_t *prog, ir_instruction_t *instr);
int execute_silu(ir_program_t *prog, ir_instruction_t *instr);
int execute_concat(ir_program_t *prog, ir_instruction_t *instr);
int execute_maxpool(ir_program_t *prog, ir_instruction_t *instr);
int execute_avgpool(ir_program_t *prog, ir_instruction_t *instr);
int execute_reshape(ir_program_t *prog, ir_instruction_t *instr);
int execute_transpose(ir_program_t *prog, ir_instruction_t *instr);
int execute_split(ir_program_t *prog, ir_instruction_t *instr);
int execute_slice(ir_program_t *prog, ir_instruction_t *instr);
int execute_cast(ir_program_t *prog, ir_instruction_t *instr);
int execute_flatten(ir_program_t *prog, ir_instruction_t *instr);
int execute_unsqueeze(ir_program_t *prog, ir_instruction_t *instr);
int execute_squeeze(ir_program_t *prog, ir_instruction_t *instr);
int execute_tile(ir_program_t *prog, ir_instruction_t *instr);
int execute_reducemax(ir_program_t *prog, ir_instruction_t *instr);
int execute_matmul(ir_program_t *prog, ir_instruction_t *instr);
int execute_softmax(ir_program_t *prog, ir_instruction_t *instr);
int execute_convtranspose(ir_program_t *prog, ir_instruction_t *instr);
int execute_resize(ir_program_t *prog, ir_instruction_t *instr);
int execute_topk(ir_program_t *prog, ir_instruction_t *instr);
int execute_gather(ir_program_t *prog, ir_instruction_t *instr);
int execute_gatherelements(ir_program_t *prog, ir_instruction_t *instr);
int execute_mod(ir_program_t *prog, ir_instruction_t *instr);
int execute_einsum(ir_program_t *prog, ir_instruction_t *instr);

/* ---- tensor lookup ---------------------------------------------------- */

ir_tensor_t *runtime_find_tensor(ir_program_t *prog, const char *id) {
    for (int i = 0; i < prog->num_tensors; i++) {
        if (strcmp(prog->tensors[i].id, id) == 0) return &prog->tensors[i];
    }
    return NULL;
}

ir_tensor_t *runtime_find_tensor_by_name(ir_program_t *prog, const char *onnx_name) {
    for (int i = 0; i < prog->num_tensors; i++) {
        if (strcmp(prog->tensors[i].name, onnx_name) == 0) return &prog->tensors[i];
    }
    return NULL;
}

static mem_region_t region_from_string(const char *s) {
    if (strcmp(s, "ACTIVATION") == 0) return REGION_ACTIVATION;
    if (strcmp(s, "WEIGHT") == 0) return REGION_WEIGHT;
    if (strcmp(s, "CONSTANT") == 0) return REGION_CONSTANT;
    if (strcmp(s, "INPUT") == 0) return REGION_INPUT;
    if (strcmp(s, "OUTPUT") == 0) return REGION_OUTPUT;
    return REGION_ACTIVATION;
}

static ir_dtype_t dtype_from_string(const char *s) {
    if (!s) return DT_FLOAT32;
    if (strcmp(s, "int64") == 0) return DT_INT64;
    if (strcmp(s, "int32") == 0) return DT_INT32;
    if (strcmp(s, "bool") == 0) return DT_BOOL;
    return DT_FLOAT32;
}

/* ---- memory binding ---------------------------------------------------- */

int runtime_bind_memory(ir_program_t *prog) {
    size_t needed[REGION_COUNT] = {0};
    for (int i = 0; i < prog->num_tensors; i++) {
        ir_tensor_t *t = &prog->tensors[i];
        size_t end = (size_t)t->memory_offset + t->size_bytes;
        if (end > needed[t->region]) needed[t->region] = end;
    }
    for (int r = 0; r < REGION_COUNT; r++) {
        if (needed[r] == 0) continue;
        prog->arena[r] = (uint8_t *)calloc(1, needed[r]);
        if (!prog->arena[r]) {
            fprintf(stderr, "runtime_bind_memory: OOM allocating region %d (%zu bytes)\n", r, needed[r]);
            return -1;
        }
        prog->arena_size[r] = needed[r];
    }
    for (int i = 0; i < prog->num_tensors; i++) {
        ir_tensor_t *t = &prog->tensors[i];
        if (!prog->arena[t->region]) continue;
        uint8_t *base = prog->arena[t->region] + t->memory_offset;
        t->data = (float *)base;
        t->idata = (int64_t *)base;
    }
    return 0;
}

void runtime_free(ir_program_t *prog) {
    for (int r = 0; r < REGION_COUNT; r++) {
        free(prog->arena[r]);
        prog->arena[r] = NULL;
    }
    free(prog->instructions);
    free(prog->tensors);
    prog->instructions = NULL;
    prog->tensors = NULL;
}

/* ---- JSON loading -------------------------------------------------------- */

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open %s\n", path); return NULL; }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = (char *)malloc(len + 1);
    if (fread(buf, 1, len, f) != (size_t)len) { fclose(f); free(buf); return NULL; }
    buf[len] = 0;
    fclose(f);
    return buf;
}

static void parse_int_array(cJSON *arr, int64_t *out, int max_n) {
    for (int i = 0; i < max_n; i++) out[i] = 0;
    if (!arr) return;
    int i = 0;
    cJSON *item;
    cJSON_ArrayForEach(item, arr) {
        if (i >= max_n) break;
        out[i++] = (int64_t)cJSON_GetNumberValue(item);
    }
}

static void load_instruction_attrs(ir_instruction_t *instr, cJSON *attrs) {
    if (!attrs) return;
    cJSON *v;
    if ((v = cJSON_GetObjectItem(attrs, "kernel"))) parse_int_array(v, instr->kernel, 2);
    if ((v = cJSON_GetObjectItem(attrs, "stride"))) parse_int_array(v, instr->stride, 2);
    if ((v = cJSON_GetObjectItem(attrs, "padding"))) parse_int_array(v, instr->padding, 4);
    if ((v = cJSON_GetObjectItem(attrs, "dilation"))) parse_int_array(v, instr->dilation, 2);
    if ((v = cJSON_GetObjectItem(attrs, "group"))) instr->group = (int64_t)cJSON_GetNumberValue(v);
    else instr->group = 1;
    if ((v = cJSON_GetObjectItem(attrs, "axis"))) instr->axis = (int64_t)cJSON_GetNumberValue(v);
    if ((v = cJSON_GetObjectItem(attrs, "alpha"))) instr->alpha = cJSON_GetNumberValue(v);
    if ((v = cJSON_GetObjectItem(attrs, "ceil_mode"))) instr->ceil_mode = (int64_t)cJSON_GetNumberValue(v);

    /* Slice: starts/ends/axes/steps folded to plain int arrays (may be
     * scalar-wrapped-as-list of length 1, per _to_py in instructions.py) */
    if ((v = cJSON_GetObjectItem(attrs, "starts"))) {
        parse_int_array(v, instr->slice_starts, IR_MAX_DIMS);
        instr->slice_n = cJSON_GetArraySize(v);
    }
    if ((v = cJSON_GetObjectItem(attrs, "ends"))) parse_int_array(v, instr->slice_ends, IR_MAX_DIMS);
    if ((v = cJSON_GetObjectItem(attrs, "axes"))) {
        /* shared by Slice's, Reduce's, and Unsqueeze's "axes" attribute -
         * each op's kernel only reads the field relevant to it. */
        parse_int_array(v, instr->slice_axes, IR_MAX_DIMS);
        parse_int_array(v, instr->reduce_axes, IR_MAX_DIMS);
        parse_int_array(v, instr->unsqueeze_axes, IR_MAX_DIMS);
        instr->reduce_n = cJSON_GetArraySize(v);
        instr->unsqueeze_n = cJSON_GetArraySize(v);
    }
    if ((v = cJSON_GetObjectItem(attrs, "steps"))) parse_int_array(v, instr->slice_steps, IR_MAX_DIMS);
    else { for (int i = 0; i < IR_MAX_DIMS; i++) instr->slice_steps[i] = 1; }

    if ((v = cJSON_GetObjectItem(attrs, "keepdims"))) instr->keepdims = (int64_t)cJSON_GetNumberValue(v);

    if ((v = cJSON_GetObjectItem(attrs, "repeats"))) {
        parse_int_array(v, instr->tile_repeats, IR_MAX_DIMS);
        instr->tile_n = cJSON_GetArraySize(v);
    }

    if ((v = cJSON_GetObjectItem(attrs, "k"))) {
        if (cJSON_IsArray(v)) instr->topk_k = (int64_t)cJSON_GetNumberValue(cJSON_GetArrayItem(v, 0));
        else instr->topk_k = (int64_t)cJSON_GetNumberValue(v);
    }
    if ((v = cJSON_GetObjectItem(attrs, "divisor"))) instr->mod_divisor = (int64_t)cJSON_GetNumberValue(v);
    if ((v = cJSON_GetObjectItem(attrs, "to"))) instr->cast_to = (int64_t)cJSON_GetNumberValue(v);

    if ((v = cJSON_GetObjectItem(attrs, "scales"))) {
        int n = cJSON_GetArraySize(v);
        for (int i = 0; i < n && i < IR_MAX_DIMS; i++)
            instr->resize_scales[i] = cJSON_GetNumberValue(cJSON_GetArrayItem(v, i));
        instr->resize_has_sizes = 0;
    }
    if ((v = cJSON_GetObjectItem(attrs, "sizes"))) {
        parse_int_array(v, instr->resize_sizes, IR_MAX_DIMS);
        instr->resize_has_sizes = 1;
    }
    if ((v = cJSON_GetObjectItem(attrs, "mode"))) {
        const char *s = cJSON_GetStringValue(v);
        if (s) strncpy(instr->resize_mode, s, sizeof(instr->resize_mode) - 1);
    }
    if ((v = cJSON_GetObjectItem(attrs, "nearest_mode"))) {
        const char *s = cJSON_GetStringValue(v);
        if (s) strncpy(instr->resize_nearest_mode, s, sizeof(instr->resize_nearest_mode) - 1);
    }
    if ((v = cJSON_GetObjectItem(attrs, "coordinate_transformation_mode"))) {
        const char *s = cJSON_GetStringValue(v);
        if (s) strncpy(instr->resize_coordinate_transformation_mode, s, sizeof(instr->resize_coordinate_transformation_mode) - 1);
    }
    if ((v = cJSON_GetObjectItem(attrs, "equation"))) {
        const char *s = cJSON_GetStringValue(v);
        if (s) strncpy(instr->einsum_equation, s, sizeof(instr->einsum_equation) - 1);
    }
    if ((v = cJSON_GetObjectItem(attrs, "perm"))) {
        parse_int_array(v, instr->perm, IR_MAX_DIMS);
        instr->perm_n = cJSON_GetArraySize(v);
    }
}

int runtime_load(ir_program_t *prog, const char *instructions_path, const char *tensors_path) {
    memset(prog, 0, sizeof(*prog));

    char *itext = read_file(instructions_path);
    char *ttext = read_file(tensors_path);
    if (!itext || !ttext) { free(itext); free(ttext); return -1; }

    cJSON *iroot = cJSON_Parse(itext);
    cJSON *troot = cJSON_Parse(ttext);
    free(itext); free(ttext);
    if (!iroot || !troot) {
        fprintf(stderr, "JSON parse error\n");
        return -1;
    }

    cJSON *ilist = cJSON_GetObjectItem(iroot, "instructions");
    cJSON *tlist = cJSON_GetObjectItem(troot, "tensors");

    prog->num_instructions = cJSON_GetArraySize(ilist);
    prog->num_tensors = cJSON_GetArraySize(tlist);
    prog->instructions = (ir_instruction_t *)calloc(prog->num_instructions, sizeof(ir_instruction_t));
    prog->tensors = (ir_tensor_t *)calloc(prog->num_tensors, sizeof(ir_tensor_t));

    int idx = 0;
    cJSON *inode;
    cJSON_ArrayForEach(inode, ilist) {
        ir_instruction_t *instr = &prog->instructions[idx];
        instr->id = (int)cJSON_GetNumberValue(cJSON_GetObjectItem(inode, "id"));
        const char *op_str = cJSON_GetStringValue(cJSON_GetObjectItem(inode, "op"));
        instr->op = opcode_from_string(op_str);
        if (instr->op == OP_UNKNOWN) {
            fprintf(stderr, "runtime_load: no C kernel registered for op '%s' "
                    "(instruction %d). Add it to runtime/ops/ and runtime.c.\n",
                    op_str, instr->id);
        }
        const char *nname = cJSON_GetStringValue(cJSON_GetObjectItem(inode, "onnx_node_name"));
        if (nname) strncpy(instr->onnx_node_name, nname, IR_MAX_NAME - 1);

        cJSON *inputs = cJSON_GetObjectItem(inode, "inputs");
        cJSON *outputs = cJSON_GetObjectItem(inode, "outputs");
        int ii = 0; cJSON *s;
        cJSON_ArrayForEach(s, inputs) {
            if (ii < IR_MAX_INPUTS) strncpy(instr->inputs[ii], cJSON_GetStringValue(s), IR_MAX_NAME - 1);
            ii++;
        }
        instr->num_inputs = ii;
        int oi = 0;
        cJSON_ArrayForEach(s, outputs) {
            if (oi < IR_MAX_OUTPUTS) strncpy(instr->outputs[oi], cJSON_GetStringValue(s), IR_MAX_NAME - 1);
            oi++;
        }
        instr->num_outputs = oi;

        load_instruction_attrs(instr, cJSON_GetObjectItem(inode, "attributes"));
        idx++;
    }

    idx = 0;
    cJSON *tnode;
    cJSON_ArrayForEach(tnode, tlist) {
        ir_tensor_t *t = &prog->tensors[idx];
        const char *id = cJSON_GetStringValue(cJSON_GetObjectItem(tnode, "id"));
        const char *name = cJSON_GetStringValue(cJSON_GetObjectItem(tnode, "name"));
        strncpy(t->id, id, IR_MAX_NAME - 1);
        if (name) strncpy(t->name, name, IR_MAX_NAME - 1);

        cJSON *shape = cJSON_GetObjectItem(tnode, "shape");
        int nd = 0; cJSON *d;
        cJSON_ArrayForEach(d, shape) {
            if (nd < IR_MAX_DIMS) t->shape[nd] = (int64_t)cJSON_GetNumberValue(d);
            nd++;
        }
        t->ndim = nd;

        cJSON *strides = cJSON_GetObjectItem(tnode, "strides");
        if (strides && !cJSON_IsNull(strides)) {
            int si = 0;
            cJSON_ArrayForEach(d, strides) { if (si < IR_MAX_DIMS) t->strides[si++] = (int64_t)cJSON_GetNumberValue(d); }
        }

        t->size_bytes = (size_t)cJSON_GetNumberValue(cJSON_GetObjectItem(tnode, "size_bytes"));
        t->region = region_from_string(cJSON_GetStringValue(cJSON_GetObjectItem(tnode, "memory_region")));
        t->dtype = dtype_from_string(cJSON_GetStringValue(cJSON_GetObjectItem(tnode, "dtype")));
        cJSON *off = cJSON_GetObjectItem(tnode, "memory_offset");
        t->memory_offset = (off && !cJSON_IsNull(off)) ? (int64_t)cJSON_GetNumberValue(off) : 0;
        idx++;
    }

    cJSON_Delete(iroot);
    cJSON_Delete(troot);
    return 0;
}

/* ---- dispatch ------------------------------------------------------------ */

int execute_instruction(ir_program_t *prog, ir_instruction_t *instr) {
    switch (instr->op) {
        case OP_CONV:      return execute_conv(prog, instr);
        case OP_ADD:        return execute_add(prog, instr);
        case OP_SUB:         return execute_sub(prog, instr);
        case OP_MUL:          return execute_mul(prog, instr);
        case OP_DIV:           return execute_div(prog, instr);
        case OP_SIGMOID:         return execute_sigmoid(prog, instr);
        case OP_RELU:              return execute_relu(prog, instr);
        case OP_SILU:                return execute_silu(prog, instr);
        case OP_CONCAT:                return execute_concat(prog, instr);
        case OP_MAXPOOL:                 return execute_maxpool(prog, instr);
        case OP_AVGPOOL:                   return execute_avgpool(prog, instr);
        case OP_RESHAPE:                     return execute_reshape(prog, instr);
        case OP_TRANSPOSE:                     return execute_transpose(prog, instr);
        case OP_SPLIT:                           return execute_split(prog, instr);
        case OP_SLICE:                             return execute_slice(prog, instr);
        case OP_CAST:                                return execute_cast(prog, instr);
        case OP_FLATTEN:                              return execute_flatten(prog, instr);
        case OP_UNSQUEEZE:                              return execute_unsqueeze(prog, instr);
        case OP_SQUEEZE:                                  return execute_squeeze(prog, instr);
        case OP_TILE:                                       return execute_tile(prog, instr);
        case OP_REDUCEMAX:                                    return execute_reducemax(prog, instr);
        case OP_MATMUL:                                         return execute_matmul(prog, instr);
        case OP_SOFTMAX:                                          return execute_softmax(prog, instr);
        case OP_CONVTRANSPOSE:                                      return execute_convtranspose(prog, instr);
        case OP_RESIZE:                                               return execute_resize(prog, instr);
        case OP_TOPK:                                                   return execute_topk(prog, instr);
        case OP_GATHER:                                                   return execute_gather(prog, instr);
        case OP_GATHERELEMENTS:                                             return execute_gatherelements(prog, instr);
        case OP_MOD:                                                          return execute_mod(prog, instr);
        case OP_EINSUM:                                                         return execute_einsum(prog, instr);
        default:
            fprintf(stderr, "execute_instruction: unimplemented opcode '%s' "
                    "(instruction %d, node '%s')\n",
                    opcode_to_string(instr->op), instr->id, instr->onnx_node_name);
            return -1;
    }
}

int runtime_execute_cb(ir_program_t *prog, runtime_post_instr_cb cb, void *user_data) {
    for (int i = 0; i < prog->num_instructions; i++) {
        ir_instruction_t *instr = &prog->instructions[i];
        if (execute_instruction(prog, instr) != 0) {
            fprintf(stderr, "runtime_execute: instruction %d ('%s') failed\n",
                    instr->id, instr->onnx_node_name);
            return -1;
        }
        /* IMPORTANT: this callback must run now, not after the full program
         * finishes. Because the memory planner reuses freed activation
         * memory (spec section 7), this instruction's output tensor(s) may
         * be overwritten by a later instruction before the program ends. */
        if (cb) cb(prog, instr, user_data);
    }
    return 0;
}

int runtime_execute(ir_program_t *prog) {
    return runtime_execute_cb(prog, NULL, NULL);
}
