"""
Constant-folding pass for "parameter" tensors that are not literal ONNX
Constant nodes but are nonetheless compile-time-constant for THIS exported
model, because the model has fully static input shapes (verified in
onnx_loader / compile_yoloe --inspect-only).

Examples in YOLOE's detect head: Slice's ends/starts/axes/steps, Unsqueeze's
axes, Tile's repeats, Resize's scales, TopK's k, Mod's divisor are all graph
*tensors* (Mul/Shape/Gather subgraphs), not ONNX Constant nodes - but their
values depend only on the static input shape, never on pixel data.

Rather than trust that classification blindly, this module runs the whole
graph twice with two DIFFERENT random inputs and only treats a candidate
tensor as foldable if its value is bit-identical across both runs. If it
differs, that tensor is genuinely data-dependent and must stay a real
runtime tensor dependency (e.g. TopK's index outputs, GatherElements'
index input) - folding it would silently bake in a wrong constant.
"""

from __future__ import annotations

import numpy as np
import onnx
import onnxruntime as ort


def _all_outputs_model(model: onnx.ModelProto, names: set[str]) -> onnx.ModelProto:
    m = onnx.ModelProto()
    m.CopyFrom(model)
    existing = {o.name for o in m.graph.output}
    for name in names:
        if name and name not in existing:
            m.graph.output.append(onnx.helper.make_tensor_value_info(name, onnx.TensorProto.UNDEFINED, None))
            existing.add(name)
    return m


def _run_once(model: onnx.ModelProto, input_name: str, input_shape: list[int], names: set[str], seed: int):
    m = _all_outputs_model(model, names)
    sess = ort.InferenceSession(m.SerializeToString(), providers=["CPUExecutionProvider"])
    rng = np.random.default_rng(seed)
    x = rng.standard_normal(input_shape).astype(np.float32)
    out_names = [o.name for o in sess.get_outputs()]
    results = sess.run(out_names, {input_name: x})
    return dict(zip(out_names, results))


def fold_candidate_tensors(
    model: onnx.ModelProto,
    input_name: str,
    input_shape: list[int],
    candidate_names: set[str],
) -> dict[str, np.ndarray]:
    """
    Returns {tensor_name: value} for every candidate whose value was
    bit-identical across two independent random-input runs.

    candidate_names should be the specific "parameter" input names collected
    by instructions.py (Slice starts/ends/axes/steps, Tile repeats, etc.) -
    NOT arbitrary activation tensors, so this stays cheap and targeted.
    """
    candidate_names = {n for n in candidate_names if n}
    if not candidate_names:
        return {}

    run_a = _run_once(model, input_name, input_shape, candidate_names, seed=1)
    run_b = _run_once(model, input_name, input_shape, candidate_names, seed=2)

    folded: dict[str, np.ndarray] = {}
    unstable: list[str] = []
    for name in candidate_names:
        a, b = run_a.get(name), run_b.get(name)
        if a is None or b is None:
            continue
        if a.shape == b.shape and np.array_equal(a, b):
            folded[name] = a
        else:
            unstable.append(name)

    if unstable:
        raise ValueError(
            f"Constant-folding invariance check FAILED for {len(unstable)} tensor(s): "
            f"{unstable}. These were assumed to be shape-only parameters but their "
            f"values changed between two different random inputs, meaning they are "
            f"actually data-dependent and must be treated as real runtime tensors "
            f"instead of folded instruction attributes. Update instructions.py's "
            f"PARAM_INPUT_POSITIONS for the responsible op."
        )

    return folded
