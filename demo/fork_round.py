"""VolMarket on an anvil fork of Ethereum mainnet, replaying HOURS consecutive real hours.

The market reads the real Uniswap V3 ETH/USDC 0.05% pool, writes scores to the deployed ERC-8004
registries and cross-checks the pool price against the Chainlink ETH/USD feed. Each hour is one
round: the three EZKL agents from agents/ prove on the round's onchain features, and a fourth,
reproducible agent runs the public pinned Chronos-Bolt weights (vol_agents.repro_agent, under
VOL_REPRO_PYTHON) on the same features; its model is registered with a modelHash and, after each
reveal, `python -m vol_agents.recompute` re-derives its revealed vector from the fork. Every agent
commits a hash first and reveals once commits close; the zk agents' reveals carry the proof.
Forecasts above the uniform baseline share half of each round's fee.

One fork, one deployment, so ERC-8004 reputation and the market accumulate across the hours:
- The fork starts before the replayed hours. From then on the forked pool follows mainnet at the
  5-minute grid the contract reads: at each grid time t, in a block stamped exactly t, a trader
  swaps the pool to the real floor mean tick of [t, t + 300 s), taken from mainnet's own
  `observe()` (archive calls). The pool then holds that tick for the whole segment, so every
  segment mean the contract reads equals mainnet's, and so do the round features and the
  realized vol. Replay starts 18 segments before the first round so its features are replayed too.
- Chainlink ETH/USD reports are replayed from mainnet: each real `transmit` transaction in the
  range is re-sent by its original transmitter (impersonated) at its original timestamp, so the
  feed answer and its age at every settlement are mainnet's.
- Round h covers [start_h, start_h + 1 h); it is created one segment before start_h, so its 17
  feature segments are grid segments too. Commits, reveals and bets fall between grid times;
  createRound, swaps and samples that share a grid time are mined in one block.

Everything happens on the local fork: nothing is broadcast.

Environment: MAINNET_RPC_URL (archive; default the public tenderly gateway), HOURS (default 24),
REPLAY_START (unix seconds or ISO-8601 UTC, a full hour; default 2026-10-21T06:00:00Z, inside the
models' test period), VOL_REPRO_PYTHON (required: interpreter with chronos-forecasting and torch;
the pinned snapshot must be downloaded). Usage: bash demo/run.sh   (writes
demo/out/fork_replay.json)
"""

import json
import math
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import UTC, datetime
from decimal import Decimal, getcontext
from pathlib import Path

from vol_agents import contract_math as cm
from vol_agents import fee_strategies as fs
from vol_agents import repro_agent as ra
from vol_agents import repro_runner as rr
from vol_agents.agent import Agent
from vol_agents.build import build, model_names, verifier_name
from vol_agents.chain import DEV_KEYS, Anvil, address_of, as_int
from vol_agents.ezkl_step import OUT as AGENTS_OUT

REPO = Path(__file__).resolve().parent.parent
RESULT = REPO / "demo" / "out" / "fork_replay.json"

POOL = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"  # Uniswap V3 ETH/USDC 0.05%, token0 USDC
FEED = "0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419"  # Chainlink ETH/USD proxy, 8 decimals
IDENTITY = "0x8004A169FB4a3325136EB29fA0ceB6D2e539a432"  # ERC-8004 v2.0.0 Identity (mainnet)
REPUTATION = "0x8004BAa17C55a88189AE136b182e5fdA19dE9b63"  # ERC-8004 v2.0.0 Reputation (mainnet)
WETH = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
USDC_BALANCE_SLOT = 9  # FiatTokenV2_2 balanceAndBlacklistStates mapping
SWAP_ROUTER = "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45"  # Uniswap SwapRouter02
DEFAULT_RPC = "https://mainnet.gateway.tenderly.co"
DEFAULT_START = "2026-10-21T06:00:00Z"
DEFAULT_HOURS = 24

# anvil dev accounts 4 and 5 (same public mnemonic as chain.DEV_KEYS); fork-local only
BETTOR_KEYS = [
    "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
    "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
]
# anvil dev account 6, operator of the reproducible agent; fork-local only
REPRO_AGENT_KEY = "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e"
# anvil dev accounts 7 and 8 (unlocked on the fork): the pool trader and the checkpoint sampler
TRADER_INDEX, SAMPLER_INDEX = 7, 8
FEE_BPS = 100
PREDICTOR_SHARE_BPS = 5000
# Commits close COMMIT_LEAD s and reveals REVEAL_LEAD s before the round start.
COMMIT_LEAD = 90
REVEAL_LEAD = 30
BET_WEI = 10**18
BOUNDS = cm.BOUNDS
# createRound one segment before startTime keeps the feature segments on the replay grid
ROUND_LEAD_S = cm.DELTA
SETTLE_AFTER_S = 10
# Fork this long before the replay grid starts: room for the deployment blocks (one second each).
SETUP_MARGIN_S = 600
# Fork-local trader inventory, far above what a day of price moves in this pool takes.
TRADER_WETH = 10**6 * 10**18
TRADER_USDC = 10**12 * 10**6
BLOCK_INTERVAL_S = 1
SWAP_GAS, CREATE_GAS, SAMPLE_GAS = 3_000_000, 2_000_000, 500_000
SWAP_LOG_SAMPLE = 3  # swap tx hashes listed per hour
ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
# Must match VolMarket TIER_COMMIT_ONLY / TIER_REPRODUCIBLE / TIER_ZK.
TIERS = {0: "commit-only", 1: "reproducible", 2: "zk"}
REPRO_AGENT_NAME = "agent-chronos-bolt"
REPRO_MODEL = "chronos-bolt-tiny"
REPRO_SOURCE = "chronos-bolt"
EXACT_INPUT = "exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))"
ROUND_SIG = "getRound(uint256)(uint64,bool,bool,uint256,uint256,uint256,uint256[5],uint256[])"
FEED_SIG = "latestRoundData()(uint80,int256,uint256,uint256,uint80)"
OBSERVE_SIG = "observe(uint32[])(int56[],uint160[])"
PREDICTION_SIG = "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)"
SWAP_TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
ANSWER_UPDATED_TOPIC = "0x0559884fd3a460db3073b7fc896cc77986f16e378210ded43186175bf646fc5f"
FEE_RECORDED_SIG = "FeeRecorded(uint256,uint24,uint256,uint256[5])"
REPUTATION_TAG1 = "logScore"
# Must equal VolMarket._reputationTag, or the consumer finds no reputation and weighs equally.
REPUTATION_TAG2 = f"vol-{cm.DELTA}s-{cm.N_SEGMENTS}"
SUMMARY_SIG = "getSummary(uint256,address[],string,string)(uint64,int128,uint8)"
# VolFeeConsumer calibration: mainnet hours ending at the replay start, never inside it.
CALIBRATION_HOURS = 24
# VolFeeConsumer fee bounds in pips (1e-6; 100 pips = 1 bp); the pool's own tier is 500 pips.
MIN_FEE_PIPS, MAX_FEE_PIPS = 100, 10_000
FIXED_FEE_PIPS = 500
VOID_REASONS = {1: "pool tick out of range", 2: "Chainlink answer stale or invalid",
                3: "Chainlink decimals", 4: "pool price deviates from Chainlink",
                5: "Chainlink call failed"}

getcontext().prec = 60


def log(msg):
    print(f"[demo] {msg}", flush=True)


def utc(t):
    return datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%d %H:%M:%SZ")


def parse_start(v):
    if v.isdigit():
        return int(v)
    return int(datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp())


def rpc(url, method, *params, timeout=180):
    """JSON-RPC over HTTP; errors never include the URL, which may carry an API key."""
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)})
    last = None
    for attempt in range(6):
        req = urllib.request.Request(url, data=body.encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                out = json.loads(r.read())
        except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
            last = type(e).__name__ + (f" {e.code}" if hasattr(e, "code") else "")
            time.sleep(2 * (attempt + 1))
            continue
        if "error" in out:
            raise RuntimeError(f"{method}: {out['error']}")
        return out["result"]
    raise RuntimeError(f"{method} failed after retries: {last}")


def cast(*args, timeout=600):
    r = subprocess.run(["cast", *map(str, args)], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"cast {' '.join(map(str, args[:3]))} failed:\n{r.stderr[-2000:]}")
    return r.stdout.strip()


def calldata(sig, *args):
    return cast("calldata", sig, *args)


def observe_calldata(secs):
    return calldata("observe(uint32[])", "[" + ",".join(map(str, secs)) + "]")


def decode_observe(data):
    out = json.loads(cast("abi-decode", OBSERVE_SIG, data, "--json"))
    return [as_int(v) for v in out[0]]


class Mainnet:
    """Archive reads on mainnet over plain JSON-RPC."""

    def __init__(self, url):
        self.url = url
        self._ts = {}

    def call(self, method, *params):
        return rpc(self.url, method, *params)

    def latest(self):
        return int(self.call("eth_blockNumber"), 16)

    def ts(self, n):
        if n not in self._ts:
            self._ts[n] = int(self.call("eth_getBlockByNumber", hex(n), False)["timestamp"], 16)
        return self._ts[n]

    def block_at_or_after(self, t):
        """First block stamped >= t. Slots are 12 s and missed slots only remove blocks, so the
        slot-count estimate back from the head never overshoots."""
        head = self.latest()
        if self.ts(head) < t:
            raise RuntimeError(f"{utc(t)} is not in mainnet's past yet")
        n = head - (self.ts(head) - t) // 12
        while self.ts(n) < t:
            n += max(1, (t - self.ts(n)) // 12)
        while self.ts(n - 1) >= t:
            n -= 1
        return n

    def observe(self, block, secs):
        data = self.call("eth_call", {"to": POOL, "data": observe_calldata(secs)}, hex(block))
        return decode_observe(data)

    def logs(self, address, topic, first, last):
        return self.call("eth_getLogs", {"address": address, "topics": [topic],
                                         "fromBlock": hex(first), "toBlock": hex(last)})

    def pool_state(self, block):
        """(liquidity, sqrtPriceX96) of the pool after `block`."""
        liq = self.call("eth_call", {"to": POOL, "data": calldata("liquidity()")}, hex(block))
        slot0 = self.call("eth_call", {"to": POOL, "data": calldata("slot0()")}, hex(block))
        return int(liq, 16), int(slot0[2:66], 16)


def int256(word):
    v = int(word, 16)
    return v - 2**256 if v >= 2**255 else v


def hour_market(mainnet, first, nxt, swaps=None):
    """Fair-fee inputs of the mainnet hour in blocks [first, nxt): pool state at its first block
    and the hour's swap volume as sum |amount1|, in WETH wei like 2 * L * sqrt(P)."""
    if swaps is None:
        swaps = mainnet.logs(POOL, SWAP_TOPIC, first, nxt - 1)
    liquidity, sqrt_price = mainnet.pool_state(first)
    volume = sum(abs(int256(lg["data"][66:130])) for lg in swaps)
    return {"state_block": first, "liquidity": liquidity, "sqrt_price_x96": sqrt_price,
            "volume_token1": volume, "swap_count": len(swaps)}


def fair_bps(rv, m):
    return fs.fair_fee(rv, m["liquidity"], m["sqrt_price_x96"], m["volume_token1"]) * 10_000


def calibrate_fee(mainnet, start):
    """VolFeeConsumer parameters from the CALIBRATION_HOURS mainnet hours before `start`."""
    step, hour = cm.DELTA, cm.N_SEGMENTS * cm.DELTA
    cal_start = start - CALIBRATION_HOURS * hour
    grid = list(range(cal_start, start + 1, step))
    cums, block_at = real_cumulatives(
        mainnet, grid, [cal_start + k * hour for k in range(CALIBRATION_HOURS + 1)])
    hours = []
    for k in range(CALIBRATION_HOURS):
        s = cal_start + k * hour
        window = [cm.floor_div(cums[s + (i + 1) * step] - cums[s + i * step], step)
                  for i in range(cm.N_SEGMENTS)]
        rv = cm.realized_vol(window)
        m = hour_market(mainnet, block_at[s], block_at[s + hour])
        bps = fair_bps(rv, m)
        hours.append({"start": s, "rv": rv, "fair_bps": bps, "fair_pips": bps * fs.PIPS_PER_BPS,
                      "liquidity": str(m["liquidity"]),
                      "sqrt_price_x96": str(m["sqrt_price_x96"]),
                      "volume_token1": str(m["volume_token1"]), "swap_count": m["swap_count"]})
    fpv, bucket_var, sources = fs.calibrate(hours, BOUNDS)
    log(f"fee calibration {utc(cal_start)} .. {utc(start)}: feePerVarE18 {fpv}, "
        f"bucketVar {bucket_var}")
    return {"bucket_var": bucket_var, "fee_per_var_e18": str(fpv), "min_fee_pips": MIN_FEE_PIPS,
            "max_fee_pips": MAX_FEE_PIPS, "fixed_fee_pips": FIXED_FEE_PIPS,
            "tag1": REPUTATION_TAG1, "tag2_zk": REPUTATION_TAG2,
            "tag2_commit": REPUTATION_TAG2 + "-commit",
            "calibration": {
                "window": [cal_start, start], "hours": CALIBRATION_HOURS,
                "fee_per_var": "ratio of sums: sum fair pips / sum rv over the calibration hours, "
                               "1e18-scaled, so fee_for_var(rv) totals the fair fee unclamped",
                "bucket_var": "mean rv of the calibration hours in each bucket; an empty bucket "
                              "takes its bounds' midpoint (bucket 0: half its upper bound, "
                              "bucket 4: 1.5x its lower bound), then a running max",
                "bucket_var_sources": sources,
                "fair": fs.FAIR_DEFINITION,
                "hours_data": [{k: v for k, v in h.items() if k != "fair_pips"} for h in hours]}}


def real_cumulatives(mainnet, grid, ends):
    """Pool tickCumulative at every grid time from mainnet observe(): one call per chunk of grid
    times up to each of `ends`, at the first block stamped at or after that end (a chunk spans at
    most 1.5 h, inside the pool's observation history). Also returns that block per end."""
    cums, block_at = {}, {}
    i = 0
    for end in ends:
        part = [t for t in grid[i:] if t <= end]
        i += len(part)
        block = mainnet.block_at_or_after(end)
        block_at[part[-1]] = block
        ts = mainnet.ts(block)
        for t, c in zip(part, mainnet.observe(block, [ts - t for t in part]), strict=True):
            cums[t] = c
    return cums, block_at


def feed_reports(mainnet, aggregator, first, last):
    """Real Chainlink transmissions on the aggregator, in block order, with the transaction that
    carried each (re-sent by its transmitter on the fork)."""
    out = []
    for lg in mainnet.logs(aggregator, ANSWER_UPDATED_TOPIC, first, last):
        tx = mainnet.call("eth_getTransactionByHash", lg["transactionHash"])
        out.append({"block": int(lg["blockNumber"], 16), "tx": lg["transactionHash"],
                    "updated_at": int(lg["data"], 16), "answer": int(lg["topics"][1], 16),
                    "from": tx["from"], "to": tx["to"], "input": tx["input"],
                    "gas": tx["gas"]})
    out.sort(key=lambda r: (r["block"], r["updated_at"]))
    return out


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
        accounts = self.rpc_call("eth_accounts")
        self.trader, self.sampler = accounts[TRADER_INDEX], accounts[SAMPLER_INDEX]
        # On mainnet anvil's public test keys carry EIP-7702 sweeper delegations; as plain EOAs
        # again they can receive the ERC-721 identity mint and keep their fork-local ETH.
        for who in [address_of(k) for k in DEV_KEYS + BETTOR_KEYS + [REPRO_AGENT_KEY]] + [
                self.trader, self.sampler]:
            self.rpc_call("anvil_setCode", who, "0x")
        return self

    def rpc_call(self, method, *params):
        return rpc(self.rpc, method, *params)

    def call_at(self, block, to, sig, *args):
        return json.loads(cast("call", to, sig, *args, "--rpc-url", self.rpc, "--block", block,
                               "--json"))

    def latest_ts(self):
        return int(self.rpc_call("eth_getBlockByNumber", "latest", False)["timestamp"], 16)

    def wait_receipt(self, tx_hash):
        """A forked anvil mines automined transactions asynchronously, after
        eth_sendTransaction has already returned the hash."""
        deadline = time.time() + 60
        while (r := self.rpc_call("eth_getTransactionReceipt", tx_hash)) is None:
            if time.time() > deadline:
                raise RuntimeError(f"transaction {tx_hash} was never mined")
            time.sleep(0.05)
        return r

    def receipt(self, tx_hash):
        r = self.wait_receipt(tx_hash)
        if r["status"] != "0x1":
            raise RuntimeError(f"transaction {tx_hash} failed: {r}")
        return r

    def mine_batch(self, ts, txs):
        """Mine `txs` ({from, to, data, gas}) in one block stamped exactly `ts`."""
        if self.latest_ts() >= ts:
            raise RuntimeError(f"chain time already at {self.latest_ts()}, cannot mine at {ts}")
        self.rpc_call("evm_setAutomine", False)
        try:
            hashes = [self.rpc_call("eth_sendTransaction", {**tx, "gas": hex(tx["gas"])})
                      for tx in txs]
            self.rpc_call("evm_setNextBlockTimestamp", ts)
            self.rpc_call("evm_mine")
        finally:
            self.rpc_call("evm_setAutomine", True)
        return [self.receipt(h) for h in hashes]

    def advance_to(self, ts):
        """The next mined block is stamped ts, or one second after the last block if that is
        later."""
        if self.latest_ts() + 1 < ts:
            self.rpc_call("evm_setNextBlockTimestamp", ts)


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
    repro = ra.ReproAgent(name=REPRO_AGENT_NAME, key=REPRO_AGENT_KEY,
                          address=address_of(REPRO_AGENT_KEY))
    local_hash = ra.local_model_hash()
    for agent, verifier in zk + [(repro, ZERO_ADDRESS)]:
        if agent is repro:
            c.send(owner, market, "registerModel(address,address,bytes32)", ZERO_ADDRESS,
                   agent.address, local_hash)
        else:
            c.send(owner, market, "registerModel(address,address)", verifier, agent.address)
        agent.model_id = as_int(c.call(market, "modelCount()(uint256)")[0]) - 1
        uri = (ra.agent_card(agent.name, local_hash, agent.model_id, market) if agent is repro
               else f"https://example.invalid/agents/{agent.name}")
        receipt = c.send(agent.key, IDENTITY, "register(string)(uint256)", uri)
        agent_id = minted_agent_id(receipt)
        c.send(agent.key, market, "linkAgent(uint256,uint256)", agent.model_id, agent_id)
        tier = model_tier(c, market, agent.model_id)
        if agent is repro:
            onchain = model_hash_of(c, market, agent.model_id)
            if tier != "reproducible" or onchain.lower() != local_hash.lower():
                raise SystemExit(f"{agent.name}: onchain tier {tier}, modelHash {onchain}; local "
                                 f"model hash {local_hash}: refusing to run rounds")
            kind = f"reproducible, modelHash {onchain}"
        else:
            if tier != "zk":
                raise RuntimeError(f"{agent.name}: onchain tier {tier}, expected zk")
            kind = f"zk, verifier {verifier}"
        log(f"{agent.name}: model {agent.model_id}, {kind}, ERC-8004 agentId {agent_id}")
        agents.append(agent)
        agent_ids[agent.name] = agent_id
        verifiers[agent.name] = verifier if verifier != ZERO_ADDRESS else None
    return market, agents, agent_ids, verifiers


def model_tier(c, market, model_id):
    return TIERS[as_int(c.call(market, "verificationTier(uint256)(uint8)", model_id)[0])]


def model_hash_of(c, market, model_id):
    return c.call(market, "modelHash(uint256)(bytes32)", model_id)[0]


def check_repro_env():
    """The reproducible agent has no fallback: missing interpreter or weights stop the replay."""
    python = os.environ.get("VOL_REPRO_PYTHON")
    if not python:
        raise SystemExit("VOL_REPRO_PYTHON is unset: point it at a Python with "
                         "chronos-forecasting and torch (see .env.example)")
    if not (os.path.isfile(python) and os.access(python, os.X_OK)):
        raise SystemExit(f"VOL_REPRO_PYTHON={python} is not an executable file")
    try:
        rr.artifact_paths()
    except FileNotFoundError as e:
        raise SystemExit(f"reproducible agent weights: {e}") from None
    h = ra.local_model_hash()
    log(f"{REPRO_AGENT_NAME}: {rr.MODEL_REPO}@{rr.MODEL_REVISION}, local model hash {h}")
    return h


def recompute(c, market, rid, model_id):
    """Exit code of the public recompute command against the fork; 0 means every bucket equals."""
    r = subprocess.run([sys.executable, "-m", "vol_agents.recompute", "--rpc-url", c.rpc,
                        "--market", market, "--round", str(rid), "--model-id", str(model_id)],
                       cwd=REPO / "agents", capture_output=True, text=True, timeout=900)
    if r.returncode != 0:
        log(f"round {rid}: recompute exit {r.returncode}: {(r.stderr or r.stdout)[-1000:]}")
    return r.returncode


def deploy_fee_consumer(c, owner, market, fee):
    return c.deploy(owner, "src/VolFeeConsumer.sol:VolFeeConsumer", market, fee["tag1"],
                    fee["tag2_zk"], fee["tag2_commit"],
                    "[" + ",".join(map(str, fee["bucket_var"])) + "]", fee["fee_per_var_e18"],
                    fee["min_fee_pips"], fee["max_fee_pips"])


def fund_trader(c):
    """Fork-local inventory: ETH wrapped to WETH, USDC written into its balance slot."""
    t = c.trader
    c.rpc_call("anvil_setBalance", t, hex(TRADER_WETH + 100 * 10**18))
    approve = calldata("approve(address,uint256)", SWAP_ROUTER, 2**256 - 1)
    for tx in ({"from": t, "to": WETH, "data": calldata("deposit()"), "value": hex(TRADER_WETH)},
               {"from": t, "to": WETH, "data": approve}, {"from": t, "to": USDC, "data": approve}):
        c.receipt(c.rpc_call("eth_sendTransaction", tx))
    slot = cast("index", "address", t, USDC_BALANCE_SLOT)
    c.rpc_call("anvil_setStorageAt", USDC, slot, "0x" + TRADER_USDC.to_bytes(32, "big").hex())
    if balance(c, USDC, t) != TRADER_USDC:
        raise RuntimeError("USDC balance slot layout changed; cannot fund the trader")


def pool_tick(c):
    return as_int(c.call(POOL, "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)")[1])


def balance(c, token, who):
    return as_int(c.call(token, "balanceOf(address)(uint256)", who)[0])


def swap_tx(c, now, target):
    """Swap that moves the forked pool from tick `now` to `target`: selling WETH raises the tick,
    selling USDC lowers it; the price limit stops it inside `target`."""
    up = target > now
    token_in, token_out, amount = (WETH, USDC, TRADER_WETH) if up else (USDC, WETH, TRADER_USDC)
    data = calldata(EXACT_INPUT, f"({token_in},{token_out},500,{c.trader},{amount},0,"
                                 f"{sqrt_price_x96(target)})")
    return {"from": c.trader, "to": SWAP_ROUTER, "data": data, "gas": SWAP_GAS}


class FeedReplay:
    """Re-sends mainnet's Chainlink transmissions on the fork in timestamp order."""

    def __init__(self, c, reports):
        self.c, self.pending, self.done = c, list(reports), []
        for who in {r["from"] for r in reports}:
            c.rpc_call("anvil_impersonateAccount", who)
            c.rpc_call("anvil_setBalance", who, hex(100 * 10**18))

    def before(self, t):
        """Replay every report stamped before t that still fits before t."""
        while self.pending and self.pending[0]["updated_at"] < t:
            r = self.pending[0]
            at = max(r["updated_at"], self.c.latest_ts() + 1)
            if at >= t:
                return
            self.pending.pop(0)
            self.c.rpc_call("evm_setNextBlockTimestamp", at)
            h = self.c.rpc_call("eth_sendTransaction", {"from": r["from"], "to": r["to"],
                                                        "data": r["input"], "gas": r["gas"]})
            status = self.c.wait_receipt(h)["status"]
            got = as_int(self.c.call(FEED, FEED_SIG)[3])
            self.done.append({"mainnet_tx": r["tx"], "mainnet_block": r["block"],
                              "mainnet_updated_at": r["updated_at"], "replayed_at": at,
                              "ok": status == "0x1" and got == at,
                              "answer_usd": r["answer"] / 1e8})
            if not self.done[-1]["ok"]:
                log(f"Chainlink report {r['tx']} did not replay (status {status})")


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


def tamper_check(c, agent, verifier, market, rid, sub):
    """The verifier accepts the revealed proof and rejects it once one output is changed."""
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

    gas = as_int(cast("estimate", verifier, "verifyProof(bytes,uint256[])", proof,
                      "[" + ",".join(map(str, inst)) + "]", "--rpc-url", c.rpc))
    return {"agent": agent.name, "honest_proof_verifies": verify(inst),
            "tampered_output_verifies": verify(tampered), "verify_proof_gas": gas}


def chainlink_check(c, market, block, settle_ts):
    _, answer, _, updated_at, _ = c.call_at(block, FEED, FEED_SIG)
    answer, updated_at = as_int(answer), as_int(updated_at)
    cums = c.call_at(block, POOL, OBSERVE_SIG, f"[{cm.DELTA},0]")[0]
    tick = cm.floor_div(as_int(cums[1]) - as_int(cums[0]), cm.DELTA)
    pool_price = as_int(c.call_at(block, market, "priceForTick(int24)(uint256)", tick)[0])
    return {"feed_price_usd": answer / 1e8, "feed_updated_at": updated_at,
            "feed_age_s": settle_ts - updated_at, "pool_mean_tick": tick,
            "pool_price_usd": pool_price / 1e8,
            "deviation_bps": round(abs(pool_price - answer) * 10_000 / answer, 2)}


def settle(c, owner, market, rid):
    # Estimated gas on purpose: the estimate is the lowest limit settle accepts, and settle reverts
    # rather than skip an external call that limit would starve.
    receipt = c.send(owner, market, "settle(uint256)", rid)
    r = c.call(market, ROUND_SIG, rid)
    failed = logs_with(receipt, market, "PriceCheckFailed(uint256,int24,int256,int256,uint8)")
    voided = truthy(r[2])
    reason = None
    if voided:
        reason = (VOID_REASONS.get(int(failed[0]["data"][-64:], 16), "price check")
                  if failed else "fewer than 90% of checkpoints readable")
    rep_failed = logs_with(receipt, market,
                           "ReputationWriteFailed(uint256,address,uint256,bytes32)")
    if rep_failed:
        raise RuntimeError(f"settle skipped ERC-8004 writes in round {rid}")
    return {"settle_block": int(receipt["blockNumber"], 0),
            "settle_tx": receipt["transactionHash"], "gas_used": int(receipt["gasUsed"], 0),
            "voided": voided, "void_reason": reason, "winning_bucket": as_int(r[3]),
            "realized_vol": as_int(r[4]), "total_stake_wei": str(as_int(r[5])),
            "pools_wei": [str(as_int(v)) for v in r[6]],
            "erc8004_feedback_logs": sum(1 for lg in receipt.get("logs") or []
                                         if lg["address"].lower() == REPUTATION.lower())}


def refund_all(outcome):
    return outcome["voided"] or as_int(outcome["pools_wei"][outcome["winning_bucket"]]) == 0


def claims(c, market, rid, bets, outcome):
    paid = []
    for key, bet in zip(BETTOR_KEYS, bets, strict=True):
        if not refund_all(outcome) and bet["bucket"] != outcome["winning_bucket"]:
            paid.append({**bet, "payout_wei": "0"})
            continue
        before = balance(c, WETH, bet["bettor"])
        c.send(key, market, "claim(uint256)", rid)
        paid.append({**bet, "payout_wei": str(balance(c, WETH, bet["bettor"]) - before)})
    return paid


def claim_predictor_rewards(c, market, rid, agents, scores, base):
    """Every forecaster above the uniform baseline pulls its share of the predictor pool."""
    pool = as_int(c.call(market, "predictorPool(uint256)(uint256)", rid)[0])
    paid = {}
    for a in agents:
        if pool == 0 or scores[a.name] is None or scores[a.name] <= base:
            paid[a.name] = "0"
            continue
        before = balance(c, WETH, a.address)
        c.send(a.key, market, "claimPredictorReward(uint256)", rid)
        paid[a.name] = str(balance(c, WETH, a.address) - before)
    return pool, paid


def collect_fee(c, owner, market, rid, outcome, pool):
    fee = 0 if refund_all(outcome) else as_int(outcome["total_stake_wei"]) * FEE_BPS // 10_000
    if fee - pool == 0:
        return fee, 0
    who = address_of(owner)
    before = balance(c, WETH, who)
    c.send(owner, market, "collectFee(uint256)", rid)
    return fee, balance(c, WETH, who) - before


def reputation_of(c, market, agent_id, tier):
    # VolMarket appends "-commit" for every model without a verifier, reproducible included.
    tag2 = REPUTATION_TAG2 + ("" if tier == "zk" else "-commit")
    count, value, decimals = c.call(REPUTATION, SUMMARY_SIG, agent_id, f"[{market}]",
                                    REPUTATION_TAG1, tag2)
    return {"tag1": REPUTATION_TAG1, "tag2": tag2, "count": as_int(count),
            "summary_value": str(as_int(value)), "summary_decimals": as_int(decimals)}


class Replay:
    def __init__(self, c, mainnet, owner, start, hours):
        self.c, self.mainnet, self.owner = c, mainnet, owner
        self.start, self.hours = start, hours
        self.rounds = {}  # round index h -> record
        self.tamper = []

    def round_start(self, h):
        return self.start + h * cm.N_SEGMENTS * cm.DELTA

    def open_round(self, h, g, real_feats):
        """createRound at grid time g, mined with the grid's swap; returns the batch tx."""
        start = self.round_start(h)
        data = calldata("createRound(uint64,uint256[])", start,
                        "[" + ",".join(map(str, BOUNDS)) + "]")
        self.rounds[h] = {"h": h, "start": start, "created_at": g, "id": h,
                          "features_real": real_feats}
        return {"from": address_of(self.owner), "to": self.market, "data": data,
                "gas": CREATE_GAS}

    def enter(self, h, feed):
        """Commit (after proving), reveal once commits close, then bet; all before start."""
        rec, c = self.rounds[h], self.c
        rid, start = rec["id"], rec["start"]
        feats = [as_int(v) for v in c.call(self.market, "getFeatures(uint256)(int256[16])", rid)[0]]
        rec["features"] = feats
        rec["features_match_mainnet"] = feats == rec["features_real"]
        subs, prove = {}, {}
        for a in self.agents:
            feed.before(c.latest_ts() + 2)
            subs[a.name] = a.commit(c, self.market, rid)
            prove[a.name] = a.timings.get("prove", {}).get("seconds") if a.kind == "zk" else None
        feed.before(start - COMMIT_LEAD)
        c.advance_to(start - COMMIT_LEAD)
        reveal_gas = {}
        for a in self.agents:
            reveal_gas[a.name] = int(a.reveal(c, self.market, rid)["gasUsed"], 0)
        probs, probs_e18 = {}, {}
        for a in self.agents:
            p = c.call(self.market, PREDICTION_SIG, rid, a.address)
            probs_e18[a.name] = [str(as_int(v)) for v in p[2]]
            probs[a.name] = [as_int(v) / 1e18 for v in p[2]]
        reproduced = {}
        for a in self.agents:
            if a.kind == "reproducible":
                t0 = time.time()
                reproduced[a.name] = recompute(c, self.market, rid, a.model_id) == 0
                log(f"round {rid}: {a.name} recompute from onchain features "
                    f"{'MATCH' if reproduced[a.name] else 'MISMATCH'} "
                    f"({time.time() - t0:.1f} s)")
        rec["bets"] = place_bets(c, self.market, rid, list(probs.values()))
        if c.latest_ts() >= start:
            raise RuntimeError(f"round {rid}: entering ran past the round start")
        if not self.tamper:
            self.tamper = [tamper_check(c, a, self.verifiers[a.name], self.market, rid,
                                        subs[a.name]) for a in self.agents if a.kind == "zk"]
        rec["agents"] = {}
        for a in self.agents:
            row = {"probs": probs[a.name], "probs_e18": probs_e18[a.name],
                   "prove_seconds": prove[a.name], "reveal_gas": reveal_gas[a.name],
                   "forecast_source": REPRO_SOURCE if a.kind == "reproducible"
                   else subs[a.name].get("source", "ezkl")}
            if a.name in reproduced:
                row["reproduced"] = reproduced[a.name]
            rec["agents"][a.name] = row
        self.record_fee(h, feed)

    def record_fee(self, h, feed):
        """VolFeeConsumer.record once reveals have closed, its Python mirror at the same block,
        and the previous-hour strategy priced from what is known at that time."""
        rec, c, fee = self.rounds[h], self.c, self.fee
        rid, start = rec["id"], rec["start"]
        feed.before(start - REVEAL_LEAD)
        c.advance_to(start - REVEAL_LEAD)
        receipt = c.send(self.owner, self.fee_consumer, "record(uint256)", rid)
        block = int(receipt["blockNumber"], 0)
        ts = int(c.rpc_call("eth_getBlockByNumber", hex(block), False)["timestamp"], 16)
        if not start - REVEAL_LEAD <= ts < start:
            raise RuntimeError(f"round {rid}: fee recorded at {ts}, outside the quote window")
        data = logs_with(receipt, self.fee_consumer, FEE_RECORDED_SIG)[0]["data"][2:]
        words = [int(data[64 * i:64 * (i + 1)], 16) for i in range(7)]
        on_fee, on_ev, on_mix = words[0], words[1], words[2:]
        mirror = fs.mirror_quote(self.fee_inputs(rid, block), self.baseline,
                                 self.registry_at(block) != ZERO_ADDRESS, fee["bucket_var"],
                                 int(fee["fee_per_var_e18"]), MIN_FEE_PIPS, MAX_FEE_PIPS)
        matches = (mirror["fee_pips"], mirror["mix_e18"], mirror["expected_var_e18"]) == (
            on_fee, on_mix, on_ev)
        if not matches:
            log(f"round {rid}: fee mirror {mirror} differs from on-chain {words}")
        lo, hi = fs.prev_hour_window(ts, self.grid_origin)
        prev_ticks = [self.ticks[t] for t in range(lo, hi, cm.DELTA)]
        prev_rv = cm.realized_vol(prev_ticks)
        fpv = int(fee["fee_per_var_e18"])
        rec["fee"] = {
            "onchain": {"fee_pips": on_fee, "mix_e18": [str(v) for v in on_mix],
                        "expected_var_e18": str(on_ev), "tx": receipt["transactionHash"],
                        "block": block, "timestamp": ts},
            "mirror": {"fee_pips": mirror["fee_pips"],
                       "mix_e18": [str(v) for v in mirror["mix_e18"]],
                       "expected_var_e18": str(mirror["expected_var_e18"]),
                       "weights": [str(w) for w in mirror["weights"]],
                       "equal_weight_fallback": mirror["equal_weight_fallback"]},
            "mirror_matches": matches,
            "fixed_bps": FIXED_FEE_PIPS / fs.PIPS_PER_BPS,
            "forecast_bps": on_fee / fs.PIPS_PER_BPS,
            "prev_hour": {"window": [lo, hi], "segment_ticks": prev_ticks,
                          "realized_vol": prev_rv},
            "prev_hour_bps": fs.fee_for_var(prev_rv, fpv, MIN_FEE_PIPS, MAX_FEE_PIPS)
            / fs.PIPS_PER_BPS,
        }

    def registry_at(self, block):
        return self.c.call_at(block, self.market, "reputationRegistry()(address)")[0]

    def fee_inputs(self, rid, block):
        """Revealed forecasts of round `rid` and their models' reputation, read at `block` the
        way VolFeeConsumer._forecasts reads them (mainnet ERC-8004 tuple getSummary)."""
        c, m = self.c, self.market
        registry = self.registry_at(block)
        n = as_int(c.call_at(block, m, "predictorCount(uint256)(uint256)", rid)[0])
        out = []
        for i in range(n):
            who = c.call_at(block, m, "predictorAt(uint256,uint256)(address)", rid, i)[0]
            p = c.call_at(block, m, PREDICTION_SIG, rid, who)
            if not truthy(p[0]):
                continue
            out.append({"probs": [as_int(v) for v in p[2]],
                        "reputation": self.model_reputation(block, as_int(p[1]), registry)})
        return out

    def model_reputation(self, block, model_id, registry):
        c, m = self.c, self.market
        if registry == ZERO_ADDRESS or not truthy(
                c.call_at(block, m, "agentBound(uint256)(bool)", model_id)[0]):
            return False, 0
        agent_id = as_int(c.call_at(block, m, "agentOfModel(uint256)(uint256)", model_id)[0])
        zk = truthy(c.call_at(block, m, "isZkModel(uint256)(bool)", model_id)[0])
        tag2 = self.fee["tag2_zk"] if zk else self.fee["tag2_commit"]
        try:
            count, value, decimals = c.call_at(block, registry, SUMMARY_SIG, agent_id, f"[{m}]",
                                               self.fee["tag1"], tag2)
        except RuntimeError:
            return False, 0
        return fs.reputation_mean(as_int(count), as_int(value), as_int(decimals))

    def close(self, h, real_window_ticks, mainnet_info, market_hour):
        rec, c = self.rounds[h], self.c
        rid = rec["id"]
        c.advance_to(rec["start"] + cm.N_SEGMENTS * cm.DELTA + SETTLE_AFTER_S)
        outcome = settle(c, self.owner, self.market, rid)
        settle_ts = c.latest_ts()
        real_rv = cm.realized_vol(real_window_ticks)
        rec["fee"].update({
            "fair_bps": fair_bps(real_rv, market_hour),
            "fair_inputs": {"realized_vol": real_rv, "state_block": market_hour["state_block"],
                            "liquidity": str(market_hour["liquidity"]),
                            "sqrt_price_x96": str(market_hour["sqrt_price_x96"]),
                            "volume_token1": str(market_hour["volume_token1"]),
                            "volume_token": "WETH wei"}})
        price = chainlink_check(c, self.market, outcome["settle_block"], settle_ts)
        preds = {a.name: c.call(self.market, PREDICTION_SIG, rid, a.address) for a in self.agents}
        scores = {n: as_int(p[3]) if truthy(p[0]) and not outcome["voided"] else None
                  for n, p in preds.items()}
        paid = claims(c, self.market, rid, rec["bets"], outcome)
        pred_pool, rewards = claim_predictor_rewards(c, self.market, rid, self.agents, scores,
                                                     self.baseline)
        fee, owner_got = collect_fee(c, self.owner, self.market, rid, outcome, pred_pool)
        win = outcome["winning_bucket"]
        for a in self.agents:
            row = rec["agents"][a.name]
            s = scores[a.name]
            row.update({"p_win": None if outcome["voided"] else row["probs"][win],
                        "log_score": None if s is None else str(s),
                        "log_score_float": None if s is None else s / 1e18,
                        "beat_baseline": s is not None and s > self.baseline,
                        "predictor_reward_wei": rewards[a.name]})
        rec.update({
            "end": rec["start"] + cm.N_SEGMENTS * cm.DELTA,
            "window_utc": [utc(rec["start"]), utc(rec["start"] + cm.N_SEGMENTS * cm.DELTA)],
            "mainnet": mainnet_info,
            "real_segment_ticks": real_window_ticks, "real_realized_vol": real_rv,
            "real_bucket": cm.bucket_of(real_rv, BOUNDS),
            "rv_matches_mainnet": outcome["voided"] or outcome["realized_vol"] == real_rv,
            "outcome": outcome, "chainlink": price, "bets": paid,
            "fee_split": {"fee_wei": str(fee), "owner_wei": str(owner_got),
                          "predictors_wei": str(pred_pool)},
        })
        rec.pop("features_real")
        status = f"VOID ({outcome['void_reason']})" if outcome["voided"] else (
            f"RV {outcome['realized_vol']} (mainnet {real_rv}) bucket {win}")
        best = ", ".join(f"{n.removeprefix('agent-')} {r['log_score_float']:.3f}"
                         for n, r in rec["agents"].items() if r["log_score_float"] is not None)
        f = rec["fee"]
        log(f"round {rid} {utc(rec['start'])}: {status}; feed age {price['feed_age_s']} s, "
            f"dev {price['deviation_bps']} bps; {best}; fee bps fair {f['fair_bps']:.3f} "
            f"forecast {f['forecast_bps']} prev-hour {f['prev_hour_bps']}")


def summarize(rounds, agents, final_rep):
    settled = [r for r in rounds if not r["outcome"]["voided"]]
    reasons = {}
    for r in rounds:
        if r["outcome"]["voided"]:
            reasons[r["outcome"]["void_reason"]] = reasons.get(r["outcome"]["void_reason"], 0) + 1
    counts = [0] * cm.BUCKETS
    for r in settled:
        counts[r["outcome"]["winning_bucket"]] += 1
    out = {}
    for a in agents:
        s = [r["agents"][a.name]["log_score_float"] for r in settled]
        out[a.name] = {
            "rounds_scored": len(s), "total_log_score": round(sum(s), 4),
            "mean_log_score": round(sum(s) / len(s), 4) if s else None,
            "beat_baseline_rounds": sum(r["agents"][a.name]["beat_baseline"] for r in settled),
            "reproduced_rounds": (sum(r["agents"][a.name]["reproduced"] is True for r in rounds)
                                  if a.kind == "reproducible" else None),
            "predictor_reward_wei": str(sum(int(r["agents"][a.name]["predictor_reward_wei"])
                                            for r in rounds)),
            "erc8004": final_rep[a.name],
        }
    return {"rounds": len(rounds), "settled": len(settled), "voided": len(rounds) - len(settled),
            "void_reasons": reasons, "bucket_counts": counts,
            "uniform_total_log_score": round(len(settled) * math.log(1 / cm.BUCKETS), 4),
            "features_match_mainnet": all(r["features_match_mainnet"] for r in rounds),
            "rv_matches_mainnet": all(r["rv_matches_mainnet"] for r in rounds),
            "agents": out,
            "fee_strategies": {
                **fs.strategy_summary([r["fee"] for r in rounds]),
                "mirror_matches": all(r["fee"]["mirror_matches"] for r in rounds),
                "equal_weight_fallback_rounds": sum(
                    r["fee"]["mirror"]["equal_weight_fallback"] for r in rounds)}}


def main():
    t_wall = time.time()
    os.environ.setdefault("ETH_RPC_TIMEOUT", "300")
    rpc_url = os.environ.get("MAINNET_RPC_URL") or DEFAULT_RPC
    hours = int(os.environ.get("HOURS") or DEFAULT_HOURS)
    start = parse_start(os.environ.get("REPLAY_START") or DEFAULT_START)
    if hours < 1 or start % 3600:
        raise SystemExit("HOURS must be >= 1 and REPLAY_START a full hour")
    check_repro_env()
    step, hour = cm.DELTA, cm.N_SEGMENTS * cm.DELTA
    end = start + hours * hour
    warm = start - ROUND_LEAD_S - (cm.N_FEATURES + 1) * step
    grid = list(range(warm, end + 1, step))
    mainnet = Mainnet(rpc_url)

    log(f"replaying {hours} h from {utc(start)}: reading mainnet observe() on "
        f"{len(grid)} grid points")
    cums, block_at = real_cumulatives(mainnet, grid, [start + h * hour for h in range(hours + 1)])
    ticks = {t: cm.floor_div(cums[t + step] - cums[t], step) for t in grid[:-1]}
    fork_block = mainnet.block_at_or_after(warm - SETUP_MARGIN_S) - 1
    aggregator = json.loads(cast("call", FEED, "aggregator()(address)", "--rpc-url", rpc_url,
                                 "--block", fork_block, "--json"))[0]
    last_block = mainnet.block_at_or_after(end + SETTLE_AFTER_S + 60)
    reports = feed_reports(mainnet, aggregator, fork_block + 1, last_block)
    log(f"forking mainnet at block {fork_block} ({utc(mainnet.ts(fork_block))}); "
        f"{len(reports)} Chainlink reports to replay")
    fee = calibrate_fee(mainnet, start)

    owner = DEV_KEYS[0]
    with ForkAnvil(rpc_url, fork_block) as c:
        fork_ts = c.latest_ts()
        market, agents, agent_ids, verifiers = deploy(c, owner)
        fee_consumer = deploy_fee_consumer(c, owner, market, fee)
        log(f"VolFeeConsumer {fee_consumer}")
        fund_trader(c)
        feed = FeedReplay(c, reports)
        rp = Replay(c, mainnet, owner, start, hours)
        rp.market, rp.agents, rp.verifiers = market, agents, verifiers
        rp.fee_consumer, rp.fee, rp.ticks, rp.grid_origin = fee_consumer, fee, ticks, warm
        rp.baseline = as_int(c.call(market, "baselineLogScore()(int256)")[0])
        tick_now = pool_tick(c)
        log(f"deployed in {c.latest_ts() - fork_ts} s of chain time; replay grid starts "
            f"{utc(warm)}")

        for g in grid:
            feed.before(g)
            batch = []
            if g in ticks and ticks[g] != tick_now:
                batch.append(swap_tx(c, tick_now, ticks[g]))
            h_open = (g + ROUND_LEAD_S - start) // hour
            opening = (g + ROUND_LEAD_S - start) % hour == 0 and 0 <= h_open < hours
            if opening:
                points = [g - (cm.N_FEATURES + 1 - i) * step for i in range(cm.N_FEATURES + 2)]
                real_feats = cm.features_from_cumulatives([cums[t] for t in points])
                batch.append(rp.open_round(h_open, g, real_feats))
            for h, rec in rp.rounds.items():
                k, rem = divmod(g - rec["start"], step)
                if rem == 0 and 0 <= k <= cm.N_SEGMENTS:
                    batch.append({"from": c.sampler, "to": market, "gas": SAMPLE_GAS,
                                  "data": calldata("sample(uint256,uint256)", h, k)})
            if batch:
                c.mine_batch(g, batch)
            if g in ticks:
                tick_now = pool_tick(c)
                if tick_now != ticks[g]:
                    raise RuntimeError(f"pool at tick {tick_now}, replay target {ticks[g]}")
            h_end = (g - start) // hour - 1
            if (g - start) % hour == 0 and 0 <= h_end < hours:
                s = rp.round_start(h_end)
                feed.before(g + SETTLE_AFTER_S)
                window = [ticks[s + k * step] for k in range(cm.N_SEGMENTS)]
                first, nxt = block_at[s], block_at[s + hour]
                swaps = mainnet.logs(POOL, SWAP_TOPIC, first, nxt - 1)
                info = {"block_from": first, "block_to": nxt - 1, "swap_count": len(swaps),
                        "swap_txs": [lg["transactionHash"] for lg in swaps[:SWAP_LOG_SAMPLE]],
                        "last_swap_tx": swaps[-1]["transactionHash"] if swaps else None}
                rp.close(h_end, window, info, hour_market(mainnet, first, nxt, swaps))
            if opening:
                rp.enter(h_open, feed)

        tiers = {a.name: model_tier(c, market, a.model_id) for a in agents}
        hashes = {a.name: model_hash_of(c, market, a.model_id) for a in agents}
        final_rep = {a.name: reputation_of(c, market, agent_ids[a.name], tiers[a.name])
                     for a in agents}
        market_left = balance(c, WETH, market)

    rounds = [rp.rounds[h] for h in sorted(rp.rounds)]
    result = {
        "schema": "vol-replay/v1",
        "network": "anvil fork of Ethereum mainnet", "fork_block": fork_block,
        "fork_timestamp": fork_ts, "generated_at": int(time.time()),
        "elapsed_s": round(time.time() - t_wall),
        "replay": {"hours": hours, "start": start, "end": end, "start_utc": utc(start),
                   "end_utc": utc(end), "grid_start": warm, "grid_step_s": step,
                   "segments_replayed": len(ticks),
                   "pool_source": "mainnet observe() 5-minute floor mean ticks (archive calls)",
                   "chainlink_reports": feed.done},
        "contracts": {"market": market, "pool": POOL, "chainlink_feed": FEED,
                      "chainlink_aggregator": aggregator, "erc8004_identity": IDENTITY,
                      "erc8004_reputation": REPUTATION, "settlement_token": WETH,
                      "fee_consumer": fee_consumer},
        "params": {"delta_s": cm.DELTA, "n_segments": cm.N_SEGMENTS, "bounds": list(BOUNDS),
                   "fee_bps": FEE_BPS, "predictor_share_bps": PREDICTOR_SHARE_BPS,
                   "commit_lead_s": COMMIT_LEAD, "reveal_lead_s": REVEAL_LEAD,
                   "round_lead_s": ROUND_LEAD_S, "bet_wei": str(BET_WEI),
                   "baseline_log_score": str(rp.baseline),
                   "baseline_log_score_float": rp.baseline / 1e18, "fee_consumer": fee},
        "agents": [{"agent": a.name, "model": getattr(a, "model", None) or REPRO_MODEL,
                    "model_type": a.kind, "tier": tiers[a.name], "model_hash": hashes[a.name],
                    "address": a.address, "model_id": a.model_id,
                    "agent_id": agent_ids[a.name], "verifier": verifiers[a.name]}
                   for a in agents],
        "tamper_checks": rp.tamper,
        "rounds": rounds,
        "summary": summarize(rounds, agents, final_rep),
        "market_balance_after_wei": str(market_left),
    }
    RESULT.parent.mkdir(parents=True, exist_ok=True)
    RESULT.write_text(json.dumps(result, indent=1) + "\n")
    print_summary(result)


def print_summary(r):
    s = r["summary"]
    print(f"\n=== VolMarket replay on a mainnet fork: {r['replay']['hours']} h from "
          f"{r['replay']['start_utc']} ===")
    print(f"fork block {r['fork_block']}, market {r['contracts']['market']}, "
          f"{len(r['replay']['chainlink_reports'])} Chainlink reports replayed, "
          f"{r['elapsed_s']} s wall time")
    print(f"rounds {s['rounds']}: settled {s['settled']}, voided {s['voided']} "
          f"{s['void_reasons']}; "
          f"features match mainnet {s['features_match_mainnet']}, RV matches mainnet "
          f"{s['rv_matches_mainnet']}; winning buckets {s['bucket_counts']}")
    print(f"{'agent':<20}{'rounds':>7}{'total ln p':>12}{'mean':>9}{'>base':>7}{'reward WETH':>13}"
          f"  ERC-8004 count")
    print(f"{'uniform baseline':<20}{s['settled']:>7}{s['uniform_total_log_score']:>12.3f}"
          f"{math.log(0.2):>9.3f}")
    for name, a in s["agents"].items():
        mean = f"{a['mean_log_score']:.3f}" if a["mean_log_score"] is not None else "-"
        print(f"{name:<20}{a['rounds_scored']:>7}{a['total_log_score']:>12.3f}{mean:>9}"
              f"{a['beat_baseline_rounds']:>7}{int(a['predictor_reward_wei']) / 1e18:>13.6f}"
              f"  {a['erc8004']['count']} ({a['erc8004']['tag2']})")
    for name, a in s["agents"].items():
        if a["reproduced_rounds"] is not None:
            print(f"{name}: recompute from onchain features matched the reveal in "
                  f"{a['reproduced_rounds']}/{s['rounds']} rounds")
    for t in r["tamper_checks"]:
        print(f"{t['agent']}: honest proof verifies={t['honest_proof_verifies']}, tampered "
              f"output verifies={t['tampered_output_verifies']}, verifyProof gas "
              f"{t['verify_proof_gas']}")
    fs_ = s["fee_strategies"]
    print(f"fee strategies over {fs_['rounds']} rounds (bps): mean "
          + ", ".join(f"{k} {v:.3f}" for k, v in fs_["mean_bps"].items()) + "; MAE vs fair "
          + ", ".join(f"{k} {v:.3f}" for k, v in fs_["mae_bps"].items())
          + f"; mirror matches {fs_['mirror_matches']}, equal-weight rounds "
          f"{fs_['equal_weight_fallback_rounds']}")
    print(f"left in market {int(r['market_balance_after_wei'])} wei; wrote "
          f"{RESULT.relative_to(REPO)}")


if __name__ == "__main__":
    sys.exit(main())
