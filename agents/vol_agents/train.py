"""Train the three forecasting models with numpy on real pool history and export them as ONNX
(opset 13, K quantiles of y = ln(max(RV, 1)) at cm.QUANTILE_LEVELS).

Samples come from dataset.build_samples over the tick-cumulative grid that analysis/ exports from
Uniswap V3 Swap logs: the 16 features exactly as VolMarket computes them at createRound, and the
realized vol of the hour that starts LEAD_S later; the target is y = cm.ln_rv(rv).

Every model ends in the monotone head q_1 = a_1, q_k = q_{k-1} + relu(a_k) + HEAD_GAP, so the K
outputs are strictly increasing in the circuit too: HEAD_GAP is two steps of the 2^-12 output grid,
which survives EZKL's rounding of each term. The loss is the mean pinball loss over the levels, the
same quantity VolMarket scores (cm.pinball / cm.pinball_e18).

Split: chronological at two cut timestamps, never shuffled: train before TRAIN_END, validation up
to TEST_START, test after it (dataset.split_by_time drops every round whose read span straddles a
cut). The models are fit on the training period only and scored once on validation and test.

Baselines: the climatological quantiles that createRound carries (models/baseline_quantiles.json,
training windows only) and the previous hour's y plus training-period residual quantiles.

Usage: uv run python -m vol_agents.train [--grid PATH] [--steps N]
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
BASELINE = MODELS / "baseline_quantiles.json"
HOLDOUT = ROOT / "tests" / "fixtures" / "real_holdout.json"
DEFAULT_GRID = ROOT.parent / "analysis" / "data" / "tick_cumulative_grid.csv"
L2 = 1e-6
HEAD_GAP = 2 / 2**cm.OUTPUT_SCALE_BITS  # ln units; 2 output grid steps between adjacent quantiles
LEAK = 0.01  # training-only gradient through a closed head relu, so a gap can reopen
TRAIN_END = 1791417600  # 2026-10-08 00:00 UTC
TEST_START = 1792022400  # 2026-10-15 00:00 UTC
STRIDE_S = 60
HOLDOUT_STRIDE_S = 3600  # the committed fixture keeps one test round per hour
SEED_SYNTH, SEED_MODEL, SEED_EDGE = 7, 100, 9
LEVELS = np.array(cm.QUANTILE_LEVELS)


@dataclass(frozen=True)
class Spec:
    name: str
    abs_input: bool  # |x| before the first layer (volatility depends on magnitude, not sign)
    hidden: int  # 0 = linear
    description: str


SPECS = [
    Spec("linear_abs", True, 0, "W |x| + b -> monotone quantile head"),
    Spec("mlp16", False, 16, "16->16 ReLU->5 -> monotone quantile head, signed features"),
    Spec("mlp32_abs", True, 32, "|x| -> 32 ReLU -> 5 -> monotone quantile head"),
]


def synth(n, rng, bounds=cm.BOUNDS):
    """Random-walk rounds in contract units: per-round volatility sigma (ticks per segment-mean
    difference) log-uniform over the real range, window volatility sigma * exp(N(0, 0.3^2)).
    Returns model input x, bucket labels, contract features x_int and the 11 window differences."""
    sigma = np.exp(rng.uniform(np.log(2.0), np.log(40.0), n))
    sigma_w = sigma * np.exp(rng.normal(0.0, 0.3, n))
    hist = np.rint(rng.normal(0.0, 1.0, (n, cm.N_FEATURES)) * sigma[:, None]).astype(np.int64)
    win = np.rint(rng.normal(0.0, 1.0, (n, cm.N_SEGMENTS - 1)) * sigma_w[:, None]).astype(np.int64)
    x_int = np.clip(hist, -cm.CLAMP, cm.CLAMP) * cm.MULT
    rv = (win * win).sum(axis=1)
    y = np.searchsorted(np.array(bounds), rv, side="right")
    return (x_int / cm.SCALE).astype(np.float32), y, x_int, win


def head_init(base_q):
    """Pre-head biases that reproduce the given increasing quantiles."""
    a = np.empty(cm.K)
    a[0] = base_q[0]
    a[1:] = np.maximum(np.diff(base_q) - HEAD_GAP, 1e-3)
    return a


def init_params(spec, rng, x_rms, base_q):
    d_in = cm.N_FEATURES
    w_std = 0.1 / (x_rms * np.sqrt(d_in))
    if spec.hidden == 0:
        return {"W": rng.normal(0, w_std, (cm.K, d_in)), "b": head_init(base_q)}
    return {
        "W1": rng.normal(0, 1.0 / (x_rms * np.sqrt(d_in)), (spec.hidden, d_in)),
        "b1": rng.normal(0, 0.1, spec.hidden),
        "W2": rng.normal(0, 0.1 / np.sqrt(spec.hidden), (cm.K, spec.hidden)),
        "b2": head_init(base_q),
    }


def head(a):
    q = np.empty_like(a)
    q[:, 0] = a[:, 0]
    q[:, 1:] = np.cumsum(np.maximum(a[:, 1:], 0) + HEAD_GAP, axis=1)
    q[:, 1:] += a[:, :1]
    return q


def forward(spec, p, x):
    """Quantiles (n, K) and the cache for the backward pass."""
    a_in = np.abs(x) if spec.abs_input else x
    if spec.hidden == 0:
        a = a_in @ p["W"].T + p["b"]
        return head(a), (a, a_in)
    h = a_in @ p["W1"].T + p["b1"]
    hr = np.maximum(h, 0)
    a = hr @ p["W2"].T + p["b2"]
    return head(a), (a, a_in, h, hr)


def pinball(q, y):
    """Mean pinball loss per sample (n,) at LEVELS, float."""
    u = y[:, None] - q
    return (np.maximum(LEVELS * u, (LEVELS - 1) * u)).mean(axis=1)


def loss_grad(spec, p, x, y):
    q, cache = forward(spec, p, x)
    n = len(y)
    loss = float(pinball(q, y).mean())
    dq = ((y[:, None] < q).astype(float) - LEVELS) / (cm.K * n)
    a = cache[0]
    tail = np.cumsum(dq[:, ::-1], axis=1)[:, ::-1]  # sum over k >= j of dq_k
    da = np.empty_like(a)
    da[:, 0] = tail[:, 0]
    da[:, 1:] = tail[:, 1:] * np.where(a[:, 1:] > 0, 1.0, LEAK)
    g = {}
    if spec.hidden == 0:
        g["W"] = da.T @ cache[1]
        g["b"] = da.sum(0)
    else:
        _, a_in, h, hr = cache
        g["W2"] = da.T @ hr
        g["b2"] = da.sum(0)
        dh = (da @ p["W2"]) * (h > 0)
        g["W1"] = dh.T @ a_in
        g["b1"] = dh.sum(0)
    for k in g:
        if k.startswith("W"):
            loss += 0.5 * L2 * float((p[k] ** 2).sum())
            g[k] += L2 * p[k]
    return loss, g


def train(spec, x, y, steps, seed, base_q):
    rng = np.random.default_rng(seed)
    p = init_params(spec, rng, float(np.sqrt(np.mean(x**2))), base_q)
    m = {k: np.zeros_like(v) for k, v in p.items()}
    v = {k: np.zeros_like(val) for k, val in p.items()}
    lr, b1, b2 = 0.02, 0.9, 0.999
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
        nodes.append(helper.make_node("Gemm", [cur, "W", "b"], ["a"], transB=1))
        inits = [("W", f32["W"]), ("b", f32["b"])]
    else:
        nodes += [
            helper.make_node("Gemm", [cur, "W1", "b1"], ["h"], transB=1),
            helper.make_node("Relu", ["h"], ["hr"]),
            helper.make_node("Gemm", ["hr", "W2", "b2"], ["a"], transB=1),
        ]
        inits = [(k, f32[k]) for k in ("W1", "b1", "W2", "b2")]
    # head: y = a @ FIRST + relu(a) @ CUM + GAPS, FIRST copies a_1 to every column, CUM[j, k] = 1
    # for 1 <= j <= k sums the opened gaps, GAPS[k] = k * HEAD_GAP
    first = np.zeros((cm.K, cm.K), np.float32)
    first[0, :] = 1
    cum = np.triu(np.ones((cm.K, cm.K), np.float32))
    cum[0, :] = 0
    gaps = (np.arange(cm.K) * HEAD_GAP).astype(np.float32)[None]
    nodes += [
        helper.make_node("Relu", ["a"], ["ar"]),
        helper.make_node("MatMul", ["a", "first"], ["base"]),
        helper.make_node("MatMul", ["ar", "cum"], ["open"]),
        helper.make_node("Add", ["base", "open"], ["q0"]),
        helper.make_node("Add", ["q0", "gaps"], ["y"]),
    ]
    inits += [("first", first), ("cum", cum), ("gaps", gaps)]
    graph = helper.make_graph(
        nodes,
        f"ln_rv_quantiles_{spec.name}",
        [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, cm.N_FEATURES])],
        [helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, cm.K])],
        initializer=[numpy_helper.from_array(a, n) for n, a in inits],
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
    model.ir_version = 8
    onnx.checker.check_model(model)
    return model


def targets(s):
    return np.log(np.maximum(s.rv, cm.RV_FLOOR)).astype(float)


def lag_targets(s):
    return np.log(np.maximum(s.lag_rv, cm.RV_FLOOR)).astype(float)


def inputs(s):
    return (s.x_int / cm.SCALE).astype(np.float32)


def load_baseline(path=BASELINE):
    b = json.loads(Path(path).read_text())
    if [int(v) for v in b["levels_e18"]] != list(cm.QUANTILE_LEVELS_E18):
        raise SystemExit(f"{path}: levels {b['levels_e18']} != {cm.QUANTILE_LEVELS_E18}")
    if b.get("until") != TRAIN_END:
        raise SystemExit(f"{path}: not fitted on the training period (until {b.get('until')})")
    return np.array([int(v) for v in b["quantiles_e18"]]) / cm.WAD


def scores(q, y):
    """Mean pinball loss (float, ln units; lower is better) and interval coverage."""
    return {"mean_pinball": round(float(pinball(q, y).mean()), 5),
            "coverage50": round(float(((y >= q[:, 1]) & (y <= q[:, 3])).mean()), 4),
            "coverage80": round(float(((y >= q[:, 0]) & (y <= q[:, 4])).mean()), 4),
            "mean_quantiles": np.round(q.mean(axis=0), 4).tolist()}


def utc(t):
    return np.datetime_as_string(np.datetime64(int(t), "s")) + "Z"


def span(s):
    return {"rounds": len(s), "t_open_first": utc(s.t_open.min()),
            "t_open_last": utc(s.t_open.max())}


def baseline_forecasts(trn, s, base_q):
    resid = targets(trn) - lag_targets(trn)
    lag_q = np.quantile(resid, LEVELS)
    return {"climatological": np.tile(base_q, (len(s), 1)),
            "train_lag_residual": lag_targets(s)[:, None] + lag_q[None]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grid", default=str(DEFAULT_GRID),
                    help="analysis' tick-cumulative grid CSV (vol_calibrate.py --export-grid)")
    ap.add_argument("--baseline", default=str(BASELINE))
    ap.add_argument("--steps", type=int, default=3000)
    a = ap.parse_args()
    base_q = load_baseline(a.baseline)

    samples = ds.build_samples(ds.load_grid(a.grid), stride=STRIDE_S)
    tr_mask, val_mask, te_mask = ds.split_by_time(samples.t_open, [TRAIN_END, TEST_START])
    trn, val, test = samples.take(tr_mask), samples.take(val_mask), samples.take(te_mask)
    y_tr, y_val, y_te = targets(trn), targets(val), targets(test)

    report = {
        "grid": Path(a.grid).name,
        "target": "y = ln(max(RV, 1)), RV in tick^2",
        "quantile_levels": list(cm.QUANTILE_LEVELS),
        "loss": "mean pinball over the levels (ln units, lower is better)",
        "lead_s": ds.LEAD_S, "stride_s": STRIDE_S,
        "cuts": {"train_end": utc(TRAIN_END), "test_start": utc(TEST_START)},
        "rounds": span(samples), "train": span(trn), "validation": span(val), "test": span(test),
        "baseline_quantiles": np.round(base_q, 6).tolist(),
        "validation_baselines": {k: scores(v, y_val)
                                 for k, v in baseline_forecasts(trn, val, base_q).items()},
        "test_baselines": {k: scores(v, y_te)
                           for k, v in baseline_forecasts(trn, test, base_q).items()},
        "models": {},
        "validation_models": {},
    }

    edge = np.random.default_rng(SEED_EDGE).uniform(-2, 2, (32, cm.N_FEATURES)).astype(np.float32)
    # real rounds across the magnitude range of the training period, plus the full input range, so
    # the calibrated ranges cover any round
    order = np.argsort(np.abs(trn.raw_diff).sum(axis=1))
    cal = np.concatenate([inputs(trn)[order[np.linspace(0, len(order) - 1, 32).astype(int)]],
                          edge])
    for i, spec in enumerate(SPECS):
        p = train(spec, inputs(trn), y_tr, a.steps, SEED_MODEL + i, base_q)
        res = scores(forward(spec, p, inputs(test))[0], y_te)
        report["validation_models"][spec.name] = scores(forward(spec, p, inputs(val))[0], y_val)
        d = MODELS / spec.name
        d.mkdir(parents=True, exist_ok=True)
        onnx.save(to_onnx(spec, p), d / "model.onnx")
        (d / "settings.json").unlink(missing_ok=True)  # calibrated for the previous weights
        meta = {
            "name": spec.name,
            "description": spec.description,
            "params": int(sum(v.size for v in p.values())),
            "quantile_levels": list(cm.QUANTILE_LEVELS),
            "output_scale_bits": cm.OUTPUT_SCALE_BITS,
            "head_gap": HEAD_GAP,
            "test_mean_pinball": res["mean_pinball"],
            "test_coverage50": res["coverage50"],
            "test_coverage80": res["coverage80"],
            "test_period": report["test"],
            "onnx_sha256": hashlib.sha256((d / "model.onnx").read_bytes()).hexdigest(),
            "train": {"period": report["train"], "steps": a.steps, "l2": L2,
                      "seed": SEED_MODEL + i},
        }
        (d / "meta.json").write_text(json.dumps(meta, indent=2) + "\n")
        (d / "cal.json").write_text(json.dumps({"input_data": [cal.reshape(-1).tolist()]}))
        report["models"][spec.name] = res
        print(json.dumps(meta))

    (MODELS / "eval.json").write_text(json.dumps(report, indent=2) + "\n")
    held = test.take((test.t_open - test.t_open.min()) % HOLDOUT_STRIDE_S == 0)
    HOLDOUT.parent.mkdir(parents=True, exist_ok=True)
    HOLDOUT.write_text(json.dumps({
        "description": "one held-out test round per hour (contract features / MULT, realized "
                       "vol, previous-hour realized vol) and the climatological baseline "
                       "quantiles; written by vol_agents.train",
        "quantile_levels": list(cm.QUANTILE_LEVELS),
        "baseline_quantiles": base_q.tolist(),
        "test_period": report["test"],
        "features": (held.x_int // cm.MULT).tolist(),
        "rv": held.rv.tolist(),
        "lag_rv": held.lag_rv.tolist(),
    }, separators=(",", ":")) + "\n")
    print(json.dumps({k: report[k] for k in ("test_baselines", "models", "validation_baselines",
                                              "validation_models")}, indent=1))


if __name__ == "__main__":
    main()
