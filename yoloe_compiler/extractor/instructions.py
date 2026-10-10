"""
Constructs the ordered Instruction list from ONNX nodes.

Constant nodes are folded directly into the tensor table (their output
becomes a CONSTANT-kind tensor) rather than emitted as an executable
instruction. Additionally, certain non-Constant-node inputs that are
compile-time-constant "parameters" (Slice starts/ends/axes/steps, Tile
repeats, Unsqueeze axes, Resize scales, TopK's k, Mod's divisor) are folded
into instruction attributes via constant_folding.py, so the C runtime never
has to model them as generic dynamic tensor reads. See constant_folding.py
for the correctness check (invariance across two different random inputs)
that guards this.
"""

from __future__ import annotations

import onnx

from .ir import Instruction
from .operators import map_node, UnsupportedOperatorError


# For each op type, which onnx input POSITIONS (0-indexed) are shape-only
# "parameters" to fold into attributes rather than kept as tensor
# dependencies. Position 0 (the primary data tensor) is never folded.
# Gather / GatherElements are deliberately excluded: in this model their
# index inputs are genuinely data-dependent (derived from TopK on the
# actual detections), so they must remain real runtime tensor deps.
PARAM_INPUT_POSITIONS: dict[str, dict[int, str]] = {
    "Slice":      {1: "starts", 2: "ends", 3: "axes", 4: "steps"},
    "Unsqueeze":  {1: "axes"},
    "Squeeze":    {1: "axes"},
    "Tile":       {1: "repeats"},
    "ReduceMax":  {1: "axes"},
    "ReduceSum":  {1: "axes"},
    "ReduceMean": {1: "axes"},
    "Resize":     {1: "roi", 2: "scales", 3: "sizes"},
    "TopK":       {1: "k"},
    "Mod":        {1: "divisor"},
    "Expand":     {1: "target_shape"},
}


def collect_param_candidate_names(graph: onnx.GraphProto) -> set[str]:
    """All onnx tensor names that PARAM_INPUT_POSITIONS says should be folded,
    across the whole graph. Fed to constant_folding.fold_candidate_tensors."""
    names = set()
    for node in graph.node:
        positions = PARAM_INPUT_POSITIONS.get(node.op_type)
        if not positions:
            continue
        for pos in positions:
            if pos < len(node.input) and node.input[pos]:
                names.add(node.input[pos])
    return names


def _to_py(value) -> object:
    """numpy array -> plain python int/float/list, safe for JSON."""
    arr = value
    if arr.ndim == 0:
        return arr.item()
    return arr.tolist()


def build_instructions(
    graph: onnx.GraphProto,
    node_order: list[int],
    tensor_id_of: dict[str, str],
    folded_params: dict[str, object],
) -> list[Instruction]:
    instructions: list[Instruction] = []
    next_id = 0

    for node_idx in node_order:
        node = graph.node[node_idx]

        if node.op_type == "Constant":
            continue

        ir_op, attrs = map_node(node)

        positions = PARAM_INPUT_POSITIONS.get(node.op_type, {})
        for pos, attr_name in positions.items():
            if pos >= len(node.input) or not node.input[pos]:
                continue
            tname = node.input[pos]
            if tname in folded_params:
                attrs[attr_name] = _to_py(folded_params[tname])
            else:
                raise ValueError(
                    f"Node {node.name!r} ({node.op_type}) input[{pos}]={tname!r} "
                    f"was expected to be a foldable shape-only parameter but no "
                    f"folded value is available. It may be data-dependent - see "
                    f"constant_folding.py."
                )

        skip_positions = set(positions.keys())
        in_ids = [
            tensor_id_of[n]
            for i, n in enumerate(node.input)
            if n != "" and i not in skip_positions
        ]
        out_ids = [tensor_id_of[n] for n in node.output if n != ""]

        instructions.append(
            Instruction(
                id=next_id,
                op=ir_op,
                inputs=in_ids,
                outputs=out_ids,
                attributes=attrs,
                onnx_node_name=node.name,
                onnx_op_type=node.op_type,
                onnx_inputs=list(node.input),
                onnx_outputs=list(node.output),
            )
        )
        next_id += 1

    return instructions
