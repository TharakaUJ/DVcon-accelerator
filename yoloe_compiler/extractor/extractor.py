"""
Top-level extraction orchestrator. Ties together onnx_loader, graph,
operators, tensors, and instructions into a single ExtractionResult.

Deliberately contains NO memory planning, NO C codegen, and NO hardware
assumptions - those are separate passes (analysis/, output/, runtime/).
"""

from __future__ import annotations

from dataclasses import dataclass

from .onnx_loader import LoadedModel
from .graph import build_dependency_graph, validate_topological_order, DependencyGraph
from .tensors import build_tensor_table
from .instructions import build_instructions, collect_param_candidate_names
from .constant_folding import fold_candidate_tensors
from .ir import Instruction, Tensor, TensorKind
from .operators import UnsupportedOperatorError


@dataclass
class ExtractionResult:
    instructions: list[Instruction]
    tensors: dict[str, Tensor]
    graph_inputs: list[str]     # tensor ids
    graph_outputs: list[str]    # tensor ids
    dependency_graph: DependencyGraph


def _assign_tensor_ids(loaded: LoadedModel, dg: DependencyGraph) -> dict[str, str]:
    """
    Build a stable, human-readable id for every ONNX tensor name.
        model inputs      -> input_<i>
        model outputs      -> handled same as activations (kept as tensor_<i> or renamed below)
        initializers        -> weight_<name-derived> / bias_<...> (kept simple: weight_<i>)
        everything else     -> tensor_<i>  (activations, in first-seen order)
    """
    tensor_id_of: dict[str, str] = {}

    for i, vi in enumerate(loaded.graph.input):
        if vi.name in dg.initializers:
            continue
        tensor_id_of[vi.name] = f"input_{i}"

    for i, init in enumerate(loaded.graph.initializer):
        tensor_id_of[init.name] = f"weight_{i}"

    counter = 0
    for node in loaded.graph.node:
        for name in list(node.input) + list(node.output):
            if name == "" or name in tensor_id_of:
                continue
            tensor_id_of[name] = f"tensor_{counter}"
            counter += 1

    for o in loaded.graph.output:
        if o.name not in tensor_id_of:
            tensor_id_of[o.name] = f"output_{o.name}"

    return tensor_id_of


def extract(model_path: str, strict_order: bool = True) -> ExtractionResult:
    loaded = LoadedModel(model_path)
    dg = build_dependency_graph(loaded.graph)

    if strict_order:
        validate_topological_order(loaded.graph, dg)

    tensor_id_of = _assign_tensor_ids(loaded, dg)

    # Fold Constant nodes' outputs into materialized CONSTANT tensors so
    # downstream ops (Reshape shape-arg, Concat axis lists, etc.) see them
    # as data rather than as an executable instruction.
    const_node_outputs = {
        n.output[0] for n in loaded.graph.node if n.op_type == "Constant" and len(n.output) == 1
    }

    node_order = list(range(len(loaded.graph.node)))  # ONNX stored order (validated above)

    # Fold shape-only "parameter" tensors (Slice starts/ends, Tile repeats,
    # TopK's k, ...) into instruction attributes. This requires one-time
    # graph execution (see constant_folding.py for the invariance check).
    candidate_names = collect_param_candidate_names(loaded.graph)
    if candidate_names:
        input_vi = [i for i in loaded.graph.input if i.name not in dg.initializers][0]
        in_shape, _ = loaded.get_shape_dtype(input_vi.name)
        in_shape = [d if isinstance(d, int) and d > 0 else 1 for d in in_shape]
        folded_params = fold_candidate_tensors(loaded.model, input_vi.name, in_shape, candidate_names)
    else:
        folded_params = {}

    try:
        instructions = build_instructions(loaded.graph, node_order, tensor_id_of, folded_params)
    except UnsupportedOperatorError:
        raise

    tensors = build_tensor_table(loaded, dg, tensor_id_of)

    # Mark folded Constant outputs explicitly as CONSTANT kind.
    for name in const_node_outputs:
        tid = tensor_id_of.get(name)
        if tid in tensors:
            tensors[tid].kind = TensorKind.CONSTANT

    graph_input_ids = [tensor_id_of[i.name] for i in loaded.graph.input if i.name not in dg.initializers]
    graph_output_ids = [tensor_id_of[o.name] for o in loaded.graph.output]

    return ExtractionResult(
        instructions=instructions,
        tensors=tensors,
        graph_inputs=graph_input_ids,
        graph_outputs=graph_output_ids,
        dependency_graph=dg,
    )
