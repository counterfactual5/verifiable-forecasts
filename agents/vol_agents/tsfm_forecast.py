"""Self-hosted inference /forecast request and the post-processing from per-step quantiles to bucket
probabilities, shared by the API agents and the local recompute of the reproducible ones.

The context (differences of Δ-second mean ticks: the 16 contract features / 128, or the long
off-chain series of history.round_context) goes out as one series; the model returns quantiles of
each next difference. Each window difference is drawn independently from its
quantiles (summing per-step quantiles instead underestimates the level and makes the distribution
U-shaped), scaled by the model's spread, squared and summed into realized vol, and the draws are
histogrammed into the round's buckets and mixed with uniform. A fixed seed makes the probabilities
a pure function of the API answer.

The bytes of this file and of tsfm_local.py (and history.py for a long-context model) are part of
a reproducible model's hash (model_hash), so any change to the request, the local inference or the
post-processing changes the registered model.
"""

import hashlib
import json
import math
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import contract_math as cm
from . import history
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
ONCHAIN, SWAPS = "onchain", "swaps"  # history.Context.source
# Long-context (spread, mix) for models without an entry in history.LONG_CONTEXT_CALIBRATION
DEFAULT_LONG_CALIBRATION = (0.8, 0.3)
# Reveal grid on the 1e18 probability scale: 1e15 = 1e-3. CPU float noise that moves one of the
# MC_DRAWS samples into another bucket shifts a probability by (1 - mix) / MC_DRAWS < 2.5e-4, so
# most recomputes reveal the very same integers.
PROB_QUANTUM = cm.PROB_SCALE // 1000
# A recompute passes when every bucket is within this of the reveal (1e18 scale, 1e15 = 1e-3):
# one grid step, as far as a near-tie in the rounding moves a bucket. The commitment still binds
# the revealed integers; only "revealed = what the public weights compute" is checked to it.
RECOMPUTE_TOLERANCE = PROB_QUANTUM
EXACT, TOLERANT, FAIL = "exact", "tolerant", "fail"


@dataclass(frozen=True)
class TsfmModel:
    model: str  # model id on the self-hosted inference service
    weights: str  # public weights "hf_repo@revision"; "" when closed
    license: str
    # Scale on the sampled differences (realized vol scales by spread^2): per-step quantiles from
    # 16 points are far too wide. Chosen on the validation period with UNIFORM_MIX fixed.
    spread: float
    # reproducible only where the public weights on CPU recompute the API's reveal within
    # RECOMPUTE_TOLERANCE on every checked round (MODEL_CARD 6.2)
    tier: str
    # Whether the agent sends history.round_context's long series. A reproducible one rebuilds it
    # from the pool's Swap logs alone (tsfm_recompute), so it is a function of chain data.
    long_context: bool

    @property
    def agent_name(self) -> str:
        return f"agent-{self.model}"


MODELS = {m.model: m for m in (
    TsfmModel("timesfm-3.0", "google/timesfm-3.0-pytorch@43046b85ec22d584a13f8098c2ed39c889e129c2",
              "TimesFM-NC-1.0", 0.5, REPRODUCIBLE, False),
    TsfmModel("timestral-209m", "mistralai/Timestral-209M@9874d252ab0aae16f7f7c999f98f98d6ad7d8365",
              "Mistral-Modified-MIT", 0.5, REPRODUCIBLE, True),
    TsfmModel("chronos-2", "amazon/chronos-2@29ec3766d36d6f73f0696f85560a422f50e8498c",
              "Apache-2.0", 0.35, REPRODUCIBLE, True),
)}
DEFAULT_MODELS = ("timesfm-3.0", "timestral-209m", "chronos-2")


def spec(model: str) -> TsfmModel:
    """Known models as listed; any other model id runs commit-only at the median spread."""
    return MODELS.get(model) or TsfmModel(model, "", "unknown", 0.5, COMMIT_ONLY, True)


def iso(t: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def horizon(n_segments: int) -> int:
    """Rounds open one segment before their start (demo/fork_round.py), so after the last feature
    one difference is skipped and the window's n_segments - 1 differences follow it."""
    return n_segments + 1


def context(features) -> list[int]:
    return [x // cm.MULT for x in features]


def calibration(model: str, source: str = ONCHAIN) -> tuple[float, float]:
    """(spread, uniform mix) for the context the forecast was made from."""
    if source == SWAPS:
        return history.LONG_CONTEXT_CALIBRATION.get(model, DEFAULT_LONG_CALIBRATION)
    return spec(model).spread, UNIFORM_MIX


def build_request(diffs, round_info, model: str) -> dict:
    """/forecast body: the context differences in ticks (oldest first) as one series whose last
    point is the createRound segment ending at start - delta, forecast up to the window's last
    difference."""
    delta = round_info["delta_s"]
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
        raise ValueError("forecast answer has no forecast rows")
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
        raise ValueError("forecast answer needs the same intervals on every step")
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


def probs(levels, steps, bounds, n_segments: int, model: str, source: str = ONCHAIN):
    scale, mix = calibration(model, source)
    return probs_from_step_quantiles(levels, steps, bounds, n_segments - 1, scale, mix)


def quantize_reveal(probs) -> list[int]:
    """1e18-scaled reveal on the PROB_QUANTUM grid that sums exactly to 1e18: largest remainder
    (ties to the lower bucket), then any empty bucket lifted to one step taken from the largest."""
    p = [float(v) for v in probs]
    if len(p) != cm.BUCKETS or any(not math.isfinite(v) or v < 0 for v in p) or sum(p) <= 0:
        raise ValueError(f"need {cm.BUCKETS} finite non-negative probabilities, got {probs}")
    total = cm.PROB_SCALE // PROB_QUANTUM
    scaled = [v / sum(p) * total for v in p]
    steps = [math.floor(v) for v in scaled]
    by_remainder = sorted(range(cm.BUCKETS), key=lambda i: (steps[i] - scaled[i], i))
    for i in by_remainder[:total - sum(steps)]:
        steps[i] += 1
    for i in range(cm.BUCKETS):
        if steps[i] == 0:
            steps[max(range(cm.BUCKETS), key=lambda j: (steps[j], -j))] -= 1
            steps[i] = 1
    return [k * PROB_QUANTUM for k in steps]


def compare_reveal(revealed, recomputed) -> tuple[int, str]:
    """(largest per-bucket |revealed - recomputed| on the 1e18 scale, EXACT | TOLERANT | FAIL)."""
    diff = max(abs(int(a) - int(b)) for a, b in zip(revealed, recomputed, strict=True))
    return diff, EXACT if diff == 0 else TOLERANT if diff <= RECOMPUTE_TOLERANCE else FAIL


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def model_hash_preimage(model: str) -> dict:
    s = spec(model)
    if s.tier != REPRODUCIBLE:
        raise ValueError(f"{model} is {s.tier}: no public recompute to hash")
    if s.long_context:
        ctx = {"source": "history.round_context over the pool Swap logs (ending at start - "
                         "delta), or its fallback, the 16 contract features / 128",
               "points": history.DEFAULT_CONTEXT,
               "history_sha256": _sha256(Path(history.__file__))}
    else:
        ctx = {"source": "16 contract features / 128", "points": 16}
    return {
        "weights": s.weights,
        "model": s.model,
        "inference": {"context": ctx, "step": "delta", "freq": "5min", "h": "nSegments + 1",
                      "level": list(LEVELS), "cleaning": "raw", "float": "float32"},
        "postprocess": {"spread": s.spread, "uniform_mix": UNIFORM_MIX,
                        "long_calibration": list(calibration(model, SWAPS)) if s.long_context
                        else None,
                        "draws": MC_DRAWS, "seed": MC_SEED, "prob_floor": MC_PROB_FLOOR,
                        "reveal_quantum": PROB_QUANTUM, "tolerance": RECOMPUTE_TOLERANCE},
        "code_sha256": _sha256(Path(__file__)),
        "local_runner_sha256": _sha256(Path(__file__).with_name("tsfm_local.py")),
    }


def model_hash(model: str) -> str:
    """keccak256 of the canonical JSON preimage (sorted keys, no spaces), 0x-prefixed bytes32."""
    raw = json.dumps(model_hash_preimage(model), sort_keys=True, separators=(",", ":"))
    return keccak(raw.encode())
