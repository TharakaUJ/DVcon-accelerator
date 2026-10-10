"""Unit tests for analysis/: liveness, memory planner, schedule/overlap validation."""

import pytest

from analysis.graph_validation import (
    MemoryOverlapError, ScheduleError, validate_instruction_order, validate_no_memory_overlap,
)
from analysis.liveness import compute_liveness, find_unused_tensors
from analysis.memory_planner import ALIGNMENT, plan_memory
from extractor.extractor import extract
from extractor.ir import Instruction, MemoryRegion, Tensor, TensorKind


def _t(tid, size=100, kind=TensorKind.ACTIVATION, region=MemoryRegion.ACTIVATION):
    return Tensor(id=tid, name=tid, shape=[size // 4], dtype="float32",
                  size_bytes=size, kind=kind, memory_region=region)


def _chain(n_instr):
    """x -> t0 -> t1 -> ... -> t{n-1}; each instruction reads the previous tensor."""
    tensors = {"x": _t("x", kind=TensorKind.INPUT, region=MemoryRegion.INPUT)}
    instrs, prev = [], "x"
    for i in range(n_instr):
        tid = f"t{i}"
        tensors[tid] = _t(tid)
        instrs.append(Instruction(id=i, op="RELU", inputs=[prev], outputs=[tid]))
        prev = tid
    return instrs, tensors


# ---- liveness -------------------------------------------------------------

def test_liveness_fields():
    instrs, tensors = _chain(3)
    compute_liveness(instrs, tensors)
    t0 = tensors["t0"]
    assert (t0.producer, t0.consumers, t0.first_use, t0.last_use, t0.discard_after) == (0, [1], 1, 1, 1)
    last = tensors["t2"]
    assert last.producer == 2 and last.consumers == [] and last.discard_after is None


def test_liveness_is_idempotent():
    instrs, tensors = _chain(3)
    compute_liveness(instrs, tensors)
    compute_liveness(instrs, tensors)
    assert tensors["t0"].consumers == [1]


def test_find_unused_tensors():
    instrs, tensors = _chain(2)
    compute_liveness(instrs, tensors)
    assert find_unused_tensors(tensors) == ["t1"]  # dangling activation
    tensors["t1"].kind = TensorKind.OUTPUT
    assert find_unused_tensors(tensors) == []


# ---- memory planner -------------------------------------------------------

def test_planner_reuses_dead_memory_and_aligns():
    instrs, tensors = _chain(4)
    compute_liveness(instrs, tensors)
    plans = plan_memory(tensors)
    act = plans["ACTIVATION"]
    for b in act.blocks:
        assert b.offset % ALIGNMENT == 0
    # chain of 4 equal-size tensors only ever needs 2 live slots (t_i + t_{i+1})
    slot = -(-100 // ALIGNMENT) * ALIGNMENT
    assert act.total_size == 2 * slot
    assert tensors["t0"].memory_offset == tensors["t2"].memory_offset
    validate_no_memory_overlap(tensors)


def test_planner_never_aliases_output_with_same_instruction_input():
    # Known-good design decision #2: an input whose last use is instruction i
    # must not be freed in time for instruction i's own output.
    instrs, tensors = _chain(2)
    compute_liveness(instrs, tensors)
    plan_memory(tensors)
    assert tensors["t0"].memory_offset != tensors["t1"].memory_offset


def test_planner_keeps_unconsumed_tensors_alive():
    instrs, tensors = _chain(3)
    tensors["side"] = _t("side")
    instrs[0].outputs.append("side")  # produced at 0, never consumed
    compute_liveness(instrs, tensors)
    plan_memory(tensors)
    validate_no_memory_overlap(tensors)
    others = {tensors[t].memory_offset for t in ("t1", "t2")}
    assert tensors["side"].memory_offset not in others


def test_persistent_regions_are_not_reused():
    tensors = {f"w{i}": _t(f"w{i}", kind=TensorKind.WEIGHT, region=MemoryRegion.WEIGHT) for i in range(3)}
    plans = plan_memory(tensors)
    offsets = sorted(t.memory_offset for t in tensors.values())
    assert len(set(offsets)) == 3
    assert plans["WEIGHT"].total_size == 3 * (-(-100 // ALIGNMENT) * ALIGNMENT)


def test_memory_reduction_on_tiny_model(tiny_model_path):
    r = extract(tiny_model_path)
    compute_liveness(r.instructions, r.tensors)
    plans = plan_memory(r.tensors)
    validate_no_memory_overlap(r.tensors)
    no_reuse = sum(t.size_bytes for t in r.tensors.values() if t.memory_region == MemoryRegion.ACTIVATION)
    assert plans["ACTIVATION"].total_size < no_reuse


# ---- graph_validation ------------------------------------------------------

def test_validate_instruction_order_ok_and_violation():
    instrs, tensors = _chain(3)
    validate_instruction_order(instrs, tensors)
    instrs[0], instrs[1] = instrs[1], instrs[0]
    with pytest.raises(ScheduleError, match="before it has a producer"):
        validate_instruction_order(instrs, tensors)


def test_validate_instruction_order_unknown_tensor():
    instrs, tensors = _chain(1)
    instrs[0].inputs = ["nope"]
    with pytest.raises(ScheduleError, match="unknown tensor"):
        validate_instruction_order(instrs, tensors)


def test_validate_no_memory_overlap_detects_conflict():
    instrs, tensors = _chain(3)
    compute_liveness(instrs, tensors)
    plan_memory(tensors)
    tensors["t1"].memory_offset = tensors["t0"].memory_offset  # both live at instr 1
    with pytest.raises(MemoryOverlapError):
        validate_no_memory_overlap(tensors)
