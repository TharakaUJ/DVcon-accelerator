"""
Tests for the command-line tools, run exactly as documented in README.md:
compile_yoloe.py, verification/dump_reference.py, runtime/yoloe_runtime,
verification/compare.py and runtime/yoloe_detect.
"""

import json
import os
import subprocess
import sys

import numpy as np
import onnx
import pytest
from onnx import TensorProto as TP, helper

from helpers import DETECT_BIN, ROOT, RUNTIME_BIN, init, make_model


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, cwd=ROOT, **kw)


def py(script, *args):
    return run([sys.executable, os.path.join(ROOT, script), *args])


@pytest.fixture(scope="module")
def compiled_tiny(tiny_model_path, tmp_path_factory):
    build = str(tmp_path_factory.mktemp("build"))
    proc = py("compile_yoloe.py", "--model", tiny_model_path, "--output", build)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    return build


def test_inspect_only(tiny_model_path):
    proc = py("compile_yoloe.py", "--model", tiny_model_path, "--inspect-only")
    assert proc.returncode == 0
    assert "All operators have IR handlers" in proc.stdout
    assert "3x  Conv" in proc.stdout


def test_compile_outputs(compiled_tiny):
    for f in ("instructions.json", "tensors.json", "weights.bin", "execution_trace.txt", "graph.dot"):
        assert os.path.getsize(os.path.join(compiled_tiny, f)) > 0, f
    with open(os.path.join(compiled_tiny, "instructions.json")) as f:
        assert len(json.load(f)["instructions"]) == 7
    with open(os.path.join(compiled_tiny, "tensors.json")) as f:
        tensors = json.load(f)["tensors"]
    weight_bytes = sum(t["size_bytes"] for t in tensors if t["kind"] in ("WEIGHT", "BIAS"))
    assert os.path.getsize(os.path.join(compiled_tiny, "weights.bin")) == weight_bytes
    assert all(t["memory_offset"] is not None for t in tensors)


def test_compile_rejects_unsupported_op(tmp_path):
    model = make_model([helper.make_node("NonZero", ["x"], ["y"])],
                       [("x", TP.FLOAT, [4])], [("y", TP.INT64, None)])
    path = str(tmp_path / "bad.onnx")
    onnx.save(model, path)
    proc = py("compile_yoloe.py", "--model", path, "--output", str(tmp_path / "build"))
    assert proc.returncode == 1
    assert "MISSING HANDLER" in proc.stdout and "Aborting" in proc.stdout


def test_documented_verification_flow(tiny_model_path, compiled_tiny, tmp_path, runtime_built):
    ref = str(tmp_path / "reference")
    out = str(tmp_path / "out")
    os.makedirs(out)

    proc = py("verification/dump_reference.py", "--model", tiny_model_path, "--build", compiled_tiny,
              "--output", ref)
    assert proc.returncode == 0, proc.stderr
    with open(os.path.join(compiled_tiny, "weights.bin"), "rb") as a, open(os.path.join(ref, "weights.bin"), "rb") as b:
        assert a.read() == b.read(), "compile-time and reference weights.bin differ"

    proc = run([RUNTIME_BIN, "--instructions", f"{compiled_tiny}/instructions.json",
                "--tensors", f"{compiled_tiny}/tensors.json", "--weights", f"{ref}/weights.bin",
                "--input", f"{ref}/input.bin", "--dump-dir", out])
    assert proc.returncode == 0, proc.stderr
    assert "Execution complete." in proc.stdout

    proc = py("verification/compare.py", "--tensors", f"{compiled_tiny}/tensors.json", "--dump-dir", out,
              "--reference", ref)
    assert proc.returncode == 0, proc.stdout
    assert "Tensor verification: 7 / 7 PASS" in proc.stdout

    # corrupt one dump: compare.py must fail and name the first diverging tensor
    with open(os.path.join(compiled_tiny, "tensors.json")) as f:
        first = min((t for t in json.load(f)["tensors"] if t["producer"] is not None), key=lambda t: t["producer"])
    path = os.path.join(out, first["id"] + ".bin")
    np.full(os.path.getsize(path) // 4, 123.0, np.float32).tofile(path)
    proc = py("verification/compare.py", "--tensors", f"{compiled_tiny}/tensors.json", "--dump-dir", out,
              "--reference", ref)
    assert proc.returncode == 1
    assert f"FIRST DIVERGING TENSOR: {first['id']}" in proc.stdout


def test_runtime_usage_and_bad_paths(runtime_built, tmp_path):
    proc = run([RUNTIME_BIN])
    assert proc.returncode == 1 and "Usage" in proc.stderr
    proc = run([RUNTIME_BIN, "--instructions", str(tmp_path / "nope.json"), "--tensors", str(tmp_path / "nope.json")])
    assert proc.returncode == 1


def _write_ppm(path, h, w):
    rgb = (np.random.default_rng(0).random((h, w, 3)) * 255).astype(np.uint8)
    with open(path, "wb") as f:
        f.write(f"P6\n{w} {h}\n255\n".encode() + rgb.tobytes())


def test_detect_end_to_end_synthetic(tmp_path, runtime_built):
    """yoloe_detect on a detection-only graph whose output0 is fixed rows
    [x1,y1,x2,y2,conf,class_id] (+0 * input, so it depends on the input)."""
    rows = np.array([[[4, 4, 20, 20, 0.9, 5], [2, 2, 8, 8, 0.1, 0]]], np.float32)
    model = make_model(
        [helper.make_node("ReduceMax", ["images"], ["m"], keepdims=1),
         helper.make_node("Reshape", ["m", "shp"], ["m3"]),
         helper.make_node("Mul", ["m3", "zero"], ["z"]),
         helper.make_node("Add", ["z", "rows"], ["output0"])],
        [("images", TP.FLOAT, [1, 3, 32, 32])], [("output0", TP.FLOAT, [1, 2, 6])],
        [init("shp", np.array([1, 1, 1], np.int64)), init("zero", np.float32(0)), init("rows", rows)],
    )
    model_path, build = str(tmp_path / "det.onnx"), str(tmp_path / "build")
    onnx.save(model, model_path)
    assert py("compile_yoloe.py", "--model", model_path, "--output", build).returncode == 0

    image, out_png = str(tmp_path / "img.ppm"), str(tmp_path / "det.png")
    _write_ppm(image, 48, 64)
    proc = run([DETECT_BIN, "--build", build, "--weights", f"{build}/weights.bin", "--image", image,
                "--output", out_png, "--conf", "0.25"])
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "1 detection(s) above conf >= 0.25" in proc.stdout
    assert "bus" in proc.stdout  # COCO class 5
    with open(out_png, "rb") as f:
        assert f.read(8) == b"\x89PNG\r\n\x1a\n"
