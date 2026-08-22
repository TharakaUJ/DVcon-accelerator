"""
Builds a tiny synthetic ONNX graph (no YOLOE dependency) to exercise the
whole extraction/memory/runtime pipeline end to end:

    input (1,3,8,8)
        -> Conv (3x3, 4 filters, pad 1)     -> t0  (1,4,8,8)
        -> Sigmoid                            -> t1
        -> Mul(t0, t1)  [[SiLU expressed manually]] -> t2
        -> Conv (1x1, 4 filters)              -> t3  (1,4,8,8)
        -> Add(t2, t3)                        -> t4
        -> MaxPool (2x2, stride 2)             -> t5  (1,4,4,4)
        -> Conv (1x1, 2 filters)                -> out (1,2,4,4)
"""

import numpy as np
import onnx
from onnx import helper, TensorProto, numpy_helper


def build(path: str, seed: int = 0):
    rng = np.random.default_rng(seed)

    inp = helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, 3, 8, 8])
    out = helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, 2, 4, 4])

    w0 = numpy_helper.from_array(rng.standard_normal((4, 3, 3, 3)).astype(np.float32), name="w0")
    b0 = numpy_helper.from_array(rng.standard_normal((4,)).astype(np.float32), name="b0")
    w1 = numpy_helper.from_array(rng.standard_normal((4, 4, 1, 1)).astype(np.float32), name="w1")
    b1 = numpy_helper.from_array(rng.standard_normal((4,)).astype(np.float32), name="b1")
    w2 = numpy_helper.from_array(rng.standard_normal((2, 4, 1, 1)).astype(np.float32), name="w2")
    b2 = numpy_helper.from_array(rng.standard_normal((2,)).astype(np.float32), name="b2")

    n0 = helper.make_node("Conv", ["input", "w0", "b0"], ["t0"], name="conv0",
                            kernel_shape=[3, 3], pads=[1, 1, 1, 1], strides=[1, 1])
    n1 = helper.make_node("Sigmoid", ["t0"], ["t1"], name="sigmoid0")
    n2 = helper.make_node("Mul", ["t0", "t1"], ["t2"], name="mul0")  # SiLU = x * sigmoid(x)
    n3 = helper.make_node("Conv", ["t2", "w1", "b1"], ["t3"], name="conv1",
                            kernel_shape=[1, 1], pads=[0, 0, 0, 0], strides=[1, 1])
    n4 = helper.make_node("Add", ["t2", "t3"], ["t4"], name="add0")
    n5 = helper.make_node("MaxPool", ["t4"], ["t5"], name="pool0",
                            kernel_shape=[2, 2], strides=[2, 2], pads=[0, 0, 0, 0])
    n6 = helper.make_node("Conv", ["t5", "w2", "b2"], ["output"], name="conv2",
                            kernel_shape=[1, 1], pads=[0, 0, 0, 0], strides=[1, 1])

    graph = helper.make_graph(
        [n0, n1, n2, n3, n4, n5, n6],
        "tiny_test_graph",
        [inp],
        [out],
        initializer=[w0, b0, w1, b1, w2, b2],
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 17)])
    model.ir_version = 8
    onnx.checker.check_model(model)
    onnx.save(model, path)
    return path


if __name__ == "__main__":
    import sys
    build(sys.argv[1] if len(sys.argv) > 1 else "tiny.onnx")
    print("wrote tiny.onnx")
