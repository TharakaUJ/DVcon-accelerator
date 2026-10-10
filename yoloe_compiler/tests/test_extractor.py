"""Unit tests for extractor/: IR helpers, dependency graph, op mapping,
tensor table, constant folding and the top-level extract()."""

import numpy as np
import onnx
import pytest
from onnx import TensorProto as TP, helper

from extractor.constant_folding import fold_candidate_tensors
from extractor.extractor import extract
from extractor.graph import build_dependency_graph, topological_sort, validate_topological_order
from extractor.ir import TensorKind, contiguous_strides, dtype_size_bytes, numel
from extractor.operators import HANDLERS, UnsupportedOperatorError, map_node
from helpers import init, make_model


# ---- ir.py ----------------------------------------------------------------

def test_dtype_size_bytes():
    assert dtype_size_bytes("float32") == 4
    assert dtype_size_bytes("int64") == 8
    assert dtype_size_bytes("bool") == 1
    with pytest.raises(ValueError):
        dtype_size_bytes("complex64")


def test_numel_and_strides():
    assert numel([1, 3, 8, 8]) == 192
    assert numel([]) == 1
    with pytest.raises(ValueError):
        numel([1, -1, 4])
    assert contiguous_strides([2, 3, 4]) == [12, 4, 1]
    assert contiguous_strides([5]) == [1]


# ---- graph.py -------------------------------------------------------------

def _chain_graph():
    return make_model(
        [helper.make_node("Relu", ["x"], ["a"], name="n0"),
         helper.make_node("Sigmoid", ["a"], ["b"], name="n1"),
         helper.make_node("Add", ["a", "b"], ["y"], name="n2")],
        [("x", TP.FLOAT, [1, 4])], [("y", TP.FLOAT, [1, 4])],
    ).graph


def test_dependency_graph():
    dg = build_dependency_graph(_chain_graph())
    assert dg.graph_inputs == {"x"}
    assert dg.graph_outputs == {"y"}
    assert dg.producer_of == {"a": 0, "b": 1, "y": 2}
    assert dg.consumers_of["a"] == [1, 2]


def test_topological_order_valid_and_sort():
    g = _chain_graph()
    dg = build_dependency_graph(g)
    validate_topological_order(g, dg)
    assert topological_sort(g, dg) == [0, 1, 2]


def test_topological_order_violation_detected():
    g = _chain_graph()
    nodes = list(g.node)
    del g.node[:]
    g.node.extend([nodes[1], nodes[0], nodes[2]])  # Sigmoid before its producer
    dg = build_dependency_graph(g)
    with pytest.raises(ValueError, match="Invalid topological order"):
        validate_topological_order(g, dg)
    order = topological_sort(g, dg)
    assert order.index(1) < order.index(0)  # Relu (now index 1) must come first


def test_topological_sort_detects_cycle():
    g = helper.make_graph(
        [helper.make_node("Add", ["x", "b"], ["a"]), helper.make_node("Relu", ["a"], ["b"])],
        "cyc", [helper.make_tensor_value_info("x", TP.FLOAT, [1])],
        [helper.make_tensor_value_info("b", TP.FLOAT, [1])],
    )
    with pytest.raises(ValueError, match="possible cycle"):
        topological_sort(g, build_dependency_graph(g))


# ---- operators.py ---------------------------------------------------------

def test_conv_attr_defaults_and_values():
    op, attrs = map_node(helper.make_node("Conv", ["x", "w"], ["y"], kernel_shape=[3, 3],
                                          pads=[1, 1, 1, 1], strides=[2, 2], group=2))
    assert op == "CONV"
    assert attrs == {"kernel": [3, 3], "stride": [2, 2], "padding": [1, 1, 1, 1],
                     "dilation": [1, 1], "group": 2}
    _, attrs = map_node(helper.make_node("Conv", ["x", "w"], ["y"], kernel_shape=[1, 1]))
    assert attrs["stride"] == [1, 1] and attrs["padding"] == [0, 0, 0, 0]


def test_string_attrs_decoded():
    _, a = map_node(helper.make_node("Resize", ["x", "", "s"], ["y"], mode="nearest",
                                     coordinate_transformation_mode="asymmetric", nearest_mode="floor"))
    assert a == {"mode": "nearest", "coordinate_transformation_mode": "asymmetric", "nearest_mode": "floor"}
    _, a = map_node(helper.make_node("Einsum", ["a", "b"], ["y"], equation="bchw,bkc->bkhw"))
    assert a == {"equation": "bchw,bkc->bkhw"}


def test_unsupported_operator_raises():
    node = helper.make_node("NonZero", ["x"], ["y"], name="nz")
    assert "NonZero" not in HANDLERS
    with pytest.raises(UnsupportedOperatorError, match="NonZero"):
        map_node(node)


# ---- constant_folding.py --------------------------------------------------

def _slice_model(ends_from_shape: bool):
    nodes, inits = [], [init("s", np.array([1], np.int64)), init("a", np.array([1], np.int64))]
    if ends_from_shape:
        nodes += [helper.make_node("Shape", ["x"], ["sh"]),
                  helper.make_node("Gather", ["sh", "i"], ["e"], axis=0)]
        inits.append(init("i", np.array([1], np.int64)))
    else:
        inits.append(init("e", np.array([3], np.int64)))
    nodes.append(helper.make_node("Slice", ["x", "s", "e", "a"], ["y"]))
    return make_model(nodes, [("x", TP.FLOAT, [1, 4, 6])], [("y", TP.FLOAT, None)], inits)


@pytest.mark.parametrize("ends_from_shape,expected_end", [(False, 3), (True, 4)])
def test_fold_shape_only_params(ends_from_shape, expected_end):
    model = _slice_model(ends_from_shape)
    folded = fold_candidate_tensors(model, "x", [1, 4, 6], {"s", "e", "a"})
    assert folded["s"].tolist() == [1]
    assert folded["e"].tolist() == [expected_end]


def test_fold_rejects_data_dependent_value():
    # A candidate whose value depends on pixel data (like TopK indices) must not fold.
    model = make_model([helper.make_node("Abs", ["x"], ["ax"])],
                       [("x", TP.FLOAT, [1, 8])], [("ax", TP.FLOAT, [1, 8])])
    with pytest.raises(ValueError, match="invariance check FAILED"):
        fold_candidate_tensors(model, "x", [1, 8], {"ax"})


# ---- extractor.py (whole pass) --------------------------------------------

def test_extract_tiny_model(tiny_model_path):
    r = extract(tiny_model_path)
    assert [i.op for i in r.instructions] == ["CONV", "SIGMOID", "MUL", "CONV", "ADD", "MAXPOOL", "CONV"]
    assert r.graph_inputs == ["input_0"]
    kinds = {t.kind for t in r.tensors.values()}
    assert {TensorKind.INPUT, TensorKind.OUTPUT, TensorKind.WEIGHT, TensorKind.BIAS,
            TensorKind.ACTIVATION} <= kinds
    out = r.tensors[r.graph_outputs[0]]
    assert out.shape == [1, 2, 4, 4] and out.size_bytes == 2 * 4 * 4 * 4
    assert r.instructions[0].onnx_node_name == "conv0"


def test_extract_folds_slice_params_into_attributes(tmp_path):
    path = str(tmp_path / "m.onnx")
    onnx.save(_slice_model(ends_from_shape=False), path)
    r = extract(path)
    (instr,) = r.instructions
    assert instr.op == "SLICE"
    assert instr.attributes == {"starts": [1], "ends": [3], "axes": [1]}
    assert instr.inputs == ["input_0"]  # param tensors removed from runtime deps


def test_extract_constant_node_marked_constant(tmp_path):
    model = make_model(
        [helper.make_node("Constant", [], ["c"], value=helper.make_tensor("v", TP.FLOAT, [1], [2.0])),
         helper.make_node("Mul", ["x", "c"], ["y"])],
        [("x", TP.FLOAT, [1, 4])], [("y", TP.FLOAT, [1, 4])],
    )
    path = str(tmp_path / "m.onnx")
    onnx.save(model, path)
    r = extract(path)
    assert [i.op for i in r.instructions] == ["MUL"]  # Constant is not executed
    const = [t for t in r.tensors.values() if t.name == "c"][0]
    assert const.kind == TensorKind.CONSTANT
