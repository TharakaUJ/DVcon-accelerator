"""
Core intermediate representation (IR) data model.

Two entities:
    Instruction  - an executable primitive operation
    Tensor       - data flowing between instructions

These are intentionally simple, serializable, backend-agnostic structures.
No ONNX-specific or hardware-specific logic belongs here.
"""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from enum import Enum
from typing import Any, Optional


class TensorKind(str, Enum):
    INPUT = "INPUT"                # model input (graph.input, not an initializer)
    OUTPUT = "OUTPUT"               # model output (graph.output)
    ACTIVATION = "ACTIVATION"       # intermediate tensor produced by an instruction
    WEIGHT = "WEIGHT"               # initializer used as a weight (e.g. conv kernel)
    BIAS = "BIAS"                   # initializer used as a bias
    CONSTANT = "CONSTANT"           # other initializer / Constant-node output


class MemoryRegion(str, Enum):
    ACTIVATION = "ACTIVATION"
    WEIGHT = "WEIGHT"
    CONSTANT = "CONSTANT"
    INPUT = "INPUT"
    OUTPUT = "OUTPUT"


@dataclass
class Tensor:
    id: str                                    # stable internal id, e.g. "tensor_18"
    name: str                                   # original ONNX tensor name
    shape: list[int]
    dtype: str                                   # "float32", "int64", ...
    layout: str = "NCHW"                        # NCHW / NHWC / LINEAR / ...
    strides: Optional[list[int]] = None
    size_bytes: int = 0
    kind: TensorKind = TensorKind.ACTIVATION

    producer: Optional[int] = None               # instruction id, None for INPUT/WEIGHT/CONSTANT
    consumers: list[int] = field(default_factory=list)

    first_use: Optional[int] = None              # first consumer instruction id
    last_use: Optional[int] = None                # last consumer instruction id
    discard_after: Optional[int] = None           # == last_use; tensor is dead after this instr

    memory_region: MemoryRegion = MemoryRegion.ACTIVATION
    memory_offset: Optional[int] = None

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["kind"] = self.kind.value if isinstance(self.kind, TensorKind) else self.kind
        d["memory_region"] = (
            self.memory_region.value
            if isinstance(self.memory_region, MemoryRegion)
            else self.memory_region
        )
        return d


@dataclass
class Instruction:
    id: int
    op: str                                       # primitive op name, e.g. "CONV", "ADD"
    inputs: list[str]                             # tensor ids, in ONNX input order
    outputs: list[str]                            # tensor ids, in ONNX output order
    attributes: dict[str, Any] = field(default_factory=dict)

    # provenance (preserved for debugging, per spec section 4)
    onnx_node_name: str = ""
    onnx_op_type: str = ""
    onnx_inputs: list[str] = field(default_factory=list)
    onnx_outputs: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def dtype_size_bytes(dtype: str) -> int:
    """Size in bytes of a single element of the given dtype string."""
    table = {
        "float32": 4, "float": 4,
        "float64": 8, "double": 8,
        "float16": 2, "bfloat16": 2,
        "int64": 8, "int32": 4, "int16": 2, "int8": 1,
        "uint64": 8, "uint32": 4, "uint16": 2, "uint8": 1,
        "bool": 1,
    }
    if dtype not in table:
        raise ValueError(f"Unknown dtype for size computation: {dtype}")
    return table[dtype]


def numel(shape: list[int]) -> int:
    n = 1
    for d in shape:
        # dynamic dims (None / -1 / string) are not resolvable here
        if not isinstance(d, int) or d < 0:
            raise ValueError(f"Cannot compute numel of dynamic/unknown shape: {shape}")
        n *= d
    return n


def contiguous_strides(shape: list[int]) -> list[int]:
    """Row-major (C-contiguous) strides, in elements, for the given shape."""
    strides = [1] * len(shape)
    for i in range(len(shape) - 2, -1, -1):
        strides[i] = strides[i + 1] * shape[i + 1]
    return strides
