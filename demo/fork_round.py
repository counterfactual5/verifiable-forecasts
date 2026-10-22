"""One VolMarket round on an anvil fork of Ethereum mainnet.

The market reads the real Uniswap V3 ETH/USDC 0.05% pool, writes scores to the deployed ERC-8004
registries and cross-checks the pool price against the Chainlink ETH/USD feed. The three EZKL agents
from agents/ prove on the round's onchain features (the pool's real last 85 minutes), and a fourth,
commit-only agent asks a time-series forecasting API (VOL_TSFM_API_URL; a deterministic local
placeholder when unset). Every agent commits a hash first and reveals once commits close; the zk
agents' reveals carry the proof. Forecasts above the uniform baseline share half of the fee.

The fork starts at a Chainlink update at least an hour in the past, so the round window is an hour
that already happened on mainnet. During the window a trader swaps the forked pool to the real
5-minute TWAP tick of each segment (read from mainnet's own `observe`), replaying the real price
path; `sample`/`settle` then close the round as anyone could, and the bettors claim. If that hour is
no longer in mainnet's observation history (an old pinned FORK_BLOCK) the trader instead swaps a
small fixed back-and-forth pattern. Everything happens on the local fork: nothing is broadcast.

Usage: bash demo/run.sh   (writes demo/out/fork_round.json for the dashboard)
"""

import json
import os
import subprocess
import sys
import time
from decimal import Decimal, getcontext
from pathlib import Path

from vol_agents import contract_math as cm
from vol_agents.agent import Agent
from vol_agents.api_agent import ApiAgent, ApiConfig
from vol_agents.build import build, model_names, verifier_name
from vol_agents.chain import DEV_KEYS, Anvil, address_of, as_int
from vol_agents.ezkl_step import OUT as AGENTS_OUT

REPO = Path(__file__).resolve().parent.parent
RESULT = REPO / "demo" / "out" / "fork_round.json"

POOL = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"  # Uniswap V3 ETH/USDC 0.05%, token0 USDC
FEED = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"  # Chainlink ETH/USD, 8 decimals
IDENTITY = "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432"  # ERC-8004 v2.0.0 Identity (mainnet)
REPUTATION = "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63"  # ERC-8004 v2.0.0 Reputation (mainnet)
WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
SWAP_ROUTER = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"  # Uniswap SwapRouter02
DEFAULT_RPC = "https://mainnet.gateway.tenderly.co"

# anvil dev accounts 4 and 5 (same public mnemonic as chain.DEV_KEYS); fork-local only
BETTOR_KEYS = [
    "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
    "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
]
# anvil dev account 6, operator of the commit-only agent; fork-local only
API_AGENT_KEY = "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e"
FEE_BPS = 100
PREDICTOR_SHARE_BPS = 5000
# Commits close COMMIT_LEAD s and reveals REVEAL_LEAD s before the round start. Kept short: the
# whole lead counts against the feed's 3900 s staleness limit at settlement.
COMMIT_LEAD = 90
REVEAL_LEAD = 30
BET_WEI = 10**18
# The placeholder bounds the models were trained on (agents/vol_agents/contract_math.py).
BOUNDS = cm.BOUNDS
# Trader inventory: WETH, plus USDC bought on the 0.3% pool so the 0.05% pool is untouched before
# the round. Swaps carry a price limit, so only the amount needed to reach the target is spent.
TRADER_WETH = 20_000
TRADER_USDC_FROM_ETH = 2_000
# Fallback pattern: ETH sold at the start of even segments, bought back in odd ones, so the price
# ends where it started and the Chainlink cross-check compares like with like.
SCRIPTED_SWAP_ETH = [3, 5, 2, 4, 6, 3]
# Blocks advance one second each so that deployment wall time does not age the Chainlink answer
# (settle voids the round once the answer is older than 3900 s).
BLOCK_INTERVAL_S = 1
ROUND_LEAD_S = 120
SETTLE_AFTER_S = 10
# Seconds between the fork block and the round start (deployment blocks plus ROUND_LEAD_S), with
# room to spare; the fork block is chosen so that start + window is still in mainnet's past.
SETUP_MARGIN_S = 600
FIXED_GAS = 8_000_000
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
EXACT_INPUT = "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"
ROUND_SIG = "getRound(uint256)(uint64,bool,bool,uint256,uint256,uint256,uint256[5],uint256[])"
FEED_SIG = "latestRoundData()(uint80,int256,uint256,uint256,uint80)"
OBSERVE_SIG = "observe(uint32[])(int56[],uint160[])"

getcontext().prec = 60


def log(msg):
    print(f"[demo] {msg}", flush=True)


def cast(*args, timeout=600):
    r = subprocess.run(["cast", *map(str, args)], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"cast {' '.join(map(str, args[:3]))} failed:\n{r.stderr[-2000:]}")
    return r.stdout.strip()


def cast_json(*args):
    return json.loads(cast(*args, "--json"))


def replayable_feed_update_block(rpc):
    """Block of the latest Chainlink answer old enough that the whole round window lies in
    mainnet's past; forking right at an update leaves the most headroom before the 3900 s
    staleness limit at settlement."""
    latest_ts = int(cast("block", "latest", "--field", "timestamp", "--rpc-url", rpc))
    round_id = as_int(cast_json("call", FEED, FEED_SIG, "--rpc-url", rpc)[0])
    for back in range(48):
        r = cast_json("call", FEED, "getRoundData(uint80)(uint80,int256,uint256,uint256,uint80)",
                      round_id - back, "--rpc-url", rpc)
        updated_at = as_int(r[3])
        if updated_at + SETUP_MARGIN_S + cm.N_SEGMENTS * cm.DELTA <= latest_ts:
            break
    else:
        raise RuntimeError("no Chainlink answer old enough to replay the window")
    block = int(cast("find-block", updated_at, "--rpc-url", rpc))
    for b in (block, block + 1):
        got = as_int(cast_json("call", FEED, FEED_SIG, "--rpc-url", rpc, "--block", b)[3])
        if got == updated_at:
            return b
    raise RuntimeError(f"no block found for Chainlink update at {updated_at}")


def real_segment_ticks(rpc, start):
    """The real pool's mean tick in each window segment, from mainnet's own observe(); None when
    the window is not (or no longer) in mainnet's observation history."""
    now = int(cast("block", "latest", "--field", "timestamp", "--rpc-url", rpc))
    ends = [start + k * cm.DELTA for k in range(cm.N_SEGMENTS + 1)]
    if ends[-1] > now:
        return None
    secs = "[" + ",".join(str(now - t) for t in ends) + "]"
    try:
        cums = [as_int(v) for v in cast_json("call", POOL, OBSERVE_SIG, secs, "--rpc-url", rpc)[0]]
    except RuntimeError:
        return None
    return [cm.floor_div(cums[k + 1] - cums[k], cm.DELTA) for k in range(cm.N_SEGMENTS)]


def sqrt_price_x96(tick):
    """sqrtPriceX96 halfway into `tick`, so a swap limited there leaves the pool at that tick."""
    return int((Decimal("1.0001") ** (Decimal(tick) + Decimal("0.5"))).sqrt() * (2**96))


class ForkAnvil(Anvil):
    def __init__(self, fork_url, fork_block):
        super().__init__()
        self.fork_url, self.fork_block = fork_url, fork_block

    def __enter__(self):
        self.proc = subprocess.Popen(
            ["anvil", "--port", str(self.port), "--silent", "--fork-url", self.fork_url,
             "--fork-block-number", str(self.fork_block)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 120
        while time.time() < deadline:
            try:
                self.block_number()
                break
            except RuntimeError:
                time.sleep(0.5)
        else:
            self.close()
            raise RuntimeError("forked anvil did not start")
        self.rpc_call("anvil_setBlockTimestampInterval", BLOCK_INTERVAL_S)
        # On mainnet anvil's public test keys carry EIP-7702 sweeper delegations; as plain EOAs
        # again they can receive the ERC-721 identity mint and keep their fork-local ETH.
        for key in DEV_KEYS + BETTOR_KEYS + [API_AGENT_KEY]:
            self.rpc_call("anvil_setCode", address_of(key), "0x")
        return self

    def rpc_call(self, method, *params):
        return cast("rpc", method, *params, "--rpc-url", self.rpc)

    def call_at(self, block, to, sig, *args):
        return cast_json("call", to, sig, *args, "--rpc-url", self.rpc, "--block", block)

    def send_gas(self, key, to, sig, *args, gas=FIXED_GAS):
        """A send with a fixed gas limit: pool swaps skip the slow fork estimate."""
        receipt = cast_json("send", to, sig, *args, "--private-key", key, "--rpc-url", self.rpc,
                            "--gas-limit", gas)
        if receipt.get("status") not in ("0x1", 1, "1"):
            raise RuntimeError(f"{sig} reverted: {receipt}")
        return receipt


def topic(event_sig):
    return cast("keccak", event_sig).lower()


def logs_with(receipt, address, event_sig):
    t0 = topic(event_sig)
    return [lg for lg in receipt.get("logs") or []
            if lg["address"].lower() == address.lower() and lg["topics"][0].lower() == t0]


def truthy(v):
    return v is True or v == "true"


def minted_agent_id(receipt):
    """ERC-8004 identities are ERC-721 tokens: the agentId is the tokenId of the mint Transfer."""
    for lg in logs_with(receipt, IDENTITY, "Transfer(address,address,uint256)"):
        if int(lg["topics"][1], 16) == 0:
            return int(lg["topics"][3], 16)
    raise RuntimeError(f"identity registration minted no token: {receipt}")


def deploy(c, owner):
    market = c.deploy(owner, "src/VolMarket.sol:VolMarket", WETH, FEE_BPS, PREDICTOR_SHARE_BPS,
                      POOL, cm.DELTA, cm.N_SEGMENTS, COMMIT_LEAD, REVEAL_LEAD)
    c.send(owner, market, "setReputation(address,address)", IDENTITY, REPUTATION)
    c.send(owner, market, "setPriceFeed(address)", FEED)
    agents, agent_ids, verifiers = [], {}, {}
    zk = []
    for i, m in enumerate(model_names()):
        build(m)
        name = verifier_name(m)
        key = DEV_KEYS[1 + i]
        zk.append((Agent(name=f"agent-{m}", model=m, key=key, address=address_of(key)),
                   c.deploy(owner, f"src/verifier/{name}.sol:{name}")))
    api = ApiAgent(name="agent-tsfm-api", key=API_AGENT_KEY, address=address_of(API_AGENT_KEY),
                   config=ApiConfig.from_env())
    for agent, verifier in zk + [(api, ZERO_ADDRESS)]:
        c.send(owner, market, "registerModel(address,address)", verifier, agent.address)
        agent.model_id = as_int(c.call(market, "modelCount()(uint256)")[0]) - 1
        receipt = c.send(agent.key, IDENTITY, "register(string)(uint256)",
                         f"https://example.invalid/agents/{agent.name}")
        agent_id = minted_agent_id(receipt)
        c.send(agent.key, market, "linkAgent(uint256,uint256)", agent.model_id, agent_id)
        kind = f"verifier {verifier}" if verifier != ZERO_ADDRESS else (
            f"commit-only (no proof), forecast source {api.source}")
        log(f"{agent.name}: model {agent.model_id}, {kind}, ERC-8004 agentId {agent_id}")
        agents.append(agent)
        agent_ids[agent.name] = agent_id
        verifiers[agent.name] = verifier if verifier != ZERO_ADDRESS else None
    return market, agents, agent_ids, verifiers


def fund_trader(c, key):
    trader = address_of(key)
    c.rpc_call("anvil_setBalance", trader, hex((TRADER_WETH + TRADER_USDC_FROM_ETH + 100) * 10**18))
    c.send(key, WETH, "deposit()", "--value", f"{TRADER_WETH + TRADER_USDC_FROM_ETH}ether")
    c.send(key, WETH, "approve(address,uint256)", SWAP_ROUTER, 2**256 - 1)
    c.send(key, USDC, "approve(address,uint256)", SWAP_ROUTER, 2**256 - 1)
    c.send_gas(key, SWAP_ROUTER, EXACT_INPUT,
               f"({WETH},{USDC},3000,{trader},{TRADER_USDC_FROM_ETH * 10**18},0,0)")


def open_round(c, owner, market):
    start = c.timestamp() + ROUND_LEAD_S
    receipt = c.send(owner, market, "createRound(uint64,uint256[])", start,
                     "[" + ",".join(map(str, BOUNDS)) + "]")
    rid = as_int(c.call(market, "roundCount()(uint256)")[0]) - 1
    feats = [as_int(v) for v in c.call(market, "getFeatures(uint256)(int256[16])", rid)[0]]
    block = int(receipt["blockNumber"], 0)
    secs = "[" + ",".join(str((cm.N_FEATURES + 1 - i) * cm.DELTA)
                          for i in range(cm.N_FEATURES + 2)) + "]"
    cums = [as_int(v) for v in c.call_at(block, POOL, OBSERVE_SIG, secs)[0]]
    if cm.features_from_cumulatives(cums) != feats:
        raise RuntimeError(f"contract features differ from the pool's observe(): {feats}")
    return rid, start, feats


def tamper_check(c, agent, verifier, market, rid, sub):
    """The verifier accepts the submitted proof and rejects it once one output is changed."""
    work = AGENTS_OUT / "rounds" / f"{market.lower()}-{rid}" / agent.name
    proof = json.loads((work / "proof.json").read_text())["hex_proof"]
    inst = [cm.encode(v) for v in sub["features"]] + list(sub["outputs"])
    tampered = inst[:-1] + [inst[-1] + 1]

    def verify(instances):
        try:
            out = c.call(verifier, "verifyProof(bytes,uint256[])(bool)", proof,
                         "[" + ",".join(map(str, instances)) + "]")
            return truthy(out[0])
        except RuntimeError:
            return False

    return {"agent": agent.name, "honest_proof_verifies": verify(inst),
            "tampered_output_verifies": verify(tampered)}


def place_bets(c, market, rid, agents_probs):
    """Bettor 0 follows the agents' consensus bucket, bettor 1 takes the runner-up."""
    mean = [sum(p[b] for p in agents_probs) / len(agents_probs) for b in range(cm.BUCKETS)]
    ranked = sorted(range(cm.BUCKETS), key=lambda b: mean[b], reverse=True)
    bets = []
    for key, bucket in zip(BETTOR_KEYS, ranked[:2], strict=True):
        who = address_of(key)
        c.send(key, WETH, "deposit()", "--value", BET_WEI)
        c.send(key, WETH, "approve(address,uint256)", market, BET_WEI)
        c.send(key, market, "bet(uint256,uint256,uint256)", rid, bucket, BET_WEI)
        bets.append({"bettor": who, "bucket": bucket, "amount_wei": str(BET_WEI)})
    return bets


def pool_tick(c):
    return as_int(c.call(POOL, "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)")[1])


def balance(c, token, who):
    return as_int(c.call(token, "balanceOf(address)(uint256)", who)[0])


def swap_to_tick(c, key, target):
    """Swap the forked pool to `target`; selling WETH raises the tick, selling USDC lowers it."""
    trader, now = address_of(key), pool_tick(c)
    if target == now:
        return "hold"
    up = target > now
    token_in, token_out = (WETH, USDC) if up else (USDC, WETH)
    amount = balance(c, token_in, trader)
    c.send_gas(key, SWAP_ROUTER, EXACT_INPUT,
               f"({token_in},{token_out},500,{trader},{amount},0,{sqrt_price_x96(target)})")
    return "sell WETH" if up else "sell USDC"


def scripted_swap(c, key, k, usdc_reserve):
    """Odd segments buy back with only the USDC the even segment's sale brought in."""
    trader = address_of(key)
    if k % 2 == 0:
        amount = SCRIPTED_SWAP_ETH[k // 2] * 10**18
        token_in, token_out, side = WETH, USDC, f"sell {SCRIPTED_SWAP_ETH[k // 2]} WETH"
    else:
        amount = balance(c, USDC, trader) - usdc_reserve
        token_in, token_out, side = USDC, WETH, "buy it back"
    c.send_gas(key, SWAP_ROUTER, EXACT_INPUT,
               f"({token_in},{token_out},500,{trader},{amount},0,0)")
    return side


def run_window(c, trader_key, market, rid, start, targets):
    """Sample every checkpoint as soon as it passes and trade the pool in between."""
    usdc_reserve = balance(c, USDC, address_of(trader_key))
    swaps = []
    for k in range(cm.N_SEGMENTS + 1):
        c.set_next_timestamp(start + k * cm.DELTA + 1)
        c.send(trader_key, market, "sample(uint256,uint256)", rid, k)
        if k == cm.N_SEGMENTS:
            break
        before = pool_tick(c)
        if targets:
            side = swap_to_tick(c, trader_key, targets[k])
        else:
            side = scripted_swap(c, trader_key, k, usdc_reserve)
        after = pool_tick(c)
        swaps.append({"segment": k, "side": side, "tick_before": before, "tick_after": after,
                      "target_tick": targets[k] if targets else None})
        goal = f" (real {targets[k]})" if targets else ""
        log(f"segment {k:2d}: {side:<12} tick {before} -> {after}{goal}")
    return swaps


def offchain_rv(c, market, rid):
    cums = []
    for k in range(cm.N_SEGMENTS + 1):
        sampled, cum = c.call(market, "getCheckpoint(uint256,uint256)(bool,int56)", rid, k)
        assert truthy(sampled)
        cums.append(as_int(cum))
    means = [cm.floor_div(cums[k] - cums[k - 1], cm.DELTA) for k in range(1, len(cums))]
    rv = cm.realized_vol(means)
    return {"segment_mean_ticks": means, "realized_vol": rv, "bucket": cm.bucket_of(rv, BOUNDS)}


def chainlink_check(c, market, block, settle_ts):
    _, answer, _, updated_at, _ = c.call_at(block, FEED, FEED_SIG)
    answer, updated_at = as_int(answer), as_int(updated_at)
    cums = c.call_at(block, POOL, OBSERVE_SIG, f"[{cm.DELTA},0]")[0]
    tick = cm.floor_div(as_int(cums[1]) - as_int(cums[0]), cm.DELTA)
    pool_price = as_int(c.call_at(block, market, "priceForTick(int24)(uint256)", tick)[0])
    deviation_bps = abs(pool_price - answer) * 10_000 / answer
    return {
        "feed": FEED, "feed_price_usd": answer / 1e8, "feed_updated_at": updated_at,
        "feed_age_s": settle_ts - updated_at, "pool_mean_tick": tick,
        "pool_price_usd": pool_price / 1e8, "deviation_bps": round(deviation_bps, 2),
        "max_deviation_bps": 200, "max_age_s": 3900,
    }


def settle(c, owner, market, rid, start):
    settle_ts = start + cm.N_SEGMENTS * cm.DELTA + SETTLE_AFTER_S
    c.set_next_timestamp(settle_ts)
    # Estimated gas on purpose: the estimate is the lowest limit settle accepts, and settle reverts
    # rather than skip an external call that limit would starve.
    receipt = c.send(owner, market, "settle(uint256)", rid)
    gas_limit = as_int(cast("tx", receipt["transactionHash"], "gas", "--rpc-url", c.rpc))
    r = c.call(market, ROUND_SIG, rid)
    events = {
        "price_check_failed": len(logs_with(
            receipt, market, "PriceCheckFailed(uint256,int24,int256,int256,uint8)")),
        "reputation_write_failed": len(logs_with(
            receipt, market, "ReputationWriteFailed(uint256,address,uint256,bytes32)")),
        "erc8004_feedback_logs": sum(1 for lg in receipt.get("logs") or []
                                     if lg["address"].lower() == REPUTATION.lower()),
    }
    return {
        "settle_block": int(receipt["blockNumber"], 0), "settle_ts": settle_ts,
        "gas_used": int(receipt["gasUsed"], 0), "gas_limit": gas_limit,
        "settled": truthy(r[1]), "voided": truthy(r[2]),
        "winning_bucket": as_int(r[3]), "realized_vol": as_int(r[4]),
        "total_stake_wei": str(as_int(r[5])), "pools_wei": [str(as_int(v)) for v in r[6]],
        "events": events,
    }


def reputation_of(c, market, agent_id, kind):
    tag2 = f"vol-{cm.DELTA}s-{cm.N_SEGMENTS}" + ("-commit" if kind == "commit-only" else "")
    count, value, decimals = c.call(
        REPUTATION, "getSummary(uint256,address[],string,string)(uint64,int128,uint8)",
        agent_id, f"[{market}]", "logScore", tag2)
    return {"tag1": "logScore", "tag2": tag2, "count": as_int(count),
            "summary_value": str(as_int(value)), "summary_decimals": as_int(decimals)}


def claims(c, market, rid, bets, outcome):
    paid = []
    refund_all = outcome["voided"] or as_int(outcome["pools_wei"][outcome["winning_bucket"]]) == 0
    for key, bet in zip(BETTOR_KEYS, bets, strict=True):
        if not refund_all and bet["bucket"] != outcome["winning_bucket"]:
            paid.append({**bet, "payout_wei": "0"})
            continue
        before = balance(c, WETH, bet["bettor"])
        c.send(key, market, "claim(uint256)", rid)
        paid.append({**bet, "payout_wei": str(balance(c, WETH, bet["bettor"]) - before)})
    return paid


def collect_fee(c, owner, market, rid, outcome):
    """Anyone may push the owner's part of the round's fee to the market owner; refunded rounds
    carry none, and with every forecaster above the baseline and a 100 % share it is 0."""
    fee = 0 if outcome["voided"] or as_int(outcome["pools_wei"][outcome["winning_bucket"]]) == 0 \
        else as_int(outcome["total_stake_wei"]) * FEE_BPS // 10_000
    pool = as_int(c.call(market, "predictorPool(uint256)(uint256)", rid)[0])
    if fee - pool == 0:
        return "0"
    who = address_of(owner)
    before = balance(c, WETH, who)
    c.send(owner, market, "collectFee(uint256)", rid)
    return str(balance(c, WETH, who) - before)


def claim_predictor_rewards(c, market, rid, agents, scores):
    """Every forecaster above the uniform baseline pulls its share of the predictor pool."""
    pool = as_int(c.call(market, "predictorPool(uint256)(uint256)", rid)[0])
    base = as_int(c.call(market, "baselineLogScore()(int256)")[0])
    paid = {}
    for a in agents:
        if pool == 0 or scores[a.name] <= base:
            paid[a.name] = "0"
            continue
        before = balance(c, WETH, a.address)
        c.send(a.key, market, "claimPredictorReward(uint256)", rid)
        paid[a.name] = str(balance(c, WETH, a.address) - before)
    return pool, base, paid


def main():
    os.environ.setdefault("ETH_RPC_TIMEOUT", "300")
    rpc = os.environ.get("MAINNET_RPC_URL") or DEFAULT_RPC
    fork_block = int(os.environ.get("FORK_BLOCK") or replayable_feed_update_block(rpc))
    log(f"forking mainnet at block {fork_block}")
    owner = DEV_KEYS[0]
    with ForkAnvil(rpc, fork_block) as c:
        fork_ts = c.timestamp()
        market, agents, agent_ids, verifiers = deploy(c, owner)
        fund_trader(c, owner)
        rid, start, feats = open_round(c, owner, market)
        log(f"round {rid}: start {start}, features from the real pool {feats}")

        subs = {}
        for a in agents:
            subs[a.name] = a.commit(c, market, rid)
            how = (f"prove {a.timings['prove']['seconds']} s" if a.kind == "zk"
                   else f"commit-only, forecast from {subs[a.name]['source']}")
            log(f"{a.name}: committed ({how})")
        c.set_next_timestamp(start - COMMIT_LEAD)
        for a in agents:
            a.reveal(c, market, rid)
            log(f"{a.name}: revealed" + (", proof verified onchain" if a.kind == "zk"
                                          else ", no proof (commit-only)"))
        checks = [tamper_check(c, a, verifiers[a.name], market, rid, subs[a.name])
                  for a in agents if a.kind == "zk"]
        probs = {}
        for a in agents:
            p = c.call(market, "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)",
                       rid, a.address)
            probs[a.name] = [as_int(v) / 1e18 for v in p[2]]
        bets = place_bets(c, market, rid, list(probs.values()))

        targets = real_segment_ticks(rpc, start)
        real_rv = cm.realized_vol(targets) if targets else None
        log("window: replaying the real pool's 5-minute TWAP path" if targets
            else "window: real hour unavailable, scripted swaps")
        swaps = run_window(c, owner, market, rid, start, targets)
        outcome = settle(c, owner, market, rid, start)
        if outcome["events"]["reputation_write_failed"]:
            raise RuntimeError(f"settle skipped ERC-8004 writes: {outcome['events']}")
        log(f"settled={outcome['settled']} voided={outcome['voided']} "
            f"RV={outcome['realized_vol']} bucket={outcome['winning_bucket']}")
        offchain = offchain_rv(c, market, rid)
        price = chainlink_check(c, market, outcome["settle_block"], outcome["settle_ts"])

        preds = {a.name: c.call(
            market, "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)", rid,
            a.address) for a in agents}
        scores = {name: as_int(p[3]) for name, p in preds.items()}
        paid = claims(c, market, rid, bets, outcome)
        pred_pool, baseline, rewards = claim_predictor_rewards(c, market, rid, agents, scores)
        fee = collect_fee(c, owner, market, rid, outcome)
        market_left = balance(c, WETH, market)

        rows = []
        for a in agents:
            p = preds[a.name]
            rows.append({
                "agent": a.name, "model": getattr(a, "model", None) or "tsfm-api",
                "model_type": a.kind, "forecast_source": subs[a.name].get("source", "ezkl"),
                "address": a.address, "model_id": a.model_id, "agent_id": agent_ids[a.name],
                "verifier": verifiers[a.name], "revealed": truthy(p[0]),
                "proof_verified_onchain": a.kind == "zk" and truthy(p[0]),
                "probs": probs[a.name], "p_win": probs[a.name][outcome["winning_bucket"]],
                "log_score": str(scores[a.name]), "log_score_float": scores[a.name] / 1e18,
                "beat_baseline": scores[a.name] > baseline,
                "predictor_reward_wei": rewards[a.name],
                "prove_seconds": a.timings.get("prove", {}).get("seconds"),
                "prove_peak_mb": a.timings.get("prove", {}).get("peak_mb"),
                "reputation": reputation_of(c, market, agent_ids[a.name], a.kind),
            })
        rows.sort(key=lambda r: r["log_score_float"], reverse=True)
        round_fee = 0 if outcome["voided"] or as_int(
            outcome["pools_wei"][outcome["winning_bucket"]]) == 0 \
            else as_int(outcome["total_stake_wei"]) * FEE_BPS // 10_000

        result = {
            "network": "anvil fork of Ethereum mainnet", "fork_block": fork_block,
            "fork_timestamp": fork_ts, "generated_at": int(time.time()),
            "contracts": {"market": market, "pool": POOL, "chainlink_feed": FEED,
                          "erc8004_identity": IDENTITY, "erc8004_reputation": REPUTATION,
                          "settlement_token": WETH},
            "round": {"id": rid, "start": start, "delta_s": cm.DELTA, "n_segments": cm.N_SEGMENTS,
                      "bounds": list(BOUNDS), "features": feats, "fee_bps": FEE_BPS,
                      "predictor_share_bps": PREDICTOR_SHARE_BPS,
                      "commit_deadline": start - COMMIT_LEAD,
                      "reveal_deadline": start - REVEAL_LEAD},
            "window": {"mode": "replay" if targets else "scripted", "real_segment_ticks": targets,
                       "real_realized_vol": real_rv},
            "outcome": outcome, "offchain_recompute": offchain, "chainlink": price,
            "agents": rows, "tamper_checks": checks, "bets": paid, "swaps": swaps,
            "fee_collected_wei": fee, "market_balance_after_wei": str(market_left),
            "fee_split": {"fee_wei": str(round_fee), "owner_wei": fee,
                          "predictors_wei": str(pred_pool), "predictor_share_bps":
                          PREDICTOR_SHARE_BPS, "baseline_log_score": str(baseline),
                          "baseline_log_score_float": baseline / 1e18},
        }
    RESULT.parent.mkdir(parents=True, exist_ok=True)
    RESULT.write_text(json.dumps(result, indent=2) + "\n")
    print_summary(result)


def print_summary(r):
    o, p, w = r["outcome"], r["chainlink"], r["window"]
    print("\n=== VolMarket round on a mainnet fork ===")
    print(f"fork block {r['fork_block']}  market {r['contracts']['market']}  window {w['mode']}")
    real = "" if w["real_realized_vol"] is None else f", real mainnet hour {w['real_realized_vol']}"
    print(f"realized vol {o['realized_vol']} tick^2 (off-chain recompute "
          f"{r['offchain_recompute']['realized_vol']}{real}), bounds {r['round']['bounds']}, "
          f"winning bucket {o['winning_bucket']}, voided {o['voided']}")
    print(f"Chainlink ETH/USD {p['feed_price_usd']:.2f} vs pool {p['pool_price_usd']:.2f}: "
          f"{p['deviation_bps']} bps (max 200), feed age {p['feed_age_s']} s (max 3900)")
    print(f"settle gas {o['gas_used']} (estimated limit {o['gas_limit']}), events {o['events']}")
    print(f"{'agent':<20}{'type':<13}{'agentId':>10}{'p_win':>8}{'logScore':>10}"
          f"{'reward WETH':>13}  ERC-8004 getSummary")
    for a in r["agents"]:
        rep = a["reputation"]
        val = int(rep["summary_value"]) / 10 ** rep["summary_decimals"]
        kind = "zk proof" if a["model_type"] == "zk" else "commit-only"
        print(f"{a['agent']:<20}{kind:<13}{a['agent_id']:>10}{a['p_win']:>8.3f}"
              f"{a['log_score_float']:>10.3f}{int(a['predictor_reward_wei']) / 1e18:>13.6f}"
              f"  count={rep['count']} value={val:.3f} ({rep['tag2']})")
    api = [a for a in r["agents"] if a["model_type"] == "commit-only"]
    for a in api:
        print(f"{a['agent']}: commit-only, forecast source {a['forecast_source']}")
    for t in r["tamper_checks"]:
        print(f"{t['agent']}: honest proof verifies={t['honest_proof_verifies']}, "
              f"tampered output verifies={t['tampered_output_verifies']}")
    for b in r["bets"]:
        print(f"bettor {b['bettor'][:10]}… bucket {b['bucket']}: payout "
              f"{int(b['payout_wei']) / 1e18:.4f} WETH")
    fs = r["fee_split"]
    print(f"fee {int(fs['fee_wei']) / 1e18:.4f} WETH: owner {int(fs['owner_wei']) / 1e18:.4f}, "
          f"forecasters {int(fs['predictors_wei']) / 1e18:.4f} ({fs['predictor_share_bps']} bps, "
          f"above baseline {fs['baseline_log_score_float']:.3f}), left in market "
          f"{int(r['market_balance_after_wei'])} wei")
    print(f"wrote {RESULT.relative_to(REPO)}")


if __name__ == "__main__":
    sys.exit(main())
