"""End to end on a local anvil: deploy, register one verifier per model, open a round, let every agent
prove and submit, then settle and compare the agents by their onchain log scores."""

import json

import pytest

from vol_agents import contract_math as cm
from vol_agents.chain import Anvil, as_int
from vol_agents.round import COMPARE, WINDOW_TICKS, deploy, open_round, settle_round, submit_all


@pytest.fixture(scope="module")
def chain():
    with Anvil() as c:
        yield c


@pytest.fixture(scope="module")
def submitted(chain):
    d = deploy(chain)
    rid = open_round(d)
    submit_all(d, rid)
    return d, rid


def test_agent_proves_and_submits(submitted):
    d, rid = submitted
    c = d.chain
    assert as_int(c.call(d.market, "predictorCount(uint256)(uint256)", rid)[0]) == len(d.agents)
    for a in d.agents:
        rec, model_id, probs, _ = c.call(
            d.market, "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)", rid, a.address
        )
        assert rec is True or rec == "true"
        assert as_int(model_id) == a.model_id
        probs = [as_int(v) for v in probs]
        assert sum(probs) == 10**18
        sub = d.rounds[rid]["submissions"][a.name]
        total = sum(sub["outputs"])
        for got, out, ref in zip(probs, sub["outputs"], sub["onnx_probs"], strict=True):
            assert got == pytest.approx(out * 10**18 // total, abs=5)
            assert got / 1e18 == pytest.approx(ref, abs=0.03)
        assert a.timings["prove"]["seconds"] < 15 * 60


def test_resubmission_rejected(submitted):
    d, rid = submitted
    a = d.agents[0]
    already_predicted = "0x3b9e91cf"  # cast sig "AlreadyPredicted()"
    with pytest.raises(RuntimeError, match=f"AlreadyPredicted|{already_predicted}"):
        a.forecast(d.chain, d.market, rid)


def test_agents_compare_after_round(submitted):
    d, rid = submitted
    COMPARE.unlink(missing_ok=True)
    res = settle_round(d, rid)
    assert res["settled"] and not res["voided"]
    assert res["realized_vol"] == cm.realized_vol(WINDOW_TICKS) == 49
    assert res["winning_bucket"] == 3

    saved = json.loads(COMPARE.read_text())
    rows = saved["agents"]
    assert 2 <= len(rows) <= 3
    assert len({r["model"] for r in rows}) == len(rows)
    scores = [r["score"] for r in rows]
    assert scores == sorted(scores, reverse=True)
    assert saved["winner"] == rows[0]["agent"]
    for r in rows:
        assert r["submitted"] is True
        assert isinstance(r["score"], int)
        onchain = d.chain.call(
            d.market, "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)", rid,
            next(a.address for a in d.agents if a.name == r["agent"]),
        )
        assert as_int(onchain[3]) == r["score"]
        assert -18 * 10**18 <= r["score"] < 0
