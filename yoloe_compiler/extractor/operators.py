"""
Maps ONNX node op_types to accelerator-friendly IR primitives, and extracts
their attributes into a normalized dict.

Per the spec: do NOT silently approximate unsupported operators. If a node's
op_type has no handler here, extraction must fail loudly with the node's
name/inputs/outputs.

This module intentionally supports only the primitive ops actually seen in
real YOLOE-style graphs (Conv/BN-fused conv, elementwise, activation,
reshape/concat/split family, pooling, matmul/softmax for detection heads,
resize for upsampling). Extend `HANDLERS` as new operators are discovered
by running `compile_yoloe.py --inspect-only` against a real model.
"""

from __future__ import annotations

from typing import Any
import onnx
from onnx import numpy_helper


class UnsupportedOperatorError(Exception):
    def __init__(self, node: onnx.NodeProto):
        self.node = node
        msg = (
            f"Unsupported operator: {node.op_type}\n"
            f"Node: {node.name!r}\n"
            f"Inputs: {list(node.input)}\n"
            f"Outputs: {list(node.output)}"
        )
        super().__init__(msg)


def _attr_dict(node: onnx.NodeProto) -> dict[str, Any]:
    """Raw ONNX attributes as a plain python dict, keyed by attribute name."""
    out = {}
    for a in node.attribute:
        out[a.name] = onnx.helper.get_attribute_value(a)
    return out


def _ints(v, default):
    if v is None:
        return list(default)
    return [int(x) for x in v]


# ---- per-op attribute normalizers ------------------------------------------
# Each function takes the raw onnx attribute dict and returns the normalized
# IR attribute dict. Ops with no attributes just return {}.

def _conv_attrs(a: dict) -> dict:
    kernel = _ints(a.get("kernel_shape"), [])
    strides = _ints(a.get("strides"), [1] * max(len(kernel), 2))
    pads = _ints(a.get("pads"), [0] * (2 * max(len(kernel), 2)))
    dilations = _ints(a.get("dilations"), [1] * max(len(kernel), 2))
    group = int(a.get("group", 1))
    return {
        "kernel": kernel,
        "stride": strides,
        "padding": pads,        # ONNX order: [x1_begin, x2_begin, ..., x1_end, x2_end, ...]
        "dilation": dilations,
        "group": group,
    }


def _pool_attrs(a: dict) -> dict:
    kernel = _ints(a.get("kernel_shape"), [])
    strides = _ints(a.get("strides"), [1] * max(len(kernel), 2))
    pads = _ints(a.get("pads"), [0] * (2 * max(len(kernel), 2)))
    ceil_mode = int(a.get("ceil_mode", 0))
    return {"kernel": kernel, "stride": strides, "padding": pads, "ceil_mode": ceil_mode}


def _concat_attrs(a: dict) -> dict:
    return {"axis": int(a.get("axis", 1))}


def _split_attrs(a: dict) -> dict:
    out = {"axis": int(a.get("axis", 0))}
    if "split" in a and a["split"] is not None and len(a["split"]) > 0:
        out["split"] = _ints(a["split"], [])
    return out


def _softmax_attrs(a: dict) -> dict:
    return {"axis": int(a.get("axis", -1))}


def _transpose_attrs(a: dict) -> dict:
    perm = a.get("perm")
    return {"perm": _ints(perm, [])} if perm is not None else {}


def _resize_attrs(a: dict) -> dict:
    return {
        "mode": a.get("mode", b"nearest").decode() if isinstance(a.get("mode"), bytes) else a.get("mode", "nearest"),
        "coordinate_transformation_mode": (
            a.get("coordinate_transformation_mode", b"half_pixel").decode()
            if isinstance(a.get("coordinate_transformation_mode"), bytes)
            else a.get("coordinate_transformation_mode", "half_pixel")
        ),
        "nearest_mode": (
            a.get("nearest_mode", b"round_prefer_floor").decode()
            if isinstance(a.get("nearest_mode"), bytes)
            else a.get("nearest_mode", "round_prefer_floor")
        ),
    }


def _reduce_attrs(a: dict) -> dict:
    out = {"keepdims": int(a.get("keepdims", 1))}
    if "axes" in a and a["axes"] is not None:
        out["axes"] = _ints(a["axes"], [])
    return out


def _leakyrelu_attrs(a: dict) -> dict:
    return {"alpha": float(a.get("alpha", 0.01))}


def _clip_attrs(a: dict) -> dict:
    # Newer opsets pass min/max as inputs, not attributes; handled at extraction time.
    return {}


def _batchnorm_attrs(a: dict) -> dict:
    return {"epsilon": float(a.get("epsilon", 1e-5))}


def _gather_attrs(a: dict) -> dict:
    return {"axis": int(a.get("axis", 0))}


def _flatten_attrs(a: dict) -> dict:
    return {"axis": int(a.get("axis", 1))}


def _gatherelements_attrs(a: dict) -> dict:
    return {"axis": int(a.get("axis", 0))}


def _mod_attrs(a: dict) -> dict:
    return {"fmod": int(a.get("fmod", 0))}


def _einsum_attrs(a: dict) -> dict:
    eq = a.get("equation")
    if isinstance(eq, bytes):
        eq = eq.decode()
    return {"equation": eq}


def _no_attrs(a: dict) -> dict:
    return {}


# op_type -> (IR primitive name, attribute normalizer)
HANDLERS: dict[str, tuple[str, Any]] = {
    "Conv":               ("CONV", _conv_attrs),
    "ConvTranspose":       ("CONVTRANSPOSE", _conv_attrs),
    "BatchNormalization":  ("BATCHNORM", _batchnorm_attrs),
    "Add":                 ("ADD", _no_attrs),
    "Sub":                 ("SUB", _no_attrs),
    "Mul":                 ("MUL", _no_attrs),
    "Div":                 ("DIV", _no_attrs),
    "Pow":                 ("POW", _no_attrs),
    "Sqrt":                ("SQRT", _no_attrs),
    "Sigmoid":             ("SIGMOID", _no_attrs),
    "Relu":                ("RELU", _no_attrs),
    "LeakyRelu":           ("LEAKYRELU", _leakyrelu_attrs),
    "Clip":                ("CLIP", _clip_attrs),
    "Silu":                ("SILU", _no_attrs),        # some exporters emit Silu directly
    "HardSigmoid":         ("HARDSIGMOID", _no_attrs),
    "Concat":              ("CONCAT", _concat_attrs),
    "Split":               ("SPLIT", _split_attrs),
    "Reshape":             ("RESHAPE", _no_attrs),
    "Transpose":           ("TRANSPOSE", _transpose_attrs),
    "Resize":              ("RESIZE", _resize_attrs),
    "Upsample":            ("RESIZE", _resize_attrs),
    "MaxPool":             ("MAXPOOL", _pool_attrs),
    "AveragePool":         ("AVGPOOL", _pool_attrs),
    "GlobalAveragePool":   ("GLOBALAVGPOOL", _no_attrs),
    "MatMul":              ("MATMUL", _no_attrs),
    "Gemm":                ("GEMM", lambda a: {
                                "alpha": float(a.get("alpha", 1.0)),
                                "beta": float(a.get("beta", 1.0)),
                                "transA": int(a.get("transA", 0)),
                                "transB": int(a.get("transB", 0)),
                            }),
    "Softmax":             ("SOFTMAX", _softmax_attrs),
    "Slice":                ("SLICE", _no_attrs),        # opset>=10: starts/ends are inputs
    "Cast":                 ("CAST", lambda a: {"to": int(a.get("to", 1))}),
    "Constant":             ("CONSTANT", _no_attrs),      # folded into a tensor, not executed
    "Shape":                ("SHAPE", _no_attrs),
    "Gather":               ("GATHER", _gather_attrs),
    "Unsqueeze":            ("UNSQUEEZE", _no_attrs),
    "Squeeze":              ("SQUEEZE", _no_attrs),
    "Flatten":              ("FLATTEN", _flatten_attrs),
    "ReduceMax":            ("REDUCEMAX", _reduce_attrs),
    "ReduceSum":            ("REDUCESUM", _reduce_attrs),
    "ReduceMean":           ("REDUCEMEAN", _reduce_attrs),
    "Exp":                  ("EXP", _no_attrs),
    "Tanh":                 ("TANH", _no_attrs),
    "Expand":               ("EXPAND", _no_attrs),
    "Tile":                 ("TILE", _no_attrs),
    "Equal":                ("EQUAL", _no_attrs),
    "Where":                ("WHERE", _no_attrs),
    "TopK":                 ("TOPK", lambda a: {"axis": int(a.get("axis", -1)), "largest": int(a.get("largest", 1))}),
    "NonMaxSuppression":    ("NMS", _no_attrs),
    "Einsum":                ("EINSUM", _einsum_attrs),
    "GatherElements":         ("GATHERELEMENTS", _gatherelements_attrs),
    "Mod":                     ("MOD", _mod_attrs),
}


def map_node(node: onnx.NodeProto) -> tuple[str, dict]:
    """Return (ir_op, attributes) for a node, or raise UnsupportedOperatorError."""
    if node.op_type not in HANDLERS:
        raise UnsupportedOperatorError(node)
    ir_op, normalizer = HANDLERS[node.op_type]
    raw = _attr_dict(node)
    return ir_op, normalizer(raw)
