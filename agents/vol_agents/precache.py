"""Pre-generate zk proofs into the proof cache for hourly rounds whose features are already known.

A round starting at S is created at S - DELTA (demo/fork_round.py, ROUND_LEAD_S), so its features
are cm.features_from_cumulatives of the pool's tickCumulative at S - DELTA - 17*DELTA .. S - DELTA,
read here with one mainnet archive observe() call; the fork replays exactly these values (its
`features_match_mainnet` check). Proofs land in out/proof-cache/<model>/<cache_key>/ like
Agent.prepare writes them, so a later replay of the same hour reuses them.

Usage: [MAINNET_RPC_URL=...] uv run python -m vol_agents.precache --start ISO|unix --hours N
       [--jobs J] [--models m ...]
Rounds whose S - DELTA is not yet in mainnet's past are skipped.
"""

import argparse
import json
import os
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime

from . import contract_math as cm
from .agent import cache_key, prove_round
from .build import model_names
from .ezkl_step import OUT

POOL = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"  # Uniswap V3 ETH/USDC 0.05%
OBSERVE_SELECTOR = "883bdbfd"  # observe(uint32[])
CACHE = OUT / "proof-cache"
DEFAULT_RPC = "https://mainnet.gateway.tenderly.co"  # demo/fork_round.py's default archive


def rpc(url, method, *params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)})
    req = urllib.request.Request(url, body.encode(), {"Content-Type": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                out = json.loads(r.read())
            if "error" in out:
                raise RuntimeError(out["error"])
            return out["result"]
        except Exception:
            if attempt == 4:
                raise
            time.sleep(2 + 3 * attempt)


def block_ts(url, n):
    return int(rpc(url, "eth_getBlockByNumber", hex(n), False)["timestamp"], 16)


def block_at_or_after(url, t):
    head = int(rpc(url, "eth_blockNumber"), 16)
    if block_ts(url, head) < t:
        raise RuntimeError(f"{t} is not in mainnet's past yet")
    n = head - (block_ts(url, head) - t) // 12
    while block_ts(url, n) < t:
        n += max(1, (t - block_ts(url, n)) // 12)
    while block_ts(url, n - 1) >= t:
        n -= 1
    return n


def observe(url, block, secs):
    words = [0x20, len(secs), *secs]
    data = "0x" + OBSERVE_SELECTOR + "".join(f"{w:064x}" for w in words)
    raw = bytes.fromhex(rpc(url, "eth_call", {"to": POOL, "data": data}, hex(block))[2:])
    word = lambda i: int.from_bytes(raw[32 * i: 32 * i + 32], "big", signed=True)  # noqa: E731
    first = word(0) // 32
    return [word(first + 1 + i) for i in range(word(first))]


def round_features(url, start):
    """The 16 features createRound computes at start - DELTA."""
    g = start - cm.DELTA
    points = [g - (cm.N_FEATURES + 1 - i) * cm.DELTA for i in range(cm.N_FEATURES + 2)]
    block = block_at_or_after(url, g)
    ts = block_ts(url, block)
    return cm.features_from_cumulatives(observe(url, block, [ts - t for t in points]))


def parse_start(v):
    if v.isdigit():
        return int(v)
    return int(datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp())


def utc(t):
    return datetime.fromtimestamp(t, UTC).strftime("%Y-%m-%dT%H:%MZ")


def main():
    ap = argparse.ArgumentParser(prog="vol_agents.precache")
    ap.add_argument("--start", required=True, help="first round start (full hour, ISO or unix)")
    ap.add_argument("--hours", type=int, required=True)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--models", nargs="*")
    ap.add_argument("--manifest", help="append one JSON line per (round, model) here")
    a = ap.parse_args()
    url = os.environ.get("MAINNET_RPC_URL") or DEFAULT_RPC
    start = parse_start(a.start)
    if start % 3600:
        raise SystemExit("--start must be a full hour")
    models = a.models or model_names()
    now = int(time.time())
    tasks = []
    for h in range(a.hours):
        s = start + h * 3600
        if s - cm.DELTA > now - 30:
            print(f"skip {utc(s)}: features not final yet")
            continue
        feats = round_features(url, s)
        tasks += [(s, m, feats) for m in models]

    def run(task):
        s, m, feats = task
        work = OUT / "precache" / f"{s}" / m
        t0 = time.time()
        _, timings, outputs = prove_round(m, feats, work, CACHE)
        rec = {"start": s, "start_utc": utc(s), "model": m, "key": cache_key(m, feats),
               "cached": bool(timings["prove"].get("cached")), "prove": timings["prove"],
               "outputs": outputs, "features": feats, "wall_s": round(time.time() - t0, 2)}
        print(json.dumps({k: rec[k] for k in ("start_utc", "model", "key", "cached", "prove")}),
              flush=True)
        if a.manifest:
            with open(a.manifest, "a") as f:
                f.write(json.dumps(rec) + "\n")
        return rec

    with ThreadPoolExecutor(a.jobs) as pool:
        recs = list(pool.map(run, tasks))
    print(f"done: {len(recs)} proofs ({sum(not r['cached'] for r in recs)} new) for "
          f"{len({r['start'] for r in recs})} rounds")


if __name__ == "__main__":
    main()
