"""One VolMarket round on a local anvil chain with the three agents competing.

deploy(): MockERC20, MockPool, VolMarket(Δ=300, N=12), the ERC-8004 Lite identity and reputation
registries and one EZKL verifier per model; each model is registered with its own agent as
operator, and each agent registers an ERC-8004 identity that the market links to its model, so
the settled log score reaches that agent's reputation. open_round(): set the pool's 17 history
segments and 12 window segments, createRound at T0. Every agent then proves and submits.
settle_round(): sample every checkpoint, settle, read each agent's onchain log score and write
out/compare_round.json.

Usage: uv run python -m vol_agents.round   (starts and stops its own anvil)
"""

import json
from dataclasses import dataclass, field

from . import contract_math as cm
from .agent import Agent
from .build import build, model_names, verifier_name
from .chain import DEV_KEYS, Anvil, address_of, as_int
from .ezkl_step import OUT

# Segment ticks: 17 history segments (tick increments of about +-2.3, RV regime near bucket 3) and
# the 12 window segments of VolMarket.t.sol's _mixed() (RV 49, bucket 3).
HISTORY_DIFFS = [2, -3, 1, 4, -2, 0, -3, 2, 1, -4, 3, -1, 2, -2, 0, 3]
BASE_TICK = 196000
WINDOW_TICKS = [
    196000, 196002, 195999, 196003, 196003, 196002, 196000, 196001, 195999, 195999, 196002, 196001,
]
COMPARE = OUT / "compare_round.json"
# ERC-8004 agent metadata URI: deterministic and never resolved, so a round stays reproducible.
AGENT_URI = "https://example.invalid/agents/{name}"


def history_ticks():
    t = [BASE_TICK]
    for d in HISTORY_DIFFS:
        t.append(t[-1] + d)
    return t


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
    """The agentId minted by `register`, read from the Registered event of its receipt.

    The Lite identity registry emits exactly one event per registration and the agentId is
    its first indexed topic.
    """
    for log in receipt.get("logs") or []:
        topics = log.get("topics") or []
        if len(topics) >= 2:
            return int(topics[1], 16)
    raise RuntimeError(f"identity registration receipt has no Registered event: {receipt}")


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
    market = chain.deploy(
        owner, "src/VolMarket.sol:VolMarket", token, 0, pool, cm.DELTA, cm.N_SEGMENTS
    )
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
        # settled log score to that agent's reputation.
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
    c.send(owner, d.market, "createRound(uint64,uint256[])", start,
           "[" + ",".join(map(str, cm.BOUNDS)) + "]")
    rid = as_int(c.call(d.market, "roundCount()(uint256)")[0]) - 1
    feats = [as_int(v) for v in c.call(d.market, "getFeatures(uint256)(int256[16])", rid)[0]]
    assert feats == cm.features_from_segment_ticks(hist), (feats, hist)
    d.rounds[rid] = {"start": start, "submissions": {}}
    return rid


def submit_all(d: Deployment, rid: int):
    for a in d.agents:
        d.rounds[rid]["submissions"][a.name] = a.forecast(d.chain, d.market, rid)


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
    rows = []
    for a in d.agents:
        p = c.call(d.market, "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)", rid,
                   a.address)
        probs = [as_int(v) for v in p[2]]
        rows.append({
            "agent": a.name,
            "model": a.model,
            "model_id": as_int(p[1]),
            "submitted": p[0] is True or p[0] == "true",
            "score": as_int(p[3]),
            "p_win": probs[win] / 1e18,
            "probs": [v / 1e18 for v in probs],
            "prove_seconds": a.timings.get("prove", {}).get("seconds"),
            "prove_peak_mb": a.timings.get("prove", {}).get("peak_mb"),
        })
    rows.sort(key=lambda r: r["score"], reverse=True)
    result = {
        "round_id": rid,
        "market": d.market,
        "settled": settled is True or settled == "true",
        "voided": voided is True or voided == "true",
        "realized_vol": rv,
        "winning_bucket": win,
        "expected": {"realized_vol": cm.realized_vol(WINDOW_TICKS),
                     "bucket": cm.bucket_of(cm.realized_vol(WINDOW_TICKS))},
        "score_unit": "natural log of p_win, scaled 1e18 (VolMarket logScore)",
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
