#ifndef YOLOE_POSTPROCESS_H
#define YOLOE_POSTPROCESS_H

#include "image.h"

#define POSTPROCESS_MAX_MASK_COEFFS 32

typedef struct {
    float x1, y1, x2, y2;   /* canvas (model-input) pixel-space xyxy */
    float conf;
    int class_id;
    float mask_coeffs[POSTPROCESS_MAX_MASK_COEFFS];
} raw_detection_t;

/*
 * Parses the model's output0 tensor ([1, N, 6+num_mask_coeffs], layout
 * [x1,y1,x2,y2,conf,class_id,mask_coeffs...] - confirmed against the actual
 * ONNX graph structure, see runtime/README section on output layout) into
 * an array of raw_detection_t, keeping only entries with conf >= conf_thresh.
 * Returns the number of detections written into `out` (out must have room
 * for at least num_candidates entries).
 */
int parse_detections(const float *output0, int num_candidates, int row_stride,
                      int num_mask_coeffs, float conf_thresh, raw_detection_t *out);

/*
 * Decodes one detection's instance mask at the mask-prototype resolution
 * (mask_protos is [num_mask_coeffs, proto_h, proto_w]), applying sigmoid,
 * and writes a proto_h x proto_w float mask (values in [0,1], caller
 * thresholds at 0.5) into `out_mask` (caller-allocated, proto_h*proto_w floats).
 */
void decode_mask(const raw_detection_t *det, int num_mask_coeffs,
                  const float *mask_protos, int proto_h, int proto_w,
                  float *out_mask);

#endif
