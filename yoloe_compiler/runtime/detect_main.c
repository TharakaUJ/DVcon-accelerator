/*
 * yoloe_detect - end-to-end object detection entirely in C, using the IR
 * compiled by compile_yoloe.py and executed by this project's reference
 * interpreter. No Python involved at inference time.
 *
 * Usage:
 *   yoloe_detect --build build/ --weights build/weights.bin \
 *                --image photo.jpg --output out.png [--conf 0.25]
 *
 * build/ must contain instructions.json + tensors.json (from
 * compile_yoloe.py). weights.bin is the raw native-dtype tensor dump from
 * verification/dump_reference.py (or an equivalent writer - see README).
 */
#include "runtime.h"
#include "image.h"
#include "postprocess.h"
#include "coco_classes.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* A small fixed color palette, cycled by class id, for box/mask drawing. */
static const uint8_t PALETTE[][3] = {
    {230,25,75}, {60,180,75}, {255,225,25}, {0,130,200}, {245,130,48},
    {145,30,180}, {70,240,240}, {240,50,230}, {210,245,60}, {250,190,212},
    {0,128,128}, {220,190,255}, {170,110,40}, {255,250,200}, {128,0,0},
    {170,255,195}, {128,128,0}, {255,215,180}, {0,0,128}, {128,128,128},
};
#define PALETTE_N (sizeof(PALETTE) / sizeof(PALETTE[0]))

static int load_raw_into(ir_tensor_t *t, FILE *f) {
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
                fclose(f); return -1;
            }
        }
    }
    fclose(f);
    return 0;
}

int main(int argc, char **argv) {
    const char *build_dir = NULL, *weights_path = NULL, *image_path = NULL;
    const char *output_path = "detections.png";
    float conf_thresh = 0.25f;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--build") && i + 1 < argc) build_dir = argv[++i];
        else if (!strcmp(argv[i], "--weights") && i + 1 < argc) weights_path = argv[++i];
        else if (!strcmp(argv[i], "--image") && i + 1 < argc) image_path = argv[++i];
        else if (!strcmp(argv[i], "--output") && i + 1 < argc) output_path = argv[++i];
        else if (!strcmp(argv[i], "--conf") && i + 1 < argc) conf_thresh = (float)atof(argv[++i]);
    }
    if (!build_dir || !weights_path || !image_path) {
        fprintf(stderr,
            "Usage: %s --build build/ --weights build/weights.bin --image photo.jpg "
            "[--output out.png] [--conf 0.25]\n", argv[0]);
        return 1;
    }

    char instr_path[1024], tensors_path[1024];
    snprintf(instr_path, sizeof(instr_path), "%s/instructions.json", build_dir);
    snprintf(tensors_path, sizeof(tensors_path), "%s/tensors.json", build_dir);

    /* 1. Load the compiled IR and set up memory */
    ir_program_t prog;
    if (runtime_load(&prog, instr_path, tensors_path) != 0) return 1;
    printf("Loaded IR: %d instructions, %d tensors\n", prog.num_instructions, prog.num_tensors);
    if (runtime_bind_memory(&prog) != 0) return 1;
    if (load_weights(&prog, weights_path) != 0) return 1;

    /* 2. Load and letterbox-preprocess the image straight into the model's
     *    input tensor - no Python, no intermediate files. */
    image_t *img = image_load(image_path);
    if (!img) return 1;
    printf("Loaded image %s (%dx%d)\n", image_path, img->w, img->h);

    ir_tensor_t *input_t = NULL;
    for (int i = 0; i < prog.num_tensors; i++) {
        if (prog.tensors[i].region == REGION_INPUT) { input_t = &prog.tensors[i]; break; }
    }
    if (!input_t) { fprintf(stderr, "No INPUT-region tensor found in the compiled model\n"); return 1; }
    int canvas_size = (int)input_t->shape[2];  /* NCHW: shape[2] == shape[3] == canvas_size */

    letterbox_t lb;
    letterbox_preprocess(img, canvas_size, input_t->data, &lb);
    printf("Preprocessed to %dx%d canvas (scale=%.4f, pad=%d,%d)\n",
           canvas_size, canvas_size, lb.scale, lb.pad_x, lb.pad_y);

    /* 3. Run the compiled instruction stream - this is the entire model
     *    forward pass, executed purely in C. */
    if (runtime_execute(&prog) != 0) {
        fprintf(stderr, "Model execution failed.\n");
        return 1;
    }
    printf("Inference complete.\n");

    /* 4. Locate the model's public outputs by their ONNX names (output0 =
     *    detections, output1 = mask prototypes - see runtime/postprocess.h
     *    for how this layout was determined from the actual graph). */
    ir_tensor_t *det_t = runtime_find_tensor_by_name(&prog, "output0");
    ir_tensor_t *proto_t = runtime_find_tensor_by_name(&prog, "output1");
    if (!det_t) { fprintf(stderr, "Could not find output tensor 'output0'\n"); return 1; }

    int num_candidates = (int)det_t->shape[1];
    int row_stride = (int)det_t->shape[2];
    int num_mask_coeffs = proto_t ? (int)proto_t->shape[1] : 0;
    int proto_h = proto_t ? (int)proto_t->shape[2] : 0;
    int proto_w = proto_t ? (int)proto_t->shape[3] : 0;

    raw_detection_t *dets = (raw_detection_t *)malloc(sizeof(raw_detection_t) * num_candidates);
    int n = parse_detections(det_t->data, num_candidates, row_stride,
                              row_stride - 6, conf_thresh, dets);
    printf("%d detection(s) above conf >= %.2f\n", n, conf_thresh);

    /* 5. Decode masks (if this is a segmentation model) and draw everything
     *    onto the original (non-letterboxed) image. */
    float *full_mask = proto_t ? (float *)malloc(sizeof(float) * proto_h * proto_w) : NULL;
    float *crop_mask = proto_t ? (float *)malloc(sizeof(float) * proto_h * proto_w) : NULL;

    for (int i = 0; i < n; i++) {
        raw_detection_t *d = &dets[i];
        int ox1, oy1, ox2, oy2;
        letterbox_unmap_box(&lb, d->x1, d->y1, d->x2, d->y2, &ox1, &oy1, &ox2, &oy2);

        const char *cname = (d->class_id >= 0 && d->class_id < COCO_NUM_CLASSES)
                             ? COCO_CLASS_NAMES[d->class_id] : "unknown";
        printf("  [%2d] %-16s conf=%.3f  box=(%d,%d)-(%d,%d)\n",
               i, cname, d->conf, ox1, oy1, ox2, oy2);

        const uint8_t *color = PALETTE[d->class_id % PALETTE_N];

        if (proto_t && ox2 > ox1 && oy2 > oy1) {
            decode_mask(d, num_mask_coeffs, proto_t->data, proto_h, proto_w, full_mask);

            /* Crop the proto-resolution mask (stride canvas_size/proto_w)
             * to this box's region before upsampling to the original image -
             * matches standard YOLO-seg mask post-processing. */
            int px1 = (int)(d->x1 * proto_w / canvas_size);
            int py1 = (int)(d->y1 * proto_h / canvas_size);
            int px2 = (int)(d->x2 * proto_w / canvas_size) + 1;
            int py2 = (int)(d->y2 * proto_h / canvas_size) + 1;
            if (px1 < 0) px1 = 0; if (py1 < 0) py1 = 0;
            if (px2 > proto_w) px2 = proto_w; if (py2 > proto_h) py2 = proto_h;
            int pbw = px2 - px1, pbh = py2 - py1;

            if (pbw > 0 && pbh > 0) {
                for (int y = 0; y < pbh; y++)
                    for (int x = 0; x < pbw; x++)
                        crop_mask[y * pbw + x] = full_mask[(py1 + y) * proto_w + (px1 + x)];
                blend_mask(img, ox1, oy1, ox2, oy2, crop_mask, pbw, pbh,
                           color[0], color[1], color[2], 0.45f);
            }
        }

        draw_rect(img, ox1, oy1, ox2, oy2, color[0], color[1], color[2], 2);
    }

    if (image_save_png(img, output_path) != 0) {
        fprintf(stderr, "Failed to write %s\n", output_path);
    } else {
        printf("Wrote %s\n", output_path);
    }

    free(full_mask); free(crop_mask); free(dets);
    image_free(img);
    runtime_free(&prog);
    return 0;
}
