"""swap_logs rebuilds a round's long context from the pool's Swap logs alone: against a fake
JSON-RPC node it must give the very series history.round_context reads from a full swap cache."""

import json

import pytest

from vol_agents import contract_math as cm
from vol_agents import history as h
from vol_agents import swap_logs as sl

POOL = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"
GENESIS = 1_792_000_000
BLOCK_S = 12
HEAD = 3000
N = 80


def word(v: int) -> str:
    return format(v % (1 << 256), "064x")


def chain_swaps():
    """(block, log_index, tick): most blocks swap, some twice; ticks of both signs, so a wrong
    sign decoding does not cancel in the differences."""
    out = []
    for b in range(1, HEAD + 1):
        if b % 7 == 3:
            continue
        out.append((b, 0, (37 * b * b + 11 * b) % 401 - 200))
        if b % 5 == 0:
            out.append((b, 1, (13 * b) % 97 - 48))
    return out


class FakeNode:
    def __init__(self, swaps):
        self.swaps = swaps
        self.log_ranges = []

    def __call__(self, url, payload, timeout=60, attempts=3):
        m, p = payload["method"], payload["params"]
        if m == "eth_blockNumber":
            return {"result": hex(HEAD)}
        if m == "eth_getBlockByNumber":
            b = int(p[0], 16)
            return {"result": {"timestamp": hex(GENESIS + BLOCK_S * b)} if b <= HEAD else None}
        if m == "eth_getLogs":
            q = p[0]
            a, z = int(q["fromBlock"], 16), int(q["toBlock"], 16)
            assert q["address"] == POOL and q["topics"] == [sl.SWAP_TOPIC]
            self.log_ranges.append((a, z))
            logs = []
            for b, i, tick in self.swaps:
                if a <= b <= z:
                    lg = {"blockNumber": hex(b), "logIndex": hex(i),
                          "data": "0x" + word(-1) + word(5) + word(1 << 96) + word(10**18)
                          + word(tick)}
                    if b % 2:
                        lg["blockTimestamp"] = hex(GENESIS + BLOCK_S * b)
                    logs.append(lg)
            return {"result": logs[::-1]}
        raise AssertionError(m)


def full_cache(tmp_path, swaps):
    cache = tmp_path / "full.csv"
    rows = sorted(swaps)
    cache.write_text("block,tick,timestamp\n" + "".join(
        f"{b},{t},{GENESIS + BLOCK_S * b}\n" for b, _, t in rows))
    h.coverage_path(cache).write_text(json.dumps(
        {"pool": POOL, "to_block": HEAD, "to_timestamp": GENESIS + BLOCK_S * HEAD}))
    return cache


def test_chain_rebuilt_series_equals_the_cache_series(tmp_path):
    swaps = chain_swaps()
    cache = full_cache(tmp_path, swaps)
    start = GENESIS + BLOCK_S * (HEAD - 100) // cm.DELTA * cm.DELTA
    diffs = h.segment_diffs(cache, start - cm.DELTA, N)
    feats = [max(-cm.CLAMP, min(cm.CLAMP, d)) * cm.MULT for d in diffs[-cm.N_FEATURES:]]
    from_cache = h.round_context(feats, start, cm.DELTA,
                                 {h.CACHE_ENV: str(cache), h.CONTEXT_ENV: str(N)})
    assert from_cache.source == "swaps" and from_cache.diffs == diffs

    node = FakeNode(swaps)
    ctx = sl.round_context_from_chain(sl.SwapLogs("http://node", node), POOL, feats, start,
                                      cm.DELTA, N)
    assert ctx == from_cache
    assert all(z - a < sl.SEGMENT_BLOCKS for a, z in node.log_ranges)
    assert len(node.log_ranges) > 1
    # nothing at or after the series end was asked for beyond its first block
    end_block = -(-(start - cm.DELTA - GENESIS) // BLOCK_S)
    assert max(z for _, z in node.log_ranges) == end_block


def test_a_disagreeing_chain_falls_back_to_the_onchain_features(tmp_path):
    swaps = chain_swaps()
    start = GENESIS + BLOCK_S * (HEAD - 100) // cm.DELTA * cm.DELTA
    feats = [cm.MULT] * cm.N_FEATURES
    ctx = sl.round_context_from_chain(sl.SwapLogs("http://node", FakeNode(swaps)), POOL, feats,
                                      start, cm.DELTA, N)
    assert ctx.source == "onchain" and ctx.diffs == [1] * cm.N_FEATURES


def test_rpc_errors_and_truncated_answers_raise():
    def failing(url, payload, timeout=60, attempts=3):
        return {"error": {"code": -32000, "message": "limit"}}

    with pytest.raises(sl.RpcError):
        sl.SwapLogs("http://node", failing).head()

    many = [(10, i, 1) for i in range(sl.LOG_CAP)]
    with pytest.raises(sl.RpcError):
        sl.SwapLogs("http://node", FakeNode(many)).swaps(POOL, 1, 20)
