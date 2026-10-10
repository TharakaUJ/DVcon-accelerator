#!/usr/bin/env python3
"""
Compares the C runtime's per-tensor .bin dumps (raw float32, from
runtime/main.c --dump-dir) against the ONNX reference .npy dumps (from
verification/dump_reference.py), tensor by tensor, in IR instruction order.

Reports max_abs_error / mean_abs_error / rmse / max_rel_error per tensor,
and stops at (clearly flags) the FIRST tensor where results diverge beyond
tolerance so debugging can start there (spec section 12).
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np


def load_c_tensor(dump_dir: str, tensor_id: str, shape: list[int], dtype: str = "float32") -> np.ndarray | None:
    path = os.path.join(dump_dir, f"{tensor_id}.bin")
    if not os.path.exists(path):
        return None
    np_dtype = np.int64 if dtype == "int64" else np.float32
    arr = np.fromfile(path, dtype=np_dtype)
    return arr.reshape(shape)


def load_ref_tensor(ref_dir: str, onnx_name: str) -> np.ndarray | None:
    safe = onnx_name.replace("/", "_")
    path = os.path.join(ref_dir, f"{safe}.npy")
    if not os.path.exists(path):
        return None
    return np.load(path)


def compare_tensor(c_arr: np.ndarray, ref_arr: np.ndarray) -> dict:
    if c_arr.shape != ref_arr.shape:
        return {"shape_mismatch": True, "c_shape": c_arr.shape, "ref_shape": ref_arr.shape}
    diff = np.abs(c_arr.astype(np.float64) - ref_arr.astype(np.float64))
    max_abs = float(diff.max()) if diff.size else 0.0
    mean_abs = float(diff.mean()) if diff.size else 0.0
    rmse = float(np.sqrt((diff ** 2).mean())) if diff.size else 0.0
    denom = np.abs(ref_arr.astype(np.float64))
    denom = np.where(denom < 1e-8, 1e-8, denom)
    max_rel = float((diff / denom).max()) if diff.size else 0.0
    return {
        "shape_mismatch": False,
        "max_abs_error": max_abs,
        "mean_abs_error": mean_abs,
        "rmse": rmse,
        "max_rel_error": max_rel,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tensors", required=True, help="build/tensors.json")
    ap.add_argument("--dump-dir", required=True, help="C runtime --dump-dir output")
    ap.add_argument("--reference", required=True, help="verification/dump_reference.py output dir")
    ap.add_argument("--abs-tol", type=float, default=1e-3)
    ap.add_argument("--rel-tol", type=float, default=1e-2)
    args = ap.parse_args()

    with open(args.tensors) as f:
        tdata = json.load(f)["tensors"]

    # sort by producer instruction id (execution order); tensors with no
    # producer (weights/inputs) are skipped, verification is about activations.
    activations = [t for t in tdata if t["producer"] is not None]
    activations.sort(key=lambda t: t["producer"])

    print("=" * 70)
    print("YOLOE C Runtime Verification")
    print("=" * 70)

    n_pass = 0
    n_checked = 0
    first_failure = None
    max_seen_error = 0.0

    for t in activations:
        c_arr = load_c_tensor(args.dump_dir, t["id"], t["shape"], t.get("dtype", "float32"))
        ref_arr = load_ref_tensor(args.reference, t["name"])
        if c_arr is None or ref_arr is None:
            continue  # not dumped on one side; skip (e.g. runtime only dumps ACTIVATION+OUTPUT)

        n_checked += 1
        result = compare_tensor(c_arr, ref_arr)

        print(f"\nTensor {t['id']} ({t['name']})")
        print(f"    shape: {t['shape']}")

        if result["shape_mismatch"]:
            print(f"    SHAPE MISMATCH: c={result['c_shape']} ref={result['ref_shape']}")
            if first_failure is None:
                first_failure = t["id"]
            continue

        max_seen_error = max(max_seen_error, result["max_abs_error"])
        ok = result["max_abs_error"] <= args.abs_tol or result["max_rel_error"] <= args.rel_tol
        print(f"    max_abs_error: {result['max_abs_error']:.3e}")
        print(f"    mean_abs_error: {result['mean_abs_error']:.3e}")
        print(f"    rmse:          {result['rmse']:.3e}")
        print(f"    max_rel_error: {result['max_rel_error']:.3e}")
        print(f"    {'PASS' if ok else 'FAIL'}")

        if ok:
            n_pass += 1
        elif first_failure is None:
            first_failure = t["id"]

    print()
    print("=" * 70)
    print(f"Tensor verification: {n_pass} / {n_checked} PASS")
    print(f"Maximum tensor error: {max_seen_error:.3e}")
    if first_failure:
        print(f"FIRST DIVERGING TENSOR: {first_failure}")
    print("=" * 70)

    sys.exit(0 if n_pass == n_checked and n_checked > 0 else 1)


if __name__ == "__main__":
    main()
