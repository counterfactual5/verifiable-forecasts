"""Offline calibration of the sampling window length and bucket bounds.

Reads a CSV of per-block base fees (columns ``block,base_fee_wei,ts``), computes the
distribution of the mean base fee over contiguous ``K``-block windows for a set of
candidate window lengths, and writes the parameters consumed by the contract.

Every number that reaches the contract is a Python ``int`` in wei; no float is used
anywhere in this module. The deterministic rules are:

* A window mean is ``sum(base_fee_wei) // K`` (floor division, exact integer math).
* Quantiles use nearest rank: ``rank = ceil(p * n / 100)`` computed with integers,
  clamped to ``[1, n]``, and the quantile is the value at ``rank - 1`` in the sorted
  sample. ``p50`` is therefore the lower median for an even number of samples
  (``rank = n // 2``).
* The recommended ``K`` minimizes ``(p90 - p10) / p50``. Ratios are compared by cross
  multiplication (``spread_a * median_b < spread_b * median_a``), never by division,
  so no rounding can flip the result. A candidate with ``p50 == 0`` has no defined ratio
  and is skipped; a candidate with no complete contiguous window is skipped as well.
  Ties keep the smallest ``K``.
* Bucket bounds are the selected candidate's ``p25``, ``p50`` and ``p75`` in ascending
  order with duplicates and non-positive values removed, which keeps the array strictly
  increasing even when quantiles tie. Fewer than two distinct positive values is an
  error: a one-bound array cannot define a market.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Final

DEFAULT_CANDIDATES: Final[tuple[int, ...]] = (10, 25, 50, 100, 200)
QUANTILE_PERCENTILES: Final[tuple[int, ...]] = (10, 25, 50, 75, 90)
BOUND_PERCENTILES: Final[tuple[int, ...]] = (25, 50, 75)
MIN_BOUNDS: Final[int] = 2
DEFAULT_OUT: Final[Path] = Path("data/params.json")
REPORT_NAME: Final[str] = "calibration.md"
METHOD: Final[str] = (
    "contiguous K-block mean, integer floor division; nearest-rank integer quantiles; "
    "K minimizes (p90-p10)/p50 by cross multiplication; bounds are distinct positive "
    "p25/p50/p75"
)
CSV_COLUMNS: Final[tuple[str, ...]] = ("block", "base_fee_wei", "ts")


@dataclass(frozen=True)
class FeeRow:
    """One block's base fee in wei, with the block number used for contiguity checks."""

    block: int
    base_fee_wei: int
    ts: int


@dataclass(frozen=True)
class CandidateStats:
    """Window-mean distribution for one candidate window length ``k``."""

    k: int
    samples: int
    quantiles: dict[str, int]

    @property
    def median(self) -> int:
        return self.quantiles["50"]

    @property
    def spread(self) -> int:
        return self.quantiles["90"] - self.quantiles["10"]


@dataclass(frozen=True)
class CalibrationResult:
    """Selected parameters plus the evidence used to choose them."""

    window_k: int
    bounds_wei: tuple[int, ...]
    quantiles: dict[str, int]
    samples: int
    candidates: tuple[CandidateStats, ...]
    skipped: dict[int, str]

    def as_params(self) -> dict[str, object]:
        return {
            "window_k": self.window_k,
            "bounds_wei": list(self.bounds_wei),
            "quantiles": dict(self.quantiles),
            "samples": self.samples,
            "method": METHOD,
        }


def _parse_int(text: str | None, field: str, line_number: int) -> int:
    if text is None:
        raise ValueError(f"line {line_number}: missing column {field!r}")
    try:
        return int(text.strip())
    except ValueError as exc:
        raise ValueError(f"line {line_number}: column {field!r} is not an integer") from exc


def load_history(path: str | Path) -> list[FeeRow]:
    """Load ``block,base_fee_wei,ts`` rows, sorted by block number.

    Duplicate block numbers are rejected because they would make the window means
    ambiguous. Sorted order lets :func:`rolling_means` detect gaps by comparing
    adjacent block numbers.
    """

    rows: list[FeeRow] = []
    try:
        handle = open(path, encoding="utf-8", newline="")
    except OSError as exc:
        raise ValueError(f"cannot read history file {path}: {exc}") from exc

    with handle:
        header = handle.readline()
        if not header:
            raise ValueError(f"{path}: empty history file")
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
            block = _parse_int(
                fields[positions["block"]] if positions["block"] < len(fields) else None,
                "block",
                line_number,
            )
            fee = _parse_int(
                fields[positions["base_fee_wei"]]
                if positions["base_fee_wei"] < len(fields)
                else None,
                "base_fee_wei",
                line_number,
            )
            ts = _parse_int(
                fields[positions["ts"]] if positions["ts"] < len(fields) else None,
                "ts",
                line_number,
            )
            if block <= 0:
                raise ValueError(f"line {line_number}: block must be positive")
            if fee < 0:
                raise ValueError(f"line {line_number}: base_fee_wei must be non-negative")
            rows.append(FeeRow(block=block, base_fee_wei=fee, ts=ts))

    if not rows:
        raise ValueError(f"{path}: history file has no data rows")

    rows.sort(key=lambda row: row.block)
    for previous, current in zip(rows, rows[1:], strict=False):
        if previous.block == current.block:
            raise ValueError(f"{path}: duplicate block {current.block}")
    return rows


def rolling_means(rows: Sequence[FeeRow], k: int) -> list[int]:
    """Mean base fee of each contiguous ``k``-block window, floor-divided.

    Windows never span a gap in block numbers, so an incomplete history yields fewer
    windows instead of silently averaging over missing blocks. A run shorter than ``k``
    contributes nothing, which is how a candidate with insufficient rows is detected.
    """

    if k <= 0:
        raise ValueError("k must be positive")
    if not rows:
        return []

    ordered = sorted(rows, key=lambda row: row.block)
    means: list[int] = []
    run_start = 0
    for index in range(1, len(ordered) + 1):
        if index < len(ordered) and ordered[index].block == ordered[index - 1].block + 1:
            continue
        run = ordered[run_start:index]
        prefix = [0]
        for row in run:
            prefix.append(prefix[-1] + row.base_fee_wei)
        for offset in range(len(run) - k + 1):
            window_sum = prefix[offset + k] - prefix[offset]
            means.append(window_sum // k)
        run_start = index
    return means


def quantile_nearest_rank(values: Sequence[int], percentile: int) -> int:
    """Nearest-rank quantile for integer ``percentile`` in ``(0, 100]``.

    ``rank = ceil(percentile * n / 100)`` using integer arithmetic only. For example
    ``p50`` of ``[1, 2, 3, 4]`` is ``2`` (the lower median), not ``2.5``.
    """

    if not values:
        raise ValueError("quantile of an empty sample is undefined")
    if not 0 < percentile <= 100:
        raise ValueError("percentile must be in (0, 100]")
    ordered = sorted(values)
    count = len(ordered)
    rank = (percentile * count + 99) // 100
    rank = min(max(rank, 1), count)
    return ordered[rank - 1]


def candidate_stats(means: Sequence[int], k: int) -> CandidateStats:
    """Summarize the window-mean distribution for one candidate ``k``."""

    if not means:
        raise ValueError(f"no complete {k}-block windows in the history")
    quantiles = {
        str(percentile): quantile_nearest_rank(means, percentile)
        for percentile in QUANTILE_PERCENTILES
    }
    return CandidateStats(k=k, samples=len(means), quantiles=quantiles)


def spread_ratio_less(spread_a: int, median_a: int, spread_b: int, median_b: int) -> bool:
    """True when ``spread_a / median_a < spread_b / median_b``, exactly.

    Cross multiplication avoids both float rounding and a division that could lose
    monotonicity for large wei values. Both medians must be positive.
    """

    if median_a <= 0 or median_b <= 0:
        raise ValueError("ratio comparison requires positive medians")
    return spread_a * median_b < spread_b * median_a


def select_candidate(stats: Iterable[CandidateStats]) -> CandidateStats:
    """Pick the narrowest relative spread, keeping the smallest ``k`` on a tie.

    Candidates with no samples or with ``p50 == 0`` are ineligible because their ratio
    is undefined. At least one eligible candidate is required.
    """

    eligible = [item for item in stats if item.samples > 0 and item.median > 0]
    if not eligible:
        raise ValueError(
            "no candidate window length produced a usable distribution "
            "(need at least one complete window and a positive p50)"
        )

    best = min(eligible, key=lambda item: item.k)
    for item in sorted(eligible, key=lambda entry: entry.k)[1:]:
        if spread_ratio_less(item.spread, item.median, best.spread, best.median):
            best = item
    return best


def bucket_bounds(quantiles: dict[str, int]) -> tuple[int, ...]:
    """Strictly increasing positive bounds from ``p25``, ``p50``, ``p75``.

    Tied quantiles collapse to one bound (for example ``p25 == p50`` yields two
    bounds) and non-positive quantiles are dropped because a bound must be positive.
    Fewer than two distinct positive values cannot express a market.
    """

    missing = [
        str(percentile) for percentile in BOUND_PERCENTILES if str(percentile) not in quantiles
    ]
    if missing:
        raise ValueError(f"missing quantile keys: {', '.join(missing)}")
    values = {
        quantiles[str(percentile)]
        for percentile in BOUND_PERCENTILES
        if quantiles[str(percentile)] > 0
    }
    positive = sorted(values)
    if len(positive) < MIN_BOUNDS:
        raise ValueError(
            "fewer than two distinct positive quantiles among p25/p50/p75; "
            "cannot build strictly increasing bounds"
        )
    return tuple(positive)


def parse_candidates(text: str) -> tuple[int, ...]:
    """Parse ``"10,25,50"`` into a sorted tuple of unique positive window lengths."""

    parts = [part.strip() for part in text.split(",")]
    if not parts or any(not part for part in parts):
        raise ValueError(f"invalid --candidates value {text!r}")
    try:
        values = [int(part) for part in parts]
    except ValueError as exc:
        raise ValueError(f"invalid --candidates value {text!r}") from exc
    if any(value <= 0 for value in values):
        raise ValueError("candidate window lengths must be positive")
    if len(set(values)) != len(values):
        raise ValueError("candidate window lengths must be unique")
    return tuple(sorted(values))


def calibrate(
    rows: Sequence[FeeRow], candidates: Sequence[int] = DEFAULT_CANDIDATES
) -> CalibrationResult:
    """Compute per-candidate statistics, select ``K``, and derive bucket bounds."""

    ordered_candidates = sorted(set(candidates))
    if not ordered_candidates or any(value <= 0 for value in ordered_candidates):
        raise ValueError("candidates must be a non-empty list of positive window lengths")

    stats: list[CandidateStats] = []
    skipped: dict[int, str] = {}
    for k in ordered_candidates:
        means = rolling_means(rows, k)
        if not means:
            skipped[k] = "fewer than k contiguous blocks"
            continue
        item = candidate_stats(means, k)
        if item.median <= 0:
            skipped[k] = "p50 is zero, relative spread is undefined"
            continue
        stats.append(item)

    selected = select_candidate(stats)
    return CalibrationResult(
        window_k=selected.k,
        bounds_wei=bucket_bounds(selected.quantiles),
        quantiles=dict(selected.quantiles),
        samples=selected.samples,
        candidates=tuple(stats),
        skipped=skipped,
    )


def write_params(result: CalibrationResult, path: str | Path = DEFAULT_OUT) -> Path:
    """Write ``params.json``, creating parent directories as needed."""

    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    payload = result.as_params()
    with destination.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return destination


def render_report(
    result: CalibrationResult,
    history: str | Path | None = None,
    row_count: int | None = None,
) -> str:
    """Human-readable Markdown summary of the calibration run."""

    lines = [
        "# Base fee calibration",
        "",
        f"- Method: {METHOD}",
        f"- Recommended window: K = {result.window_k} blocks",
        f"- Samples (window means): {result.samples}",
        f"- Bounds (wei): {', '.join(str(value) for value in result.bounds_wei)}",
        "",
    ]
    if history is not None or row_count is not None:
        source = str(history) if history is not None else "unknown"
        lines.append(f"- History: {source} ({row_count if row_count is not None else '?'} rows)")
        lines.append("")

    lines.extend(
        [
            "## Quantiles (wei, nearest rank)",
            "",
            "| K | samples | p10 | p25 | p50 | p75 | p90 | spread (bps of p50) |",
            "|---:|---:|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for item in result.candidates:
        bps = item.spread * 10_000 // item.median
        quantiles = item.quantiles
        lines.append(
            f"| {item.k} | {item.samples} | {quantiles['10']} | {quantiles['25']} | "
            f"{quantiles['50']} | {quantiles['75']} | {quantiles['90']} | {bps} |"
        )
    lines.append("")

    if result.skipped:
        lines.append("## Skipped candidates")
        lines.append("")
        for k in sorted(result.skipped):
            lines.append(f"- K = {k}: {result.skipped[k]}")
        lines.append("")

    lines.extend(
        [
            "## Selected parameters",
            "",
            f"- `window_k`: {result.window_k}",
            f"- `bounds_wei`: `{list(result.bounds_wei)}`",
            "- Buckets follow half-open intervals: "
            f"(-inf, {result.bounds_wei[0]}), "
            + ", ".join(
                f"[{low}, {high})"
                for low, high in zip(result.bounds_wei, result.bounds_wei[1:], strict=False)
            )
            + f", [{result.bounds_wei[-1]}, +inf).",
            "",
        ]
    )
    return "\n".join(lines)


def write_report(
    result: CalibrationResult,
    path: str | Path,
    history: str | Path | None = None,
    row_count: int | None = None,
) -> Path:
    """Write the Markdown summary, creating parent directories as needed."""

    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        render_report(result, history=history, row_count=row_count), encoding="utf-8"
    )
    return destination


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point: history CSV in, ``params.json`` and summary out."""

    parser = argparse.ArgumentParser(
        description="Calibrate the base fee sampling window and bucket bounds offline."
    )
    parser.add_argument(
        "--history",
        required=True,
        help="CSV with columns block,base_fee_wei,ts",
    )
    parser.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help=f"output params JSON path (default: {DEFAULT_OUT})",
    )
    parser.add_argument(
        "--candidates",
        default=",".join(str(value) for value in DEFAULT_CANDIDATES),
        help="comma-separated candidate window lengths",
    )
    args = parser.parse_args(argv)

    try:
        rows = load_history(args.history)
        candidates = parse_candidates(args.candidates)
        result = calibrate(rows, candidates)
    except ValueError as exc:
        print(f"calibration failed: {exc}", file=sys.stderr)
        return 1

    params_path = write_params(result, args.out)
    report_path = write_report(
        result,
        params_path.with_name(REPORT_NAME),
        history=args.history,
        row_count=len(rows),
    )
    print(
        f"window_k={result.window_k} samples={result.samples} bounds_wei={list(result.bounds_wei)}"
    )
    print(f"wrote {params_path} and {report_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
