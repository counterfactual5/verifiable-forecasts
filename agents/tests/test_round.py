"""End to end on a local anvil: deploy, register one verifier per model, open a round, let every
agent prove and commit, reveal once commits close, then settle and compare the agents by their
onchain log scores. The settled round also shows each agent's log score in its ERC-8004
reputation."""

import json

import pytest

from vol_agents import contract_math as cm
from vol_agents.chain import DEV_KEYS, Anvil, as_int
from vol_agents.round import (
    COMPARE,
    WINDOW_TICKS,
    commit_all,
    deploy,
    open_round,
    reveal_all,
    settle_round,
)

PREDICTION_SIG = "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)"
SUMMARY_SIG = "getSummary(uint256,address[],string,string)(int256)"
FEEDBACK_SIG = "giveFeedback(uint256,int128,uint8,string,string,string,string,bytes32)"


@pytest.fixture(scope="module")
def chain():
    with Anvil() as c:
        yield c


@pytest.fixture(scope="module")
def committed(chain):
    d = deploy(chain)
    rid = open_round(d)
    commit_all(d, rid)
    return d, rid


@pytest.fixture(scope="module")
def submitted(committed):
    """Reveal the committed forecasts. The resubmission test stays above this fixture on purpose:
    a second commit is only possible while commits are open."""
    d, rid = committed
    reveal_all(d, rid)
    return d, rid


@pytest.fixture(scope="module")
def settled(submitted):
    """Settle the module's round once; the tests below read this settled state.

    A round settles only once, so the settlement belongs to a fixture. The resubmission test
    stays above this fixture on purpose: it needs a round that is not settled yet.
    """
    d, rid = submitted
    return d, rid, settle_round(d, rid)


def test_resubmission_rejected(committed):
    d, rid = committed
    a = d.agents[0]
    hidden = d.chain.call(d.market, PREDICTION_SIG, rid, a.address)
    assert hidden[0] is False or hidden[0] == "false", "forecast must stay hidden until revealed"
    already_predicted = "0x3b9e91cf"  # cast sig "AlreadyPredicted()"
    with pytest.raises(RuntimeError, match=f"AlreadyPredicted|{already_predicted}"):
        a.commit(d.chain, d.market, rid, d.rounds[rid]["submissions"][a.name])


def test_agent_proves_and_submits(submitted):
    d, rid = submitted
    c = d.chain
    assert as_int(c.call(d.market, "predictorCount(uint256)(uint256)", rid)[0]) == len(d.agents)
    for a in d.agents:
        rec, model_id, probs, _ = c.call(
            d.market,
            "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)",
            rid,
            a.address,
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
    a = d.agents[0]
    already_revealed = "0xa89ac151"  # cast sig "AlreadyRevealed()"
    with pytest.raises(RuntimeError, match=f"AlreadyRevealed|{already_revealed}"):
        a.reveal(d.chain, d.market, rid)


def test_agents_compare_after_round(settled):
    d, rid, res = settled
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


def test_agent_score_written_to_reputation(settled):
    d, rid, _ = settled
    c = d.chain
    scores = {
        a.name: as_int(c.call(d.market, PREDICTION_SIG, rid, a.address)[3])
        for a in d.agents
    }
    for a in d.agents:
        summary = as_int(
            c.call(
                d.reputation,
                SUMMARY_SIG,
                d.agent_ids[a.name],
                f"[{d.market}]",
                "logScore",
                "",
            )[0]
        )
        assert summary == scores[a.name]

    # Feedback from a client other than the market must stay out of the market's summary.
    a = d.agents[0]
    c.send(
        DEV_KEYS[0],
        d.reputation,
        FEEDBACK_SIG,
        d.agent_ids[a.name],
        123456789,
        18,
        "logScore",
        "vol-300s-12",
        "",
        "",
        "0x" + "00" * 32,
    )
    summary = as_int(
        c.call(
            d.reputation,
            SUMMARY_SIG,
            d.agent_ids[a.name],
            f"[{d.market}]",
            "logScore",
            "",
        )[0]
    )
    assert summary == scores[a.name]
