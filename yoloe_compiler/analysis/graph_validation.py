"""
Independent validation passes over the finished IR (spec section 18 and 21):

1. validate_instruction_order: every instruction's inputs must already have
   a valid producer by the time it runs, unless the input is a model input,
   initializer (weight/bias/constant), or output of an earlier instruction.

2. validate_no_memory_overlap: no two simultaneously-live tensors may be
   assigned overlapping memory ranges within the same region.

3. validate_static_shapes: every tensor an instruction reads or writes has
   a fully resolved shape.
"""

from __future__ import annotations

from extractor.ir import Instruction, Tensor, TensorKind


class ScheduleError(Exception):
    pass


class MemoryOverlapError(Exception):
    pass


class UnresolvedShapeError(Exception):
    pass


def validate_static_shapes(instructions: list[Instruction], tensors: dict[str, Tensor]) -> None:
    """Every tensor the runtime touches needs a fully static shape: an
    unresolved dim would give it size_bytes == 0 and no memory, and the
    runtime would silently skip it."""
    used = {tid for instr in instructions for tid in instr.inputs + instr.outputs}
    bad = [f"{tid} ({tensors[tid].name}): {tensors[tid].shape}" for tid in sorted(used)
           if any(not isinstance(d, int) or d < 0 for d in tensors[tid].shape)]
    if bad:
        raise UnresolvedShapeError(
            f"{len(bad)} tensor(s) have shapes ONNX shape inference could not resolve: "
            f"{bad[:10]}. The model must have static shapes (re-export with a fixed "
            f"input size, or run onnx-simplifier).")


def validate_instruction_order(instructions: list[Instruction], tensors: dict[str, Tensor]) -> None:
    produced: set[str] = set()
    for t in tensors.values():
        if t.kind in (TensorKind.INPUT, TensorKind.WEIGHT, TensorKind.BIAS, TensorKind.CONSTANT):
            produced.add(t.id)

    for instr in instructions:
        for in_id in instr.inputs:
            if in_id not in tensors:
                raise ScheduleError(
                    f"Instruction {instr.id} ({instr.op}, onnx node {instr.onnx_node_name!r}) "
                    f"references unknown tensor id {in_id!r}"
                )
            if in_id not in produced:
                raise ScheduleError(
                    f"Instruction {instr.id} ({instr.op}, onnx node {instr.onnx_node_name!r}) "
                    f"consumes tensor {in_id!r} before it has a producer. "
                    f"Invalid schedule / dependency violation."
                )
        for out_id in instr.outputs:
            produced.add(out_id)


def validate_no_memory_overlap(tensors: dict[str, Tensor]) -> None:
    by_region: dict[str, list[Tensor]] = {}
    for t in tensors.values():
        if t.memory_offset is None:
            continue
        by_region.setdefault(t.memory_region.value, []).append(t)

    for region, items in by_region.items():
        if region != "ACTIVATION":
            continue  # persistent regions never alias by construction
        # Only tensors with a defined lifetime (producer set) participate in reuse checks.
        live = [t for t in items if t.producer is not None]
        for i in range(len(live)):
            a = live[i]
            a_start, a_end = a.producer, (a.discard_after if a.discard_after is not None else float("inf"))
            a0, a1 = a.memory_offset, a.memory_offset + (a.size_bytes or 0)
            for j in range(i + 1, len(live)):
                b = live[j]
                b_start, b_end = b.producer, (b.discard_after if b.discard_after is not None else float("inf"))
                # do lifetimes overlap? Inclusive: a tensor is still being read
                # by its discard_after instruction, so it must not share memory
                # with that instruction's outputs (memory_planner design rule).
                if a_start > b_end or b_start > a_end:
                    continue
                b0, b1 = b.memory_offset, b.memory_offset + (b.size_bytes or 0)
                # do memory ranges overlap?
                if a0 < b1 and b0 < a1:
                    raise MemoryOverlapError(
                        f"Tensors {a.id!r} (live [{a_start},{a_end}], bytes [{a0},{a1})) and "
                        f"{b.id!r} (live [{b_start},{b_end}], bytes [{b0},{b1})) overlap in memory "
                        f"while simultaneously live."
                    )
