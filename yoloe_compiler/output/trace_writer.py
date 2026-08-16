from __future__ import annotations

from extractor.ir import Instruction, Tensor


def write_execution_trace(instructions: list[Instruction], tensors: dict[str, Tensor], path: str) -> None:
    lines = []
    for instr in instructions:
        lines.append(f"[{instr.id:03d}] {instr.op}   (onnx: {instr.onnx_op_type} '{instr.onnx_node_name}')")
        for role, tid in zip(_input_roles(instr), instr.inputs):
            t = tensors.get(tid)
            shape = t.shape if t else "?"
            off = f" offset={_fmt_off(t)}" if t else ""
            lines.append(f"      {role}: {tid:<12} {shape}{off}")
        for tid in instr.outputs:
            t = tensors.get(tid)
            shape = t.shape if t else "?"
            off = f" offset={_fmt_off(t)}" if t else ""
            lines.append(f"      output: {tid:<12} {shape}{off}")
        if instr.attributes:
            lines.append(f"      attrs: {instr.attributes}")

        # Dead-tensor annotations: any input tensor whose discard_after == this instr
        for tid in instr.inputs:
            t = tensors.get(tid)
            if t and t.discard_after == instr.id:
                lines.append(f"")
                lines.append(f"      {tid}:")
                lines.append(f"          last_use = {t.last_use}")
                lines.append(f"          DEAD AFTER THIS INSTRUCTION")
        lines.append("")

    with open(path, "w") as f:
        f.write("\n".join(lines))


def _fmt_off(t: Tensor) -> str:
    if t.memory_offset is None:
        return "0x??????"
    return f"0x{t.memory_offset:06x}"


def _input_roles(instr: Instruction) -> list[str]:
    """Best-effort human labels for input positions, per op."""
    role_table = {
        "CONV": ["input", "weight", "bias"],
        "CONVTRANSPOSE": ["input", "weight", "bias"],
        "GEMM": ["input", "weight", "bias"],
        "ADD": ["input0", "input1"],
        "SUB": ["input0", "input1"],
        "MUL": ["input0", "input1"],
        "DIV": ["input0", "input1"],
        "BATCHNORM": ["input", "scale", "bias", "mean", "var"],
    }
    roles = role_table.get(instr.op)
    if roles:
        # pad/truncate to actual arg count
        if len(roles) >= len(instr.inputs):
            return roles[: len(instr.inputs)]
        return roles + [f"input{i}" for i in range(len(roles), len(instr.inputs))]
    return [f"input{i}" for i in range(len(instr.inputs))]
