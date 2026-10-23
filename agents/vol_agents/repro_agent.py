"""Reproducible agent: public pinned weights (Chronos-Bolt, `repro_runner`) that anyone can re-run.

The model runs in a separate interpreter (VOL_REPRO_PYTHON, with chronos-forecasting and torch) on
the round's onchain features; its quantiles of next-hour realized vol become bucket probabilities
(api_agent.probs_from_quantiles), quantized to whole basis points so float noise below 1e-4 does
not change the revealed vector. The market registers the model with verifier address(0) and
modelHash = keccak256(sha256(weights) || sha256(config.json) || sha256(repro_runner.py)), i.e.
verification tier "reproducible": no proof at reveal, but `python -m vol_agents.recompute`
re-derives the revealed vector from onchain data and the pinned snapshot. Equality is only claimed
on the same machine and software stack; there is no fallback forecast when the runner fails.
"""

import base64
import hashlib
import json
import math
import os
import subprocess
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path

from . import contract_math as cm
from . import repro_runner as rr
from .agent import Forecaster
from .api_agent import ROUND_SIG, probs_from_quantiles
from .chain import Anvil, as_int, keccak
from .round import register_identity

RUNNER_PATH = Path(rr.__file__).resolve()
BPS = 10_000
# 1e14 = PROB_SCALE / BPS: one basis point on the contract's 1e18 probability scale
BPS_UNIT = cm.PROB_SCALE // BPS
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
CARD_PREFIX = "data:application/json;base64,"
DEFAULT_TIMEOUT_S = 300


def quantize_bps(probs) -> list[int]:
    """Whole basis points (each >= 1, summing to 10000, leftovers by largest fractional part),
    scaled by BPS_UNIT so the vector sums to exactly 1e18."""
    if len(probs) != cm.BUCKETS:
        raise ValueError(f"need {cm.BUCKETS} probabilities, got {len(probs)}")
    p = [float(v) for v in probs]
    if any(not math.isfinite(v) or v < 0 for v in p) or sum(p) <= 0:
        raise ValueError(f"probabilities must be non-negative with a positive sum: {probs}")
    fp = [Fraction(v) for v in p]
    total = sum(fp)
    scaled = [v / total * BPS for v in fp]
    ints = [max(math.floor(v), 1) for v in scaled]
    short = BPS - sum(ints)
    if short > 0:
        # a bucket already raised to the 1 bp floor holds more than its share: no leftover for it
        for i in sorted(range(cm.BUCKETS),
                        key=lambda i: scaled[i] - math.floor(scaled[i]) if scaled[i] >= 1 else -1,
                        reverse=True)[:short]:
            ints[i] += 1
    for _ in range(-short):
        ints[max(range(cm.BUCKETS), key=lambda i: ints[i])] -= 1
    assert sum(ints) == BPS and min(ints) >= 1
    return [v * BPS_UNIT for v in ints]


def _sha256_file(path) -> bytes:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.digest()


def model_hash(weights_path, config_path, runner_path) -> str:
    """keccak256(sha256(weights) || sha256(config) || sha256(runner)) as 0x-prefixed bytes32."""
    return keccak(b"".join(_sha256_file(p) for p in (weights_path, config_path, runner_path)))


def local_model_hash() -> str:
    """Hash of the pinned snapshot on this machine and of this checkout's runner."""
    weights, config = rr.artifact_paths()
    return model_hash(weights, config, RUNNER_PATH)


def build_runner_request(features, bounds, n_segments=cm.N_SEGMENTS) -> dict:
    if len(features) != cm.N_FEATURES:
        raise ValueError(f"need {cm.N_FEATURES} features, got {len(features)}")
    if len(bounds) != cm.BUCKETS - 1:
        raise ValueError(f"need {cm.BUCKETS - 1} bounds, got {len(bounds)}")
    return {
        "model": f"{rr.MODEL_REPO}@{rr.MODEL_REVISION}",
        "features": [int(f) for f in features],
        "bounds": [int(b) for b in bounds],
        "prediction_length": n_segments - 1,
        "quantile_levels": list(rr.QUANTILE_LEVELS),
    }


def run_runner(request: dict, python=None) -> dict:
    """Run repro_runner.py under VOL_REPRO_PYTHON; any failure raises, there is no fallback."""
    python = python or os.environ.get("VOL_REPRO_PYTHON")
    if not python:
        raise RuntimeError("VOL_REPRO_PYTHON is unset: it must name an interpreter with "
                           "chronos-forecasting and torch")
    if not (os.path.isfile(python) and os.access(python, os.X_OK)):
        raise RuntimeError(f"VOL_REPRO_PYTHON={python} is not an executable file")
    timeout = float(os.environ.get("VOL_REPRO_TIMEOUT_S") or DEFAULT_TIMEOUT_S)
    try:
        r = subprocess.run([python, str(RUNNER_PATH)], input=json.dumps(request),
                           capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"repro runner timed out after {timeout:g} s") from None
    if r.returncode != 0:
        raise RuntimeError(f"repro runner failed (exit {r.returncode}): {r.stderr[-2000:]}")
    lines = r.stdout.strip().splitlines()
    try:
        out = json.loads(lines[-1])
        levels = [float(v) for v in out["levels"]]
        values = [float(v) for v in out["values"]]
    except (IndexError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        raise RuntimeError(f"repro runner printed no valid answer: {r.stdout[-500:]!r}") from None
    if len(levels) != len(values) or len(levels) < 2:
        raise RuntimeError(f"repro runner answered {len(levels)} levels, {len(values)} values")
    return {"levels": levels, "values": values}


def forecast(features, bounds, python=None) -> dict:
    """Runner quantiles -> bucket probabilities -> the integer vector that is revealed."""
    q = run_runner(build_runner_request(features, bounds), python)
    probs = probs_from_quantiles(q["levels"], q["values"], bounds)
    return {**q, "probs": probs, "outputs": quantize_bps(probs)}


def round_inputs(chain, market: str, round_id: int) -> tuple[list[int], list[int]]:
    feats = [as_int(v) for v in
             chain.call(market, "getFeatures(uint256)(int256[16])", round_id)[0]]
    bounds = [as_int(b) for b in chain.call(market, ROUND_SIG, round_id)[7]]
    return feats, bounds


def agent_card(name: str, model_hash_: str, model_id=None, market=None) -> str:
    """ERC-8004 agent URI: the registration JSON inline as a base64 data URI."""
    card = {
        "type": "https://eips.ethereum.org/EIPS/eip-8004#registration-v1",
        "name": name,
        "description": "VolMarket forecaster running public pinned Chronos-Bolt weights; "
                       "reveals are recomputable from onchain features (same machine only).",
        "model": f"{rr.MODEL_REPO}@{rr.MODEL_REVISION}",
        "modelHash": model_hash_,
        "modelHashPreimage": "keccak256(sha256(model.safetensors) || sha256(config.json) || "
                             "sha256(agents/vol_agents/repro_runner.py))",
        "verification": "reproducible",
        "recompute": (
            "cd agents && VOL_REPRO_PYTHON=<python with chronos-forecasting> uv run python -m "
            f"vol_agents.recompute --rpc-url <RPC> --market {market or '<MARKET>'} "
            f"--round <ROUND> --model-id {'<MODEL_ID>' if model_id is None else model_id}"
        ),
    }
    if market is not None:
        card["market"] = market
    if model_id is not None:
        card["modelId"] = model_id
    raw = json.dumps(card, sort_keys=True, separators=(",", ":")).encode()
    return CARD_PREFIX + base64.b64encode(raw).decode()


def register(chain: Anvil, market: str, owner_key: str, identity: str, agent,
             model_hash_: str | None = None) -> int:
    """Register the agent's model as reproducible (verifier address(0) plus hash), mint its
    ERC-8004 identity with the agent card and link the two; returns the agentId."""
    h = model_hash_ or local_model_hash()
    chain.send(owner_key, market, "registerModel(address,address,bytes32)", ZERO_ADDRESS,
               agent.address, h)
    agent.model_id = as_int(chain.call(market, "modelCount()(uint256)")[0]) - 1
    agent_id = register_identity(chain, identity, agent.key,
                                 agent_card(agent.name, h, agent.model_id, market))
    chain.send(agent.key, market, "linkAgent(uint256,uint256)", agent.model_id, agent_id)
    return agent_id


@dataclass
class ReproAgent(Forecaster):
    python: str | None = None  # default: VOL_REPRO_PYTHON

    kind = "reproducible"

    def prepare(self, chain: Anvil, market: str, round_id: int) -> dict:
        feats, bounds = round_inputs(chain, market, round_id)
        f = forecast(feats, bounds, self.python)
        return {"features": feats, "outputs": f["outputs"], "proof": "0x",
                "source": f"{rr.MODEL_REPO}@{rr.MODEL_REVISION}",
                "quantiles": {"levels": f["levels"], "values": f["values"]},
                "repro_probs": f["probs"]}
