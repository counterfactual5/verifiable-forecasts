"""Offline calibration of the realized-volatility bucket bounds for the vol market.

The module rebuilds Uniswap V3 ``tickCumulative`` from raw Swap events, reproduces the
contract's realized-vol caliber exactly, and calibrates the four bucket bounds that
``VolMarket.createRound`` consumes.

Units and integer rules (every number that reaches the contract is a Python ``int``; no
float is used in the settlement caliber):

* ``tick`` is a Uniswap V3 tick; one tick is 1/1e4 of a price ratio.
* ``tickCumulative`` is the integral of the tick over time, in tick*seconds.
* A segment mean is a tick per second, floor-divided.
* ``rv`` is a realized variance in tick^2, normalized to ``nSegments - 1`` squared terms.

The caliber mirrored here is ``VolMarket._realizedVol`` / ``VolMarket._floorDiv``
(contracts/src/VolMarket.sol) and is pinned item-by-item by the shared fixture
``contracts/test/fixtures/vol_rv_cases.json``, which this module is tested against.

Between two Swap events the pool tick is constant, so a Swap log is enough to rebuild the
tick timeline. The rebuild matches the pool oracle up to a constant offset in the
cumulative, which cancels in the differences the contract uses:

* the tick of a block is the one its last Swap leaves behind, and it persists until the
  next Swap, so a block without any Swap keeps the previous tick;
* the oracle charges a block the tick that was live before it, which is the post-swap tick
  of the previous Swap block, so both integrate the same tick over every interval between
  two Swap blocks.

Known deviation: the argument above holds only for a complete Swap log stream.
``eth_getLogs`` gateways can silently truncate a response by log count — 11,769 logs
were measured in one 10,000-block segment of pool 0x88e6...5640 — and a truncated
segment breaks the equivalence for every window it touches. A live comparison of 8
windows against the pool oracle matched 6 and mismatched 2 (RV 117 vs oracle 54; 1132
vs 1114); the attribution is unresolved, with log completeness the prime suspect. The
calibrated bounds are therefore an approximation of the settlement distribution, not a
guarantee.
"""

from __future__ import annotations

import argparse
import bisect
import json
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
from typing import Final

DEFAULT_DELTA: Final[int] = 300
DEFAULT_N_SEGMENTS: Final[int] = 12
# Quantile levels are fractions of the sample, so the exact level 0.2 is the p20 quantile.
DEFAULT_QUANTILES: Final[tuple[float, ...]] = (0.20, 0.40, 0.60, 0.80)
BPS: Final[int] = 10_000
MIN_COVERAGE_BPS: Final[int] = 9000
METHOD: Final[str] = "swap-srvp-p20-p40-p60-p80"
CSV_COLUMNS: Final[tuple[str, ...]] = ("block", "tick", "timestamp")
DEFAULT_OUT: Final[Path] = Path("data/vol_params.json")
REPORT_NAME: Final[str] = "calibration_report.md"


class MissingInitialTick(ValueError):
    """Raised when a window opens before the first observed Swap, so no tick covers it."""


@dataclass(frozen=True)
class Swap:
    """One Uniswap V3 Swap event: the block it happened in, the post-swap tick, the time."""

    block: int
    tick: int
    timestamp: int


@dataclass(frozen=True)
class TimelinePoint:
    """A tick change: the tick holds from ``timestamp`` until the next point."""

    timestamp: int
    tick: int
    block: int


@dataclass(frozen=True)
class WindowVol:
    """Settlement outcome of one window, in the shape the contract settles it.

    A voided window has no realized volatility: the contract refunds every stake and never
    looks at the intermediate means, so the derived fields are ``None`` here as well.
    """

    start: int
    cums: tuple[int, ...]
    available: tuple[int, ...]
    segment_means: tuple[int, ...]
    sum_squares: int | None
    terms: int | None
    rv: int | None
    bucket: int | None
    voided: bool


@dataclass(frozen=True)
class CalibrationResult:
    """Calibrated bounds plus the evidence they were derived from."""

    delta: int
    n_segments: int
    quantiles: tuple[float, ...]
    raw_quantiles: tuple[int, ...]
    bounds: tuple[int, ...]
    rvs: tuple[int, ...]
    swap_count: int
    skipped_windows: int

    def as_params(self) -> dict[str, object]:
        """Serialisable parameters; ``bounds`` is top level, as the contract consumes it."""

        return {
            "delta": self.delta,
            "nSegments": self.n_segments,
            "bounds": list(self.bounds),
            "windows": len(self.rvs),
            "method": METHOD,
            "quantileLevels": list(self.quantiles),
            "quantiles": list(self.raw_quantiles),
            "swapCount": self.swap_count,
            "skippedWindows": self.skipped_windows,
            "rvMin": min(self.rvs),
            "rvMax": max(self.rvs),
            "rvMean": sum(self.rvs) // len(self.rvs),
            "bucketSharesPercent": bucket_shares(self.rvs, self.bounds),
        }


def load_swaps(path: str | Path) -> list[Swap]:
    """Read a ``block,tick,timestamp`` CSV of Swap events, keeping the file order.

    The order matters: the last row of a block is the Swap that leaves the tick the
    block ends with. The file is checked: ascending in block; rows of equal block keep
    their file order.
    """

    rows: list[Swap] = []
    try:
        handle = open(path, encoding="utf-8", newline="")
    except OSError as exc:
        raise ValueError(f"cannot read swap file {path}: {exc}") from exc

    with handle:
        header = handle.readline()
        if not header:
            raise ValueError(f"{path}: empty swap file")
        columns = [name.strip() for name in header.strip().split(",")]
        positions: dict[str, int] = {}
        for name in CSV_COLUMNS:
            if name not in columns:
                raise ValueError(f"{path}: missing required column {name!r}")
            positions[name] = columns.index(name)

        for line_number, raw in enumerate(handle, start=2):
            if not raw.strip():
                continue
            fields = [field.strip() for field in raw.strip().split(",")]
            values: dict[str, int] = {}
            for name in CSV_COLUMNS:
                index = positions[name]
                text = fields[index] if index < len(fields) else ""
                if not text:
                    raise ValueError(f"line {line_number}: missing column {name!r}")
                try:
                    values[name] = int(text)
                except ValueError as exc:
                    raise ValueError(
                        f"line {line_number}: column {name!r} is not an integer"
                    ) from exc
            if values["block"] <= 0:
                raise ValueError(f"line {line_number}: block must be positive")
            if values["timestamp"] < 0:
                raise ValueError(f"line {line_number}: timestamp must be non-negative")
            # collapse_swaps keeps the last in-file row per block, so a descending block
            # would silently pick the wrong tick.
            if rows and values["block"] < rows[-1].block:
                raise ValueError(
                    f"line {line_number}: block {values['block']} is lower than the "
                    f"previous block {rows[-1].block}; the file must be ascending in block"
                )
            rows.append(
                Swap(
                    block=values["block"],
                    tick=values["tick"],
                    timestamp=values["timestamp"],
                )
            )

    if not rows:
        raise ValueError(f"{path}: swap file has no data rows")
    return rows


def collapse_swaps(swaps: Sequence[Swap]) -> list[TimelinePoint]:
    """Collapse Swap events to one tick change per block, ordered by time.

    The tick of a block is the one its last Swap leaves behind, and it persists until the
    next Swap. The oracle charges that same tick to the seconds before the next Swap
    block, so both views integrate the same tick over every interval between two Swap
    blocks. They differ only before the first observed Swap, where the oracle still knows
    the pool's initial tick and a Swap log does not; the realized volatility only depends
    on differences of cumulatives, so that offset cancels.

    The rows of a block are read in file order, so the last row of a block is the last
    Swap of that block.
    """

    last_of_block: dict[int, Swap] = {}
    for swap in swaps:
        last_of_block[swap.block] = swap

    ordered = sorted(last_of_block.values(), key=lambda swap: (swap.timestamp, swap.block))
    points: list[TimelinePoint] = []
    for swap in ordered:
        if points and points[-1].timestamp == swap.timestamp:
            points[-1] = TimelinePoint(timestamp=swap.timestamp, tick=swap.tick, block=swap.block)
        else:
            points.append(
                TimelinePoint(timestamp=swap.timestamp, tick=swap.tick, block=swap.block)
            )
    return points


def floor_div(numerator: int, denominator: int) -> int:
    """Integer floor division toward negative infinity, as the contract's ``_floorDiv``.

    Python's ``//`` already rounds toward negative infinity, so it is exactly the Solidity
    ``_floorDiv`` of VolMarket.sol for a positive denominator: ``floor_div(-3200, 300)`` is
    ``-11`` and not the truncating ``-10``.
    """

    if denominator <= 0:
        raise ValueError("denominator must be positive")
    return numerator // denominator


def bucket_of(bounds: Sequence[int], value: int) -> int:
    """Bucket index of ``value`` over ascending bounds: the number of bounds ``<= value``.

    Half-open semantics as ``MarketMath.bucketOf``: bucket ``i`` covers
    ``bounds[i - 1] <= value < bounds[i]``.
    """

    count = 0
    for bound in bounds:
        if value < bound:
            return count
        count += 1
    return count


def coverage_voids(available: int, n_segments: int) -> bool:
    """True when fewer than 90% of the checkpoints are readable, so the window is void.

    The contract compares ``available * 10000 < (nSegments + 1) * 9000``; the factors are
    basis points of coverage, not a scaled probability.
    """

    return available * BPS < (n_segments + 1) * MIN_COVERAGE_BPS


def _clipped_segments(
    points: Sequence[TimelinePoint], window_start: int
) -> list[tuple[int, int | None, int]]:
    """Constant-tick segments at or after ``window_start`` as ``(start, end, tick)``.

    The last segment has no end: the pool tick does not change without a Swap, so it holds
    until the next observed tick change.
    """

    index = -1
    for position, point in enumerate(points):
        if point.timestamp <= window_start:
            index = position
        else:
            break
    if index < 0:
        raise MissingInitialTick(
            f"no Swap at or before window start {window_start}; the initial tick is unknown"
        )

    segments: list[tuple[int, int | None, int]] = []
    for position in range(index, len(points)):
        point = points[position]
        start = max(point.timestamp, window_start)
        end = points[position + 1].timestamp if position + 1 < len(points) else None
        segments.append((start, end, point.tick))
    return segments


def tick_cumulatives(
    points: Sequence[TimelinePoint],
    window_start: int,
    delta: int,
    n_segments: int,
) -> tuple[int, ...]:
    """``tickCumulative`` at the ``nSegments + 1`` checkpoints, relative to the window start.

    Checkpoint ``k`` sits at ``window_start + k * delta``; the cumulative is the integral
    of the tick over ``[window_start, window_start + k * delta]`` in tick*seconds, so
    ``C_0`` is zero by construction.
    """

    if delta <= 0:
        raise ValueError("delta must be positive")
    if n_segments < 2:
        raise ValueError("nSegments must be at least 2")

    segments = _clipped_segments(points, window_start)
    starts = [segment[0] for segment in segments]
    prefix = [0]
    for position in range(1, len(segments)):
        previous_start, _, previous_tick = segments[position - 1]
        prefix.append(prefix[-1] + previous_tick * (starts[position] - previous_start))

    cumulatives: list[int] = []
    for step in range(n_segments + 1):
        moment = window_start + step * delta
        position = bisect.bisect_right(starts, moment) - 1
        if position < 0:
            raise MissingInitialTick(f"no tick covers checkpoint {step}")
        start, _, tick = segments[position]
        cumulatives.append(prefix[position] + tick * (moment - start))
    return tuple(cumulatives)


def cumulative_grid(points: Sequence[TimelinePoint], step: int) -> list[tuple[int, int]]:
    """``(timestamp, tickCumulative)`` at every multiple of ``step`` inside the observed span.

    The cumulative is the integral of the tick from the first observed Swap, so it differs
    from the pool oracle's ``tickCumulative`` by one constant, which cancels in every
    difference the contract takes. A consumer can therefore rebuild the contract's features
    and realized volatility for any round whose checkpoints fall on the grid.
    """

    if step <= 0:
        raise ValueError("step must be positive")
    if not points:
        return []
    first, last = points[0].timestamp, points[-1].timestamp
    grid: list[tuple[int, int]] = []
    cumulative = 0
    position = 0
    moment = -(-first // step) * step
    previous = first
    while moment <= last:
        while position + 1 < len(points) and points[position + 1].timestamp <= moment:
            cumulative += points[position].tick * (points[position + 1].timestamp - previous)
            previous = points[position + 1].timestamp
            position += 1
        grid.append((moment, cumulative + points[position].tick * (moment - previous)))
        moment += step
    return grid


def write_grid(grid: Sequence[tuple[int, int]], path: str | Path) -> Path:
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    lines = ["timestamp,tick_cumulative", *(f"{t},{c}" for t, c in grid)]
    destination.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return destination


def segment_means(
    cumulatives: Sequence[int], available: Sequence[int], delta: int
) -> tuple[int, ...]:
    """Mean tick per second of every consecutive pair of readable checkpoints.

    The mean spans the checkpoints' real distance, so a gap between two readable points
    yields one longer segment. Division floors toward negative infinity.
    """

    means: list[int] = []
    previous_index: int | None = None
    for index in available:
        if previous_index is not None:
            span = (index - previous_index) * delta
            means.append(floor_div(cumulatives[index] - cumulatives[previous_index], span))
        previous_index = index
    return tuple(means)


def realized_vol(
    cumulatives: Sequence[int], available: Sequence[int], delta: int, n_segments: int
) -> tuple[int, int, int]:
    """``(sumSquares, terms, rv)`` over the readable checkpoints, as the contract computes.

    ``sumSquares`` is the sum of the squared differences of adjacent segment means, ``terms``
    their number, and ``rv = floor(sumSquares * (nSegments - 1) / terms)`` in tick^2.
    """

    means = segment_means(cumulatives, available, delta)
    sum_squares = 0
    terms = 0
    for previous, current in zip(means, means[1:], strict=False):
        difference = current - previous
        sum_squares += difference * difference
        terms += 1
    if terms == 0:
        return sum_squares, terms, 0
    return sum_squares, terms, (sum_squares * (n_segments - 1)) // terms


def window_vol(
    points: Sequence[TimelinePoint],
    window_start: int,
    delta: int,
    n_segments: int,
    missing: Sequence[int] = (),
    bounds: Sequence[int] = (),
) -> WindowVol:
    """Settle one window the way the contract settles a round.

    ``missing`` lists the checkpoint indices that could not be read; the coverage rule and
    the ``m == 0`` rule void the window exactly as ``VolMarket.settle`` does.
    """

    cumulatives = tick_cumulatives(points, window_start, delta, n_segments)
    unreadable = set(missing)
    available = tuple(index for index in range(n_segments + 1) if index not in unreadable)

    def voided() -> WindowVol:
        return WindowVol(
            start=window_start,
            cums=cumulatives,
            available=available,
            segment_means=(),
            sum_squares=None,
            terms=None,
            rv=None,
            bucket=None,
            voided=True,
        )

    if coverage_voids(len(available), n_segments):
        return voided()

    sum_squares, terms, rv = realized_vol(cumulatives, available, delta, n_segments)
    if terms == 0:
        return voided()

    return WindowVol(
        start=window_start,
        cums=cumulatives,
        available=available,
        segment_means=segment_means(cumulatives, available, delta),
        sum_squares=sum_squares,
        terms=terms,
        rv=rv,
        bucket=bucket_of(bounds, rv) if bounds else None,
        voided=False,
    )


def window_rvs(
    points: Sequence[TimelinePoint],
    delta: int,
    n_segments: int,
    step: int | None = None,
) -> tuple[list[int], int]:
    """Realized volatility of every consecutive window, in tick^2.

    Windows start at the first observed Swap and step by ``step`` seconds (default:
    ``delta``, so windows overlap). A window counts only when it opens and closes inside
    the observed span, because the tail of the log cannot prove that no Swap happened
    after the last observed one. Voided windows are skipped and counted.
    """

    if not points:
        return [], 0
    if step is None:
        step = delta
    if step <= 0:
        raise ValueError("step must be positive")

    first = points[0].timestamp
    last = points[-1].timestamp
    span = n_segments * delta
    rvs: list[int] = []
    skipped = 0
    start = first
    while start + span <= last:
        outcome = window_vol(points, start, delta, n_segments)
        if outcome.voided or outcome.rv is None:
            skipped += 1
        else:
            rvs.append(outcome.rv)
        start += step
    return rvs, skipped


def quantile_nearest_rank(values: Sequence[int], level: float) -> int:
    """Nearest-rank quantile of an integer sample at fraction ``level`` of the sample.

    ``rank = ceil(level * n)`` computed with exact rational arithmetic (the level is read
    as a fraction, never as a binary float), clamped to ``[1, n]``; the quantile is the
    value at ``rank - 1`` of the sorted sample. The p20 quantile of 50 samples is
    therefore the 10th smallest one.
    """

    if not values:
        raise ValueError("quantile of an empty sample is undefined")
    fraction = Fraction(str(level))
    if not 0 < fraction <= 1:
        raise ValueError("quantile level must be in (0, 1]")
    ordered = sorted(values)
    count = len(ordered)
    rank = -((-fraction.numerator * count) // fraction.denominator)
    rank = min(max(rank, 1), count)
    return ordered[rank - 1]


def strictly_increasing(values: Sequence[int]) -> tuple[int, ...]:
    """Turn quantile values into strictly increasing bounds.

    A tie between two quantiles is resolved by raising the later bound by the minimal
    integer amount that restores strict increase (``bounds[i] = max(q_i, bounds[i-1] + 1)``).
    The first bound is at least 1, so every bound is positive even when the lowest quantile
    is 0.
    """

    bounds: list[int] = []
    previous = 0
    for value in values:
        bound = max(value, previous + 1)
        bounds.append(bound)
        previous = bound
    return tuple(bounds)


def calibrate_bounds(
    rvs: Sequence[int], quantiles: Sequence[float] = DEFAULT_QUANTILES
) -> tuple[int, ...]:
    """Bucket bounds from a sample of realized volatilities.

    The bounds are the requested quantiles of the sample, resolved to strictly increasing
    values; four quantiles therefore always yield exactly four bounds.
    """

    if not rvs:
        raise ValueError("no realized volatility samples to calibrate")
    if not quantiles:
        raise ValueError("at least one quantile level is required")
    raw = tuple(quantile_nearest_rank(rvs, level) for level in quantiles)
    return strictly_increasing(raw)


def bucket_shares(rvs: Sequence[int], bounds: Sequence[int]) -> list[int]:
    """Share of the realized-variance sample per bucket, in whole percent."""

    if not rvs:
        return [0] * (len(bounds) + 1)
    counts = [0] * (len(bounds) + 1)
    for value in rvs:
        counts[bucket_of(bounds, value)] += 1
    return [count * 100 // len(rvs) for count in counts]


def calibrate(
    swaps: Sequence[Swap],
    delta: int = DEFAULT_DELTA,
    n_segments: int = DEFAULT_N_SEGMENTS,
    quantiles: Sequence[float] = DEFAULT_QUANTILES,
    step: int | None = None,
) -> CalibrationResult:
    """Calibrate the bucket bounds from a Swap history.

    The bounds are the ``p20``/``p40``/``p60``/``p80`` quantiles of the realized
    volatility of the consecutive windows, resolved to strictly increasing values.
    """

    if delta <= 0:
        raise ValueError("delta must be positive")
    if n_segments < 2:
        raise ValueError("nSegments must be at least 2")
    if not quantiles:
        raise ValueError("at least one quantile level is required")

    points = collapse_swaps(swaps)
    rvs, skipped = window_rvs(points, delta, n_segments, step)
    if not rvs:
        raise ValueError(
            f"no window of {n_segments * delta} s is covered by the swap history; "
            "fetch a longer history"
        )

    raw = tuple(quantile_nearest_rank(rvs, level) for level in quantiles)
    # The collision rule lives only in calibrate_bounds; this function must not re-derive it.
    return CalibrationResult(
        delta=delta,
        n_segments=n_segments,
        quantiles=tuple(quantiles),
        raw_quantiles=raw,
        bounds=calibrate_bounds(rvs, quantiles),
        rvs=tuple(rvs),
        swap_count=len(swaps),
        skipped_windows=skipped,
    )


def write_params(result: CalibrationResult, path: str | Path = DEFAULT_OUT) -> Path:
    """Write the calibrated parameters as JSON, creating parent directories as needed."""

    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("w", encoding="utf-8") as handle:
        json.dump(result.as_params(), handle, indent=2, sort_keys=True)
        handle.write("\n")
    return destination


def render_report(result: CalibrationResult, history: str | Path | None = None) -> str:
    """Human-readable Markdown summary of the calibration run."""

    shares = bucket_shares(result.rvs, result.bounds)
    lines = [
        "# Realized volatility calibration",
        "",
        f"- Method: {METHOD}",
        f"- History: {history if history is not None else 'unknown'} "
        f"({result.swap_count} swaps)",
        f"- Window: {result.n_segments} segments of {result.delta} s "
        f"({result.n_segments * result.delta} s)",
        f"- Samples (windows): {len(result.rvs)}",
        f"- Skipped windows: {result.skipped_windows}",
        f"- RV range (tick^2): {min(result.rvs)} .. {max(result.rvs)}",
        f"- RV mean (tick^2): {sum(result.rvs) // len(result.rvs)}",
        "",
        "## Quantiles (tick^2, nearest rank)",
        "",
        "| level | value | bound after collision rule |",
        "|---:|---:|---:|",
    ]
    for level, raw, bound in zip(
        result.quantiles, result.raw_quantiles, result.bounds, strict=True
    ):
        lines.append(f"| p{round(level * 100)} | {raw} | {bound} |")

    lines.extend(
        [
            "",
            "## Bounds",
            "",
            f"- `bounds`: `{list(result.bounds)}`",
            "- A tie between two quantiles is resolved by raising the later bound by the "
            "minimal integer amount that restores strict increase.",
            "- The bounds are realized variances in tick^2; `VolMarket.createRound` takes "
            "them as they are.",
            "",
            "## Bucket shares of the sample (percent)",
            "",
            "| bucket | range (tick^2) | share |",
            "|---:|---|---:|",
        ]
    )
    edges = [0, *result.bounds]
    for index, share in enumerate(shares):
        low = edges[index]
        high = edges[index + 1] if index + 1 < len(edges) else None
        span = f"[{low}, {high})" if high is not None else f"[{low}, +inf)"
        lines.append(f"| {index} | {span} | {share} |")
    lines.extend(
        [
            "",
            "## Known deviation / approximation",
            "",
            "The block-granularity equivalence between this Swap-log reconstruction and the "
            "pool oracle holds only for a complete Swap log stream. `eth_getLogs` gateways "
            "can silently truncate a response by log count (11,769 logs measured in one "
            "10,000-block segment of pool 0x88e6...5640); a truncated segment breaks the "
            "equivalence for every window it touches. A live comparison of 8 windows "
            "against the pool oracle matched 6 and mismatched 2 (RV 117 vs oracle 54; "
            "1132 vs 1114); the attribution is unresolved, with log completeness the "
            "prime suspect. The calibrated bounds are an approximation of the settlement "
            "distribution, not a guarantee.",
            "",
        ]
    )
    return "\n".join(lines)


def write_report(
    result: CalibrationResult, path: str | Path, history: str | Path | None = None
) -> Path:
    """Write the Markdown summary, creating parent directories as needed."""

    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(render_report(result, history=history), encoding="utf-8")
    return destination


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point: a Swap CSV in, ``vol_params.json`` and a report out."""

    parser = argparse.ArgumentParser(
        description="Calibrate the realized-volatility bucket bounds from Swap events."
    )
    parser.add_argument(
        "--swaps",
        required=True,
        help="CSV with columns block,tick,timestamp",
    )
    parser.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help=f"output params JSON path (default: {DEFAULT_OUT})",
    )
    parser.add_argument(
        "--delta",
        type=int,
        default=DEFAULT_DELTA,
        help=f"segment length in seconds (default: {DEFAULT_DELTA})",
    )
    parser.add_argument(
        "--n-segments",
        type=int,
        default=DEFAULT_N_SEGMENTS,
        help=f"segments per window (default: {DEFAULT_N_SEGMENTS})",
    )
    parser.add_argument(
        "--quantiles",
        default=",".join(str(level) for level in DEFAULT_QUANTILES),
        help="comma-separated quantile levels as fractions of the sample",
    )
    parser.add_argument(
        "--step",
        type=int,
        default=None,
        help="window step in seconds (default: the segment length)",
    )
    parser.add_argument(
        "--export-grid",
        default=None,
        help="also write timestamp,tick_cumulative at every --grid-step seconds to this CSV",
    )
    parser.add_argument(
        "--grid-step",
        type=int,
        default=60,
        help="grid spacing in seconds for --export-grid (default: 60)",
    )
    args = parser.parse_args(argv)

    try:
        levels = tuple(float(part.strip()) for part in args.quantiles.split(",") if part.strip())
        swaps = load_swaps(args.swaps)
        result = calibrate(
            swaps,
            delta=args.delta,
            n_segments=args.n_segments,
            quantiles=levels,
            step=args.step,
        )
    except ValueError as exc:
        print(f"calibration failed: {exc}", file=sys.stderr)
        return 1

    params_path = write_params(result, args.out)
    report_path = write_report(
        result, params_path.with_name(REPORT_NAME), history=args.swaps
    )
    print(
        f"windows={len(result.rvs)} bounds={list(result.bounds)} "
        f"quantiles={list(result.raw_quantiles)}"
    )
    print(f"wrote {params_path} and {report_path}")
    if args.export_grid:
        try:
            grid = cumulative_grid(collapse_swaps(swaps), args.grid_step)
        except ValueError as exc:
            print(f"grid export failed: {exc}", file=sys.stderr)
            return 1
        print(f"wrote {write_grid(grid, args.export_grid)} ({len(grid)} rows)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
