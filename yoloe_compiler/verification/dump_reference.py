#!/usr/bin/env python3
"""
Runs the original ONNX model (via onnxruntime) and dumps:
  - every intermediate tensor as reference/<tensor_name>.npy   (spec section 13)
  - weights.bin: raw float32 concatenation of every WEIGHT/BIAS tensor,
    ID-sorted exactly like tensors.json (so runtime/main.c can mmap them in)
  - input.bin: raw float32 dump of the model input, in the same order
  - a name_map.json so the C-side tensor ids can be matched back to .npy files

Usage:
    python verification/dump_reference.py --model yoloe.onnx \
        --build build/ --input image.npy --output reference/
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np
import onnx
import onnxruntime as ort

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from extractor.onnx_loader import LoadedModel


def make_all_outputs_model(model_path: str) -> onnx.ModelProto:
    """Add every node output as a graph output so ORT will return it.
    Uses the real dtype from shape inference (many detect-head tensors are
    int64 - TopK indices, Cast targets, etc.) rather than UNDEFINED, since
    this onnxruntime build rejects UNDEFINED graph outputs outright."""
    from extractor.onnx_loader import LoadedModel, ONNX_ELEM_TYPE_TO_STR

    loaded = LoadedModel(model_path)
    model = loaded.model
    existing = {o.name for o in model.graph.output}

    str_to_elem = {v: k for k, v in ONNX_ELEM_TYPE_TO_STR.items()}

    for node in model.graph.node:
        for out in node.output:
            if not out or out in existing:
                continue
            shape, dtype = loaded.get_shape_dtype(out)
            elem_type = str_to_elem.get(dtype, onnx.TensorProto.FLOAT)
            model.graph.output.append(onnx.helper.make_tensor_value_info(out, elem_type, None))
            existing.add(out)
    return model


def dump_reference(model_path: str, build_dir: str, input_path: str | None, output_dir: str):
    os.makedirs(output_dir, exist_ok=True)

    loaded = LoadedModel(model_path)

    # 1. Build an input if none was supplied (random, deterministic seed).
    input_vi = [i for i in loaded.graph.input if i.name not in loaded.initializers][0]
    shape, dtype = loaded.get_shape_dtype(input_vi.name)
    shape = [d if isinstance(d, int) and d > 0 else 1 for d in shape]
    if input_path:
        x = np.load(input_path).astype(np.float32)
    else:
        rng = np.random.default_rng(0)
        x = rng.standard_normal(shape).astype(np.float32)
        print(f"No --input given; using random input with shape {shape}")

    # 2. Run with every node output exposed.
    all_out_model = make_all_outputs_model(model_path)
    tmp_path = os.path.join(output_dir, "_all_outputs.onnx")
    onnx.save(all_out_model, tmp_path)

    sess = ort.InferenceSession(tmp_path, providers=["CPUExecutionProvider"])
    input_name = sess.get_inputs()[0].name
    output_names = [o.name for o in sess.get_outputs()]
    results = sess.run(output_names, {input_name: x})

    for name, arr in zip(output_names, results):
        safe_name = name.replace("/", "_")
        np.save(os.path.join(output_dir, f"{safe_name}.npy"), arr)

    np.save(os.path.join(output_dir, "_model_input.npy"), x)
    print(f"Dumped {len(output_names)} intermediate/output tensors to {output_dir}/")

    # 3. tensor_id -> onnx name map (from build/tensors.json, if present)
    tensors_json_path = os.path.join(build_dir, "tensors.json")
    id_to_name = {}
    if os.path.exists(tensors_json_path):
        with open(tensors_json_path) as f:
            tdata = json.load(f)
        id_to_name = {t["id"]: t["name"] for t in tdata["tensors"]}
        with open(os.path.join(output_dir, "id_to_onnx_name.json"), "w") as f:
            json.dump(id_to_name, f, indent=2)

        # 4. weights.bin - raw bytes in each tensor's native dtype, ID-sorted
        #    WEIGHT/BIAS tensors, matching main.c's load order (which
        #    iterates tensors in the same id-sorted order). Do NOT force
        #    everything to float32 - some YOLOE initializers (e.g. Split's
        #    split-size tensor) are int64.
        weight_bytes = bytearray()
        for tid in sorted(id_to_name.keys()):
            t = next(t for t in tdata["tensors"] if t["id"] == tid)
            if t["kind"] in ("WEIGHT", "BIAS"):
                arr = loaded.get_initializer_array(t["name"])  # native dtype, no cast
                weight_bytes += arr.tobytes()
        with open(os.path.join(output_dir, "weights.bin"), "wb") as f:
            f.write(weight_bytes)
        print(f"Wrote weights.bin ({len(weight_bytes)} bytes)")

    with open(os.path.join(output_dir, "input.bin"), "wb") as f:
        f.write(x.astype(np.float32).tobytes())
    print(f"Wrote input.bin ({x.nbytes} bytes, shape={list(x.shape)})")

    os.remove(tmp_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--build", default="build/", help="dir containing tensors.json (for id mapping)")
    ap.add_argument("--input", default=None, help="optional .npy input; random if omitted")
    ap.add_argument("--output", default="reference/")
    args = ap.parse_args()
    dump_reference(args.model, args.build, args.input, args.output)


if __name__ == "__main__":
    main()
