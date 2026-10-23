"""The pool's Swap logs over JSON-RPC, written in the history cache format, so a recompute rebuilds
a round's long context from chain data alone. agents/ never imports analysis/fetch_swaps.py, the
fetcher that keeps the live agents' cache; both write the same `block,tick,timestamp` rows and
coverage sidecar, so history.round_context reads either the same way.

The logs must come from a node that serves the real pool's history (mainnet, MAINNET_RPC_URL): on
the demo's anvil fork the pool carries replay swaps after the fork block.
"""

import json
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

from . import history

# Swap(address,address,int256,int256,uint160,uint128,int24)
SWAP_TOPIC = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
# Public gateways truncate or refuse wider eth_getLogs ranges and cap answers near 10 000 logs;
# 2 000 blocks of this pool stay far below that.
SEGMENT_BLOCKS = 2000
LOG_CAP = 10_000
# Fetched before the series' first checkpoint so the tick in force there is known.
LEAD_S = 3600
SECONDS_PER_BLOCK = 12  # only seeds the timestamp search; the search itself is exact


class RpcError(RuntimeError):
    pass


def http_transport(url: str, payload: dict, timeout=60, attempts=3) -> dict:
    data = json.dumps(payload).encode()
    for k in range(attempts):
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.loads(r.read())
        except (urllib.error.URLError, OSError, json.JSONDecodeError) as e:
            if k == attempts - 1:
                raise RpcError(f"{payload['method']} failed: {type(e).__name__}") from None
            time.sleep(1 + k)
    raise AssertionError("unreachable")


def signed_word(word: str) -> int:
    v = int(word, 16)
    return v - (1 << 256) if v >> 255 else v


class SwapLogs:
    def __init__(self, url: str, transport=http_transport):
        self.url, self.transport = url, transport
        self._ts: dict[int, int] = {}

    def call(self, method: str, params: list):
        resp = self.transport(self.url, {"jsonrpc": "2.0", "id": 1, "method": method,
                                         "params": params})
        if resp.get("error") is not None or "result" not in resp:
            raise RpcError(f"{method}: {resp.get('error')}")
        return resp["result"]

    def head(self) -> int:
        return int(self.call("eth_blockNumber", []), 16)

    def timestamp(self, block: int) -> int:
        if block not in self._ts:
            b = self.call("eth_getBlockByNumber", [hex(block), False])
            if b is None:
                raise RpcError(f"block {block} not found")
            self._ts[block] = int(b["timestamp"], 16)
        return self._ts[block]

    def first_block_at_or_after(self, t: int) -> int:
        """Lowest block whose timestamp is >= t (timestamps strictly increase)."""
        hi = self.head()
        if self.timestamp(hi) < t:
            raise RpcError(f"chain head is before {t}")
        lo = max(0, hi - (self.timestamp(hi) - t) // SECONDS_PER_BLOCK - 1)
        step = 64
        while lo > 0 and self.timestamp(lo) >= t:
            lo, hi = max(0, lo - step), lo
            step *= 2
        # invariant: timestamp(lo) < t <= timestamp(hi), or lo == 0
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if self.timestamp(mid) >= t:
                hi = mid
            else:
                lo = mid
        return lo if self.timestamp(lo) >= t else hi

    def swaps(self, pool: str, from_block: int, to_block: int) -> list[tuple[int, int, int]]:
        """(block, tick, timestamp) of every Swap in [from_block, to_block], in log order."""
        rows = []
        for a in range(from_block, to_block + 1, SEGMENT_BLOCKS):
            b = min(a + SEGMENT_BLOCKS - 1, to_block)
            logs = self.call("eth_getLogs", [{"address": pool, "topics": [SWAP_TOPIC],
                                              "fromBlock": hex(a), "toBlock": hex(b)}])
            if len(logs) >= LOG_CAP:
                raise RpcError(f"blocks {a}-{b}: {len(logs)} logs, the answer may be truncated")
            for lg in logs:
                block = int(lg["blockNumber"], 16)
                if not a <= block <= b or lg.get("removed"):
                    raise RpcError(f"blocks {a}-{b}: unexpected log at block {block}")
                if lg.get("blockTimestamp"):
                    self._ts.setdefault(block, int(lg["blockTimestamp"], 16))
                data = lg["data"][2:]
                rows.append((block, int(lg["logIndex"], 16), signed_word(data[256:320])))
        rows.sort()
        return [(block, tick, self.timestamp(block)) for block, _, tick in rows]


def write_cache(path: Path, rows, pool: str, to_block: int, to_timestamp: int) -> Path:
    path.write_text("block,tick,timestamp\n" + "".join(f"{b},{t},{s}\n" for b, t, s in rows),
                    encoding="utf-8")
    history.coverage_path(path).write_text(json.dumps(
        {"pool": pool, "to_block": to_block, "to_timestamp": to_timestamp}), encoding="utf-8")
    return path


def round_context_from_chain(logs: SwapLogs, pool: str, features, start: int, delta: int,
                             n: int = history.DEFAULT_CONTEXT) -> history.Context:
    """history.round_context over a cache fetched from the pool's logs for exactly this round:
    every Swap from LEAD_S before the first checkpoint through the first block at or after
    start - delta."""
    end = start - delta
    first = logs.first_block_at_or_after(end - (n + 1) * delta - LEAD_S)
    last = logs.first_block_at_or_after(end)
    rows = logs.swaps(pool, first, last)
    with tempfile.TemporaryDirectory() as d:
        cache = write_cache(Path(d) / "swaps.csv", rows, pool, last, logs.timestamp(last))
        return history.round_context(features, start, delta,
                                     {history.CACHE_ENV: str(cache), history.CONTEXT_ENV: str(n)})
