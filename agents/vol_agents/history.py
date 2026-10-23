"""Long context for the time-series model agents: 5-minute segment-mean tick differences.

Input is the rolling Swap cache that analysis/ keeps (`fetch_swaps.py --tail`), read as files;
agents/ never imports analysis/ (swap_logs writes the same format from a node's Swap logs, so a
recompute rebuilds the series from chain data alone):
- `<cache>`: CSV `block,tick,timestamp`, ascending in block, the rows of a block in log order;
- `<cache>.coverage.json`: `{"pool", "to_block", "to_timestamp"}`, every Swap up to `to_block`
  (timestamp `to_timestamp`) is in the CSV.

Series for a round created at T = start - delta (demo/fork_round.py opens a round one segment
before its start): checkpoints c_k = T - (n + 1 - k) * delta for k = 0 .. n + 1, segment means
m_j = floorDiv(C(c_{j+1}) - C(c_j), delta), differences d_j = m_{j+1} - m_j for j = 0 .. n - 1,
unclamped. The last point is the createRound segment, as in tsfm_forecast.build_request, and
clamping the last 16 by cm.CLAMP gives the round's onchain features / cm.MULT. This is the c512
context of the offline evaluation (MODEL_CARD 6.2), equal to it on all 339 evaluated rounds.

C(t) integrates the tick from the first cached Swap: the tick of a block is the one its last Swap
leaves, held until the next Swap block, as the pool oracle charges it. The constant offset to the
oracle's tickCumulative cancels in every difference. C(T) depends only on Swaps before T, so no
Swap at or after T (let alone the round start) is read.

Missing or stale data raises HistoryUnavailable instead of guessing: an unreadable cache or
sidecar, coverage that ends before T, or no Swap at or before c_0 (the initial tick is unknown).
`round_context` turns that, and a series that disagrees with the onchain features, into the
fallback to the 16 onchain differences.
"""

import csv
import json
import os
from dataclasses import dataclass
from pathlib import Path

from . import contract_math as cm

DEFAULT_CONTEXT = 512  # ~42.7 h of 5-minute differences, the evaluated long context
CACHE_ENV = "VOL_HISTORY_CACHE"
CONTEXT_ENV = "VOL_HISTORY_CONTEXT"
# (spread, uniform mix) of the tsfm_forecast sampling post-process per model for the long context,
# chosen on the validation period 2026-10-08 .. 10-15 with c512 only (MODEL_CARD 6.2); the
# 16-point spreads in tsfm_forecast.MODELS do not transfer.
LONG_CONTEXT_CALIBRATION = {
    "remote-model": (0.9, 0.3),
    "chronos-2": (0.8, 0.3),
    "remote-model-b": (0.8, 0.3),
    "timesfm-3.0": (0.8, 0.3),
    "timestral-209m": (0.8, 0.2),
}


class HistoryUnavailable(Exception):
    """The cache cannot provide the requested series."""


def coverage_path(cache: Path) -> Path:
    return cache.with_name(cache.name + ".coverage.json")


def read_coverage(cache: Path) -> int:
    """Timestamp up to which the cache holds every Swap."""
    try:
        payload = json.loads(coverage_path(cache).read_text(encoding="utf-8"))
        return int(payload["to_timestamp"])
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as e:
        raise HistoryUnavailable(f"no readable coverage for {cache}: {type(e).__name__}") from None


def tick_path(cache: Path, before: int) -> list[tuple[int, int]]:
    """(timestamp, tick) at every tick change strictly before `before`, ascending."""
    last_of_block: dict[int, tuple[int, int, int]] = {}
    previous = -1
    try:
        with cache.open(newline="", encoding="utf-8") as f:
            rows = csv.reader(f)
            if next(rows, None) != ["block", "tick", "timestamp"]:
                raise HistoryUnavailable(f"{cache}: expected header block,tick,timestamp")
            for row in rows:
                block, tick, ts = (int(v) for v in row)
                if block < previous:
                    raise HistoryUnavailable(f"{cache}: block {block} after {previous}")
                previous = block
                if ts < before:
                    last_of_block[block] = (ts, block, tick)
    except OSError as e:
        raise HistoryUnavailable(f"cannot read {cache}: {type(e).__name__}") from None
    except ValueError:
        raise HistoryUnavailable(f"{cache}: malformed row after block {previous}") from None
    path: list[tuple[int, int]] = []
    for ts, _, tick in sorted(last_of_block.values()):
        if path and path[-1][0] == ts:
            path[-1] = (ts, tick)
        else:
            path.append((ts, tick))
    return path


def cumulatives(path: list[tuple[int, int]], checkpoints: list[int]) -> list[int]:
    """Integral of the tick from the first change up to each ascending checkpoint."""
    if not path or path[0][0] > checkpoints[0]:
        raise HistoryUnavailable(
            f"no Swap at or before {checkpoints[0]}; the cache starts too late")
    out = []
    acc, pos = 0, 0
    for t in checkpoints:
        while pos + 1 < len(path) and path[pos + 1][0] <= t:
            acc += path[pos][1] * (path[pos + 1][0] - path[pos][0])
            pos += 1
        out.append(acc + path[pos][1] * (t - path[pos][0]))
    return out


def segment_diffs(cache, end: int, n: int = DEFAULT_CONTEXT, delta: int = cm.DELTA) -> list[int]:
    """The n segment-mean differences whose last segment ends at `end`; reads only Swaps before
    `end`."""
    if n < 1 or delta < 1:
        raise ValueError("n and delta must be positive")
    cache = Path(cache)
    covered = read_coverage(cache)
    if covered < end:
        raise HistoryUnavailable(f"cache covers up to {covered}, the series ends at {end}")
    checkpoints = [end - (n + 1 - k) * delta for k in range(n + 2)]
    c = cumulatives(tick_path(cache, end), checkpoints)
    means = [cm.floor_div(c[j + 1] - c[j], delta) for j in range(n + 1)]
    return [means[j + 1] - means[j] for j in range(n)]


def consistent_with_features(diffs, features) -> bool:
    """Whether the last points, clamped as the contract does, are the round's onchain features."""
    k = len(features)
    if len(diffs) < k:
        return False
    return [max(-cm.CLAMP, min(cm.CLAMP, d)) * cm.MULT for d in diffs[-k:]] == list(features)


@dataclass(frozen=True)
class Context:
    diffs: list[int]  # segment-mean tick differences, oldest first, last ends at start - delta
    source: str  # "swaps" (long off-chain context) or "onchain" (the 16 features)
    reason: str | None = None  # why the onchain fallback was used


def round_context(features, start: int, delta: int, env=None) -> Context:
    """The long context for a round from $VOL_HISTORY_CACHE ($VOL_HISTORY_CONTEXT points,
    default 512), or the 16 onchain differences when it is unset, unusable or disagrees with the
    features."""
    env = os.environ if env is None else env
    onchain = [x // cm.MULT for x in features]
    cache = (env.get(CACHE_ENV) or "").strip()
    if not cache:
        return Context(onchain, "onchain", f"{CACHE_ENV} unset")
    n = int(env.get(CONTEXT_ENV) or DEFAULT_CONTEXT)
    if n < len(features):
        raise ValueError(f"{CONTEXT_ENV} must be at least {len(features)}, got {n}")
    try:
        diffs = segment_diffs(cache, start - delta, n, delta)
    except HistoryUnavailable as e:
        return Context(onchain, "onchain", str(e))
    if not consistent_with_features(diffs, features):
        return Context(onchain, "onchain", "swap history disagrees with the onchain features")
    return Context(diffs, "swaps")
