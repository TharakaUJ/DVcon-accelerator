# YOLOE ONNX Execution-Plan Extractor and C Reference Runtime

Converts a YOLOE ONNX graph into a deterministic IR (instructions.json +
tensors.json), plans memory with a lifetime-reuse allocator, and executes
the IR with a from-scratch C reference interpreter - verified tensor-by-
tensor against ONNXRuntime.

```
ONNX  ->  extraction (Python)  ->  instructions.json + tensors.json
                                          |
                                          v
                                  C reference runtime
                                          |
                                          v
                        verification against onnxruntime (per-tensor)
```

## Layout

```
extractor/       ONNX -> IR. onnx_loader, graph (dependency/topo-sort),
                  operators (op_type -> IR primitive map, 26 ops covered),
                  tensors (shape/dtype/layout/kind), instructions
                  (+ constant_folding.py: resolves shape-only "parameter"
                  tensors like Slice starts/ends into attributes, with an
                  invariance check so it never folds a data-dependent
                  value by mistake), ir.py (Instruction/Tensor dataclasses)

analysis/         liveness.py (producer/consumer/lifetime analysis),
                  memory_planner.py (linear-scan lifetime-reuse allocator,
                  alias-safe - see "Known-good design decisions" below),
                  graph_validation.py (schedule + no-overlap checks)

output/            json_writer, trace_writer (execution_trace.txt),
                    dot_writer (graph.dot for Graphviz)

runtime/            C reference interpreter + end-to-end detection driver.
                       runtime.h/.c    - IR loading, memory binding, dispatch
                       main.c           - yoloe_runtime: generic IR runner /
                                          verification tool (dumps every tensor)
                       detect_main.c     - yoloe_detect: full pure-C object
                                          detection - image in, drawn PNG out,
                                          no Python at inference time
                       image.h/.c         - stb_image-based load/save, letterbox
                                          preprocessing, box/mask drawing
                       postprocess.h/.c    - output0/output1 -> detections +
                                          decoded instance masks
                       coco_classes.h       - 80 COCO class names
                       ops/*.c               - one file per op family
                       thirdparty/            - vendored cJSON + stb_image(_write)
                     Build: cd runtime && make   (builds both binaries)

verification/        dump_reference.py - runs the ONNX model through
                      onnxruntime with every node exposed as an output,
                      dumps per-tensor .npy + weights.bin/input.bin
                      compare.py        - diffs C runtime .bin dumps
                      against the .npy reference, per tensor, reporting
                      max/mean abs error, RMSE, max rel error, and the
                      FIRST diverging tensor

compile_yoloe.py       Top-level CLI: ONNX -> build/{instructions,tensors}.json
                        + execution_trace.txt + graph.dot.
                        `--inspect-only` prints the model summary (op list,
                        shapes, dynamic-shape check) without compiling.

examples/               tiny.onnx (synthetic 7-node test graph) +
                        make_tiny_model.py to regenerate it. Bus.jpg is a
                        real photo (from ultralytics' public assets) used
                        for realistic-input verification runs.
```

## Quick start: pure-C object detection (image in, detections out)

```bash
# 1. Compile the model to IR (Python, one-time per model) - this now also
#    writes weights.bin directly from the ONNX initializers
python3 compile_yoloe.py --model your_model.onnx --output build/

# 2. Build the C binaries (one-time)
cd runtime && make && cd ..

# 3. Run detection - 100% C from here on, no Python involved
./runtime/yoloe_detect \
    --build build/ \
    --weights build/weights.bin \
    --image photo.jpg \
    --output detections.png \
    --conf 0.25
```

`yoloe_detect` loads the JPEG/PNG directly (via stb_image), letterbox-resizes
it into the model's input tensor, runs the full compiled instruction stream,
parses `output0`/`output1` into detections with decoded instance masks
(auto-detected by ONNX tensor name - works for detection-only models too,
where mask decoding is simply skipped), and draws boxes + translucent mask
overlays onto a copy of the original image.

Output tensor layout (`output0`, `[1, 300, 6+num_mask_coeffs]`) was
determined by tracing the actual ONNX graph, not assumed: `[x1,y1,x2,y2]`
in model-input pixel space, `conf`, `class_id`, then per-detection mask
coefficients dotted against `output1`'s prototypes.

## Quick start: tensor-level verification against ONNXRuntime

For validating a newly-compiled model or after modifying a kernel:

```bash
# Inspect a model before compiling (spec step 24)
python3 compile_yoloe.py --model your_model.onnx --inspect-only

# Get ground truth from onnxruntime, plus input.bin in the runtime's
#    raw binary format (weights.bin now comes from the compile step above)
python3 verification/dump_reference.py --model your_model.onnx \
    --build build/ --output reference/
    # optionally: --input some_image.npy (must already be preprocessed to
    # the model's expected NCHW float32 shape/range)

# 5. Run the C interpreter, dumping every intermediate tensor as it's produced
mkdir -p out
./runtime/yoloe_runtime \
    --instructions build/instructions.json \
    --tensors build/tensors.json \
    --weights reference/weights.bin \
    --input reference/input.bin \
    --dump-dir out/

# 6. Compare tensor-by-tensor
python3 verification/compare.py \
    --tensors build/tensors.json --dump-dir out/ --reference reference/
```

## Known-good design decisions (found the hard way - keep these)

1. **Dump tensors as they're produced, not after the program finishes.**
   The memory planner reuses freed activation memory, so a tensor's memory
   may be overwritten by a later instruction before the program ends. The
   runtime's `--dump-dir` streams each tensor to disk immediately after its
   producing instruction runs (`runtime_execute_cb` in runtime.c); dumping
   only at the end silently captures stale/overwritten data.

2. **The memory planner must not let an instruction's output alias memory
   just freed by that same instruction's own input**, unless the op is a
   pure same-index elementwise map. Ops like Gather/Transpose/Concat read
   `input[j]` to write `output[i]` for `j != i`, so releasing an input's
   memory before all of the current instruction's outputs are safely
   written is a use-after-free-style correctness bug (it caused a real
   segfault during development, traced to corrupted int64 indices).
   `analysis/memory_planner.py`'s `release_expired` only frees tensors
   whose `discard_after < current_instruction`, not `<=`.

3. **Elementwise binops (Add/Sub/Mul/Div) must dispatch on tensor dtype.**
   YOLOE's detect head does real int64 arithmetic (e.g. dividing flattened
   anchor indices by the class count). Treating int64 tensor bytes as
   float32 silently produces garbage - `runtime/ops/elementwise.c` checks
   `dtype` and picks an int64 or float32 kernel accordingly.

4. **Not every "parameter-looking" ONNX input is a literal Constant node.**
   Exporters often compute Slice bounds, Tile repeats, etc. via a small
   Shape-derived subgraph rather than a Constant op. `constant_folding.py`
   resolves these at compile time by running the graph twice with two
   different random inputs and only trusting the fold if the value is
   bit-identical both times - this distinguishes genuine shape-only
   constants from data-dependent tensors (like TopK's indices output, which
   must NOT be folded and stays a real runtime tensor dependency).

5. **Weights/constants are not all float32.** Some initializers (e.g.
   Split's split-size list) are int64. `output/weights_writer.py` (the
   compile-time writer) and `verification/dump_reference.py`'s writer copy
   each tensor's native dtype bytes directly rather than assuming float32
   everywhere - and the C loader (`load_weights` in both `main.c` and
   `detect_main.c`) reads by byte count, not `sizeof(float)`-scaled count.

6. **`weights.bin` is a compile-time artifact, not a verification-only
   one.** It's written by `compile_yoloe.py` itself (via
   `output/weights_writer.py`) straight from the ONNX initializers, so
   `yoloe_detect` never needs Python or onnxruntime at inference time -
   `verification/dump_reference.py` also writes a `weights.bin` but only as
   a side effect of generating ground-truth data for `compare.py`.

## Verification status (yoloe-26n-seg, nano)

445 instructions / 734 tensors extracted; memory planner cuts activation
memory from 368.7 MB (no reuse) to ~59 MB. 448-458+/460 intermediate
tensors match ONNXRuntime exactly or within float32 accumulation tolerance,
depending on input. The uploaded model's prompt-embedding initializers were
found to be all-zero (needs re-export with real class prompts to produce
meaningful detections); with those initializers patched to non-degenerate
test values, the full TopK -> Gather -> GatherElements -> Mod -> Einsum
detect-head decode was confirmed correct (299/300 TopK selections exact,
the sole difference traced to a genuine 5-significant-figure score tie at
the top-300 cutoff, not an implementation bug).

## Known gaps / next steps

- C kernels are unoptimized nested loops by design (spec: correctness
  before speed). Tiling/SIMD/threading/quantization are all future work.
- Resize only implements nearest-neighbor (sufficient for this model's
  Upsample-equivalent nodes); bilinear is unimplemented.
- Einsum only supports the exact equation YOLOE uses
  (`bchw,bkc->bkhw`) - fails loudly rather than attempting a generic
  einsum evaluator, since no other equation appears in this model.
- No FPGA backend yet - that's the explicit next phase once this reference
  path is fully trusted (see spec section 22: the instruction stream itself
  should not need to change when the C backend is swapped for an FPGA one).
