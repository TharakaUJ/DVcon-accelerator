"""
Writes weights.bin: raw bytes (each tensor in its own native dtype - no
forced float32 cast) for every WEIGHT/BIAS-kind tensor, concatenated in the
same id-sorted order tensors.json lists them in. This is a pure function of
the model's initializers, so - unlike verification/dump_reference.py, which
also needs to *run* the model through onnxruntime to get activation ground
truth - this belongs in the compile step itself: weights.bin is needed to
run the compiled IR at all, not just to verify it.
"""

from __future__ import annotations

from extractor.onnx_loader import LoadedModel
from extractor.ir import Tensor, TensorKind


def write_weights_bin(loaded: LoadedModel, tensors: dict[str, Tensor], path: str) -> int:
    total_bytes = 0
    with open(path, "wb") as f:
        for tid in sorted(tensors.keys()):
            t = tensors[tid]
            if t.kind not in (TensorKind.WEIGHT, TensorKind.BIAS):
                continue
            arr = loaded.get_initializer_array(t.name)  # native dtype, no cast
            data = arr.tobytes()
            f.write(data)
            total_bytes += len(data)
    return total_bytes
