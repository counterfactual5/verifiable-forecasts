"""inference /forecast request and the post-processing from per-step quantiles to bucket
probabilities, shared by the API agents and the local recompute of the reproducible ones.

The 16 contract features (differences of Δ-second mean ticks, / 128) go out as one series; the model
returns quantiles of each next difference. Each window difference is drawn independently from its
quantiles (summing per-step quantiles instead underestimates the level and makes the distribution
U-shaped), scaled by the model's spread, squared and summed into realized vol, and the draws are
histogrammed into the round's buckets and mixed with uniform. A fixed seed makes the probabilities
a pure function of the API answer.

The bytes of this file are part of a reproducible model's hash (model_hash), so any change to the
request or the post-processing changes the registered model.
"""

import hashlib
import json
import math
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import contract_math as cm
from .chain import keccak

# Interval levels asked for: with the median they cover the 21 native quantiles of most models
# (0.01, 0.05, 0.1 .. 0.9 step 0.05, 0.95, 0.99); models with fewer levels answer the nearest.
LEVELS = (98, 90, 80, 70, 60, 50, 40, 30, 20, 10)
MC_DRAWS = 4000
MC_SEED = 0
MC_PROB_FLOOR = 1e-4
# Weight of the uniform distribution mixed into every forecast so no bucket collapses. Chosen on
# the validation period 2026-10-08 .. 10-15 (165 hourly rounds): mixes of 0.05-0.1 scored below
# uniform there for timesfm-3.0 and timestral-209m (draws from 16-point contexts miss often).
UNIFORM_MIX = 0.3
REPRODUCIBLE, COMMIT_ONLY = "reproducible", "commit-only"


@dataclass(frozen=True)
class TsfmModel:
    model: str  # inference model id
    agent_name: str
    weights: str  # public weights "hf_repo@revision"; "" when closed
    license: str
    # Scale on the sampled differences (realized vol scales by spread^2): per-step quantiles from
    # 16 points are far too wide. Chosen on the validation period with UNIFORM_MIX fixed.
    spread: float
    # reproducible only where the public weights recompute the API's revealed vector bit for bit
    # on CPU (174/174 test rounds for timesfm-3.0; chronos-2 173/174; timestral-209m unchecked)
    tier: str


MODELS = {m.model: m for m in (
    TsfmModel("timesfm-3.0", "agent-timesfm3",
                 "google/timesfm-3.0-pytorch@43046b85ec22d584a13f8098c2ed39c889e129c2",
                 "TimesFM-NC-1.0", 0.5, REPRODUCIBLE),
    TsfmModel("timestral-209m", "agent-timestral", "mistralai/Timestral-209M@9874d252ab0aae16",
                 "Mistral-Modified-MIT", 0.5, COMMIT_ONLY),
    TsfmModel("chronos-2", "agent-chronos",
                 "amazon/chronos-2@29ec3766d36d6f73f0696f85560a422f50e8498c", "Apache-2.0", 0.35,
                 COMMIT_ONLY),
    TsfmModel("remote-model", "agent-remote", "", "Proprietary", 0.5, COMMIT_ONLY),
)}
DEFAULT_MODELS = ("timesfm-3.0", "timestral-209m", "chronos-2")


def spec(model: str) -> TsfmModel:
    """Known models as listed; any other inference id runs commit-only at the median spread."""
    return MODELS.get(model) or TsfmModel(model, f"agent-{model}", "", "unknown", 0.5,
                                             COMMIT_ONLY)


def iso(t: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def horizon(n_segments: int) -> int:
    """Rounds open one segment before their start (demo/fork_round.py), so after the last feature
    one difference is skipped and the window's n_segments - 1 differences follow it."""
    return n_segments + 1


def context(features) -> list[int]:
    return [x // cm.MULT for x in features]


def build_request(features, round_info, model: str) -> dict:
    """/forecast body: the feature differences in ticks as one series whose last point is the
    createRound segment ending at start - delta, forecast up to the window's last difference."""
    delta = round_info["delta_s"]
    diffs = context(features)
    last = round_info["start"] - delta
    freq = f"{delta // 60}min" if delta % 60 == 0 else f"{delta}s"
    uid = f"round-{round_info['id']}"
    return {
        "model": model,
        "series": [{"unique_id": uid, "ds": iso(last - delta * (len(diffs) - 1 - i)),
                    "y": float(d)} for i, d in enumerate(diffs)],
        "h": horizon(round_info["n_segments"]),
        "freq": freq,
        "level": list(LEVELS),
        # raw: the differences are already on a regular grid; cleaning would damp real jumps
        "options": {"cleaning": {"preset": "raw"}},
    }


def step_quantiles(resp: dict) -> tuple[list[float], list[list[float]]]:
    """(levels, per-step values) from a /forecast answer, steps in time order."""
    rows = sorted(resp["forecast"], key=lambda p: p["ds"])
    if not rows:
        raise ValueError("inference answer has no forecast rows")
    per_step = []
    for p in rows:
        q = {0.5: float(p["y_hat"])}
        for k, iv in p.get("intervals", {}).items():
            half = float(k) / 200
            q[round(0.5 - half, 6)] = float(iv["lo"])
            q[round(0.5 + half, 6)] = float(iv["hi"])
        per_step.append(q)
    levels = sorted(per_step[0])
    if len(levels) < 3 or any(sorted(q) != levels for q in per_step):
        raise ValueError("inference answer needs the same intervals on every step")
    return levels, [[q[lv] for lv in levels] for q in per_step]


def sample_quantiles(levels, values, u):
    """Inverse CDF through the quantiles at u in (0, 1): linear between them, exponential tails
    through the two outermost quantiles on each side. Crossing quantiles are sorted first."""
    q = np.asarray(levels, float)
    v = np.sort(np.asarray(values, float))
    x = np.interp(u, q, v)
    lo, hi = u < q[0], u > q[-1]
    t_lo = max((v[1] - v[0]) / math.log(q[1] / q[0]), 1e-9)
    t_hi = max((v[-1] - v[-2]) / math.log((1 - q[-2]) / (1 - q[-1])), 1e-9)
    x[lo] = v[0] - t_lo * np.log(q[0] / u[lo])
    x[hi] = v[-1] + t_hi * np.log((1 - q[-1]) / (1 - u[hi]))
    return x


def probs_from_step_quantiles(levels, steps, bounds, n_diffs, spread=1.0, mix=0.0,
                              draws=MC_DRAWS, seed=MC_SEED) -> list[float]:
    """Bucket probabilities of RV = sum of the last n_diffs steps squared, each drawn independently
    from its quantiles and scaled by spread, then mixed with uniform by weight mix."""
    if len(steps) < n_diffs:
        raise ValueError(f"need {n_diffs} forecast steps, got {len(steps)}")
    u = np.random.default_rng(seed).random((n_diffs, draws))
    rv = np.zeros(draws)
    for k, s in enumerate(steps[-n_diffs:]):
        rv += (spread * sample_quantiles(levels, s, u[k])) ** 2
    b = np.searchsorted(np.asarray(bounds, float), rv, side="right")
    p = np.maximum(np.bincount(b, minlength=cm.BUCKETS) / draws, MC_PROB_FLOOR)
    p = p / p.sum()
    return [float((1 - mix) * v + mix / cm.BUCKETS) for v in p]


def probs(levels, steps, bounds, n_segments: int, model: str) -> list[float]:
    return probs_from_step_quantiles(levels, steps, bounds, n_segments - 1, spec(model).spread,
                                     UNIFORM_MIX)


def model_hash_preimage(model: str) -> dict:
    s = spec(model)
    if s.tier != REPRODUCIBLE:
        raise ValueError(f"{model} is {s.tier}: no public recompute to hash")
    return {
        "weights": s.weights,
        "tsfm_model": s.model,
        "inference": {"context": "16 contract features / 128, step delta", "freq": "5min",
                      "h": "nSegments + 1", "level": list(LEVELS), "cleaning": "raw",
                      "float": "float32"},
        "postprocess": {"spread": s.spread, "uniform_mix": UNIFORM_MIX, "draws": MC_DRAWS,
                        "seed": MC_SEED, "prob_floor": MC_PROB_FLOOR},
        "code_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }


def model_hash(model: str) -> str:
    """keccak256 of the canonical JSON preimage (sorted keys, no spaces), 0x-prefixed bytes32."""
    raw = json.dumps(model_hash_preimage(model), sort_keys=True, separators=(",", ":"))
    return keccak(raw.encode())
