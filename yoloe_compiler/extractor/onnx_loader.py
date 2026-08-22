"""
Loads an ONNX model and runs shape inference so every intermediate
tensor has a known shape/dtype before IR extraction begins.
"""

from __future__ import annotations

import onnx
from onnx import shape_inference, numpy_helper


ONNX_ELEM_TYPE_TO_STR = {
    onnx.TensorProto.FLOAT: "float32",
    onnx.TensorProto.FLOAT16: "float16",
    onnx.TensorProto.DOUBLE: "float64",
    onnx.TensorProto.INT64: "int64",
    onnx.TensorProto.INT32: "int32",
    onnx.TensorProto.INT16: "int16",
    onnx.TensorProto.INT8: "int8",
    onnx.TensorProto.UINT8: "uint8",
    onnx.TensorProto.BOOL: "bool",
}


class LoadedModel:
    def __init__(self, path: str):
        self.path = path
        model = onnx.load(path)
        try:
            model = shape_inference.infer_shapes(model, strict_mode=False)
        except Exception as e:  # shape inference can fail on some graphs; keep going
            print(f"[onnx_loader] WARNING: shape_inference.infer_shapes failed: {e}")
        onnx.checker.check_model(model, full_check=False)
        self.model = model
        self.graph = model.graph

        # name -> initializer TensorProto (weights/biases/constants)
        self.initializers = {init.name: init for init in self.graph.initializer}

        # name -> onnx.ValueInfoProto for every tensor whose type/shape we know
        # (graph.input, graph.output, and graph.value_info from shape inference)
        self.value_info: dict[str, onnx.ValueInfoProto] = {}
        for vi in list(self.graph.input) + list(self.graph.output) + list(self.graph.value_info):
            self.value_info[vi.name] = vi

    # ---- introspection helpers -------------------------------------------------

    def summarize(self) -> dict:
        op_counts: dict[str, int] = {}
        for node in self.graph.node:
            op_counts[node.op_type] = op_counts.get(node.op_type, 0) + 1

        inputs = [self._io_summary(vi) for vi in self.graph.input
                   if vi.name not in self.initializers]
        outputs = [self._io_summary(vi) for vi in self.graph.output]

        dynamic = any(
            any((not d.HasField("dim_value")) for d in vi.type.tensor_type.shape.dim)
            for vi in list(self.graph.input) + list(self.graph.output)
            if vi.name not in self.initializers
        )

        has_batchnorm = "BatchNormalization" in op_counts
        custom_domains = sorted({n.domain for n in self.graph.node if n.domain not in ("", "ai.onnx")})

        return {
            "num_nodes": len(self.graph.node),
            "unique_ops": sorted(op_counts.keys()),
            "op_counts": dict(sorted(op_counts.items(), key=lambda kv: -kv[1])),
            "inputs": inputs,
            "outputs": outputs,
            "num_initializers": len(self.graph.initializer),
            "has_dynamic_shapes": dynamic,
            "has_batchnorm": has_batchnorm,
            "custom_domains": custom_domains,
        }

    def _io_summary(self, vi: onnx.ValueInfoProto) -> dict:
        dims = []
        for d in vi.type.tensor_type.shape.dim:
            if d.HasField("dim_value"):
                dims.append(d.dim_value)
            elif d.HasField("dim_param") and d.dim_param:
                dims.append(d.dim_param)
            else:
                dims.append(None)
        dtype = ONNX_ELEM_TYPE_TO_STR.get(vi.type.tensor_type.elem_type, "unknown")
        return {"name": vi.name, "shape": dims, "dtype": dtype}

    def get_shape_dtype(self, tensor_name: str):
        """Return (shape:list[int|str|None], dtype:str) for a graph tensor, or (None, None)."""
        if tensor_name in self.initializers:
            arr = numpy_helper.to_array(self.initializers[tensor_name])
            return list(arr.shape), str(arr.dtype)
        vi = self.value_info.get(tensor_name)
        if vi is None:
            return None, None
        info = self._io_summary(vi)
        return info["shape"], info["dtype"]

    def get_initializer_array(self, name: str):
        return numpy_helper.to_array(self.initializers[name])
