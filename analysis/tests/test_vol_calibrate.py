"""Offline, deterministic tests for the realized-volatility calibration module."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from vol_calibrate import (
    DEFAULT_QUANTILES,
    METHOD,
    Swap,
    bucket_of,
    calibrate,
    calibrate_bounds,
    collapse_swaps,
    coverage_voids,
    cumulative_grid,
    floor_div,
    load_swaps,
    main,
    quantile_nearest_rank,
    realized_vol,
    strictly_increasing,
    tick_cumulatives,
    window_rvs,
    window_vol,
)

FIXTURE_PATH = (
    Path(__file__).resolve().parents[2] / "contracts" / "test" / "fixtures" / "vol_rv_cases.json"
)
START_TIME = 1_700_000_000


def write_csv(tmp_path: Path, rows: list[tuple[int, int, int]], name: str = "swaps.csv") -> Path:
    path = tmp_path / name
    lines = ["block,tick,timestamp"]
    lines.extend(f"{block},{tick},{timestamp}" for block, tick, timestamp in rows)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def nearest_rank_percent(values: list[int], percentile: int) -> int:
    """Independent nearest-rank quantile, computed in whole percent."""

    ordered = sorted(values)
    rank = (percentile * len(ordered) + 99) // 100
    rank = min(max(rank, 1), len(ordered))
    return ordered[rank - 1]


# --- Shared fixture parity ---------------------------------------------------------


def test_rv_cases_fixture_parity() -> None:
    fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    delta = fixture["delta"]
    n_segments = fixture["nSegments"]
    bounds = fixture["bounds"]

    assert len(fixture["cases"]) == 8
    for case in fixture["cases"]:
        offsets = case["timeline"]["offsets"]
        ticks = case["timeline"]["ticks"]
        swaps = [
            Swap(block=index + 1, tick=tick, timestamp=START_TIME + offset)
            for index, (offset, tick) in enumerate(zip(offsets, ticks, strict=True))
        ]
        points = collapse_swaps(swaps)
        outcome = window_vol(
            points,
            START_TIME,
            delta,
            n_segments,
            missing=case["missing"],
            bounds=bounds,
        )

        for index, expected in enumerate(case["tickCumulatives"]):
            if expected is not None:
                assert outcome.cums[index] == expected, f"{case['name']} checkpoint {index}"

        assert outcome.voided is case["voided"], case["name"]
        if case["voided"]:
            assert outcome.segment_means == ()
            assert outcome.sum_squares is None
            assert outcome.terms is None
            assert outcome.rv is None
            assert outcome.bucket is None
            continue

        assert list(outcome.segment_means) == case["segmentMeans"], case["name"]
        assert outcome.sum_squares == case["sumSquares"], case["name"]
        assert outcome.terms == case["terms"], case["name"]
        assert outcome.rv == case["rv"], case["name"]
        assert outcome.bucket == case["bucket"], case["name"]
        if "rvIfTruncated" in case:
            # The floor caliber, not the truncating one the fixture rules out.
            assert outcome.rv != case["rvIfTruncated"], case["name"]


# --- Swap -> tickCumulative reconstruction ------------------------------------------


def test_reconstructs_tick_cumulative_from_swap_csv(tmp_path: Path) -> None:
    path = write_csv(
        tmp_path,
        [
            (100, 100, 1000),
            (101, 500, 1100),
            (101, 200, 1150),
            (103, 900, 1300),
        ],
    )
    swaps = load_swaps(path)
    points = collapse_swaps(swaps)

    # The second Swap of block 101 wins, and block 102 (no Swap) keeps that tick.
    assert [(point.timestamp, point.tick) for point in points] == [
        (1000, 100),
        (1150, 200),
        (1300, 900),
    ]

    cumulatives = tick_cumulatives(points, 1000, 300, 3)
    # 100 * 150 s + 200 * 150 s up to 1300, then the 900 tick takes over.
    assert cumulatives == (0, 45_000, 315_000, 585_000)


def test_load_swaps_rejects_descending_blocks(tmp_path: Path) -> None:
    path = write_csv(tmp_path, [(100, 100, 1000), (99, 200, 1100)])
    with pytest.raises(ValueError, match="ascending in block"):
        load_swaps(path)


def test_load_swaps_accepts_repeated_blocks_in_file_order(tmp_path: Path) -> None:
    path = write_csv(
        tmp_path,
        [
            (100, 100, 1000),
            (100, 300, 1050),
            (101, 200, 1100),
        ],
    )
    swaps = load_swaps(path)
    assert [swap.block for swap in swaps] == [100, 100, 101]
    # The last in-file row of a repeated block is the tick that survives the collapse.
    assert collapse_swaps(swaps)[0].tick == 300


def test_window_start_before_first_swap_uses_previous_tick(tmp_path: Path) -> None:
    path = write_csv(
        tmp_path,
        [
            (100, 100, 1000),
            (102, 900, 1300),
        ],
    )
    points = collapse_swaps(load_swaps(path))

    # The window opens after the first Swap: that Swap's tick is the initial value.
    cumulatives = tick_cumulatives(points, 1100, 300, 2)
    assert cumulatives == (0, 100 * 200 + 900 * 100, 100 * 200 + 900 * 400)


def test_reconstruction_differs_from_the_oracle_only_by_an_offset(tmp_path: Path) -> None:
    path = write_csv(
        tmp_path,
        [(100 + index, 100 + (index % 4) * 30, START_TIME + 300 * index) for index in range(8)],
    )
    points = collapse_swaps(load_swaps(path))

    cumulatives = tick_cumulatives(points, START_TIME, 300, 3)
    # The oracle counts from the pool's first observation, so its cumulative carries a
    # constant offset; the differences the contract uses are unaffected.
    offset = 34_211_767_011_299
    shifted = tuple(value + offset for value in cumulatives)

    assert realized_vol(shifted, (0, 1, 2, 3), 300, 3) == realized_vol(
        cumulatives, (0, 1, 2, 3), 300, 3
    )


def test_window_start_before_any_swap_is_rejected(tmp_path: Path) -> None:
    path = write_csv(tmp_path, [(100, 100, 1000)])
    points = collapse_swaps(load_swaps(path))
    with pytest.raises(ValueError, match="initial tick"):
        tick_cumulatives(points, 500, 300, 2)


# --- Integer caliber ----------------------------------------------------------------


def test_floor_div_matches_solidity_toward_minus_inf() -> None:
    assert floor_div(-3200, 300) == -11
    assert floor_div(-1500, 300) == -5
    assert floor_div(-1, 300) == -1
    assert floor_div(3200, 300) == 10
    assert floor_div(1500, 300) == 5
    assert floor_div(0, 300) == 0


def test_coverage_void_rule() -> None:
    # 12 of 13 checkpoints readable: 120000 >= 13 * 9000, so the window settles.
    assert coverage_voids(12, 12) is False
    # 11 of 13 readable: 110000 < 117000, so the window is void.
    assert coverage_voids(11, 12) is True
    assert coverage_voids(13, 12) is False
    assert coverage_voids(0, 12) is True


def test_window_is_void_when_checkpoints_are_missing(tmp_path: Path) -> None:
    path = write_csv(
        tmp_path,
        [(100 + index, 100 + index, START_TIME + 300 * index) for index in range(13)],
    )
    points = collapse_swaps(load_swaps(path))

    settled = window_vol(points, START_TIME, 300, 12)
    assert settled.voided is False
    assert settled.terms == 11

    voided = window_vol(points, START_TIME, 300, 12, missing=[0, 3])
    assert voided.voided is True
    assert voided.rv is None
    assert voided.bucket is None


def test_bucket_of_uses_half_open_intervals() -> None:
    bounds = [8, 20, 45, 110]
    assert bucket_of(bounds, 0) == 0
    assert bucket_of(bounds, 7) == 0
    assert bucket_of(bounds, 8) == 1
    assert bucket_of(bounds, 20) == 2
    assert bucket_of(bounds, 110) == 4
    assert bucket_of(bounds, 5000) == 4


# --- Calibration --------------------------------------------------------------------


def test_calibrated_bounds_are_four_strictly_increasing() -> None:
    values = [value for value in range(50) for _ in range(2)]
    assert len(values) == 100
    bounds = calibrate_bounds(values, DEFAULT_QUANTILES)

    assert len(bounds) == 4
    assert all(isinstance(bound, int) for bound in bounds)
    assert all(bound > 0 for bound in bounds)
    assert list(bounds) == sorted(bounds)
    assert len(set(bounds)) == 4
    assert all(later > earlier for earlier, later in zip(bounds, bounds[1:], strict=False))


def test_calibrated_bounds_follow_the_documented_quantile_rule() -> None:
    values = [(index * 7) % 101 for index in range(50)]
    bounds = calibrate_bounds(values, DEFAULT_QUANTILES)

    expected = [
        nearest_rank_percent(values, 20),
        nearest_rank_percent(values, 40),
        nearest_rank_percent(values, 60),
        nearest_rank_percent(values, 80),
    ]
    assert list(bounds) == list(strictly_increasing(expected))


def test_calibrate_recomputes_the_quantiles_of_its_own_rv_series(tmp_path: Path) -> None:
    path = write_csv(
        tmp_path,
        [
            (100 + index, 100 + (index % 9) * 25, START_TIME + 300 * index)
            for index in range(40)
        ],
    )
    result = calibrate(load_swaps(path))

    assert len(result.rvs) > 4
    expected = [
        nearest_rank_percent(list(result.rvs), 20),
        nearest_rank_percent(list(result.rvs), 40),
        nearest_rank_percent(list(result.rvs), 60),
        nearest_rank_percent(list(result.rvs), 80),
    ]
    assert list(result.raw_quantiles) == expected
    assert list(result.bounds) == list(strictly_increasing(expected))


def test_calibrate_bounds_come_from_calibrate_bounds(tmp_path: Path) -> None:
    path = write_csv(
        tmp_path,
        [
            (100 + index, 100 + (index % 9) * 25, START_TIME + 300 * index)
            for index in range(40)
        ],
    )
    result = calibrate(load_swaps(path))
    # The quantile-plus-collision rule has a single implementation.
    assert list(result.bounds) == list(calibrate_bounds(result.rvs, result.quantiles))


def test_calibrated_bounds_stay_strictly_increasing_on_a_constant_sample() -> None:
    bounds = calibrate_bounds([7] * 50, DEFAULT_QUANTILES)

    assert len(bounds) == 4
    assert all(bound > 0 for bound in bounds)
    assert all(later > earlier for earlier, later in zip(bounds, bounds[1:], strict=False))


def test_calibrated_bounds_change_with_input_data() -> None:
    small = calibrate_bounds([index for index in range(1, 51)], DEFAULT_QUANTILES)
    large = calibrate_bounds([index * 100 for index in range(1, 51)], DEFAULT_QUANTILES)

    assert small != large
    assert all(later > earlier for earlier, later in zip(large, large[1:], strict=False))
    assert all(bound > 0 for bound in large)


def test_quantile_nearest_rank_is_deterministic_and_clamped() -> None:
    values = [5, 1, 9, 3]
    assert quantile_nearest_rank(values, 0.20) == 1
    assert quantile_nearest_rank(values, 0.25) == 1
    assert quantile_nearest_rank(values, 1.0) == 9
    with pytest.raises(ValueError, match="empty sample"):
        quantile_nearest_rank([], 0.5)
    with pytest.raises(ValueError, match="level"):
        quantile_nearest_rank(values, 1.5)


# --- Window series and CLI ------------------------------------------------------------


def test_window_rvs_covers_every_complete_window(tmp_path: Path) -> None:
    rows = [
        (100 + index, 100 + (index % 7) * 10, START_TIME + 300 * index)
        for index in range(25)
    ]
    path = write_csv(tmp_path, rows)
    points = collapse_swaps(load_swaps(path))

    rvs, skipped = window_rvs(points, 300, 12)
    assert skipped == 0
    # 25 checkpoints span 7200 s, so 13 windows of 3600 s fit with a 300 s step.
    assert len(rvs) == 13
    assert all(rv >= 0 for rv in rvs)


def test_cli_writes_params_and_report(tmp_path: Path) -> None:
    rows = [
        (100 + index, 100 + (index % 5) * 20, START_TIME + 300 * index)
        for index in range(25)
    ]
    path = write_csv(tmp_path, rows)
    out = tmp_path / "vol_params.json"

    assert main(["--swaps", str(path), "--out", str(out)]) == 0

    payload = json.loads(out.read_text(encoding="utf-8"))
    expected = calibrate(load_swaps(path))
    assert payload["bounds"] == list(expected.bounds)
    assert payload["delta"] == expected.delta
    assert payload["nSegments"] == expected.n_segments
    assert payload["method"] == METHOD
    assert payload["windows"] == len(expected.rvs)
    assert len(payload["bounds"]) == 4
    assert payload["bounds"] == sorted(payload["bounds"])
    assert len(set(payload["bounds"])) == 4

    report = out.with_name("calibration_report.md")
    assert report.exists()
    text = report.read_text(encoding="utf-8")
    assert "Realized volatility calibration" in text
    assert str(payload["bounds"]) in text


def irregular_rows() -> list[tuple[int, int, int]]:
    rows, t, tick = [], START_TIME + 17, 200_000
    for index in range(400):
        t += 13 + (index * 37) % 211
        tick += (index * 7919) % 41 - 20
        rows.append((1000 + index, tick, t))
    return rows


def test_cumulative_grid_reproduces_window_cumulatives(tmp_path: Path) -> None:
    points = collapse_swaps(load_swaps(write_csv(tmp_path, irregular_rows())))
    grid = cumulative_grid(points, 60)
    times = [t for t, _ in grid]
    assert all(t % 60 == 0 for t in times)
    assert times == list(range(times[0], times[-1] + 60, 60))
    assert points[0].timestamp <= times[0] and times[-1] <= points[-1].timestamp
    at = dict(grid)
    checked = 0
    for start in times[::7]:
        if start + 12 * 300 > times[-1]:
            break
        want = tick_cumulatives(points, start, 300, 12)
        got = tuple(at[start + k * 300] - at[start] for k in range(13))
        assert got == want
        checked += 1
    assert checked >= 5


def test_cli_exports_the_cumulative_grid(tmp_path: Path) -> None:
    path = write_csv(tmp_path, irregular_rows())
    grid_path = tmp_path / "grid.csv"
    out = tmp_path / "vol_params.json"
    assert main(["--swaps", str(path), "--out", str(out), "--export-grid", str(grid_path),
                 "--grid-step", "60"]) == 0
    lines = grid_path.read_text(encoding="utf-8").splitlines()
    assert lines[0] == "timestamp,tick_cumulative"
    rows = [tuple(int(v) for v in line.split(",")) for line in lines[1:]]
    assert rows == cumulative_grid(collapse_swaps(load_swaps(path)), 60)


def test_cli_until_calibrates_on_the_earlier_swaps_only(tmp_path: Path) -> None:
    rows = irregular_rows()
    path = write_csv(tmp_path, rows)
    until = rows[300][2]
    out = tmp_path / "vol_params.json"
    grid_path = tmp_path / "grid.csv"
    assert main(["--swaps", str(path), "--out", str(out), "--until", str(until),
                 "--export-grid", str(grid_path)]) == 0
    payload = json.loads(out.read_text(encoding="utf-8"))
    earlier = [swap for swap in load_swaps(path) if swap.timestamp < until]
    expected = calibrate(earlier)
    assert payload["bounds"] == list(expected.bounds)
    assert payload["windows"] == len(expected.rvs)
    assert payload["windows"] < len(calibrate(load_swaps(path)).rvs)
    assert payload["swapCount"] == 300
    assert payload["until"] == until
    lines = grid_path.read_text(encoding="utf-8").splitlines()[1:]
    assert len(lines) == len(cumulative_grid(collapse_swaps(load_swaps(path)), 60))


def test_cli_reports_a_history_that_covers_no_window(tmp_path: Path, capsys) -> None:
    path = write_csv(tmp_path, [(100, 100, START_TIME)])
    assert main(["--swaps", str(path), "--out", str(tmp_path / "vol_params.json")]) == 1
    assert "calibration failed" in capsys.readouterr().err
