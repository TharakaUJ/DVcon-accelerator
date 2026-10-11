"""
Shared helpers for the test suite: build small ONNX graphs, compile them to
the IR, run them through the C reference runtime, and compare every produced
tensor against onnxruntime.
"""

from __future__ import annotations

import json
import os
import subprocess
from dataclasses import dataclass

import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, numpy_helper

from compile_yoloe import compile_model
from verification.compare import compare_tensor, load_c_tensor
from verification.dump_reference import make_all_outputs_model

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNTIME_DIR = os.path.join(ROOT, "runtime")
RUNTIME_BIN = os.path.join(RUNTIME_DIR, "yoloe_runtime")
DETECT_BIN = os.path.join(RUNTIME_DIR, "yoloe_detect")

OPSET = 17


def init(name: str, arr) -> onnx.TensorProto:
    return numpy_helper.from_array(np.asarray(arr), name=name)


def make_model(nodes, inputs, outputs, initializers=(), opset: int = OPSET) -> onnx.ModelProto:
    """inputs/outputs: list of (name, elem_type, shape) tuples (shape may be None)."""
    graph = helper.make_graph(
        nodes,
        "test_graph",
        [helper.make_tensor_value_info(n, t, s) for n, t, s in inputs],
        [helper.make_tensor_value_info(n, t, s) for n, t, s in outputs],
        initializer=list(initializers),
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", opset)])
    model.ir_version = 8
    # fills output shapes left as None (data_prop: shapes computed via Shape/Gather)
    model = onnx.shape_inference.infer_shapes(model, strict_mode=True, data_prop=True)
    onnx.checker.check_model(model)
    return model


@dataclass
class E2EResult:
    build_dir: str
    instructions: list
    tensors: list
    errors: dict          # tensor name -> compare_tensor() result
    stdout: str


def run_e2e(model: onnx.ModelProto, tmp_path, x: np.ndarray | None = None, seed: int = 0) -> E2EResult:
    """Compile `model`, run it in the C runtime and in onnxruntime, and compare
    every tensor the C runtime produced. Raises AssertionError if the C
    runtime fails to execute."""
    model_path = os.path.join(tmp_path, "model.onnx")
    build_dir = os.path.join(tmp_path, "build")
    dump_dir = os.path.join(tmp_path, "dump")
    os.makedirs(dump_dir, exist_ok=True)
    onnx.save(model, model_path)

    compile_model(model_path, build_dir)

    with open(os.path.join(build_dir, "instructions.json")) as f:
        instructions = json.load(f)["instructions"]
    with open(os.path.join(build_dir, "tensors.json")) as f:
        tensors = json.load(f)["tensors"]

    graph_inputs = [t for t in tensors if t["kind"] == "INPUT"]
    assert len(graph_inputs) == 1, "test helper supports single-input graphs only"
    in_t = graph_inputs[0]
    if x is None:
        x = np.random.default_rng(seed).standard_normal(in_t["shape"]).astype(np.float32)
    input_bin = os.path.join(tmp_path, "input.bin")
    x.tofile(input_bin)

    proc = subprocess.run(
        [RUNTIME_BIN,
         "--instructions", os.path.join(build_dir, "instructions.json"),
         "--tensors", os.path.join(build_dir, "tensors.json"),
         "--weights", os.path.join(build_dir, "weights.bin"),
         "--input", input_bin,
         "--dump-dir", dump_dir],
        capture_output=True, text=True,
    )
    assert proc.returncode == 0, f"C runtime failed:\n{proc.stdout}\n{proc.stderr}"

    ref_model = make_all_outputs_model(model_path)
    sess = ort.InferenceSession(ref_model.SerializeToString(), providers=["CPUExecutionProvider"])
    names = [o.name for o in sess.get_outputs()]
    ref = dict(zip(names, sess.run(names, {in_t["name"]: x})))

    errors = {}
    for t in tensors:
        if t["producer"] is None:
            continue
        c_arr = load_c_tensor(dump_dir, t["id"], t["shape"], t["dtype"])
        assert c_arr is not None, f"C runtime did not dump {t['id']} ({t['name']})"
        errors[t["name"]] = compare_tensor(c_arr, ref[t["name"]])

    return E2EResult(build_dir, instructions, tensors, errors, proc.stdout)


def assert_matches(result: E2EResult, abs_tol: float = 1e-4, rel_tol: float = 1e-3) -> None:
    assert result.errors, "no tensors were compared"
    for name, err in result.errors.items():
        assert not err["shape_mismatch"], f"{name}: shape mismatch {err}"
        ok = err["max_abs_error"] <= abs_tol or err["max_rel_error"] <= rel_tol
        assert ok, f"{name}: max_abs={err['max_abs_error']:.3e} max_rel={err['max_rel_error']:.3e}"
