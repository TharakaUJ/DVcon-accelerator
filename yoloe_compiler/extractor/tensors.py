"""
Constructs the full Tensor table for the IR: one Tensor record per unique
ONNX tensor name that participates in the graph (inputs, outputs, weights,
biases, constants, activations).

Producer/consumer instruction ids and lifetime fields (first_use, last_use,
discard_after) are filled in a second pass once instruction ids are known
(see extractor.py / analysis/liveness.py).
"""

from __future__ import annotations

import onnx
from onnx import numpy_helper

from .ir import Tensor, TensorKind, MemoryRegion, dtype_size_bytes, numel, contiguous_strides
from .graph import DependencyGraph
from .onnx_loader import LoadedModel


def _guess_layout(shape: list, name: str, is_weight: bool) -> str:
    if is_weight and len(shape) == 4:
        return "OIHW"     # ONNX conv weight layout: [out_ch, in_ch/group, kh, kw]
    if len(shape) == 4:
        return "NCHW"      # ONNX activations are NCHW by convention
    return "LINEAR"


def _classify_kind(name: str, dg: DependencyGraph, is_bias_of_conv: set) -> TensorKind:
    if name in dg.graph_outputs:
        return TensorKind.OUTPUT
    if name in dg.graph_inputs:
        return TensorKind.INPUT
    if name in dg.initializers:
        return TensorKind.BIAS if name in is_bias_of_conv else TensorKind.WEIGHT
    return TensorKind.ACTIVATION


def build_tensor_table(
    loaded: LoadedModel,
    dg: DependencyGraph,
    tensor_id_of: dict[str, str],
) -> dict[str, Tensor]:
    """
    tensor_id_of: mapping from ONNX tensor name -> stable IR tensor id
                  (e.g. "input_0", "weight_17", "tensor_18"), built by extractor.py.
    Returns: dict of IR tensor id -> Tensor
    """
    graph = loaded.graph

    # Heuristic: 2nd input of Conv/ConvTranspose/Gemm is weight, 3rd is bias.
    bias_names = set()
    for node in graph.node:
        if node.op_type in ("Conv", "ConvTranspose", "Gemm") and len(node.input) >= 3:
            bias_names.add(node.input[2])

    all_names = set(tensor_id_of.keys())
    tensors: dict[str, Tensor] = {}

    for name in all_names:
        tid = tensor_id_of[name]
        shape, dtype = loaded.get_shape_dtype(name)
        is_weight_like = name in dg.initializers

        if shape is None or dtype is None or "unknown" == dtype:
            # Not resolvable via shape inference; leave as unresolved, extraction
            # will raise later if this tensor is actually needed. This is common
            # for e.g. Shape/Gather int scalars that only exist implicitly.
            shape = shape or []
            dtype = dtype or "float32"

        has_dynamic = any((not isinstance(d, int)) or d < 0 for d in shape)

        size_bytes = 0
        if not has_dynamic and shape:
            try:
                size_bytes = numel(shape) * dtype_size_bytes(dtype)
            except ValueError:
                size_bytes = 0
        elif not shape:
            # scalar
            try:
                size_bytes = dtype_size_bytes(dtype)
            except ValueError:
                size_bytes = 0

        kind = _classify_kind(name, dg, bias_names)
        layout = _guess_layout(shape, name, is_weight_like)
        strides = contiguous_strides(shape) if (shape and not has_dynamic) else None

        region = {
            TensorKind.INPUT: MemoryRegion.INPUT,
            TensorKind.OUTPUT: MemoryRegion.OUTPUT,
            TensorKind.WEIGHT: MemoryRegion.WEIGHT,
            TensorKind.BIAS: MemoryRegion.WEIGHT,
            TensorKind.CONSTANT: MemoryRegion.CONSTANT,
            TensorKind.ACTIVATION: MemoryRegion.ACTIVATION,
        }[kind]

        tensors[tid] = Tensor(
            id=tid,
            name=name,
            shape=list(shape),
            dtype=dtype,
            layout=layout,
            strides=strides,
            size_bytes=size_bytes,
            kind=kind,
            memory_region=region,
        )

    return tensors
