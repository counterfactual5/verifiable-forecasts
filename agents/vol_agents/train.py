"""Train the three forecasting models with numpy and export them as ONNX (opset 13, Softmax output).

Training data are synthetic tick paths in the contract's units: 17 constant-tick segments before
createRound give the 16 features exactly as VolMarket computes them, and the 12 window segments that
follow give the realized-vol bucket under the round's bounds. Each path draws its own volatility, so
the models learn to read the recent tick variability into a 5-bucket distribution.

Usage: uv run python -m vol_agents.train [--samples N] [--steps N]
Writes models/<name>/model.onnx, meta.json and cal.json (EZKL calibration inputs); drops any
pinned settings.json, which vol_agents.build recalibrates.
"""

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

from . import contract_math as cm

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "models"
L2 = 1e-3
# Logits are clipped to [-LOGIT_CLIP, LOGIT_CLIP] in the model: the Softmax exp lookup then spans
# at most 2 * LOGIT_CLIP at scale 2^12 for any input, which keeps every circuit at logrows 15.
LOGIT_CLIP = 3.0
LEAK = 0.05  # gradient through the clip when saturated, so saturated samples still train


@dataclass(frozen=True)
class Spec:
    name: str
    abs_input: bool  # |x| before the first layer (the bucket depends on magnitude, not sign)
    hidden: int  # 0 = linear softmax
    description: str


SPECS = [
    Spec("linear_abs", True, 0, "softmax(W |x| + b): linear in absolute feature values"),
    Spec("mlp16", False, 16, "16->16 ReLU->5 softmax on signed features"),
    Spec("mlp32_abs", True, 32, "|x| -> 32 ReLU -> 5 softmax"),
]


def synth(n, rng):
    """Feature matrix x (model input) and bucket labels from random-walk tick paths."""
    sigma = np.exp(rng.uniform(np.log(0.25), np.log(6.0), n))
    sigma_w = sigma * np.exp(rng.normal(0.0, 0.3, n))
    hist = np.rint(rng.normal(0.0, 1.0, (n, cm.N_FEATURES)) * sigma[:, None]).astype(np.int64)
    win = np.rint(rng.normal(0.0, 1.0, (n, cm.N_SEGMENTS - 1)) * sigma_w[:, None]).astype(np.int64)
    # constant-tick segments: segment means are the ticks, so f_j is the tick increment
    x_int = np.clip(hist, -cm.CLAMP, cm.CLAMP) * cm.MULT
    rv = (win * win).sum(axis=1) * (cm.N_SEGMENTS - 1) // (cm.N_SEGMENTS - 1)
    y = np.searchsorted(np.array(cm.BOUNDS), rv, side="right")
    return (x_int / cm.SCALE).astype(np.float32), y, x_int, win


def init_params(spec, rng):
    d_in = cm.N_FEATURES
    # inputs are ticks / 32, so first-layer weights start around 32 / sqrt(fan_in)
    if spec.hidden == 0:
        return {"W": rng.normal(0, 8.0, (cm.BUCKETS, d_in)), "b": np.zeros(cm.BUCKETS)}
    return {
        "W1": rng.normal(0, 8.0, (spec.hidden, d_in)),
        "b1": rng.normal(0, 0.1, spec.hidden),
        "W2": rng.normal(0, 1.0 / np.sqrt(spec.hidden), (cm.BUCKETS, spec.hidden)),
        "b2": np.zeros(cm.BUCKETS),
    }


def forward(spec, p, x):
    a = np.abs(x) if spec.abs_input else x
    if spec.hidden == 0:
        z = a @ p["W"].T + p["b"]
        return np.clip(z, -LOGIT_CLIP, LOGIT_CLIP), (z, a)
    h = a @ p["W1"].T + p["b1"]
    hr = np.maximum(h, 0)
    z = hr @ p["W2"].T + p["b2"]
    return np.clip(z, -LOGIT_CLIP, LOGIT_CLIP), (z, a, h, hr)


def softmax(z):
    z = z - z.max(axis=1, keepdims=True)
    e = np.exp(z)
    return e / e.sum(axis=1, keepdims=True)


def loss_grad(spec, p, x, y):
    z, cache = forward(spec, p, x)
    prob = softmax(z)
    n = len(y)
    loss = -np.log(prob[np.arange(n), y] + 1e-12).mean()
    dz = prob.copy()
    dz[np.arange(n), y] -= 1
    dz /= n
    dz *= np.where(np.abs(cache[0]) <= LOGIT_CLIP, 1.0, LEAK)
    g = {}
    if spec.hidden == 0:
        _, a = cache
        g["W"] = dz.T @ a
        g["b"] = dz.sum(0)
    else:
        _, a, h, hr = cache
        g["W2"] = dz.T @ hr
        g["b2"] = dz.sum(0)
        dh = (dz @ p["W2"]) * (h > 0)
        g["W1"] = dh.T @ a
        g["b1"] = dh.sum(0)
    for k in g:
        if k.startswith("W"):
            loss += 0.5 * L2 * float((p[k] ** 2).sum()) / 1000
            g[k] += L2 * p[k] / 1000
    return loss, g


def train(spec, x, y, steps, seed):
    rng = np.random.default_rng(seed)
    p = init_params(spec, rng)
    m = {k: np.zeros_like(v) for k, v in p.items()}
    v = {k: np.zeros_like(val) for k, val in p.items()}
    lr, b1, b2 = 0.05, 0.9, 0.999
    for t in range(1, steps + 1):
        idx = rng.integers(0, len(y), 2048)
        _, g = loss_grad(spec, p, x[idx], y[idx])
        step_lr = lr * (0.1 ** (t / steps))
        for k in p:
            m[k] = b1 * m[k] + (1 - b1) * g[k]
            v[k] = b2 * v[k] + (1 - b2) * g[k] ** 2
            p[k] -= step_lr * (m[k] / (1 - b1**t)) / (np.sqrt(v[k] / (1 - b2**t)) + 1e-8)
    return p


def to_onnx(spec, p):
    f32 = {k: v.astype(np.float32) for k, v in p.items()}
    nodes, cur = [], "x"
    if spec.abs_input:
        nodes.append(helper.make_node("Abs", [cur], ["xa"]))
        cur = "xa"
    if spec.hidden == 0:
        nodes.append(helper.make_node("Gemm", [cur, "W", "b"], ["logits"], transB=1))
        inits = [("W", f32["W"]), ("b", f32["b"])]
    else:
        nodes += [
            helper.make_node("Gemm", [cur, "W1", "b1"], ["h"], transB=1),
            helper.make_node("Relu", ["h"], ["hr"]),
            helper.make_node("Gemm", ["hr", "W2", "b2"], ["logits"], transB=1),
        ]
        inits = [(k, f32[k]) for k in ("W1", "b1", "W2", "b2")]
    nodes += [
        helper.make_node("Clip", ["logits", "clip_lo", "clip_hi"], ["logits_c"]),
        helper.make_node("Softmax", ["logits_c"], ["y"], axis=1),
    ]
    inits += [
        ("clip_lo", np.array(-LOGIT_CLIP, np.float32)),
        ("clip_hi", np.array(LOGIT_CLIP, np.float32)),
    ]
    graph = helper.make_graph(
        nodes,
        f"rv_bucket_{spec.name}",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, cm.N_FEATURES])],
        [helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, cm.BUCKETS])],
        initializer=[numpy_helper.from_array(a, n) for n, a in inits],
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
    model.ir_version = 8
    onnx.checker.check_model(model)
    return model


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=40000)
    ap.add_argument("--steps", type=int, default=3000)
    a = ap.parse_args()
    rng = np.random.default_rng(7)
    x, y, _, _ = synth(a.samples, rng)
    xt, yt, _, _ = synth(10000, np.random.default_rng(8))
    prior = np.bincount(y, minlength=cm.BUCKETS) / len(y)
    base_ll = -np.log(prior[yt]).mean()
    print(f"bucket prior {np.round(prior, 3).tolist()}  prior log loss {base_ll:.4f}")
    for i, spec in enumerate(SPECS):
        p = train(spec, x, y, a.steps, seed=100 + i)
        z, _ = forward(spec, p, xt)
        prob = softmax(z)
        ll = -np.log(prob[np.arange(len(yt)), yt] + 1e-12).mean()
        acc = float((prob.argmax(1) == yt).mean())
        n_params = int(sum(v.size for v in p.values()))
        d = MODELS / spec.name
        d.mkdir(parents=True, exist_ok=True)
        onnx.save(to_onnx(spec, p), d / "model.onnx")
        (d / "settings.json").unlink(missing_ok=True)  # calibrated for the previous weights
        meta = {
            "name": spec.name,
            "description": spec.description,
            "params": n_params,
            "test_log_loss": round(float(ll), 4),
            "prior_log_loss": round(float(base_ll), 4),
            "test_accuracy": round(acc, 4),
            "logit_clip": LOGIT_CLIP,
            "onnx_sha256": hashlib.sha256((d / "model.onnx").read_bytes()).hexdigest(),
            "train": {"samples": a.samples, "steps": a.steps, "l2": L2},
        }
        (d / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        # realistic paths plus the full input range, so the calibrated ranges cover any round
        edge = np.random.default_rng(9).uniform(-2, 2, (32, cm.N_FEATURES)).astype(np.float32)
        cal = np.concatenate([xt[:32], edge])
        (d / "cal.json").write_text(json.dumps({"input_data": [cal.reshape(-1).tolist()]}))
        print(json.dumps(meta))


if __name__ == "__main__":
    main()
