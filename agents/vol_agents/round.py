"""One VolMarket round on a local anvil chain with the three agents competing.

deploy(): MockERC20, MockPool, VolMarket(Δ=300, N=12, quantile levels, output scale 2^12), the
ERC-8004 Lite identity and reputation registries and one EZKL verifier per model; each model is
registered with its own agent as operator, and each agent registers an ERC-8004 identity that the
market links to its model, so the settled pinball score reaches that agent's reputation.
open_round(): set the pool's 17 history segments and 12 window segments, createRound at T0 with
the training-period climatological baseline quantiles (models/baseline_quantiles.json).
commit_all(): every agent proves and commits a hash of its forecast; reveal_all(): once commits
close, every agent reveals outputs and proof. settle_round(): sample every checkpoint, settle,
read each agent's onchain score (-pinball loss) and write out/compare_round.json.

Usage: uv run python -m vol_agents.round   (starts and stops its own anvil)
"""

import json
from dataclasses import dataclass, field

from . import contract_math as cm
from .agent import Agent
from .build import build, model_names, verifier_name
from .chain import DEV_KEYS, Anvil, address_of, as_int
from .ezkl_step import OUT, ROOT

# Segment ticks: 17 history segments (tick increments of about +-12, a typical hour of the real
# pool) and VolMarket.t.sol's _mixed() window path scaled by 5 (RV 49 * 25 = 1225, bucket 3 under
# cm.BOUNDS).
HISTORY_DIFFS = [10, -15, 5, 20, -10, 0, -15, 10, 5, -20, 15, -5, 10, -10, 0, 15]
BASE_TICK = 196000
WINDOW_TICKS = [
    196000, 196010, 195995, 196015, 196015, 196010, 196000, 196005, 195995, 195995, 196010, 196005,
]
COMPARE = OUT / "compare_round.json"
BASELINE_QUANTILES = ROOT / "models" / "baseline_quantiles.json"
PREDICTION_SIG = "getPrediction(uint256,address)(bool,uint256,int256[],int256)"
SCORING_SIG = "getRoundScoring(uint256)(int256,uint256,int256[])"
# Commits close COMMIT_LEAD s and reveals REVEAL_LEAD s before the round start (T0 + 2 * DELTA);
# the commit phase must outlast the agents' proving, which advances anvil's wall-clock time.
COMMIT_LEAD = 300
REVEAL_LEAD = 60
# ERC-8004 agent metadata URI: deterministic and never resolved, so a round stays reproducible.
AGENT_URI = "https://example.invalid/agents/{name}"
# keccak256("Registered(uint256,string,address)")
REGISTERED_TOPIC = "0xca52e62c367d81bb2e328eb795f7c7ba24afb478408a26c0e201d155c449bc4a"
# keccak256("Transfer(address,address,uint256)")
TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"


def history_ticks():
    t = [BASE_TICK]
    for d in HISTORY_DIFFS:
        t.append(t[-1] + d)
    return t


def int_list(values) -> str:
    """cast argument for uint256[] / int256[]."""
    return "[" + ",".join(str(int(v)) for v in values) + "]"


def baseline_quantiles(path=BASELINE_QUANTILES) -> list[int]:
    """Training-period climatological quantiles of ln RV (1e18), checked against the market's
    levels and output grid."""
    b = json.loads(path.read_text())
    if [int(t) for t in b["levels_e18"]] != list(cm.QUANTILE_LEVELS_E18):
        raise ValueError(f"{path}: levels {b['levels_e18']} differ from QUANTILE_LEVELS_E18")
    q = [int(v) for v in b["quantiles_e18"]]
    if any(v % cm.OUTPUT_UNIT_E18 for v in q) or not cm.valid_outputs(
            [v // cm.OUTPUT_UNIT_E18 for v in q]):
        raise ValueError(f"{path}: baseline quantiles off the 2^-12 grid or not increasing")
    return q


def deploy_market(chain: Anvil, owner, token, pool, fee_bps=0, share_bps=0,
                  commit_lead=COMMIT_LEAD, reveal_lead=REVEAL_LEAD) -> str:
    return chain.deploy(
        owner, "src/VolMarket.sol:VolMarket", token, fee_bps, share_bps, pool, cm.DELTA,
        cm.N_SEGMENTS, commit_lead, reveal_lead, int_list(cm.QUANTILE_LEVELS_E18),
        cm.OUTPUT_SCALE_BITS,
    )


def create_round(chain: Anvil, owner, market, start, bounds=cm.BOUNDS, baseline=None):
    chain.send(owner, market, "createRound(uint64,uint256[],int256[])", start, int_list(bounds),
               int_list(baseline if baseline is not None else baseline_quantiles()))


@dataclass
class Deployment:
    chain: Anvil
    token: str
    pool: str
    market: str
    identity: str
    reputation: str
    agents: list[Agent]
    agent_ids: dict = field(default_factory=dict)  # agent name -> ERC-8004 agentId
    rounds: dict = field(default_factory=dict)


def _registered_agent_id(receipt: dict) -> int:
    """The agentId minted by `register`, read from the events of its receipt.

    The Lite identity registry emits only Registered(agentId indexed, ...); an ERC-721 ERC-8004
    registry also emits a mint Transfer(0, owner, tokenId) that may come first. Registered is
    preferred, the mint Transfer is the fallback, and a receipt with neither raises instead of
    returning a default id.
    """
    logs = [
        [t.lower() for t in (log.get("topics") or [])] for log in receipt.get("logs") or []
    ]
    for topics in logs:
        if len(topics) >= 2 and topics[0] == REGISTERED_TOPIC:
            return int(topics[1], 16)
    for topics in logs:
        if len(topics) >= 4 and topics[0] == TRANSFER_TOPIC and int(topics[1], 16) == 0:
            return int(topics[3], 16)
    raise RuntimeError(
        f"identity registration receipt has no Registered or mint Transfer event: {receipt}"
    )


def register_identity(chain: Anvil, identity: str, key: str, uri: str) -> int:
    """Register `uri` under the account of `key` and return the minted ERC-8004 agentId.

    The registering key owns the identity, which is what lets that account link the identity
    to its model.
    """
    receipt = chain.send(key, identity, "register(string)(uint256)", uri)
    return _registered_agent_id(receipt)


def deploy(chain: Anvil, models=None) -> Deployment:
    models = models or model_names()
    assert 2 <= len(models) <= 3
    owner = DEV_KEYS[0]
    token = chain.deploy(owner, "test/mocks/MockERC20.sol:MockERC20")
    pool = chain.deploy(owner, "test/mocks/MockPool.sol:MockPool")
    market = deploy_market(chain, owner, token, pool)
    identity = chain.deploy(owner, "src/erc8004/IdentityRegistryLite.sol:IdentityRegistryLite")
    reputation = chain.deploy(
        owner, "src/erc8004/ReputationRegistryLite.sol:ReputationRegistryLite"
    )
    chain.send(owner, market, "setReputation(address,address)", identity, reputation)
    agents = []
    agent_ids = {}
    for i, m in enumerate(models):
        build(m)
        name = verifier_name(m)
        verifier = chain.deploy(owner, f"src/verifier/{name}.sol:{name}")
        key = DEV_KEYS[1 + i]
        agent = Agent(name=f"agent-{m}", model=m, key=key, address=address_of(key))
        chain.send(owner, market, "registerModel(address,address)", verifier, agent.address)
        agent.model_id = as_int(chain.call(market, "modelCount()(uint256)")[0]) - 1
        # The agent owns its identity and links it to its model, so the market can write the
        # settled pinball score to that agent's reputation.
        agent_id = register_identity(
            chain, identity, key, AGENT_URI.format(name=agent.name)
        )
        chain.send(key, market, "linkAgent(uint256,uint256)", agent.model_id, agent_id)
        agent_ids[agent.name] = agent_id
        agents.append(agent)
    return Deployment(
        chain=chain,
        token=token,
        pool=pool,
        market=market,
        identity=identity,
        reputation=reputation,
        agents=agents,
        agent_ids=agent_ids,
    )


def open_round(d: Deployment) -> int:
    c, owner = d.chain, DEV_KEYS[0]
    t0 = c.timestamp() + 1000
    start = t0 + 2 * cm.DELTA
    hist = history_ticks()
    c.send(owner, d.pool, "setSegments(uint256,uint256,int24[])", t0 - 17 * cm.DELTA, cm.DELTA,
           "[" + ",".join(map(str, hist)) + "]")
    c.send(owner, d.pool, "setSegments(uint256,uint256,int24[])", start, cm.DELTA,
           "[" + ",".join(map(str, WINDOW_TICKS)) + "]")
    c.set_next_timestamp(t0)
    create_round(c, owner, d.market, start)
    rid = as_int(c.call(d.market, "roundCount()(uint256)")[0]) - 1
    feats = [as_int(v) for v in c.call(d.market, "getFeatures(uint256)(int256[16])", rid)[0]]
    assert feats == cm.features_from_segment_ticks(hist), (feats, hist)
    d.rounds[rid] = {"start": start, "submissions": {}}
    return rid


def commit_all(d: Deployment, rid: int):
    for a in d.agents:
        d.rounds[rid]["submissions"][a.name] = a.commit(d.chain, d.market, rid)


def reveal_all(d: Deployment, rid: int):
    d.chain.set_next_timestamp(max(d.chain.timestamp() + 1, d.rounds[rid]["start"] - COMMIT_LEAD))
    for a in d.agents:
        a.reveal(d.chain, d.market, rid)


def submit_all(d: Deployment, rid: int):
    commit_all(d, rid)
    reveal_all(d, rid)


def settle_round(d: Deployment, rid: int):
    c, owner = d.chain, DEV_KEYS[0]
    start = d.rounds[rid]["start"]
    for k in range(cm.N_SEGMENTS + 1):
        c.set_next_timestamp(start + k * cm.DELTA + 1)
        c.send(owner, d.market, "sample(uint256,uint256)", rid, k)
    c.set_next_timestamp(start + cm.N_SEGMENTS * cm.DELTA + 10)
    c.send(owner, d.market, "settle(uint256)", rid)
    r = c.call(
        d.market,
        "getRound(uint256)(uint64,bool,bool,uint256,uint256,uint256,uint256[5],uint256[])",
        rid,
    )
    settled, voided, win, rv = r[1], r[2], as_int(r[3]), as_int(r[4])
    ln_rv, baseline_loss, baseline = c.call(d.market, SCORING_SIG, rid)
    ln_rv, baseline_loss = as_int(ln_rv), as_int(baseline_loss)
    rows = []
    for a in d.agents:
        p = c.call(d.market, PREDICTION_SIG, rid, a.address)
        q = [as_int(v) for v in p[2]]
        score = as_int(p[3])
        rows.append({
            "agent": a.name,
            "model": getattr(a, "model", None),
            "model_id": as_int(p[1]),
            "submitted": p[0] is True or p[0] == "true",
            "score": score,
            "pinball_loss": -score / 1e18,
            "excess": max(baseline_loss + score, 0) / 1e18,
            "quantiles": [v / 1e18 for v in q],
            "quantiles_e18": [str(v) for v in q],
            "prove_seconds": a.timings.get("prove", {}).get("seconds"),
            "prove_peak_mb": a.timings.get("prove", {}).get("peak_mb"),
        })
    rows.sort(key=lambda r: r["score"], reverse=True)
    expected_rv = cm.realized_vol(WINDOW_TICKS)
    result = {
        "round_id": rid,
        "market": d.market,
        "settled": settled is True or settled == "true",
        "voided": voided is True or voided == "true",
        "realized_vol": rv,
        "winning_bucket": win,
        "ln_rv_e18": str(ln_rv),
        "ln_rv": ln_rv / 1e18,
        "quantile_levels": list(cm.QUANTILE_LEVELS),
        "baseline_quantiles": [as_int(v) / 1e18 for v in baseline],
        "baseline_loss": baseline_loss / 1e18,
        "expected": {"realized_vol": expected_rv, "bucket": cm.bucket_of(expected_rv),
                     "ln_rv_e18": str(cm.ln_rv_e18(expected_rv))},
        "score_unit": "-mean pinball loss of ln(max(RV, 1)) over the quantile levels, scaled 1e18",
        "winner": rows[0]["agent"],
        "agents": rows,
    }
    COMPARE.parent.mkdir(parents=True, exist_ok=True)
    COMPARE.write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    with Anvil() as chain:
        d = deploy(chain)
        rid = open_round(d)
        submit_all(d, rid)
        print(json.dumps(settle_round(d, rid), indent=2))


if __name__ == "__main__":
    main()
