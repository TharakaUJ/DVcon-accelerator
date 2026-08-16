"""
Memory planning pass - kept strictly separate from graph extraction (spec
section 7). Input: tensors with sizes + lifetimes (instruction-id ranges).
Output: memory_offset per tensor, plus a peak-memory report per region.

Algorithm: simple deterministic linear-scan allocator (a la linear-scan
register allocation). Not globally optimal, not fragmentation-aware beyond
first-fit reuse - intentionally simple per spec ("do not optimize
aggressively yet").

Weights/biases/constants/inputs/outputs each get their own region with an
independent, non-reused offset space (they are persistent for the whole run,
or owned by the caller in the case of INPUT/OUTPUT).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from extractor.ir import Tensor, TensorKind, MemoryRegion


@dataclass
class MemoryBlock:
    offset: int
    size: int
    tensor_id: str
    start: int   # instruction id when this tensor's memory becomes live (== producer)
    end: int     # instruction id after which memory may be reused (== discard_after)


@dataclass
class RegionPlan:
    region: str
    base: int
    total_size: int
    blocks: list[MemoryBlock] = field(default_factory=list)


ALIGNMENT = 64  # bytes; FPGA-friendly burst alignment


def _align(x: int, a: int = ALIGNMENT) -> int:
    return ((x + a - 1) // a) * a


def plan_persistent_region(tensors: list[Tensor], region: MemoryRegion, base: int) -> RegionPlan:
    """WEIGHT / CONSTANT / INPUT / OUTPUT: every tensor gets its own permanent slot."""
    offset = base
    blocks = []
    for t in tensors:
        size = _align(t.size_bytes) if t.size_bytes else 0
        blocks.append(MemoryBlock(offset=offset, size=size, tensor_id=t.id, start=-1, end=-1))
        t.memory_offset = offset
        offset += size
    return RegionPlan(region=region.value, base=base, total_size=offset - base, blocks=blocks)


def plan_activation_region(tensors: list[Tensor], base: int) -> RegionPlan:
    """
    Linear-scan lifetime allocator with free-list reuse for ACTIVATION tensors.

    tensors must have producer (start) and discard_after (end) set by the
    liveness pass. Tensors with no consumers (discard_after is None) - e.g.
    tensors that feed straight into a graph output - are treated as live
    until the end of the program so they are never silently reused.
    """
    events = []  # (instr_id, kind, tensor) kind: 0=free(process first), 1=alloc
    max_instr = 0
    for t in tensors:
        if t.producer is None:
            continue
        start = t.producer
        end = t.discard_after if t.discard_after is not None else float("inf")
        max_instr = max(max_instr, start)
        events.append((start, 1, t, end))

    events.sort(key=lambda e: (e[0], -e[1]))  # allocate in producer order

    free_list: list[tuple[int, int]] = []   # list of (offset, size), sorted by offset
    active: dict[str, tuple[int, int, float]] = {}  # tid -> (offset, size, end)
    blocks: list[MemoryBlock] = []
    high_water = base

    def release_expired(current_instr: int):
        # A tensor with discard_after == current_instr is still being READ
        # by current_instr (it's that instruction's last use), so its
        # memory must not be handed to an output PRODUCED by that same
        # instruction - that would let an op like Gather/Transpose/Concat
        # read already-overwritten bytes for any output position that
        # depends on a different input position (safe only for pure
        # elementwise-same-index ops, not safe in general). Release only
        # tensors whose last use was STRICTLY BEFORE this instruction.
        expired = [tid for tid, (off, sz, end) in active.items() if end < current_instr]
        for tid in expired:
            off, sz, end = active.pop(tid)
            free_list.append((off, sz))
        free_list.sort(key=lambda b: b[0])

    for start, _, t, end in events:
        release_expired(start)

        size = _align(t.size_bytes) if t.size_bytes else 0
        # first-fit
        chosen = None
        for i, (off, sz) in enumerate(free_list):
            if sz >= size:
                chosen = i
                break
        if chosen is not None:
            off, sz = free_list.pop(chosen)
            if sz > size:
                free_list.append((off + size, sz - size))
                free_list.sort(key=lambda b: b[0])
            offset = off
        else:
            offset = high_water
            high_water += size

        t.memory_offset = offset
        active[t.id] = (offset, size, end)
        blocks.append(MemoryBlock(offset=offset, size=size, tensor_id=t.id, start=start,
                                    end=(end if end != float("inf") else -1)))

    return RegionPlan(
        region=MemoryRegion.ACTIVATION.value,
        base=base,
        total_size=high_water - base,
        blocks=blocks,
    )


def plan_memory(tensors: dict[str, Tensor], region_bases: dict[str, int] | None = None) -> dict[str, RegionPlan]:
    """
    Top-level entry point. Returns {region_name: RegionPlan}.

    region_bases lets the caller configure where each region starts (spec
    section 8: "Do not assume that all tensors share the same memory pool").
    """
    region_bases = region_bases or {
        MemoryRegion.ACTIVATION.value: 0,
        MemoryRegion.WEIGHT.value: 0,
        MemoryRegion.CONSTANT.value: 0,
        MemoryRegion.INPUT.value: 0,
        MemoryRegion.OUTPUT.value: 0,
    }

    by_region: dict[str, list[Tensor]] = {}
    for t in tensors.values():
        by_region.setdefault(t.memory_region.value, []).append(t)

    plans: dict[str, RegionPlan] = {}

    if MemoryRegion.ACTIVATION.value in by_region:
        acts = sorted(by_region[MemoryRegion.ACTIVATION.value], key=lambda t: (t.producer or 0))
        plans[MemoryRegion.ACTIVATION.value] = plan_activation_region(
            acts, region_bases[MemoryRegion.ACTIVATION.value]
        )

    for region_name in (MemoryRegion.WEIGHT.value, MemoryRegion.CONSTANT.value,
                         MemoryRegion.INPUT.value, MemoryRegion.OUTPUT.value):
        if region_name in by_region:
            items = sorted(by_region[region_name], key=lambda t: t.id)
            plans[region_name] = plan_persistent_region(
                items, MemoryRegion(region_name), region_bases[region_name]
            )

    return plans
