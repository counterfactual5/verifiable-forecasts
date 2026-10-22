"""Train the three forecasting models with numpy on real pool history and export them as ONNX
(opset 13, Softmax output).

Samples come from dataset.build_samples over the tick-cumulative grid that analysis/ exports from
Uniswap V3 Swap logs: the 16 features exactly as VolMarket computes them at createRound, and the
realized-vol bucket of the hour that starts LEAD_S later, under cm.BOUNDS.

Split: chronological at two cut timestamps, never shuffled: train before TRAIN_END, validation up
to TEST_START, test after it (dataset.split_by_time drops every round whose read span straddles a
cut). The bounds must come from the training period only: --params is analysis' vol_params.json
written with `--until TRAIN_END`, and its bounds must equal cm.BOUNDS. Validation only decides
whether synthetic random-walk rounds are added as augmentation; the final models are fit on the
training period and scored once on the test period.

Baselines, fitted on the training period: the uniform forecast (log score ln 0.2), the empirical
bucket frequencies, and the bucket of the previous hour's realized vol (smoothed one-hot and an
empirical transition matrix).

Usage: uv run python -m vol_agents.train [--grid PATH] [--params PATH] [--steps N]
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
from .api_agent import PLACEHOLDER_LEVELS, placeholder_quantiles, probs_from_quantiles

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "models"
HOLDOUT = ROOT / "tests" / "fixtures" / "real_holdout.json"
DEFAULT_GRID = ROOT.parent / "analysis" / "data" / "tick_cumulative_grid.csv"
DEFAULT_PARAMS = ROOT.parent / "analysis" / "data" / "train" / "vol_params.json"
L2 = 1e-6
# Logits are clipped to [-LOGIT_CLIP, LOGIT_CLIP] in the model: the Softmax exp lookup then spans
# at most 2 * LOGIT_CLIP at scale 2^12 for any input, which keeps every circuit at logrows 15.
LOGIT_CLIP = 3.0
LEAK = 0.05  # gradient through the clip when saturated, so saturated samples still train
TRAIN_END = 1791417600  # 2026-10-08 00:00 UTC
TEST_START = 1792022400  # 2026-10-15 00:00 UTC
STRIDE_S = 60
HOLDOUT_STRIDE_S = 3600  # the committed fixture keeps one test round per hour
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


def scores(prob, y):
    """Mean log score (the contract's ln p_win, higher is better), accuracy, mean forecast."""
    return {"log_score": round(-log_loss(prob, y), 4), "accuracy": round(accuracy(prob, y), 4),
            "mean_probs": np.round(prob.mean(axis=0), 4).tolist()}


def utc(t):
    return np.datetime_as_string(np.datetime64(int(t), "s")) + "Z"


def span(s):
    return {"rounds": len(s), "t_open_first": utc(s.t_open.min()),
            "t_open_last": utc(s.t_open.max())}


def shares(y):
    return np.round(np.bincount(y, minlength=cm.BUCKETS) / len(y), 4).tolist()


def placeholder_scale(s):
    """Quantiles of next-hour RV over the trailing RV the commit-only placeholder reads
    (api_agent.trailing_realized_vol, from the clamped features)."""
    diffs = s.x_int[:, -(cm.N_SEGMENTS - 1):] // cm.MULT
    trailing = np.maximum((diffs * diffs).sum(axis=1), 1)
    return [round(float(np.quantile(s.rv / trailing, q)), 2) for q in PLACEHOLDER_LEVELS]


def placeholder_probs(s):
    """The commit-only agent's placeholder forecast (api_agent.PLACEHOLDER_SCALE)."""
    out = [probs_from_quantiles(*placeholder_quantiles(x.tolist()), cm.BOUNDS) for x in s.x_int]
    return np.array(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grid", default=str(DEFAULT_GRID),
                    help="analysis' tick-cumulative grid CSV (vol_calibrate.py --export-grid)")
    ap.add_argument("--params", default=str(DEFAULT_PARAMS),
                    help="analysis' vol_params.json written with --until TRAIN_END")
    ap.add_argument("--steps", type=int, default=3000)
    a = ap.parse_args()
    params = json.loads(Path(a.params).read_text())
    if tuple(params["bounds"]) != cm.BOUNDS:
        raise SystemExit(f"{a.params} bounds {params['bounds']} != contract_math.BOUNDS")
    if params.get("until") != TRAIN_END:
        raise SystemExit(f"{a.params} was not calibrated on the training period (--until "
                         f"{TRAIN_END}), got until={params.get('until')}")

    samples = ds.build_samples(ds.load_grid(a.grid), stride=STRIDE_S)
    tr_mask, val_mask, te_mask = ds.split_by_time(samples.t_open, [TRAIN_END, TEST_START])
    trn, val, test = samples.take(tr_mask), samples.take(val_mask), samples.take(te_mask)
    syn = synth(len(trn), np.random.default_rng(SEED_SYNTH))

    selection = {}
    for i, spec in enumerate(SPECS):
        selection[spec.name] = {
            tag: scores(softmax(forward(spec, fit(spec, trn, extra, a.steps, SEED_MODEL + i),
                                        inputs(val))[0]), labels(val))["log_score"]
            for tag, extra in (("real", None), ("real+synthetic", syn))}
    tags = ("real", "real+synthetic")
    mean = {tag: np.mean([r[tag] for r in selection.values()]) for tag in tags}
    augment = bool(mean["real+synthetic"] > mean["real"])
    print(f"validation log score {selection}; synthetic augmentation {'on' if augment else 'off'}")

    y_te = labels(test)
    base = Baselines(labels(trn), lag_buckets(trn))
    scale = placeholder_scale(trn)
    forecasts = {"uniform": np.full((len(test), cm.BUCKETS), 1 / cm.BUCKETS),
                 **{f"train_{k}": v for k, v in base.predict(lag_buckets(test)).items()},
                 "commit_only_placeholder": placeholder_probs(test)}
    baselines = {k: scores(v, y_te) for k, v in forecasts.items()}
    raw = np.abs(samples.raw_diff)
    report = {
        "grid": Path(a.grid).name,
        "bounds": list(cm.BOUNDS),
        "bounds_source": {k: params.get(k) for k in ("method", "quantileLevels", "windows",
                                                      "swapCount", "until")},
        "lead_s": ds.LEAD_S, "stride_s": STRIDE_S,
        "cuts": {"train_end": utc(TRAIN_END), "test_start": utc(TEST_START)},
        "rounds": span(samples), "train": span(trn), "validation": span(val), "test": span(test),
        "selection": {"validation_log_score": selection, "synthetic_augmentation": augment},
        "bucket_share": {"train": shares(labels(trn)), "validation": shares(labels(val)),
                         "test": shares(y_te)},
        "clamp": {"features_clamped_share": round(float((raw > cm.CLAMP).mean()), 5),
                  "rounds_with_a_clamped_feature_share": round(
                      float((raw > cm.CLAMP).any(axis=1).mean()), 5),
                  "abs_diff_p50_p99_max": [int(np.percentile(raw, 50)),
                                           int(np.percentile(raw, 99)), int(raw.max())]},
        "baseline_lag_onehot_eps": round(base.eps, 4),
        "placeholder_scale": scale,
        "test_baselines": baselines,
        "models": {},
    }

    syn_fit = syn if augment else None
    edge = np.random.default_rng(SEED_EDGE).uniform(-2, 2, (32, cm.N_FEATURES)).astype(np.float32)
    # real rounds across the magnitude range of the training period, plus the full input range, so
    # the calibrated ranges cover any round
    order = np.argsort(np.abs(trn.raw_diff).sum(axis=1))
    cal = np.concatenate([inputs(trn)[order[np.linspace(0, len(order) - 1, 32).astype(int)]],
                          edge])
    for i, spec in enumerate(SPECS):
        p = fit(spec, trn, syn_fit, a.steps, SEED_MODEL + i)
        res = scores(softmax(forward(spec, p, inputs(test))[0]), y_te)
        d = MODELS / spec.name
        d.mkdir(parents=True, exist_ok=True)
        onnx.save(to_onnx(spec, p), d / "model.onnx")
        (d / "settings.json").unlink(missing_ok=True)  # calibrated for the previous weights
        meta = {
            "name": spec.name,
            "description": spec.description,
            "params": int(sum(v.size for v in p.values())),
            "bounds": list(cm.BOUNDS),
            "test_log_score": res["log_score"],
            "test_accuracy": res["accuracy"],
            "test_period": report["test"],
            "logit_clip": LOGIT_CLIP,
            "onnx_sha256": hashlib.sha256((d / "model.onnx").read_bytes()).hexdigest(),
            "train": {"period": report["train"], "synthetic_rounds": 0 if syn_fit is None
                      else len(syn_fit[1]), "steps": a.steps, "l2": L2, "seed": SEED_MODEL + i},
        }
        (d / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        (d / "cal.json").write_text(json.dumps({"input_data": [cal.reshape(-1).tolist()]}))
        report["models"][spec.name] = res
        print(json.dumps(meta))

    (MODELS / "eval.json").write_text(json.dumps(report, indent=2) + "\n")
    held = test.take((test.t_open - test.t_open.min()) % HOLDOUT_STRIDE_S == 0)
    HOLDOUT.parent.mkdir(parents=True, exist_ok=True)
    HOLDOUT.write_text(json.dumps({
        "description": "one held-out test round per hour (contract features / MULT, bucket, "
                       "previous-hour bucket) and the training-period baselines; written by "
                       "vol_agents.train",
        "bounds": list(cm.BOUNDS),
        "test_period": report["test"],
        "prior": base.prior.tolist(),
        "lag_transition": base.transition.tolist(),
        "features": (held.x_int // cm.MULT).tolist(),
        "bucket": labels(held).tolist(),
        "lag_bucket": lag_buckets(held).tolist(),
    }, separators=(",", ":")) + "\n")
    print(json.dumps({k: report[k] for k in ("bucket_share", "clamp", "test_baselines",
                                              "models")}, indent=1))


if __name__ == "__main__":
    main()
