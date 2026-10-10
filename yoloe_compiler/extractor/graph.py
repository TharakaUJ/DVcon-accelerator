"""
Builds an explicit producer/consumer dependency graph over ONNX tensor names,
independent of whatever order graph.node happens to be stored in, and
validates that a given node ordering is a legal topological order.

Per spec section 18: we must not assume ONNX node order is automatically a
valid schedule - we verify it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import onnx


@dataclass
class DependencyGraph:
    # tensor_name -> index of the onnx node that produces it (None if graph input/initializer)
    producer_of: dict[str, int] = field(default_factory=dict)
    # tensor_name -> list of node indices that consume it
    consumers_of: dict[str, list[int]] = field(default_factory=dict)
    # names that are graph inputs (not produced by any node)
    graph_inputs: set[str] = field(default_factory=set)
    # names that are initializers (weights/biases/constants)
    initializers: set[str] = field(default_factory=set)
    # names that are graph outputs
    graph_outputs: set[str] = field(default_factory=set)


def build_dependency_graph(graph: onnx.GraphProto) -> DependencyGraph:
    dg = DependencyGraph()
    dg.initializers = {i.name for i in graph.initializer}
    dg.graph_inputs = {i.name for i in graph.input if i.name not in dg.initializers}
    dg.graph_outputs = {o.name for o in graph.output}

    for idx, node in enumerate(graph.node):
        for out_name in node.output:
            if out_name == "":
                continue
            dg.producer_of[out_name] = idx
        for in_name in node.input:
            if in_name == "":
                continue
            dg.consumers_of.setdefault(in_name, []).append(idx)

    return dg


def validate_topological_order(graph: onnx.GraphProto, dg: DependencyGraph) -> None:
    """
    Verify that graph.node, in its current stored order, is a valid
    topological order: every input to node i is either a graph input,
    an initializer, or was produced by some node j < i.

    Raises ValueError with details on the first violation found.
    """
    produced_by_index: dict[str, int] = {}
    for idx, node in enumerate(graph.node):
        for in_name in node.input:
            if in_name == "":
                continue
            if in_name in dg.graph_inputs or in_name in dg.initializers:
                continue
            producer_idx = produced_by_index.get(in_name)
            if producer_idx is None:
                raise ValueError(
                    f"Invalid topological order: node[{idx}] "
                    f"'{node.name}' ({node.op_type}) consumes '{in_name}' "
                    f"which has no known producer before this point "
                    f"(not a graph input, initializer, or prior node output)."
                )
        for out_name in node.output:
            if out_name != "":
                produced_by_index[out_name] = idx


def topological_sort(graph: onnx.GraphProto, dg: DependencyGraph) -> list[int]:
    """
    Kahn's algorithm over node indices, using the dependency graph.
    Returns a list of node indices in a valid topological order.
    Used as a fallback / cross-check against the stored ONNX order.
    """
    n = len(graph.node)
    indegree = [0] * n
    adj: dict[int, list[int]] = {i: [] for i in range(n)}

    for idx, node in enumerate(graph.node):
        deps = set()
        for in_name in node.input:
            if in_name == "" or in_name in dg.graph_inputs or in_name in dg.initializers:
                continue
            producer = dg.producer_of.get(in_name)
            if producer is not None:
                deps.add(producer)
        indegree[idx] = len(deps)
        for d in deps:
            adj[d].append(idx)

    from collections import deque
    queue = deque(i for i in range(n) if indegree[i] == 0)
    order = []
    while queue:
        i = queue.popleft()
        order.append(i)
        for j in adj[i]:
            indegree[j] -= 1
            if indegree[j] == 0:
                queue.append(j)

    if len(order) != n:
        raise ValueError(
            f"Graph is not a DAG or is disconnected in an unexpected way: "
            f"topologically sorted {len(order)} of {n} nodes (possible cycle)."
        )
    return order
