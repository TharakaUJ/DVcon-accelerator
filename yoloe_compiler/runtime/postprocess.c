#include "postprocess.h"
#include <math.h>
#include <string.h>

int parse_detections(const float *output0, int num_candidates, int row_stride,
                      int num_mask_coeffs, float conf_thresh, raw_detection_t *out) {
    int n = 0;
    for (int i = 0; i < num_candidates; i++) {
        const float *row = output0 + (size_t)i * row_stride;
        float conf = row[4];
        if (conf < conf_thresh) continue;

        raw_detection_t *d = &out[n++];
        d->x1 = row[0]; d->y1 = row[1]; d->x2 = row[2]; d->y2 = row[3];
        d->conf = conf;
        d->class_id = (int)(row[5] + 0.5f);
        int nc = num_mask_coeffs < POSTPROCESS_MAX_MASK_COEFFS ? num_mask_coeffs : POSTPROCESS_MAX_MASK_COEFFS;
        memcpy(d->mask_coeffs, row + 6, sizeof(float) * nc);
    }
    return n;
}

void decode_mask(const raw_detection_t *det, int num_mask_coeffs,
                  const float *mask_protos, int proto_h, int proto_w,
                  float *out_mask) {
    int64_t plane = (int64_t)proto_h * proto_w;
    for (int64_t p = 0; p < plane; p++) {
        double acc = 0.0;
        for (int k = 0; k < num_mask_coeffs; k++) {
            acc += (double)det->mask_coeffs[k] * (double)mask_protos[k * plane + p];
        }
        out_mask[p] = 1.0f / (1.0f + expf((float)(-acc)));
    }
}
