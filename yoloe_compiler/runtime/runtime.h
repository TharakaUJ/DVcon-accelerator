#ifndef YOLOE_RUNTIME_H
#define YOLOE_RUNTIME_H

#include <stddef.h>
#include <stdint.h>

#define IR_MAX_INPUTS 8
#define IR_MAX_OUTPUTS 4
#define IR_MAX_DIMS 8
#define IR_MAX_NAME 64

typedef enum {
    OP_UNKNOWN = 0,
    OP_CONV,
    OP_ADD,
    OP_SUB,
    OP_MUL,
    OP_DIV,
    OP_SIGMOID,
    OP_RELU,
    OP_SILU,
    OP_LEAKYRELU,
    OP_CONCAT,
    OP_SPLIT,
    OP_RESHAPE,
    OP_TRANSPOSE,
    OP_RESIZE,
    OP_MAXPOOL,
    OP_AVGPOOL,
    OP_MATMUL,
    OP_GEMM,
    OP_SOFTMAX,
    OP_BATCHNORM,
    OP_SLICE,
    OP_CAST,
    OP_GATHER,
    OP_UNSQUEEZE,
    OP_SQUEEZE,
    OP_FLATTEN,
    OP_REDUCEMAX,
    OP_TILE,
    OP_TOPK,
    OP_CONVTRANSPOSE,
    OP_EINSUM,
    OP_GATHERELEMENTS,
    OP_MOD,
    OP_COUNT
} ir_opcode_t;

typedef enum {
    DT_FLOAT32 = 0,
    DT_INT64,
    DT_INT32,
    DT_BOOL,
} ir_dtype_t;

typedef enum {
    REGION_ACTIVATION = 0,
    REGION_WEIGHT,
    REGION_CONSTANT,
    REGION_INPUT,
    REGION_OUTPUT,
    REGION_COUNT
} mem_region_t;

/* A materialized tensor: shape/dtype metadata plus a pointer into the
 * backend's memory arena (set up by runtime_bind_memory). The IR only
 * ever describes float32 NCHW activations for the initial correctness
 * pass; dtype is kept explicit so this is not hard-coded forever. */
typedef struct {
    char id[IR_MAX_NAME];
    char name[IR_MAX_NAME];
    int ndim;
    int64_t shape[IR_MAX_DIMS];
    int64_t strides[IR_MAX_DIMS];
    size_t size_bytes;
    mem_region_t region;
    ir_dtype_t dtype;
    int64_t memory_offset;   /* offset within its region's arena */
    float *data;              /* resolved float32 view (valid when dtype==DT_FLOAT32) */
    int64_t *idata;            /* resolved int64 view (valid when dtype==DT_INT64) - same
                                 * underlying bytes as `data`, reinterpreted */
} ir_tensor_t;

typedef struct {
    char key[32];
    /* attribute values are stored as a small fixed union covering what the
     * ops we implement actually need; extend as new ops are added. */
    int int_vals[8];
    int int_count;
} ir_attr_t;

typedef struct {
    int id;
    ir_opcode_t op;
    char onnx_node_name[IR_MAX_NAME];

    char inputs[IR_MAX_INPUTS][IR_MAX_NAME];
    int num_inputs;

    char outputs[IR_MAX_OUTPUTS][IR_MAX_NAME];
    int num_outputs;

    /* normalized attributes actually needed by kernels; parsed from JSON
     * per-opcode in runtime.c (avoids a generic dynamic-attribute system
     * for this first correctness pass). */
    int64_t kernel[2];
    int64_t stride[2];
    int64_t padding[4];
    int64_t dilation[2];
    int64_t group;
    int64_t axis;
    double alpha;
    int64_t ceil_mode;

    /* Slice: folded starts/ends/axes/steps (spec: resolved at compile time
     * since this model has static shapes; see extractor/constant_folding.py) */
    int64_t slice_starts[IR_MAX_DIMS], slice_ends[IR_MAX_DIMS];
    int64_t slice_axes[IR_MAX_DIMS], slice_steps[IR_MAX_DIMS];
    int slice_n;

    /* Reduce* (axes) / Unsqueeze (axes) / Tile (repeats) - folded params */
    int64_t reduce_axes[IR_MAX_DIMS]; int reduce_n; int64_t keepdims;
    int64_t unsqueeze_axes[IR_MAX_DIMS]; int unsqueeze_n;
    int64_t tile_repeats[IR_MAX_DIMS]; int tile_n;

    int64_t topk_k;
    int64_t mod_divisor;
    int64_t cast_to;          /* ONNX TensorProto.DataType value */

    /* Resize: exactly one of these is populated (folded from scales or sizes input) */
    double resize_scales[IR_MAX_DIMS];
    int64_t resize_sizes[IR_MAX_DIMS];
    int resize_has_sizes;
    char resize_mode[16];
    char resize_nearest_mode[24];
    char resize_coordinate_transformation_mode[24];

    char einsum_equation[32];

    int64_t perm[IR_MAX_DIMS]; int perm_n;
    int64_t gather_axis;
} ir_instruction_t;

typedef struct {
    ir_instruction_t *instructions;
    int num_instructions;

    ir_tensor_t *tensors;
    int num_tensors;

    /* memory arenas, one per region */
    uint8_t *arena[REGION_COUNT];
    size_t arena_size[REGION_COUNT];
} ir_program_t;

/* Load instructions.json + tensors.json into prog. Does not bind memory
 * or load weight data - call runtime_bind_memory and then load weights
 * separately (see runtime_load_weights in main.c). */
int runtime_load(ir_program_t *prog, const char *instructions_path, const char *tensors_path);

/* Find a tensor by its IR id string ("tensor_18", "weight_3", ...). */
ir_tensor_t *runtime_find_tensor(ir_program_t *prog, const char *id);

/* Find a tensor by its ORIGINAL ONNX name (e.g. "output0", "images") -
 * useful for driver code that only knows the model's public input/output
 * names, not the compiler's internal tensor ids. */
ir_tensor_t *runtime_find_tensor_by_name(ir_program_t *prog, const char *onnx_name);

/* Allocate arenas from tensors' memory_offset/size_bytes and point every
 * tensor's `data` field into the right arena. Call once after loading. */
int runtime_bind_memory(ir_program_t *prog);

void runtime_free(ir_program_t *prog);

/* Callback invoked immediately after an instruction's outputs are computed,
 * before any later instruction can reuse their memory. Used by verification
 * tooling to dump ground-truth intermediate values; NULL disables dumping.
 * This is the only correct place to snapshot activation tensors, since the
 * memory planner aggressively reuses freed activation memory. */
typedef void (*runtime_post_instr_cb)(ir_program_t *prog, ir_instruction_t *instr, void *user_data);

/* Execute the full instruction stream in order, calling cb (if non-NULL)
 * after each instruction. */
int runtime_execute_cb(ir_program_t *prog, runtime_post_instr_cb cb, void *user_data);

/* Convenience wrapper: execute with no callback. */
int runtime_execute(ir_program_t *prog);

/* Execute a single instruction (dispatches by opcode). */
int execute_instruction(ir_program_t *prog, ir_instruction_t *instr);

ir_opcode_t opcode_from_string(const char *s);
const char *opcode_to_string(ir_opcode_t op);

#endif /* YOLOE_RUNTIME_H */
