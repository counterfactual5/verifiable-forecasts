"""Self-hosted inference /forecast request and the post-processing from per-step quantiles to the
K quantiles of y = ln(max(RV, 1)) the market scores, shared by the API agents and the local
recompute of the reproducible ones.

The context (differences of Δ-second mean ticks: the 16 contract features / 128, or the long
off-chain series of history.round_context) goes out as one series; the model returns quantiles of
each next difference. Each window difference is drawn independently from its
quantiles (summing per-step quantiles instead underestimates the level and makes the distribution
U-shaped), scaled by the model's spread, squared and summed into realized vol per path; the
empirical quantiles of ln(max(RV_path, 1)) at the market's levels are quantized to the 2^-12
output grid. A fixed seed makes the reveal a pure function of the API answer.

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
REPRODUCIBLE, COMMIT_ONLY = "reproducible", "commit-only"
ONCHAIN, SWAPS = "onchain", "swaps"  # history.Context.source
# Long-context spread for models without an entry in history.LONG_CONTEXT_SPREAD
DEFAULT_LONG_SPREAD = 0.8
# A recompute passes when every quantile is within this of the reveal, in 1e18 ln units (1e15 =
# 4.096 steps of the 2^-12 output grid): float drift on CPU that moves a few of the MC_DRAWS paths
# shifts an empirical quantile by far less. The commitment still binds the revealed integers; only
# "revealed = what the public weights compute" is checked to it.
RECOMPUTE_TOLERANCE_E18 = 10**15
EXACT, TOLERANT, FAIL = "exact", "tolerant", "fail"


@dataclass(frozen=True)
class TsfmModel:
    model: str  # model id on the self-hosted inference service
    weights: str  # public weights "hf_repo@revision"; "" when closed
    license: str
    # Scale on the sampled differences (realized vol scales by spread^2): per-step quantiles from
    # 16 points are far too wide. Chosen by mean pinball loss of the ln RV quantiles on the
    # validation period 2026-10-08 .. 10-15 (165 hourly rounds, MODEL_CARD 6.2).
    spread: float
    # reproducible only where the public weights on CPU recompute the API's reveal within
    # RECOMPUTE_TOLERANCE_E18 on every checked round (MODEL_CARD 6.2)
    tier: str
    # Whether the agent sends history.round_context's long series. A reproducible one rebuilds it
    # from the pool's Swap logs alone (tsfm_recompute), so it is a function of chain data.
    long_context: bool

    @property
    def agent_name(self) -> str:
        return f"agent-{self.model}"


MODELS = {m.model: m for m in (
    TsfmModel("timesfm-3.0", "google/timesfm-3.0-pytorch@43046b85ec22d584a13f8098c2ed39c889e129c2",
              "TimesFM-NC-1.0", 0.6, REPRODUCIBLE, False),
    TsfmModel("timestral-209m", "mistralai/Timestral-209M@9874d252ab0aae16f7f7c999f98f98d6ad7d8365",
              "Mistral-Modified-MIT", 0.5, REPRODUCIBLE, True),
    TsfmModel("chronos-2", "amazon/chronos-2@29ec3766d36d6f73f0696f85560a422f50e8498c",
              "Apache-2.0", 0.4, REPRODUCIBLE, True),
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


def calibration(model: str, source: str = ONCHAIN) -> float:
    """Spread for the context the forecast was made from."""
    if source == SWAPS:
        return history.LONG_CONTEXT_SPREAD.get(model, DEFAULT_LONG_SPREAD)
    return spec(model).spread


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


def rv_paths(levels, steps, n_diffs, spread=1.0, draws=MC_DRAWS, seed=MC_SEED) -> np.ndarray:
    """RV per path = sum of the last n_diffs steps squared, each drawn independently from its
    quantiles and scaled by spread."""
    if len(steps) < n_diffs:
        raise ValueError(f"need {n_diffs} forecast steps, got {len(steps)}")
    u = np.random.default_rng(seed).random((n_diffs, draws))
    rv = np.zeros(draws)
    for k, s in enumerate(steps[-n_diffs:]):
        rv += (spread * sample_quantiles(levels, s, u[k])) ** 2
    return rv


def ln_quantiles_from_step_quantiles(levels, steps, n_diffs, spread=1.0, taus=cm.QUANTILE_LEVELS,
                                     draws=MC_DRAWS, seed=MC_SEED) -> list[float]:
    """Empirical quantiles (numpy linear) of y = ln(max(RV_path, RV_FLOOR)) at taus."""
    y = np.log(np.maximum(rv_paths(levels, steps, n_diffs, spread, draws, seed), cm.RV_FLOOR))
    return [float(v) for v in np.quantile(y, list(taus))]


def ln_quantiles(levels, steps, n_segments: int, model: str, source: str = ONCHAIN):
    return ln_quantiles_from_step_quantiles(levels, steps, n_segments - 1,
                                            calibration(model, source))


def quantize_reveal(q) -> list[int]:
    """outputs[k] = round(q_k * 2^OUTPUT_SCALE_BITS), lifted to strictly increasing by one grid
    step; rejected unless VolMarket.revealPrediction would accept it."""
    q = [float(v) for v in q]
    if len(q) != cm.K or any(not math.isfinite(v) for v in q):
        raise ValueError(f"need {cm.K} finite quantiles, got {q}")
    out = cm.quantize_quantiles(q)
    if not cm.valid_outputs(out):
        raise ValueError(f"quantiles outside [Q_MIN, Q_MAX]: {q}")
    return out


def compare_reveal(revealed_e18, recomputed_e18) -> tuple[int, str]:
    """(largest per-quantile |revealed - recomputed| in 1e18 ln units, EXACT | TOLERANT | FAIL)."""
    diff = max(abs(int(a) - int(b)) for a, b in zip(revealed_e18, recomputed_e18, strict=True))
    return diff, EXACT if diff == 0 else TOLERANT if diff <= RECOMPUTE_TOLERANCE_E18 else FAIL


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
        "postprocess": {"spread": s.spread,
                        "long_spread": calibration(model, SWAPS) if s.long_context else None,
                        "draws": MC_DRAWS, "seed": MC_SEED},
        "output": {"target": "ln(max(RV, 1)) of the sampled paths, RV in tick^2",
                   "quantile": "numpy linear empirical quantile",
                   "levels_e18": [str(t) for t in cm.QUANTILE_LEVELS_E18],
                   "scale_bits": cm.OUTPUT_SCALE_BITS,
                   "grid": "round(q * 2^scale_bits), then strictly increasing by +1",
                   "tolerance_e18": str(RECOMPUTE_TOLERANCE_E18)},
        "code_sha256": _sha256(Path(__file__)),
        "local_runner_sha256": _sha256(Path(__file__).with_name("tsfm_local.py")),
    }


def model_hash(model: str) -> str:
    """keccak256 of the canonical JSON preimage (sorted keys, no spaces), 0x-prefixed bytes32."""
    raw = json.dumps(model_hash_preimage(model), sort_keys=True, separators=(",", ":"))
    return keccak(raw.encode())
