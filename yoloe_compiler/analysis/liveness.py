"""
Fills in producer/consumers/first_use/last_use/discard_after on every
Tensor, based on the final Instruction list. This is a pure analysis pass:
it does not mutate instructions and does not know about memory.
"""

from __future__ import annotations

from extractor.ir import Instruction, Tensor, TensorKind


def compute_liveness(instructions: list[Instruction], tensors: dict[str, Tensor]) -> None:
    # Reset any stale state (idempotent).
    for t in tensors.values():
        t.producer = None
        t.consumers = []
        t.first_use = None
        t.last_use = None
        t.discard_after = None

    for instr in instructions:
        for out_id in instr.outputs:
            if out_id not in tensors:
                continue
            tensors[out_id].producer = instr.id
        for in_id in instr.inputs:
            if in_id not in tensors:
                continue
            tensors[in_id].consumers.append(instr.id)

    for t in tensors.values():
        if t.consumers:
            t.first_use = min(t.consumers)
            t.last_use = max(t.consumers)
            t.discard_after = t.last_use
        else:
            t.first_use = None
            t.last_use = None
            # Graph outputs and never-consumed tensors are never "discarded"
            # by the scheduler; they must live until the caller reads them.
            t.discard_after = None


def find_unused_tensors(tensors: dict[str, Tensor]) -> list[str]:
    """Tensors that are neither consumed nor a model output nor a constant/weight."""
    out = []
    for tid, t in tensors.items():
        if t.kind in (TensorKind.WEIGHT, TensorKind.BIAS, TensorKind.CONSTANT):
            continue
        if t.kind == TensorKind.OUTPUT:
            continue
        if not t.consumers:
            out.append(tid)
    return out
