"""Commit-only agent backed by a third-party time-series forecasting (TSFM) HTTP API.

The API gets the same onchain inputs the zk agents use (the round's 16 contract features, i.e.
differences of 5-minute mean ticks, plus the relative mean-tick path they imply) and the round's
bucket bounds, and answers with either 5 bucket probabilities or quantiles of the hour's realized
volatility in tick^2. Quantiles are turned into bucket probabilities by interpolating their CDF at
the bounds. The agent commits and reveals like the zk agents but without a proof: the market
registers its model with verifier address(0), so its score only shows the forecast was made in
time, not which model made it.

Configuration (environment): VOL_TSFM_API_URL (unset: a deterministic local placeholder forecast),
VOL_TSFM_API_KEY (sent as "Authorization: Bearer <key>", or raw under VOL_TSFM_API_KEY_HEADER),
VOL_TSFM_TIMEOUT_S (default 30). Request and response formats: agents/README.md.
"""

import itertools
import json
import math
import os
import urllib.error
import urllib.request
from dataclasses import dataclass
from fractions import Fraction

from . import contract_math as cm
from .agent import Forecaster
from .chain import Anvil, as_int

REQUEST_SCHEMA = "vol-forecast-request/v1"
QUANTILE_LEVELS = (0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95)
# Every bucket keeps at least this probability: a zero would score the floor -18 if it happens.
MIN_PROB = 1e-6
PLACEHOLDER_LEVELS = (0.1, 0.5, 0.9)
# Quantiles as multiples of the trailing realized vol: p10/p50/p90 of next-hour RV over trailing RV
# in the training period (models/eval.json "placeholder_scale", vol_agents.train).
PLACEHOLDER_SCALE = (0.24, 0.94, 4.63)
ROUND_SIG = "getRound(uint256)(uint64,bool,bool,uint256,uint256,uint256,uint256[5],uint256[])"


@dataclass(frozen=True)
class ApiConfig:
    url: str
    key: str | None = None
    key_header: str | None = None
    timeout_s: float = 30.0

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        url = (env.get("VOL_TSFM_API_URL") or "").strip()
        if not url:
            return None
        return cls(url=url, key=env.get("VOL_TSFM_API_KEY") or None,
                   key_header=env.get("VOL_TSFM_API_KEY_HEADER") or None,
                   timeout_s=float(env.get("VOL_TSFM_TIMEOUT_S") or 30))


def build_request(features, bounds, round_info):
    """JSON body for the API: the round's onchain inputs in ticks, and what to forecast."""
    diffs = [x // cm.MULT for x in features]
    path = [0]
    for d in diffs:
        path.append(path[-1] + d)
    return {
        "schema": REQUEST_SCHEMA,
        "target": "realized_vol_tick2",
        "round": round_info,
        "bounds_tick2": list(bounds),
        "history": {
            "step_s": round_info["delta_s"],
            "segment_mean_tick_diffs": diffs,
            "relative_segment_mean_ticks": path,
            "clamp_ticks": cm.CLAMP,
        },
        "quantile_levels": list(QUANTILE_LEVELS),
    }


def call_api(cfg: ApiConfig, body: dict) -> dict:
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if cfg.key:
        if cfg.key_header:
            headers[cfg.key_header] = cfg.key
        else:
            headers["Authorization"] = f"Bearer {cfg.key}"
    req = urllib.request.Request(cfg.url, data=json.dumps(body).encode(), headers=headers,
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=cfg.timeout_s) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"TSFM API answered HTTP {e.code}") from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        raise RuntimeError(f"TSFM API call failed: {type(e).__name__}") from None


def probs_from_response(resp: dict, bounds) -> list[float]:
    if "bucket_probs" in resp:
        return _normalized(resp["bucket_probs"])
    if "quantiles" in resp:
        q = resp["quantiles"]
        return probs_from_quantiles([p["level"] for p in q], [p["value"] for p in q], bounds)
    raise ValueError("response needs 'bucket_probs' or 'quantiles'")


def _normalized(probs) -> list[float]:
    if len(probs) != cm.BUCKETS:
        raise ValueError(f"bucket_probs needs {cm.BUCKETS} values, got {len(probs)}")
    p = [float(v) for v in probs]
    if any(not math.isfinite(v) or v < 0 for v in p) or sum(p) <= 0:
        raise ValueError(f"bucket_probs must be non-negative with a positive sum: {probs}")
    s = sum(p)
    return [v / s for v in p]


def quantile_cdf(levels, values):
    """CDF of realized vol (>= 0) through the given quantiles: linear between them, linear from
    (0, 0) up to the lowest one, and an exponential upper tail fitted through the top two."""
    pts = sorted(zip((float(v) for v in values), (float(q) for q in levels), strict=True),
                 key=lambda t: (t[1], t[0]))
    if len(pts) < 2:
        raise ValueError("need at least two quantiles")
    vs, qs = [p[0] for p in pts], [p[1] for p in pts]
    if any(not 0 < q < 1 for q in qs) or any(b <= a for a, b in itertools.pairwise(qs)):
        raise ValueError(f"quantile levels must be strictly increasing in (0, 1): {qs}")
    if any(not math.isfinite(v) for v in vs) or any(b < a for a, b in itertools.pairwise(vs)):
        raise ValueError(f"quantile values must be finite and non-decreasing: {vs}")
    vs = [max(v, 0.0) for v in vs]
    knots = ([(0.0, 0.0)] if vs[0] > 0 else []) + list(zip(vs, qs, strict=True))
    v_hi, q_hi = vs[-1], qs[-1]
    span = vs[-1] - vs[-2]
    tail = span / math.log((1 - qs[-2]) / (1 - q_hi)) if span > 0 else max(v_hi, 1.0)

    def cdf(x):
        if x >= v_hi:
            return 1 - (1 - q_hi) * math.exp(-(x - v_hi) / tail)
        if x < knots[0][0]:
            return 0.0
        for (x0, c0), (x1, c1) in itertools.pairwise(knots):
            if x0 <= x < x1:
                return c0 + (c1 - c0) * (x - x0) / (x1 - x0)
        return knots[-1][1]

    return cdf


def probs_from_quantiles(levels, values, bounds) -> list[float]:
    """Bucket i holds bounds[i-1] <= rv < bounds[i] (VolMarket bucketOf)."""
    cdf = quantile_cdf(levels, values)
    edges = [0.0] + [cdf(float(b)) for b in bounds] + [1.0]
    return [max(edges[i + 1] - edges[i], 0.0) for i in range(cm.BUCKETS)]


def quantize(probs, min_prob=MIN_PROB) -> list[int]:
    """1e18-scaled integers that sum exactly to 1e18, each at least min_prob (largest remainder).
    As reveal outputs they become exactly these probabilities onchain."""
    p = [Fraction(max(v, min_prob)) for v in _normalized(probs)]
    s = sum(p)
    scaled = [v / s * cm.PROB_SCALE for v in p]
    ints = [math.floor(v) for v in scaled]
    short = cm.PROB_SCALE - sum(ints)
    for i in sorted(range(cm.BUCKETS), key=lambda i: scaled[i] - ints[i], reverse=True)[:short]:
        ints[i] += 1
    assert sum(ints) == cm.PROB_SCALE and min(ints) > 0
    return ints


def trailing_realized_vol(features, n_segments=cm.N_SEGMENTS) -> int:
    """The contract's RV formula over the last n_segments - 1 feature differences (clamped)."""
    diffs = [x // cm.MULT for x in features][-(n_segments - 1):]
    return sum(d * d for d in diffs)


def placeholder_quantiles(features):
    """Deterministic stand-in when no API is configured: quantiles around the trailing RV."""
    rv = max(trailing_realized_vol(features), 1)
    return list(PLACEHOLDER_LEVELS), [rv * s for s in PLACEHOLDER_SCALE]


@dataclass
class ApiAgent(Forecaster):
    config: ApiConfig | None = None

    kind = "commit-only"

    @property
    def source(self):
        return "tsfm-api" if self.config else "placeholder"

    def prepare(self, chain: Anvil, market: str, round_id: int) -> dict:
        feats = [as_int(v) for v in
                 chain.call(market, "getFeatures(uint256)(int256[16])", round_id)[0]]
        r = chain.call(market, ROUND_SIG, round_id)
        bounds = [as_int(b) for b in r[7]]
        delta = as_int(chain.call(market, "delta()(uint32)")[0])
        n = as_int(chain.call(market, "nSegments()(uint8)")[0])
        info = {"market": market, "id": round_id, "start": as_int(r[0]), "delta_s": delta,
                "n_segments": n}
        if self.config:
            probs = probs_from_response(call_api(self.config, build_request(feats, bounds, info)),
                                        bounds)
        else:
            probs = probs_from_quantiles(*placeholder_quantiles(feats), bounds)
        return {"features": feats, "outputs": quantize(probs), "proof": "0x",
                "source": self.source, "api_probs": probs}
