"""Reproducible agent: integer basis-point quantization, the model hash over weights, config and
runner, the runner protocol, same-machine determinism of Chronos-Bolt inference, and one anvil
round in which a registered reproducible agent reveals and `vol_agents.recompute` re-derives its
forecast from onchain data, failing on a tampered reveal, a wrong hash or a broken runner.

Tests that run the model need VOL_REPRO_PYTHON (an interpreter with chronos-forecasting and torch,
weights pre-downloaded) and fail without it: agents/README.md "Reproducible agent" sets it up."""

import base64
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from vol_agents import contract_math as cm
from vol_agents import repro_agent as ra
from vol_agents import repro_runner as rr
from vol_agents.chain import DEV_KEYS, Anvil, address_of, as_int, keccak
from vol_agents.round import WINDOW_TICKS, history_ticks

AGENTS_DIR = Path(__file__).resolve().parent.parent
BOUNDS = list(cm.BOUNDS)
FEATURES = cm.features_from_segment_ticks(history_ticks())
BPS_UNIT = 10**14


def _require_model():
    if not os.environ.get("VOL_REPRO_PYTHON"):
        pytest.fail("VOL_REPRO_PYTHON unset: point it at an interpreter with chronos-forecasting "
                    "and torch (agents/README.md, Reproducible agent)", pytrace=False)


def _recompute(*args, env=None):
    return subprocess.run(
        [sys.executable, "-m", "vol_agents.recompute", *map(str, args)],
        cwd=AGENTS_DIR, capture_output=True, text=True, timeout=600,
        env={**os.environ, **(env or {})},
    )


# ---------------------------------------------------------------- pure helpers

def test_quantize_bps_sums_and_no_zero_bucket():
    cases = ([0.2] * 5, [1, 0, 0, 0, 0], [0.1, 0.2, 0.3, 0.15, 0.25], [1e-30, 1, 1, 1, 3],
             [0.33333, 0.33333, 0.33334, 0, 0], [0.99999, 1e-9, 1e-9, 1e-9, 1e-9])
    for probs in cases:
        ints = ra.quantize_bps(probs)
        assert len(ints) == cm.BUCKETS
        assert sum(ints) == cm.PROB_SCALE, probs
        assert min(ints) >= BPS_UNIT, probs
        # the contract turns these outputs into exactly the same probabilities
        assert cm.probs_from_outputs(ints) == ints
    assert ra.quantize_bps([1, 0, 0, 0, 0]) == [9996 * BPS_UNIT] + [BPS_UNIT] * 4
    assert ra.quantize_bps([0.2] * 5) == [2000 * BPS_UNIT] * 5
    with pytest.raises(ValueError):
        ra.quantize_bps([0, 0, 0, 0, 0])
    with pytest.raises(ValueError):
        ra.quantize_bps([1, 2, 3])


def test_quantize_bps_is_multiple_of_1e14():
    cases = ([0.123456, 0.2, 0.3, 0.1, 0.276544], [3, 1, 4, 1, 5], [1e-7, 2e-7, 0.5, 0.4, 0.1])
    for probs in cases:
        ints = ra.quantize_bps(probs)
        assert all(v % BPS_UNIT == 0 for v in ints)
        assert sum(v // BPS_UNIT for v in ints) == 10_000
    # the largest fractional parts (.9 and .7 bp) take the two leftover basis points
    assert ra.quantize_bps([0.20004, 0.19999, 0.2, 0.2, 0.19997]) == [2000 * BPS_UNIT] * 5
    # a bucket lifted to the 1 bp floor takes no leftover basis point
    lifted = ra.quantize_bps([0.9, 2499.775, 2499.775, 2499.775, 2499.775])
    assert lifted == [v * BPS_UNIT for v in (1, 2500, 2500, 2500, 2499)]


def test_model_hash_combines_weights_config_runner(tmp_path):
    files = {}
    for name, body in (("w", b"weights"), ("c", b'{"a": 1}'), ("r", b"print(1)")):
        files[name] = tmp_path / name
        files[name].write_bytes(body)
    h = ra.model_hash(files["w"], files["c"], files["r"])
    manual = keccak(b"".join(hashlib.sha256(files[n].read_bytes()).digest() for n in "wcr"))
    assert h == manual and h.startswith("0x") and len(h) == 66
    for n in "wcr":
        original = files[n].read_bytes()
        files[n].write_bytes(original + b"x")
        assert ra.model_hash(files["w"], files["c"], files["r"]) != h, n
        files[n].write_bytes(original)
    assert ra.model_hash(files["w"], files["c"], files["r"]) == h
    # order matters: swapping weights and config is a different model
    assert ra.model_hash(files["c"], files["w"], files["r"]) != h


def test_runner_request_shape():
    req = ra.build_runner_request(FEATURES, BOUNDS)
    assert req["features"] == FEATURES and req["bounds"] == BOUNDS
    assert req["prediction_length"] == cm.N_SEGMENTS - 1
    assert req["quantile_levels"] == list(rr.QUANTILE_LEVELS)
    assert req["model"] == f"{rr.MODEL_REPO}@{rr.MODEL_REVISION}"
    json.dumps(req)
    assert rr.series_from_features(FEATURES) == [(f // cm.MULT) ** 2 for f in FEATURES]
    with pytest.raises(ValueError):
        ra.build_runner_request(FEATURES[:-1], BOUNDS)
    with pytest.raises(ValueError):
        ra.build_runner_request(FEATURES, BOUNDS[:-1])


# ---------------------------------------------------------------- model

def test_inference_deterministic_same_machine():
    _require_model()
    a = ra.forecast(FEATURES, BOUNDS)
    b = ra.forecast(FEATURES, BOUNDS)
    assert a["outputs"] == b["outputs"] and a["values"] == b["values"]
    assert sum(a["outputs"]) == cm.PROB_SCALE
    assert len(a["values"]) == len(rr.QUANTILE_LEVELS)
    assert all(v >= 0 for v in a["values"])
    assert a["values"] == sorted(a["values"])


def test_recompute_offline_prints_vector():
    _require_model()
    r = _recompute("--features=" + ",".join(map(str, FEATURES)),
                   "--bounds=" + ",".join(map(str, BOUNDS)))
    assert r.returncode == 0, r.stderr
    vec = json.loads(r.stdout)
    assert len(vec) == cm.BUCKETS and sum(vec) == cm.PROB_SCALE
    assert all(v % BPS_UNIT == 0 and v >= BPS_UNIT for v in vec)
    assert vec == ra.forecast(FEATURES, BOUNDS)["outputs"]


# ---------------------------------------------------------------- onchain

COMMIT_LEAD, REVEAL_LEAD = 300, 60
PREDICTION_SIG = "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)"


@pytest.fixture(scope="module")
def repro_round():
    """One round with three reproducible models: honest, registered under a wrong hash, and one
    whose operator reveals a tampered vector. Inference runs once; all three commit its result."""
    _require_model()
    owner = DEV_KEYS[0]
    with Anvil() as c:
        token = c.deploy(owner, "test/mocks/MockERC20.sol:MockERC20")
        pool = c.deploy(owner, "test/mocks/MockPool.sol:MockPool")
        market = c.deploy(owner, "src/VolMarket.sol:VolMarket", token, 0, 0, pool, cm.DELTA,
                          cm.N_SEGMENTS, COMMIT_LEAD, REVEAL_LEAD)
        identity = c.deploy(owner, "src/erc8004/IdentityRegistryLite.sol:IdentityRegistryLite")
        reputation = c.deploy(owner,
                              "src/erc8004/ReputationRegistryLite.sol:ReputationRegistryLite")
        c.send(owner, market, "setReputation(address,address)", identity, reputation)

        good_hash = ra.local_model_hash()
        agents = {}
        for role, key, h in (("honest", DEV_KEYS[1], good_hash),
                             ("wrong-hash", DEV_KEYS[2], keccak(b"another model")),
                             ("tampered", DEV_KEYS[3], good_hash)):
            a = ra.ReproAgent(name=f"agent-repro-{role}", key=key, address=address_of(key))
            ra.register(c, market, owner, identity, a, h)
            agents[role] = a

        t0 = c.timestamp() + 1000
        start = t0 + 2 * cm.DELTA
        c.send(owner, pool, "setSegments(uint256,uint256,int24[])", t0 - 17 * cm.DELTA, cm.DELTA,
               "[" + ",".join(map(str, history_ticks())) + "]")
        c.send(owner, pool, "setSegments(uint256,uint256,int24[])", start, cm.DELTA,
               "[" + ",".join(map(str, WINDOW_TICKS)) + "]")
        c.set_next_timestamp(t0)
        c.send(owner, market, "createRound(uint64,uint256[])", start,
               "[" + ",".join(map(str, BOUNDS)) + "]")
        rid = 0

        forecast = agents["honest"].commit(c, market, rid)
        agents["wrong-hash"].commit(c, market, rid, dict(forecast))
        tampered = list(forecast["outputs"])
        hi = max(range(cm.BUCKETS), key=lambda i: tampered[i])
        lo = (hi + 1) % cm.BUCKETS
        tampered[hi] -= BPS_UNIT
        tampered[lo] += BPS_UNIT
        agents["tampered"].commit(c, market, rid, {**forecast, "outputs": tampered})

        c.set_next_timestamp(start - COMMIT_LEAD)
        for a in agents.values():
            a.reveal(c, market, rid)
        yield {"chain": c, "market": market, "identity": identity, "round": rid,
               "agents": agents, "forecast": forecast, "tampered": tampered}


def _online(d, role, env=None):
    return _recompute("--rpc-url", d["chain"].rpc, "--market", d["market"], "--round", d["round"],
                      "--model-id", d["agents"][role].model_id, env=env)


def test_repro_round_registers_reveals_and_recomputes(repro_round):
    d = repro_round
    c, market, a = d["chain"], d["market"], d["agents"]["honest"]
    mid = a.model_id
    assert as_int(c.call(market, "verificationTier(uint256)(uint8)", mid)[0]) == 1
    assert c.call(market, "isZkModel(uint256)(bool)", mid)[0] in (False, "false")
    onchain_hash = c.call(market, "modelHash(uint256)(bytes32)", mid)[0]
    assert onchain_hash.lower() == ra.local_model_hash().lower()

    rec = c.call(market, PREDICTION_SIG, d["round"], a.address)
    assert rec[0] in (True, "true") and as_int(rec[1]) == mid
    assert [as_int(v) for v in rec[2]] == d["forecast"]["outputs"]
    assert d["forecast"]["proof"] == "0x"

    r = _online(d, "honest")
    assert r.returncode == 0, r.stdout + r.stderr
    summary = json.loads(r.stdout)
    assert summary["match"] is True and summary["revealed"] == d["forecast"]["outputs"]

    agent_id = as_int(c.call(market, "agentOfModel(uint256)(uint256)", mid)[0])
    assert agent_id != 0
    uri = c.call(d["identity"], "getAgentURI(uint256)(string)", agent_id)[0]
    prefix = "data:application/json;base64,"
    assert uri.startswith(prefix)
    card = json.loads(base64.b64decode(uri[len(prefix):]))
    assert card["modelHash"].lower() == onchain_hash.lower()
    assert card["verification"] == "reproducible"
    assert card["model"] == f"{rr.MODEL_REPO}@{rr.MODEL_REVISION}"
    assert "vol_agents.recompute" in card["recompute"]


def test_recompute_fails_on_tampered_reveal(repro_round):
    d = repro_round
    r = _online(d, "tampered")
    assert r.returncode != 0
    summary = json.loads(r.stdout)
    assert summary["match"] is False
    assert summary["revealed"] == d["tampered"]
    assert summary["recomputed"] == d["forecast"]["outputs"]
    assert sum(1 for x, y in zip(summary["revealed"], summary["recomputed"], strict=True)
               if x != y) == 2


def test_recompute_fails_on_hash_mismatch(repro_round):
    d = repro_round
    r = _online(d, "wrong-hash")
    assert r.returncode != 0
    assert "model hash mismatch" in r.stderr


def test_recompute_fails_on_runner_error_no_fallback(repro_round, tmp_path, monkeypatch):
    d = repro_round
    broken = tmp_path / "broken-python"
    broken.write_text("#!/bin/sh\necho 'model exploded' >&2\nexit 3\n")
    broken.chmod(0o755)

    r = _online(d, "honest", env={"VOL_REPRO_PYTHON": str(broken)})
    assert r.returncode != 0
    assert "recomputed" not in r.stdout and "model exploded" in r.stderr
    r = _recompute("--features=" + ",".join(map(str, FEATURES)),
                   "--bounds=" + ",".join(map(str, BOUNDS)),
                   env={"VOL_REPRO_PYTHON": str(broken)})
    assert r.returncode != 0 and r.stdout.strip() == ""

    fresh = ra.ReproAgent(name="agent-repro-broken", key=DEV_KEYS[1], address="0x0")
    monkeypatch.setenv("VOL_REPRO_PYTHON", str(broken))
    with pytest.raises(RuntimeError, match="runner"):
        fresh.prepare(d["chain"], d["market"], d["round"])
    monkeypatch.delenv("VOL_REPRO_PYTHON")
    with pytest.raises(RuntimeError, match="VOL_REPRO_PYTHON"):
        fresh.prepare(d["chain"], d["market"], d["round"])
    assert fresh.pending == {}
