#!/usr/bin/env python3
"""
Compile an ONNX model into the accelerator IR.

Usage:
    python compile_yoloe.py --model yoloe.onnx --output build/
    python compile_yoloe.py --model yoloe.onnx --inspect-only
"""

from __future__ import annotations

import argparse
import os
import sys
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from extractor.onnx_loader import LoadedModel
from extractor.extractor import extract
from extractor.operators import UnsupportedOperatorError, HANDLERS
from extractor.graph import build_dependency_graph, validate_topological_order
from analysis.liveness import compute_liveness, find_unused_tensors
from analysis.memory_planner import plan_memory
from analysis.graph_validation import validate_instruction_order, validate_no_memory_overlap
from output.json_writer import write_instructions_json, write_tensors_json
from output.trace_writer import write_execution_trace
from output.dot_writer import write_dot
from output.weights_writer import write_weights_bin


def inspect_model(model_path: str) -> dict:
    """Spec section 24: report before writing substantial code."""
    loaded = LoadedModel(model_path)
    summary = loaded.summarize()

    unsupported = sorted(set(summary["unique_ops"]) - set(HANDLERS.keys()))
    summary["unsupported_ops"] = unsupported
    summary["all_ops_supported"] = len(unsupported) == 0
    return summary


def print_inspection(summary: dict) -> None:
    print("=" * 70)
    print("ONNX MODEL INSPECTION")
    print("=" * 70)
    print(f"Nodes:              {summary['num_nodes']}")
    print(f"Initializers:       {summary['num_initializers']}")
    print(f"Dynamic shapes:     {summary['has_dynamic_shapes']}")
    print(f"BatchNorm present:  {summary['has_batchnorm']}")
    print(f"Custom domains:     {summary['custom_domains'] or 'none'}")
    print()
    print("Inputs:")
    for i in summary["inputs"]:
        print(f"    {i['name']:<24} shape={i['shape']} dtype={i['dtype']}")
    print("Outputs:")
    for o in summary["outputs"]:
        print(f"    {o['name']:<24} shape={o['shape']} dtype={o['dtype']}")
    print()
    print(f"Unique ONNX operators ({len(summary['unique_ops'])}):")
    for op in summary["unique_ops"]:
        flag = "" if op in summary.get("unsupported_ops", []) is False else ""
        supported = op not in summary["unsupported_ops"]
        mark = "OK" if supported else "MISSING HANDLER"
        print(f"    {summary['op_counts'][op]:>4}x  {op:<24} [{mark}]")
    print()
    if summary["unsupported_ops"]:
        print(f"UNSUPPORTED (need a handler in extractor/operators.py): {summary['unsupported_ops']}")
    else:
        print("All operators have IR handlers. Ready to extract.")
    print("=" * 70)


def compile_model(model_path: str, output_dir: str) -> None:
    os.makedirs(output_dir, exist_ok=True)

    print("[1/7] Loading + validating ONNX graph: {}".format(model_path))
    try:
        result = extract(model_path, strict_order=True)
    except UnsupportedOperatorError as e:
        print("\nEXTRACTION FAILED\n")
        print(str(e))
        sys.exit(1)

    print(f"      {len(result.instructions)} instructions, {len(result.tensors)} tensors")

    print("[2/7] Computing tensor liveness (producer/consumers/first_use/last_use)")
    compute_liveness(result.instructions, result.tensors)
    unused = find_unused_tensors(result.tensors)
    if unused:
        print(f"      WARNING: {len(unused)} tensor(s) produced but never consumed and not a model output: {unused[:10]}{'...' if len(unused) > 10 else ''}")

    # Safety check: any CONSTANT-kind tensor genuinely consumed at runtime
    # (not folded into an attribute by constant_folding.py) needs its data
    # written somewhere for the C runtime to read - weights_writer.py only
    # covers WEIGHT/BIAS today. None of the models this project has been
    # tested against hit this case (all Constant-node outputs turned out to
    # be shape-only parameters that got folded away), but warn loudly
    # rather than silently leaving such a tensor as zeroed/uninitialized.
    from extractor.ir import TensorKind
    consumed_ids = {tid for instr in result.instructions for tid in instr.inputs}
    unhandled_constants = [
        tid for tid in consumed_ids
        if result.tensors[tid].kind == TensorKind.CONSTANT
    ]
    if unhandled_constants:
        print(f"      WARNING: {len(unhandled_constants)} CONSTANT tensor(s) are real runtime "
              f"data dependencies with no data source in weights.bin: {unhandled_constants}. "
              f"Extend output/weights_writer.py to include CONSTANT-kind tensors before running "
              f"this model in the C runtime, or its values will be zero.")

    print("[3/7] Validating instruction ordering (dependency correctness)")
    validate_instruction_order(result.instructions, result.tensors)
    print("      OK: every instruction's inputs are available when it runs.")

    print("[4/7] Planning memory (linear-scan lifetime allocator, per-region)")
    plans = plan_memory(result.tensors)
    for region, plan in plans.items():
        print(f"      {region:<12} base=0x{plan.base:06x} size={plan.total_size:>10} bytes  ({len(plan.blocks)} tensors)")
    validate_no_memory_overlap(result.tensors)
    print("      OK: no simultaneously-live tensors overlap in memory.")

    print("[5/7] Writing instructions.json / tensors.json")
    write_instructions_json(result.instructions, os.path.join(output_dir, "instructions.json"))
    write_tensors_json(result.tensors, os.path.join(output_dir, "tensors.json"))

    print("[6/7] Writing weights.bin (native dtype, id-sorted)")
    loaded = LoadedModel(model_path)
    n_bytes = write_weights_bin(loaded, result.tensors, os.path.join(output_dir, "weights.bin"))
    print(f"      {n_bytes} bytes")

    print("[7/7] Writing execution_trace.txt / graph.dot")
    write_execution_trace(result.instructions, result.tensors, os.path.join(output_dir, "execution_trace.txt"))
    write_dot(result.instructions, result.tensors, os.path.join(output_dir, "graph.dot"))

    print()
    print(f"Done. Outputs in {output_dir}/")
    print(f"    instructions.json      ({len(result.instructions)} instructions)")
    print(f"    tensors.json            ({len(result.tensors)} tensors)")
    print(f"    weights.bin              ({n_bytes} bytes)")
    print(f"    execution_trace.txt")
    print(f"    graph.dot")


def main():
    ap = argparse.ArgumentParser(description="Compile an ONNX model to the accelerator IR.")
    ap.add_argument("--model", required=True, help="Path to input .onnx file")
    ap.add_argument("--output", default="build/", help="Output directory")
    ap.add_argument("--inspect-only", action="store_true",
                     help="Only run the spec-24 model inspection report; do not extract.")
    args = ap.parse_args()

    if args.inspect_only:
        summary = inspect_model(args.model)
        print_inspection(summary)
        return

    # Always print the inspection first (cheap, and catches unsupported ops early).
    summary = inspect_model(args.model)
    print_inspection(summary)
    print()
    if not summary["all_ops_supported"]:
        print("Aborting: extend extractor/operators.py HANDLERS before compiling this model.")
        sys.exit(1)

    compile_model(args.model, args.output)


if __name__ == "__main__":
    main()
