from __future__ import annotations

import json
from extractor.ir import Instruction, Tensor


def write_instructions_json(instructions: list[Instruction], path: str) -> None:
    data = {"instructions": [i.to_dict() for i in instructions]}
    with open(path, "w") as f:
        json.dump(data, f, indent=2)


def write_tensors_json(tensors: dict[str, Tensor], path: str) -> None:
    # stable order: input_*, weight_*, tensor_*, output_* by numeric suffix where possible
    def sort_key(tid: str):
        return tid
    ordered = [tensors[tid].to_dict() for tid in sorted(tensors.keys(), key=sort_key)]
    data = {"tensors": ordered}
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
