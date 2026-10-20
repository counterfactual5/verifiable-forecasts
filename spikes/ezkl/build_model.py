"""Build a tiny 16->32->5 MLP (Gemm/Relu/Gemm/Softmax) as ONNX using numpy only.

Usage: uv run python build_model.py [--logits]
Writes model.onnx (or model_logits.onnx), input.json, cal.json.
"""
import json
import sys

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

LOGITS = "--logits" in sys.argv
rng = np.random.default_rng(42)

D_IN, D_H, D_OUT = 16, 32, 5
W1 = (rng.standard_normal((D_H, D_IN)) * 0.3).astype(np.float32)
b1 = (rng.standard_normal(D_H) * 0.1).astype(np.float32)
W2 = (rng.standard_normal((D_OUT, D_H)) * 0.3).astype(np.float32)
b2 = (rng.standard_normal(D_OUT) * 0.1).astype(np.float32)

nodes = [
    helper.make_node("Gemm", ["x", "W1", "b1"], ["h"], transB=1),
    helper.make_node("Relu", ["h"], ["hr"]),
    helper.make_node("Gemm", ["hr", "W2", "b2"], ["logits" if not LOGITS else "y"], transB=1),
]
if not LOGITS:
    nodes.append(helper.make_node("Softmax", ["logits"], ["y"], axis=1))

graph = helper.make_graph(
    nodes,
    "rv_bucket_mlp",
    [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, D_IN])],
    [helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, D_OUT])],
    initializer=[numpy_helper.from_array(a, n) for a, n in [(W1, "W1"), (b1, "b1"), (W2, "W2"), (b2, "b2")]],
)
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
model.ir_version = 8
onnx.checker.check_model(model)
name = "model_logits.onnx" if LOGITS else "model.onnx"
onnx.save(model, name)
print(f"saved {name}; params={W1.size + b1.size + W2.size + b2.size}")

# Features are pre-normalized off-chain to roughly [-1, 1]: tick deltas / 100,
# RV features / typical RV, hour / 23 * 2 - 1.
x = rng.uniform(-1, 1, (1, D_IN)).astype(np.float32)
json.dump({"input_data": [x.reshape(-1).tolist()]}, open("input.json", "w"))
cal = rng.uniform(-1, 1, (20, D_IN)).astype(np.float32)
json.dump({"input_data": [cal.reshape(-1).tolist()]}, open("cal.json", "w"))

try:
    import onnxruntime as ort

    out = ort.InferenceSession(name).run(None, {"x": x})[0]
    print("onnxruntime output:", out.tolist())
except ImportError:
    pass
