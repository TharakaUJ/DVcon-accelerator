"""
End-to-end per-operator tests: each case is a small ONNX graph that is
compiled to the IR, executed by the C reference runtime (runtime/yoloe_runtime)
and compared tensor-by-tensor against onnxruntime.
"""

import numpy as np
import pytest
from onnx import TensorProto as TP, helper

from helpers import assert_matches, init, make_model, run_e2e

F = TP.FLOAT
I64 = TP.INT64
rng = np.random.default_rng(1234)


def w(*shape):
    return rng.standard_normal(shape).astype(np.float32)


def i64(v):
    return np.array(v, dtype=np.int64)


def node(op, ins, outs, **attrs):
    return helper.make_node(op, ins, outs, name=f"{op.lower()}_{outs[0]}", **attrs)


X4 = [1, 4, 6, 6]

# name -> (nodes, input shape, output (name, type, shape), initializers)
CASES = {
    # ---- convolution family -------------------------------------------------
    "conv_3x3_pad1_bias": ([node("Conv", ["x", "w", "b"], ["y"], kernel_shape=[3, 3], pads=[1, 1, 1, 1])],
                           X4, ("y", F, None), [init("w", w(8, 4, 3, 3)), init("b", w(8))]),
    "conv_stride2_nobias": ([node("Conv", ["x", "w"], ["y"], kernel_shape=[3, 3], pads=[1, 1, 1, 1], strides=[2, 2])],
                            X4, ("y", F, None), [init("w", w(8, 4, 3, 3))]),
    "conv_depthwise": ([node("Conv", ["x", "w", "b"], ["y"], kernel_shape=[3, 3], pads=[1, 1, 1, 1], group=4)],
                       X4, ("y", F, None), [init("w", w(4, 1, 3, 3)), init("b", w(4))]),
    "conv_grouped": ([node("Conv", ["x", "w"], ["y"], kernel_shape=[1, 1], group=2)],
                     X4, ("y", F, None), [init("w", w(6, 2, 1, 1))]),
    "conv_dilation2": ([node("Conv", ["x", "w"], ["y"], kernel_shape=[3, 3], pads=[2, 2, 2, 2], dilations=[2, 2])],
                       X4, ("y", F, None), [init("w", w(2, 4, 3, 3))]),
    "conv_asymmetric_pad": ([node("Conv", ["x", "w"], ["y"], kernel_shape=[3, 3], pads=[0, 0, 1, 1], strides=[2, 2])],
                            X4, ("y", F, None), [init("w", w(2, 4, 3, 3))]),
    "convtranspose_k2_s2": ([node("ConvTranspose", ["x", "w", "b"], ["y"], kernel_shape=[2, 2], strides=[2, 2])],
                            X4, ("y", F, None), [init("w", w(4, 3, 2, 2)), init("b", w(3))]),
    "convtranspose_k3_s2_pad": ([node("ConvTranspose", ["x", "w"], ["y"], kernel_shape=[3, 3], strides=[2, 2],
                                      pads=[1, 1, 1, 1], output_padding=[1, 1])],
                                X4, ("y", F, None), [init("w", w(4, 2, 3, 3))]),

    # ---- elementwise / activations -----------------------------------------
    "add_channel_broadcast": ([node("Add", ["x", "b"], ["y"])], X4, ("y", F, None), [init("b", w(1, 4, 1, 1))]),
    "sub_scalar": ([node("Sub", ["x", "s"], ["y"])], X4, ("y", F, None), [init("s", np.float32(0.5))]),
    "mul_row_broadcast": ([node("Mul", ["x", "m"], ["y"])], X4, ("y", F, None), [init("m", w(6))]),
    "div_tensor": ([node("Div", ["x", "d"], ["y"])], X4, ("y", F, None),
                   [init("d", (np.abs(w(1, 4, 6, 6)) + 0.5).astype(np.float32))]),
    "sigmoid_mul_silu": ([node("Sigmoid", ["x"], ["s"]), node("Mul", ["x", "s"], ["y"])], X4, ("y", F, None), []),
    "relu": ([node("Relu", ["x"], ["y"])], X4, ("y", F, None), []),

    # ---- pooling --------------------------------------------------------------
    "maxpool_k2_s2": ([node("MaxPool", ["x"], ["y"], kernel_shape=[2, 2], strides=[2, 2])], X4, ("y", F, None), []),
    "maxpool_sppf_k5_s1_p2": ([node("MaxPool", ["x"], ["y"], kernel_shape=[5, 5], strides=[1, 1], pads=[2, 2, 2, 2])],
                              X4, ("y", F, None), []),
    "avgpool_k3_s1_p1": ([node("AveragePool", ["x"], ["y"], kernel_shape=[3, 3], strides=[1, 1], pads=[1, 1, 1, 1])],
                         X4, ("y", F, None), []),

    # ---- data movement ------------------------------------------------------
    "concat_axis1": ([node("Relu", ["x"], ["r"]), node("Concat", ["x", "r"], ["y"], axis=1)], X4, ("y", F, None), []),
    "concat_neg_axis_3way": ([node("Relu", ["x"], ["r"]), node("Sigmoid", ["x"], ["s"]),
                              node("Concat", ["x", "r", "s"], ["y"], axis=-1)], X4, ("y", F, None), []),
    "split_even": ([node("Split", ["x"], ["a", "b"], axis=1), node("Add", ["a", "b"], ["y"])],
                   X4, ("y", F, None), []),
    "split_sizes": ([node("Split", ["x", "sp"], ["a", "b"], axis=1), node("Relu", ["a"], ["y"]),
                     node("Sigmoid", ["b"], ["z"])], X4, ("y", F, None), [init("sp", i64([1, 3]))]),
    "reshape": ([node("Reshape", ["x", "shp"], ["y"])], X4, ("y", F, None), [init("shp", i64([1, 4, 36]))]),
    "flatten": ([node("Flatten", ["x"], ["y"], axis=1)], X4, ("y", F, None), []),
    "unsqueeze_squeeze": ([node("Unsqueeze", ["x", "ax"], ["u"]), node("Squeeze", ["u", "ax"], ["y"])],
                          X4, ("y", F, None), [init("ax", i64([2]))]),
    "transpose_perm": ([node("Transpose", ["x"], ["y"], perm=[0, 2, 3, 1])], X4, ("y", F, None), []),
    "transpose_default_reverse": ([node("Transpose", ["x"], ["y"])], X4, ("y", F, None), []),
    "slice_axis_step": ([node("Slice", ["x", "s", "e", "a", "st"], ["y"])], X4, ("y", F, None),
                        [init("s", i64([1, 0])), init("e", i64([4, 6])), init("a", i64([1, 3])), init("st", i64([1, 2]))]),
    "slice_negative_start": ([node("Slice", ["x", "s", "e", "a"], ["y"])], X4, ("y", F, None),
                             [init("s", i64([-2])), init("e", i64([2 ** 62])), init("a", i64([-1]))]),
    "tile": ([node("Tile", ["x", "r"], ["y"])], X4, ("y", F, None), [init("r", i64([1, 2, 1, 3]))]),
    "resize_nearest_asymmetric_floor": (
        [node("Resize", ["x", "", "sc"], ["y"], mode="nearest", coordinate_transformation_mode="asymmetric",
              nearest_mode="floor")], X4, ("y", F, None), [init("sc", np.array([1, 1, 2, 2], np.float32))]),

    # ---- reductions / matmul / softmax -------------------------------------
    "reducemax_last_keepdims": ([node("ReduceMax", ["x"], ["y"], axes=[-1], keepdims=1)], X4, ("y", F, None), []),
    "reducemax_channel_nokeep": ([node("ReduceMax", ["x"], ["y"], axes=[1], keepdims=0)], X4, ("y", F, None), []),
    "matmul_2d": ([node("MatMul", ["x", "m"], ["y"])], [4, 6], ("y", F, None), [init("m", w(6, 5))]),
    "matmul_batched_same": ([node("MatMul", ["x", "m"], ["y"])], [2, 4, 6], ("y", F, None), [init("m", w(2, 6, 3))]),
    "matmul_rhs_2d_broadcast": ([node("MatMul", ["x", "m"], ["y"])], [2, 4, 6], ("y", F, None), [init("m", w(6, 3))]),
    "matmul_self_attention": ([node("Transpose", ["x"], ["xt"], perm=[0, 1, 3, 2]),
                               node("MatMul", ["x", "xt"], ["y"])], [1, 2, 4, 6], ("y", F, None), []),
    "softmax_last": ([node("Softmax", ["x"], ["y"], axis=-1)], X4, ("y", F, None), []),
    "softmax_axis1": ([node("Softmax", ["x"], ["y"], axis=1)], X4, ("y", F, None), []),
    "einsum_bchw_bkc": ([node("Einsum", ["x", "e"], ["y"], equation="bchw,bkc->bkhw")], X4, ("y", F, None),
                        [init("e", w(1, 5, 4))]),

    # ---- detect-head style: TopK / Gather / GatherElements / int64 math -----
    "topk_values_indices": ([node("TopK", ["x", "k"], ["v", "i"], axis=-1)], [2, 10], ("v", F, None),
                            [init("k", i64([3]))]),
    "gather_const_indices": ([node("Gather", ["x", "idx"], ["y"], axis=1)], X4, ("y", F, None),
                             [init("idx", i64([3, 0, -1]))]),
    "topk_gather_elements": ([node("TopK", ["x", "k"], ["v", "i"], axis=-1),
                              node("GatherElements", ["x", "i"], ["y"], axis=1)],
                             [3, 12], ("y", F, None), [init("k", i64([4]))]),
    "topk_gather_rows": ([node("ReduceMax", ["x"], ["m"], axes=[-1], keepdims=0),
                          node("TopK", ["m", "k"], ["v", "i"], axis=-1),
                          node("Squeeze", ["i", "ax0"], ["i1"]),
                          node("Gather", ["x", "i1"], ["y"], axis=1)],
                         [1, 20, 5], ("y", F, None), [init("k", i64([6])), init("ax0", i64([0]))]),
    # Relu*40 -> Cast(int64) -> Mod / Div / Add / Sub / Mul (int64) -> Cast(float)
    "int64_cast_mod_div_add": (
        [node("Relu", ["x"], ["r"]), node("Mul", ["r", "ten"], ["m"]), node("Cast", ["m"], ["mi"], to=I64),
         node("Mod", ["mi", "four"], ["md"]), node("Div", ["mi", "three"], ["dv"]), node("Add", ["md", "dv"], ["s"]),
         node("Sub", ["s", "one"], ["sm"]), node("Mul", ["sm", "two"], ["p"]), node("Cast", ["p"], ["y"], to=F)],
        [1, 16], ("y", F, None),
        [init("ten", np.float32(40.0)), init("four", i64(4)), init("three", i64(3)), init("one", i64(1)),
         init("two", i64(2))]),
}


@pytest.mark.parametrize("case", sorted(CASES))
def test_op_matches_onnxruntime(case, tmp_path, runtime_built):
    nodes, in_shape, (out_name, out_type, out_shape), inits = CASES[case]
    model = make_model(nodes, [("x", F, in_shape)], [(out_name, out_type, out_shape)], inits)
    result = run_e2e(model, str(tmp_path))
    assert_matches(result)


def test_tiny_model_end_to_end(tiny_model_path, tmp_path, runtime_built):
    import onnx
    result = run_e2e(onnx.load(tiny_model_path), str(tmp_path))
    assert len(result.instructions) == 7
    assert len(result.errors) == 7
    assert_matches(result)


def test_memory_reuse_does_not_corrupt_long_chain(tmp_path, runtime_built):
    """A deep chain with skip connections forces heavy activation-memory reuse;
    every intermediate must still match (streaming dumps + planner safety)."""
    nodes, prev, skips = [], "x", []
    for i in range(12):
        nodes.append(node("Conv", [prev, f"w{i}"], [f"c{i}"], kernel_shape=[3, 3], pads=[1, 1, 1, 1]))
        nodes.append(node("Sigmoid", [f"c{i}"], [f"s{i}"]))
        nodes.append(node("Mul", [f"c{i}", f"s{i}"], [f"a{i}"]))
        if i % 3 == 2:
            nodes.append(node("Add", [f"a{i}", skips[-1]], [f"r{i}"]))
            prev = f"r{i}"
        else:
            prev = f"a{i}"
        skips.append(prev)
    nodes.append(node("Concat", [skips[0], skips[5], prev], ["y"], axis=1))
    inits = [init(f"w{i}", w(4, 4, 3, 3) * 0.3) for i in range(12)]
    model = make_model(nodes, [("x", F, X4)], [("y", F, None)], inits)
    result = run_e2e(model, str(tmp_path))
    assert_matches(result)


# Known gaps in the C runtime (confirmed by these tests). Each is xfail(strict):
# when a gap gets fixed the test starts passing and pytest flags it, so move
# the case into CASES above at that point.
KNOWN_GAPS = {
    "resize_nearest_half_pixel_round_prefer_floor": (
        "resize.c always floors; ignores nearest_mode (ONNX default round_prefer_floor)",
        [node("Resize", ["x", "", "sc"], ["y"], mode="nearest")], X4, ("y", F, None),
        [init("sc", np.array([1, 1, 2, 2], np.float32))]),
    "matmul_size1_batch_broadcast": (
        "matmul.c only broadcasts operands with fewer dims, not size-1 batch dims",
        [node("MatMul", ["x", "m"], ["y"])], [2, 4, 6], ("y", F, None), [init("m", w(1, 6, 3))]),
    "constant_node_input": (
        "Constant-node outputs are never written to weights.bin, so they read as zeros",
        [helper.make_node("Constant", [], ["c"], value=helper.make_tensor("v", F, [1], [2.0])),
         node("Mul", ["x", "c"], ["y"])], X4, ("y", F, None), []),
    "shape_derived_slice_end": (
        "the Shape/Gather subgraph feeding a folded param is still emitted; SHAPE has no C kernel",
        [node("Shape", ["x"], ["sh"]), node("Gather", ["sh", "i"], ["e"], axis=0),
         node("Slice", ["x", "s", "e", "a"], ["y"])], X4, ("y", F, None),
        [init("i", i64([1])), init("s", i64([1])), init("a", i64([1]))]),
    "leakyrelu": (
        "LEAKYRELU opcode is registered but has no kernel",
        [node("LeakyRelu", ["x"], ["y"], alpha=0.1)], X4, ("y", F, None), []),
    "reducemax_no_axes": (
        "reducemax.c reduces nothing when axes is omitted (ONNX: reduce all axes)",
        [node("ReduceMax", ["x"], ["y"], keepdims=1)], X4, ("y", F, None), []),
    "topk_axis1": (
        "topk.c always works on the last axis",
        [node("TopK", ["x", "k"], ["v", "i"], axis=1)], X4, ("v", F, None), [init("k", i64([2]))]),
    "topk_smallest": (
        "topk.c ignores largest=0",
        [node("TopK", ["x", "k"], ["v", "i"], axis=-1, largest=0)], [2, 10], ("v", F, None),
        [init("k", i64([3]))]),
    "concat_int64": (
        "concat.c copies sizeof(float) per element; int64 tensors are corrupted",
        [node("Mul", ["x", "big"], ["xb"]), node("Cast", ["xb"], ["xi"], to=I64),
         node("Concat", ["xi", "xi"], ["ci"], axis=1), node("Cast", ["ci"], ["y"], to=F)],
        [1, 2, 3], ("y", F, None), [init("big", np.float32(1000.0))]),
    "einsum_other_equation": (
        "einsum.c only implements bchw,bkc->bkhw",
        [node("Einsum", ["x", "m"], ["y"], equation="bij,jk->bik")], [2, 4, 6], ("y", F, None),
        [init("m", w(6, 3))]),
}


@pytest.mark.parametrize("case", [
    pytest.param(name, marks=pytest.mark.xfail(strict=True, reason=KNOWN_GAPS[name][0]))
    for name in sorted(KNOWN_GAPS)
])
def test_known_gap(case, tmp_path, runtime_built):
    reason, nodes, in_shape, (out_name, out_type, out_shape), inits = KNOWN_GAPS[case]
    model = make_model(nodes, [("x", F, in_shape)], [(out_name, out_type, out_shape)], inits)
    result = run_e2e(model, str(tmp_path))
    assert_matches(result)
