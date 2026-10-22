"""Train the three forecasting models with numpy on real pool history and export them as ONNX
(opset 13, Softmax output).

Samples come from dataset.build_samples over the tick-cumulative grid that analysis/ exports from
Uniswap V3 Swap logs: the 16 features exactly as VolMarket computes them at createRound, and the
realized-vol bucket of the hour that starts LEAD_S later, under cm.BOUNDS.

Split: chronological, never shuffled. The last TEST_FRAC of the rounds is the test set, separated
from the training part by a leak gap (no sample on one side reads a second the other side reads).
Model selection uses the last VAL_FRAC of the training part, split the same way: synthetic
random-walk paths are kept as augmentation only if they lower the mean validation log loss.

Baselines, fitted on the training part: the bucket prior, and the bucket of the previous hour's
realized vol (smoothed one-hot and an empirical transition matrix).

Usage: uv run python -m vol_agents.train --grid PATH [--params PATH] [--steps N]
Writes models/<name>/model.onnx, meta.json and cal.json (EZKL calibration inputs), models/eval.json
and the held-out fixture tests/fixtures/real_holdout.json; drops any pinned settings.json, which
vol_agents.build recalibrates.
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
from . import dataset as ds

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "models"
HOLDOUT = ROOT / "tests" / "fixtures" / "real_holdout.json"
DEFAULT_GRID = ROOT.parent / "analysis" / "data" / "tick_cumulative_grid.csv"
DEFAULT_PARAMS = ROOT.parent / "analysis" / "data" / "vol_params.json"
L2 = 1e-6
# Logits are clipped to [-LOGIT_CLIP, LOGIT_CLIP] in the model: the Softmax exp lookup then spans
# at most 2 * LOGIT_CLIP at scale 2^12 for any input, which keeps every circuit at logrows 15.
LOGIT_CLIP = 3.0
LEAK = 0.05  # gradient through the clip when saturated, so saturated samples still train
TEST_FRAC = 0.2
VAL_FRAC = 0.2
STRIDE_S = 60
HOLDOUT_EVERY = 5  # the committed fixture keeps one test round every 5 * STRIDE_S
SEED_SYNTH, SEED_MODEL, SEED_EDGE = 7, 100, 9


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


def synth(n, rng, bounds=cm.BOUNDS):
    """Random-walk rounds in contract units: per-round volatility sigma (ticks per segment-mean
    difference) log-uniform over the real range, window volatility sigma * exp(N(0, 0.3^2)).
    Returns model input x, labels y, contract features x_int and the 11 window differences."""
    sigma = np.exp(rng.uniform(np.log(2.0), np.log(40.0), n))
    sigma_w = sigma * np.exp(rng.normal(0.0, 0.3, n))
    hist = np.rint(rng.normal(0.0, 1.0, (n, cm.N_FEATURES)) * sigma[:, None]).astype(np.int64)
    win = np.rint(rng.normal(0.0, 1.0, (n, cm.N_SEGMENTS - 1)) * sigma_w[:, None]).astype(np.int64)
    x_int = np.clip(hist, -cm.CLAMP, cm.CLAMP) * cm.MULT
    rv = (win * win).sum(axis=1)
    y = np.searchsorted(np.array(bounds), rv, side="right")
    return (x_int / cm.SCALE).astype(np.float32), y, x_int, win


def init_params(spec, rng, x_rms):
    d_in = cm.N_FEATURES
    w_std = 1.0 / (x_rms * np.sqrt(d_in))
    if spec.hidden == 0:
        return {"W": rng.normal(0, w_std, (cm.BUCKETS, d_in)), "b": np.zeros(cm.BUCKETS)}
    return {
        "W1": rng.normal(0, w_std, (spec.hidden, d_in)),
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
            loss += 0.5 * L2 * float((p[k] ** 2).sum())
            g[k] += L2 * p[k]
    return loss, g


def train(spec, x, y, steps, seed):
    rng = np.random.default_rng(seed)
    p = init_params(spec, rng, float(np.sqrt(np.mean(x**2))))
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


def log_loss(prob, y):
    return float(-np.log(np.maximum(prob[np.arange(len(y)), y], 1e-12)).mean())


def accuracy(prob, y):
    return float((prob.argmax(1) == y).mean())


class Baselines:
    """Prior and previous-hour-bucket forecasts, fitted on the training rounds only."""

    def __init__(self, y, lag_bucket):
        self.prior = np.bincount(y, minlength=cm.BUCKETS) / len(y)
        same = float((lag_bucket == y).mean())
        # smoothed one-hot (1 - eps) * onehot + eps / 5; the train log loss is minimal where
        # 1 - eps + eps / 5 equals the training hit rate
        self.eps = min(1.0, (1 - same) * cm.BUCKETS / (cm.BUCKETS - 1))
        counts = np.ones((cm.BUCKETS, cm.BUCKETS))  # add-one smoothing
        np.add.at(counts, (lag_bucket, y), 1)
        self.transition = counts / counts.sum(axis=1, keepdims=True)

    def predict(self, lag_bucket):
        n = len(lag_bucket)
        onehot = np.full((n, cm.BUCKETS), self.eps / cm.BUCKETS)
        onehot[np.arange(n), lag_bucket] += 1 - self.eps
        return {
            "prior": np.tile(self.prior, (n, 1)),
            "lag_onehot": onehot,
            "lag_transition": self.transition[lag_bucket],
        }


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


def labels(s):
    return np.searchsorted(np.array(cm.BOUNDS), s.rv, side="right")


def lag_buckets(s):
    return np.searchsorted(np.array(cm.BOUNDS), s.lag_rv, side="right")


def inputs(s):
    return (s.x_int / cm.SCALE).astype(np.float32)


def fit(spec, real, synthetic, steps, seed):
    x, y = inputs(real), labels(real)
    if synthetic is not None:
        x, y = np.concatenate([x, synthetic[0]]), np.concatenate([y, synthetic[1]])
    return train(spec, x, y, steps, seed)


def evaluate(spec, p, s):
    prob = softmax(forward(spec, p, inputs(s))[0])
    return {"log_loss": round(log_loss(prob, labels(s)), 4),
            "accuracy": round(accuracy(prob, labels(s)), 4)}


def span(s):
    return {"rounds": len(s), "t_open_first": int(s.t_open.min()),
            "t_open_last": int(s.t_open.max())}


def split(samples, frac):
    tr, te = ds.time_split(samples.t_open, frac, ds.leak_gap())
    return samples.take(tr), samples.take(te)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grid", default=str(DEFAULT_GRID),
                    help="analysis' tick-cumulative grid CSV (vol_calibrate.py --export-grid)")
    ap.add_argument("--params", default=str(DEFAULT_PARAMS),
                    help="analysis' vol_params.json; its bounds must equal cm.BOUNDS")
    ap.add_argument("--steps", type=int, default=3000)
    a = ap.parse_args()
    params = json.loads(Path(a.params).read_text())
    if tuple(params["bounds"]) != cm.BOUNDS:
        raise SystemExit(f"{a.params} bounds {params['bounds']} != contract_math.BOUNDS")

    samples = ds.build_samples(ds.load_grid(a.grid), stride=STRIDE_S)
    trainval, test = split(samples, TEST_FRAC)
    fit_part, val = split(trainval, VAL_FRAC)
    n_syn = len(fit_part)
    syn = synth(n_syn, np.random.default_rng(SEED_SYNTH))

    selection = {}
    for i, spec in enumerate(SPECS):
        row = {}
        for tag, extra in (("real", None), ("real+synthetic", syn)):
            p = fit(spec, fit_part, extra, a.steps, SEED_MODEL + i)
            row[tag] = evaluate(spec, p, val)["log_loss"]
        selection[spec.name] = row
    mean = {tag: np.mean([r[tag] for r in selection.values()]) for tag in ("real", "real+synthetic")}
    augment = mean["real+synthetic"] < mean["real"]
    print(f"validation log loss {selection}; synthetic augmentation {'on' if augment else 'off'}")

    y_tr, y_te = labels(trainval), labels(test)
    base = Baselines(y_tr, lag_buckets(trainval))
    baselines = {k: {"log_loss": round(log_loss(v, y_te), 4), "accuracy": round(accuracy(v, y_te), 4)}
                 for k, v in base.predict(lag_buckets(test)).items()}
    raw = np.abs(samples.raw_diff)
    report = {
        "grid": Path(a.grid).name,
        "bounds": list(cm.BOUNDS),
        "bounds_source": {k: params[k] for k in ("method", "quantileLevels", "windows", "swapCount")},
        "lead_s": ds.LEAD_S, "stride_s": STRIDE_S, "leak_gap_s": ds.leak_gap(),
        "rounds": span(samples), "train": span(trainval), "test": span(test),
        "validation": {"fit": span(fit_part), "val": span(val), "log_loss": selection,
                       "synthetic_augmentation": bool(augment)},
        "bucket_share": {"train": np.round(base.prior, 4).tolist(),
                         "test": np.round(np.bincount(y_te, minlength=cm.BUCKETS) / len(y_te),
                                          4).tolist()},
        "clamp": {"features_clamped_share": round(float((raw > cm.CLAMP).mean()), 5),
                  "rounds_with_a_clamped_feature_share": round(
                      float((raw > cm.CLAMP).any(axis=1).mean()), 5),
                  "abs_diff_p50_p99_max": [int(np.percentile(raw, 50)),
                                           int(np.percentile(raw, 99)), int(raw.max())]},
        "baseline_lag_onehot_eps": round(base.eps, 4),
        "test_baselines": baselines,
        "models": {},
    }

    syn_full = synth(len(trainval), np.random.default_rng(SEED_SYNTH)) if augment else None
    edge = np.random.default_rng(SEED_EDGE).uniform(-2, 2, (32, cm.N_FEATURES)).astype(np.float32)
    # real rounds across the magnitude range of the training part, plus the full input range, so
    # the calibrated ranges cover any round
    order = np.argsort(np.abs(trainval.raw_diff).sum(axis=1))
    cal = np.concatenate([inputs(trainval)[order[np.linspace(0, len(order) - 1, 32).astype(int)]],
                          edge])
    for i, spec in enumerate(SPECS):
        p = fit(spec, trainval, syn_full, a.steps, SEED_MODEL + i)
        res = evaluate(spec, p, test)
        d = MODELS / spec.name
        d.mkdir(parents=True, exist_ok=True)
        onnx.save(to_onnx(spec, p), d / "model.onnx")
        (d / "settings.json").unlink(missing_ok=True)  # calibrated for the previous weights
        meta = {
            "name": spec.name,
            "description": spec.description,
            "params": int(sum(v.size for v in p.values())),
            "bounds": list(cm.BOUNDS),
            "test_log_loss": res["log_loss"],
            "test_accuracy": res["accuracy"],
            "test_baselines": baselines,
            "logit_clip": LOGIT_CLIP,
            "onnx_sha256": hashlib.sha256((d / "model.onnx").read_bytes()).hexdigest(),
            "train": {"rounds": len(trainval), "synthetic_rounds": 0 if syn_full is None
                      else len(syn_full[1]), "test_rounds": len(test), "steps": a.steps,
                      "l2": L2, "seed": SEED_MODEL + i},
        }
        (d / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        (d / "cal.json").write_text(json.dumps({"input_data": [cal.reshape(-1).tolist()]}))
        report["models"][spec.name] = res
        print(json.dumps(meta))

    (MODELS / "eval.json").write_text(json.dumps(report, indent=2) + "\n")
    keep = np.arange(len(test)) % HOLDOUT_EVERY == 0
    held = test.take(keep)
    HOLDOUT.parent.mkdir(parents=True, exist_ok=True)
    HOLDOUT.write_text(json.dumps({
        "description": "every 5th held-out test round (contract features / MULT, bucket, "
                       "previous-hour bucket) and the training-part baselines; written by "
                       "vol_agents.train",
        "bounds": list(cm.BOUNDS),
        "prior": base.prior.tolist(),
        "lag_transition": base.transition.tolist(),
        "features": (held.x_int // cm.MULT).tolist(),
        "bucket": labels(held).tolist(),
        "lag_bucket": lag_buckets(held).tolist(),
    }, separators=(",", ":")) + "\n")
    print(json.dumps({k: report[k] for k in ("rounds", "clamp", "test_baselines", "models")}))


if __name__ == "__main__":
    main()
