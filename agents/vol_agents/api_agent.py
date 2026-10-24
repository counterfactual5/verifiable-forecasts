"""Agents backed by a time-series forecasting (TSFM) model on the operator's self-hosted inference
service.

The service gets the same onchain inputs the zk agents use: the round's 16 contract features, i.e.
differences of 5-minute mean ticks (or, for long-context models, history.round_context's longer
series of the same differences). The agent commits and reveals like the zk agents but without a
proof (verifier address(0)).

Two wire formats (VOL_TSFM_API_SCHEMA):
- "tsfm-forecast" (default): `POST {url}/forecast`, one agent per model (tsfm_agents); request
  and post-processing in tsfm_forecast. A model whose public weights recompute the revealed
  vector on CPU has tier "reproducible" and registers tsfm_forecast.model_hash; the others are
  commit-only, so their score only shows the forecast was made in time, not which model made it.
- "vol-forecast-request/v1": the generic schema in agents/README.md, answered with quantiles of
  realized vol in tick^2 (mapped to ln and interpolated to the market's levels); always
  commit-only.

Reveals are K signed integers outputs[k] = q_k * 2^OUTPUT_SCALE_BITS, q_k the forecast quantiles
of y = ln(max(RV, 1)) at contract_math.QUANTILE_LEVELS.

Configuration (environment): VOL_TSFM_API_URL (unset: a deterministic local placeholder forecast;
for tsfm-forecast the service's base URL, e.g. https://<host>/v1), VOL_TSFM_API_KEY (sent as
"Authorization: Bearer <key>", or raw under VOL_TSFM_API_KEY_HEADER), VOL_TSFM_MODEL (one model,
default remote-model), VOL_TSFM_MODELS (comma-separated models for tsfm_agents, default
timesfm-3.0,timestral-209m,chronos-2), VOL_TSFM_TIMEOUT_S (default 30). Formats: agents/README.md.
"""

import itertools
import json
import math
import os
import urllib.error
import urllib.request
from dataclasses import dataclass

import numpy as np

from . import contract_math as cm
from . import history
from . import tsfm_forecast as sf
from .agent import Forecaster
from .chain import Anvil, address_of, as_int

REQUEST_SCHEMA = "vol-forecast-request/v1"
QUANTILE_LEVELS = (0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95)
PLACEHOLDER_LEVELS = (0.1, 0.5, 0.9)
# Quantiles as multiples of the trailing realized vol: p10/p50/p90 of next-hour RV over trailing RV
# in the training period (models/eval.json "placeholder_scale", vol_agents.train).
PLACEHOLDER_SCALE = (0.24, 0.94, 4.63)
ROUND_SIG = "getRound(uint256)(uint64,bool,bool,uint256,uint256,uint256,uint256[5],uint256[])"

TSFM = "tsfm-forecast"
TSFM_DEFAULT_MODEL = "remote-model"


@dataclass(frozen=True)
class ApiConfig:
    url: str
    key: str | None = None
    key_header: str | None = None
    timeout_s: float = 30.0
    schema: str = TSFM
    model: str = TSFM_DEFAULT_MODEL

    @classmethod
    def from_env(cls, env=None):
        env = os.environ if env is None else env
        url = (env.get("VOL_TSFM_API_URL") or "").strip()
        if not url:
            return None
        schema = (env.get("VOL_TSFM_API_SCHEMA") or TSFM).strip()
        if schema not in (TSFM, REQUEST_SCHEMA):
            raise ValueError(f"VOL_TSFM_API_SCHEMA must be {TSFM} or {REQUEST_SCHEMA}")
        return cls(url=url, key=env.get("VOL_TSFM_API_KEY") or None,
                   key_header=env.get("VOL_TSFM_API_KEY_HEADER") or None,
                   timeout_s=float(env.get("VOL_TSFM_TIMEOUT_S") or 30), schema=schema,
                   model=(env.get("VOL_TSFM_MODEL") or TSFM_DEFAULT_MODEL).strip())


def models_from_env(env=None) -> list[str]:
    env = os.environ if env is None else env
    raw = env.get("VOL_TSFM_MODELS") or ",".join(sf.DEFAULT_MODELS)
    models = [m.strip() for m in raw.split(",") if m.strip()]
    if len(set(models)) != len(models):
        raise ValueError(f"VOL_TSFM_MODELS lists a model twice: {raw}")
    return models


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


def call_api(cfg: ApiConfig, body: dict, url: str | None = None) -> dict:
    headers = {"Content-Type": "application/json", "Accept": "application/json"}
    if cfg.key:
        if cfg.key_header:
            headers[cfg.key_header] = cfg.key
        else:
            headers["Authorization"] = f"Bearer {cfg.key}"
    req = urllib.request.Request(url or cfg.url, data=json.dumps(body).encode(), headers=headers,
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=cfg.timeout_s) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"TSFM API answered HTTP {e.code}") from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
        raise RuntimeError(f"TSFM API call failed: {type(e).__name__}") from None


def quantiles_from_response(resp: dict) -> list[float]:
    """ln quantiles at the market's levels from a generic answer's RV quantiles (tick^2)."""
    if "quantiles" in resp:
        q = resp["quantiles"]
        return ln_quantiles([p["level"] for p in q], [p["value"] for p in q])
    if "bucket_probs" in resp:
        raise ValueError("bucket_probs answers are no longer scored: the market takes quantiles "
                         "of ln realized vol; answer 'quantiles' of realized vol in tick^2")
    raise ValueError("response needs 'quantiles'")


def ln_quantiles(levels, values, taus=cm.QUANTILE_LEVELS) -> list[float]:
    """RV quantiles (tick^2) to quantiles of y = ln(max(RV, RV_FLOOR)) at taus: ln is monotone,
    so the quantiles map one to one; levels in between are linear in (tau, y), levels outside the
    given ones take the nearest given quantile."""
    pts = sorted(zip((float(q) for q in levels), (float(v) for v in values), strict=True))
    if len(pts) < 2:
        raise ValueError("need at least two quantiles")
    qs, vs = [p[0] for p in pts], [p[1] for p in pts]
    if any(not 0 < q < 1 for q in qs) or any(b <= a for a, b in itertools.pairwise(qs)):
        raise ValueError(f"quantile levels must be strictly increasing in (0, 1): {qs}")
    if any(not math.isfinite(v) for v in vs) or any(b < a for a, b in itertools.pairwise(vs)):
        raise ValueError(f"quantile values must be finite and non-decreasing: {vs}")
    ys = [math.log(max(v, cm.RV_FLOOR)) for v in vs]
    return [float(v) for v in np.interp(list(taus), qs, ys)]


def trailing_realized_vol(features, n_segments=cm.N_SEGMENTS) -> int:
    """The contract's RV formula over the last n_segments - 1 feature differences (clamped)."""
    diffs = [x // cm.MULT for x in features][-(n_segments - 1):]
    return sum(d * d for d in diffs)


def placeholder_quantiles(features):
    """Deterministic stand-in when no API is configured: RV quantiles around the trailing RV."""
    rv = max(trailing_realized_vol(features), 1)
    return list(PLACEHOLDER_LEVELS), [rv * s for s in PLACEHOLDER_SCALE]


def placeholder_forecast(features) -> list[float]:
    return ln_quantiles(*placeholder_quantiles(features))


@dataclass
class ApiAgent(Forecaster):
    config: ApiConfig | None = None

    # Reveals carry no proof whatever the tier; the caller registers by `tier` and `model_hash`.
    kind = "commit-only"

    @property
    def tsfm(self) -> bool:
        return bool(self.config) and self.config.schema == TSFM

    @property
    def source(self):
        if not self.config:
            return "placeholder"
        return f"tsfm:{self.config.model}" if self.tsfm else "tsfm-api"

    @property
    def tier(self) -> str:
        return sf.spec(self.config.model).tier if self.tsfm else sf.COMMIT_ONLY

    @property
    def model_hash(self) -> str | None:
        """bytes32 to register with registerModel(address(0), operator, hash) when reproducible."""
        return sf.model_hash(self.config.model) if self.tier == sf.REPRODUCIBLE else None

    def context(self, feats, info) -> history.Context:
        """The series sent to the model: the long off-chain one when the model takes it (and
        $VOL_HISTORY_CACHE provides it), else the 16 onchain differences."""
        s = sf.spec(self.config.model) if self.tsfm else None
        if s and s.long_context:
            env = os.environ
            if s.tier == sf.REPRODUCIBLE:
                # the registered model_hash fixes the context length
                env = {**os.environ, history.CONTEXT_ENV: str(history.DEFAULT_CONTEXT)}
            return history.round_context(feats, info["start"], info["delta_s"], env)
        reason = "model reads the onchain features only" if s else None
        return history.Context(sf.context(feats), sf.ONCHAIN, reason)

    def api_quantiles(self, feats, bounds, info, ctx: history.Context | None = None):
        """Forecast quantiles of y = ln(max(RV, 1)) at contract_math.QUANTILE_LEVELS (floats)."""
        cfg = self.config
        if self.tsfm:
            ctx = ctx or self.context(feats, info)
            resp = call_api(cfg, sf.build_request(ctx.diffs, info, cfg.model),
                            url=cfg.url.rstrip("/") + "/forecast")
            levels, steps = sf.step_quantiles(resp)
            return sf.ln_quantiles(levels, steps, info["n_segments"], cfg.model, ctx.source)
        return quantiles_from_response(call_api(cfg, build_request(feats, bounds, info)))

    def prepare(self, chain: Anvil, market: str, round_id: int) -> dict:
        feats = [as_int(v) for v in
                 chain.call(market, "getFeatures(uint256)(int256[16])", round_id)[0]]
        r = chain.call(market, ROUND_SIG, round_id)
        bounds = [as_int(b) for b in r[7]]
        delta = as_int(chain.call(market, "delta()(uint32)")[0])
        n = as_int(chain.call(market, "nSegments()(uint8)")[0])
        info = {"market": market, "id": round_id, "start": as_int(r[0]), "delta_s": delta,
                "n_segments": n}
        ctx = self.context(feats, info)
        q = self.api_quantiles(feats, bounds, info, ctx) if self.config else (
            placeholder_forecast(feats))
        outputs = sf.quantize_reveal(q)
        return {"features": feats, "outputs": outputs,
                "quantiles": [o / (1 << cm.OUTPUT_SCALE_BITS) for o in outputs],
                "api_quantiles": q, "proof": "0x", "source": self.source,
                "context_source": ctx.source, "context_points": len(ctx.diffs),
                "context_reason": ctx.reason}


def tsfm_agents(config: ApiConfig, keys, models=None) -> list[ApiAgent]:
    """One independent agent per model (own name, key and address, so own modelId), all
    sharing the endpoint and API key of config; models default to VOL_TSFM_MODELS."""
    models = list(models or models_from_env())
    if len(keys) < len(models):
        raise ValueError(f"{len(models)} models need {len(models)} keys, got {len(keys)}")
    return [ApiAgent(name=sf.spec(m).agent_name, key=k, address=address_of(k),
                     config=ApiConfig(**{**config.__dict__, "schema": TSFM, "model": m}))
            for m, k in zip(models, keys, strict=False)]
