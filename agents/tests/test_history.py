import json
from pathlib import Path

import pytest

from vol_agents import contract_math as cm
from vol_agents import history as h

FIXTURES = Path(__file__).resolve().parents[2] / "contracts" / "test" / "fixtures"
RV_CASES = json.loads((FIXTURES / "vol_rv_cases.json").read_text())
T0 = 1_792_000_000  # multiple of 300
DELTA = cm.DELTA


def write_cache(tmp_path, swaps, covered_to):
    """swaps: (timestamp, tick) rows in block order, one block each, or (timestamp, tick, block)."""
    cache = tmp_path / "swaps.csv"
    lines = ["block,tick,timestamp"]
    for i, s in enumerate(swaps):
        block = s[2] if len(s) == 3 else 100 + i
        lines.append(f"{block},{s[1]},{s[0]}")
    cache.write_text("\n".join(lines) + "\n")
    h.coverage_path(cache).write_text(
        json.dumps({"pool": "0x", "to_block": 0, "to_timestamp": covered_to}))
    return cache


def segment_swaps(start, ticks, offset=0):
    """One swap per segment, at start + k * DELTA + offset, holding ticks[k]."""
    return [(start + k * DELTA + offset, t) for k, t in enumerate(ticks)]


def wavy(n):
    return [200_000 + (37 * k * k + 11 * k) % 181 - 90 for k in range(n)]


def env_for(cache, n=None):
    env = {h.CACHE_ENV: str(cache)}
    if n is not None:
        env[h.CONTEXT_ENV] = str(n)
    return env


@pytest.mark.parametrize("case", [c for c in RV_CASES["cases"] if not c["missing"]],
                         ids=lambda c: c["name"])
def test_matches_the_shared_rv_fixture(tmp_path, case):
    n_seg, delta = RV_CASES["nSegments"], RV_CASES["delta"]
    tl = case["timeline"]
    end = T0 + n_seg * delta
    cache = write_cache(tmp_path, [(T0 + o, t) for o, t in zip(tl["offsets"], tl["ticks"],
                                                               strict=True)], end)
    d = h.segment_diffs(cache, end, n_seg - 1, delta)
    m = case["segmentMeans"]
    assert d == [m[i + 1] - m[i] for i in range(n_seg - 1)]
    assert sum(x * x for x in d) * (n_seg - 1) // len(d) == case["rv"]


def test_last_points_are_the_contract_features(tmp_path):
    n = 40
    end = T0 + (n + 1) * DELTA
    ticks = wavy(n + 1)
    cache = write_cache(tmp_path, segment_swaps(T0, ticks), end)
    feats = cm.features_from_segment_ticks(ticks[-(cm.N_FEATURES + 1):])
    d = h.segment_diffs(cache, end, n)
    assert d == [ticks[k + 1] - ticks[k] for k in range(n)]
    assert any(abs(x) > cm.CLAMP for x in d[-16:])  # the series is unclamped, the features not
    assert h.consistent_with_features(d, feats)
    ctx = h.round_context(feats, end + DELTA, DELTA, env_for(cache, n))
    assert ctx.source == "swaps" and ctx.diffs == d and ctx.reason is None


def test_reads_nothing_at_or_after_the_series_end(tmp_path):
    n = 30
    end = T0 + (n + 1) * DELTA
    base = [(T0 - 1, 200_000)] + segment_swaps(T0, wavy(n + 1), offset=7)
    want = h.segment_diffs(write_cache(tmp_path, base, end + 3 * DELTA), end, n)
    later = [(end, -500_000), (end + 1, 900_000), (end + DELTA, 0), (end + 2 * DELTA, 1)]
    got = h.segment_diffs(write_cache(tmp_path, base + later, end + 3 * DELTA), end, n)
    assert got == want
    # the same jump one second earlier is inside the series and must move it
    earlier = base + [(end - 1, -500_000)]
    assert h.segment_diffs(write_cache(tmp_path, earlier, end + 3 * DELTA), end, n) != want


def test_round_context_ends_one_segment_before_the_round_start(tmp_path):
    n = 20
    t_open = T0 + (n + 1) * DELTA
    ticks = wavy(n + 3)
    cache = write_cache(tmp_path, segment_swaps(T0, ticks), t_open + 2 * DELTA)
    feats = cm.features_from_segment_ticks(ticks[n + 1 - 17:n + 1])
    ctx = h.round_context(feats, t_open + DELTA, DELTA, env_for(cache, n))
    assert ctx.source == "swaps"
    assert ctx.diffs == h.segment_diffs(cache, t_open, n)


def test_the_last_swap_of_a_block_sets_its_tick(tmp_path):
    n = 2
    end = T0 + 3 * DELTA
    swaps = [(T0, 10, 1), (T0 + DELTA, 99, 2), (T0 + DELTA, 20, 2), (T0 + 2 * DELTA, 30, 3)]
    assert h.segment_diffs(write_cache(tmp_path, swaps, end), end, n) == [10, 10]


def test_stale_coverage_fails_and_falls_back_to_the_onchain_features(tmp_path):
    n = 20
    end = T0 + (n + 1) * DELTA
    ticks = wavy(n + 1)
    cache = write_cache(tmp_path, segment_swaps(T0, ticks), end - 1)
    with pytest.raises(h.HistoryUnavailable, match="covers up to"):
        h.segment_diffs(cache, end, n)
    feats = cm.features_from_segment_ticks(ticks[-17:])
    ctx = h.round_context(feats, end + DELTA, DELTA, env_for(cache, n))
    assert ctx.source == "onchain"
    assert ctx.diffs == [x // cm.MULT for x in feats]
    assert "covers up to" in ctx.reason


def test_a_cache_starting_after_the_first_checkpoint_fails(tmp_path):
    n = 20
    end = T0 + (n + 1) * DELTA
    cache = write_cache(tmp_path, segment_swaps(T0, wavy(n + 1), offset=1), end)
    with pytest.raises(h.HistoryUnavailable, match="starts too late"):
        h.segment_diffs(cache, end, n)


def test_missing_sidecar_or_cache_fails(tmp_path):
    end = T0 + 3 * DELTA
    cache = write_cache(tmp_path, segment_swaps(T0, [1, 2, 3]), end)
    h.coverage_path(cache).unlink()
    with pytest.raises(h.HistoryUnavailable, match="coverage"):
        h.segment_diffs(cache, end, 2)
    with pytest.raises(h.HistoryUnavailable):
        h.segment_diffs(tmp_path / "absent.csv", end, 2)


def test_a_foreign_header_or_descending_blocks_fail(tmp_path):
    end = T0 + 3 * DELTA
    cache = write_cache(tmp_path, [(T0, 1, 5), (T0 + DELTA, 2, 4)], end)
    with pytest.raises(h.HistoryUnavailable, match="after"):
        h.segment_diffs(cache, end, 2)
    cache.write_text("timestamp,tick\n1,2\n")
    with pytest.raises(h.HistoryUnavailable, match="header"):
        h.segment_diffs(cache, end, 2)


def test_disagreeing_history_falls_back(tmp_path):
    n = 20
    end = T0 + (n + 1) * DELTA
    ticks = wavy(n + 1)
    cache = write_cache(tmp_path, segment_swaps(T0, ticks), end)
    feats = cm.features_from_segment_ticks(ticks[-17:])
    feats[-1] += cm.MULT
    ctx = h.round_context(feats, end + DELTA, DELTA, env_for(cache, n))
    assert ctx.source == "onchain" and "disagrees" in ctx.reason


def test_unset_cache_uses_the_onchain_features():
    feats = [128 * k for k in range(-8, 8)]
    ctx = h.round_context(feats, T0, DELTA, env={})
    assert ctx == h.Context(list(range(-8, 8)), "onchain", f"{h.CACHE_ENV} unset")


def test_default_context_is_512(tmp_path):
    n = h.DEFAULT_CONTEXT
    end = T0 + (n + 1) * DELTA
    ticks = wavy(n + 1)
    cache = write_cache(tmp_path, segment_swaps(T0, ticks), end)
    feats = cm.features_from_segment_ticks(ticks[-17:])
    ctx = h.round_context(feats, end + DELTA, DELTA, env_for(cache))
    assert ctx.source == "swaps" and len(ctx.diffs) == 512
