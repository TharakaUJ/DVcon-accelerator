from __future__ import annotations

from extractor.ir import Instruction, Tensor, TensorKind


_KIND_COLOR = {
    TensorKind.INPUT: "#8ecae6",
    TensorKind.OUTPUT: "#ffb703",
    TensorKind.WEIGHT: "#adb5bd",
    TensorKind.BIAS: "#ced4da",
    TensorKind.CONSTANT: "#e9ecef",
    TensorKind.ACTIVATION: "#ffffff",
}


def write_dot(instructions: list[Instruction], tensors: dict[str, Tensor], path: str) -> None:
    lines = ["digraph IR {", "  rankdir=TB;", "  node [fontname=\"Helvetica\"];"]

    # instruction nodes (box)
    for instr in instructions:
        label = f"{instr.op}\\n[{instr.id}] {instr.onnx_node_name}"
        lines.append(f'  instr_{instr.id} [shape=box, style=filled, fillcolor="#219ebc", '
                      f'fontcolor=white, label="{label}"];')

    # tensor nodes (ellipse), skip weights/bias to keep the graph readable unless small
    shown_tensors = set()
    for instr in instructions:
        for tid in list(instr.inputs) + list(instr.outputs):
            shown_tensors.add(tid)

    for tid in shown_tensors:
        t = tensors.get(tid)
        if t is None:
            continue
        color = _KIND_COLOR.get(t.kind, "#ffffff")
        label = f"{tid}\\n{t.shape}\\n{t.dtype}"
        lines.append(f'  tensor_{tid} [shape=ellipse, style=filled, fillcolor="{color}", '
                      f'label="{label}"];')

    # edges: tensor -> instruction (consumed) and instruction -> tensor (produced)
    for instr in instructions:
        for tid in instr.inputs:
            if tid in shown_tensors:
                lines.append(f'  tensor_{tid} -> instr_{instr.id};')
        for tid in instr.outputs:
            if tid in shown_tensors:
                lines.append(f'  instr_{instr.id} -> tensor_{tid};')

    lines.append("}")
    with open(path, "w") as f:
        f.write("\n".join(lines))
