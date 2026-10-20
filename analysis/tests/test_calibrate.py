"""Offline, deterministic tests for the calibration module."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from calibrate import (
    DEFAULT_CANDIDATES,
    METHOD,
    FeeRow,
    bucket_bounds,
    calibrate,
    candidate_stats,
    load_history,
    main,
    parse_candidates,
    quantile_nearest_rank,
    rolling_means,
    select_candidate,
    spread_ratio_less,
    write_params,
    write_report,
)

SRC_DIR = Path(__file__).resolve().parents[1] / "src"


def write_csv(tmp_path: Path, rows: list[tuple[int, int, int]], name: str = "history.csv") -> Path:
    path = tmp_path / name
    lines = ["block,base_fee_wei,ts"]
    lines.extend(f"{block},{fee},{ts}" for block, fee, ts in rows)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def fee_rows(count: int, fee: int = 1_000_000_000, start: int = 1) -> list[FeeRow]:
    return [FeeRow(block=start + i, base_fee_wei=fee, ts=1_700_000_000 + i) for i in range(count)]


# --- CSV loading -----------------------------------------------------------------


def test_load_history_parses_rows_sorted_by_block(tmp_path: Path) -> None:
    path = write_csv(
        tmp_path,
        [
            (3, 30, 1003),
            (1, 10, 1001),
            (2, 20, 1002),
        ],
    )
    rows = load_history(path)
    assert [(row.block, row.base_fee_wei, row.ts) for row in rows] == [
        (1, 10, 1001),
        (2, 20, 1002),
        (3, 30, 1003),
    ]


def test_load_history_rejects_missing_column(tmp_path: Path) -> None:
    path = tmp_path / "bad.csv"
    path.write_text("block,ts\n1,100\n", encoding="utf-8")
    with pytest.raises(ValueError, match="base_fee_wei"):
        load_history(path)


def test_load_history_rejects_non_integer_fee(tmp_path: Path) -> None:
    path = write_csv(tmp_path, [(1, 10, 100)])
    path.write_text("block,base_fee_wei,ts\n1,abc,100\n", encoding="utf-8")
    with pytest.raises(ValueError, match="not an integer"):
        load_history(path)


def test_load_history_rejects_duplicate_blocks(tmp_path: Path) -> None:
    path = write_csv(tmp_path, [(1, 10, 100), (1, 20, 101)])
    with pytest.raises(ValueError, match="duplicate block"):
        load_history(path)


# --- Rolling means ----------------------------------------------------------------


def test_rolling_means_use_floor_division() -> None:
    rows = [FeeRow(block=1, base_fee_wei=10, ts=0), FeeRow(block=2, base_fee_wei=11, ts=0)]
    assert rolling_means(rows, 2) == [10]  # 21 // 2 == 10, never 10.5


def test_rolling_means_cover_every_contiguous_window() -> None:
    rows = fee_rows(4, fee=100)
    assert rolling_means(rows, 2) == [100, 100, 100]
    assert rolling_means(rows, 1) == [100, 100, 100, 100]


def test_rolling_means_do_not_span_block_gaps() -> None:
    rows = [
        FeeRow(block=1, base_fee_wei=100, ts=0),
        FeeRow(block=2, base_fee_wei=100, ts=0),
        FeeRow(block=9, base_fee_wei=100, ts=0),
        FeeRow(block=10, base_fee_wei=100, ts=0),
    ]
    assert rolling_means(rows, 2) == [100, 100]
    assert rolling_means(rows, 3) == []


def test_rolling_means_require_positive_k() -> None:
    with pytest.raises(ValueError, match="k must be positive"):
        rolling_means(fee_rows(3), 0)


def test_rolling_means_do_not_depend_on_input_row_order() -> None:
    rows = fee_rows(4, fee=100)
    assert rolling_means(list(reversed(rows)), 2) == rolling_means(rows, 2)


# --- Integer quantiles -------------------------------------------------------------


def test_quantile_nearest_rank_matches_ceiling_rule() -> None:
    values = list(range(1, 11))
    assert quantile_nearest_rank(values, 10) == 1
    assert quantile_nearest_rank(values, 25) == 3
    assert quantile_nearest_rank(values, 50) == 5
    assert quantile_nearest_rank(values, 75) == 8
    assert quantile_nearest_rank(values, 90) == 9


def test_quantile_nearest_rank_uses_lower_median_for_even_samples() -> None:
    assert quantile_nearest_rank([1, 2, 3, 4], 50) == 2


def test_quantile_nearest_rank_returns_int_without_float() -> None:
    value = quantile_nearest_rank([1_000_000_007, 1_000_000_009], 50)
    assert isinstance(value, int)
    assert value == 1_000_000_007


def test_quantile_nearest_rank_rejects_empty_sample() -> None:
    with pytest.raises(ValueError, match="empty sample"):
        quantile_nearest_rank([], 50)


# --- K selection -------------------------------------------------------------------


def test_spread_ratio_comparison_is_exact_cross_multiplication() -> None:
    # 3/2 < 4/2 exactly; a float-based comparison of huge wei values could lose this.
    assert spread_ratio_less(3, 2, 4, 2) is True
    assert spread_ratio_less(4, 2, 3, 2) is False
    assert spread_ratio_less(1, 3, 1, 3) is False


def test_spread_ratio_comparison_rejects_zero_median() -> None:
    with pytest.raises(ValueError, match="positive medians"):
        spread_ratio_less(1, 0, 1, 1)


def test_select_candidate_minimizes_relative_spread() -> None:
    volatile = candidate_stats([100, 200] * 5, 10)
    steady = candidate_stats([100] * 10, 50)
    assert select_candidate([volatile, steady]).k == 50
    assert select_candidate([steady, volatile]).k == 50


def test_select_candidate_keeps_smallest_k_on_tie() -> None:
    first = candidate_stats([100, 200] * 5, 10)
    second = candidate_stats([100, 200] * 5, 25)
    assert select_candidate([second, first]).k == 10


def test_select_candidate_rejects_zero_median_candidates() -> None:
    zero_median = candidate_stats([0, 0, 0], 10)
    assert zero_median.median == 0
    with pytest.raises(ValueError, match="usable distribution"):
        select_candidate([zero_median])


# --- Bucket bounds -----------------------------------------------------------------


def test_bucket_bounds_use_p25_p50_p75() -> None:
    quantiles = {"25": 10, "50": 20, "75": 30}
    assert bucket_bounds(quantiles) == (10, 20, 30)


def test_bucket_bounds_deduplicate_tied_quantiles() -> None:
    quantiles = {"25": 10, "50": 10, "75": 30}
    bounds = bucket_bounds(quantiles)
    assert bounds == (10, 30)
    assert list(bounds) == sorted(set(bounds))


def test_bucket_bounds_require_two_distinct_positive_values() -> None:
    with pytest.raises(ValueError, match="two distinct positive"):
        bucket_bounds({"25": 7, "50": 7, "75": 7})
    with pytest.raises(ValueError, match="two distinct positive"):
        bucket_bounds({"25": 0, "50": 0, "75": 0})


def test_bucket_bounds_require_all_three_quantile_keys() -> None:
    with pytest.raises(ValueError, match="missing quantile keys"):
        bucket_bounds({"25": 10, "50": 20})


# --- End to end calibration --------------------------------------------------------


def build_history() -> list[FeeRow]:
    """A fee path whose window-mean spread shrinks as the window grows.

    The oscillation period (97 blocks) is longer than every candidate window, so a
    longer window averages more of the swing away and the window means stay spread
    out enough for the quantile bounds to be distinct.
    """

    rows: list[FeeRow] = []
    for index in range(120):
        fee = 1_000_000_000 + ((index * 7919) % 97) * 10_000_000
        rows.append(FeeRow(block=index + 1, base_fee_wei=fee, ts=1_700_000_000 + index))
    return rows


def test_calibrate_selects_k_and_builds_strictly_increasing_bounds() -> None:
    result = calibrate(build_history(), DEFAULT_CANDIDATES)
    assert result.window_k in DEFAULT_CANDIDATES
    assert len(result.bounds_wei) >= 2
    assert list(result.bounds_wei) == sorted(set(result.bounds_wei))
    assert all(isinstance(bound, int) for bound in result.bounds_wei)
    assert all(bound > 0 for bound in result.bounds_wei)
    assert set(result.quantiles) == {"10", "25", "50", "75", "90"}
    assert all(isinstance(value, int) for value in result.quantiles.values())


def test_calibrate_skips_candidates_without_enough_rows() -> None:
    rows = build_history()[:12]
    result = calibrate(rows, [10, 50, 200])
    assert 50 in result.skipped
    assert 200 in result.skipped
    assert result.window_k == 10


def test_calibrate_reports_window_with_too_few_rows() -> None:
    rows = build_history()[:3]
    with pytest.raises(ValueError, match="usable distribution"):
        calibrate(rows, [10, 50])


def test_params_json_contains_only_integers_for_bounds(tmp_path: Path) -> None:
    result = calibrate(build_history(), DEFAULT_CANDIDATES)
    path = write_params(result, tmp_path / "nested" / "params.json")
    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["window_k"] == result.window_k
    assert isinstance(payload["window_k"], int)
    assert payload["samples"] == result.samples
    assert payload["method"] == METHOD
    assert all(isinstance(bound, int) for bound in payload["bounds_wei"])
    assert all(isinstance(value, int) for value in payload["quantiles"].values())
    assert list(payload["bounds_wei"]) == sorted(set(payload["bounds_wei"]))
    assert len(payload["bounds_wei"]) >= 2


def test_report_markdown_mentions_window_and_bounds(tmp_path: Path) -> None:
    result = calibrate(build_history(), DEFAULT_CANDIDATES)
    path = write_report(
        result, tmp_path / "data" / "calibration.md", history="h.csv", row_count=120
    )
    text = path.read_text(encoding="utf-8")
    assert f"K = {result.window_k}" in text
    assert "window_k" in text
    assert "p10" in text


def test_parse_candidates_rejects_invalid_values() -> None:
    with pytest.raises(ValueError, match="unique"):
        parse_candidates("10,10")
    with pytest.raises(ValueError, match="positive"):
        parse_candidates("10,0")
    with pytest.raises(ValueError, match="invalid"):
        parse_candidates("10,abc")


def test_parse_candidates_accepts_sorted_unique_values() -> None:
    assert parse_candidates("50,10,25") == (10, 25, 50)


# --- CLI ----------------------------------------------------------------------------


def test_cli_end_to_end_writes_params_and_report(tmp_path: Path) -> None:
    history = write_csv(
        tmp_path,
        [
            (
                index + 1,
                1_000_000_000 + ((index * 7919) % 97) * 10_000_000,
                1_700_000_000 + index,
            )
            for index in range(120)
        ],
    )
    out = tmp_path / "out" / "params.json"
    exit_code = main(["--history", str(history), "--out", str(out), "--candidates", "10,25"])
    assert exit_code == 0
    payload = json.loads(out.read_text(encoding="utf-8"))
    assert payload["window_k"] in (10, 25)
    assert (out.parent / "calibration.md").exists()


def test_cli_reports_failure_without_writing_output(tmp_path: Path, capsys) -> None:
    history = write_csv(tmp_path, [(1, 1_000_000_000, 100)])
    out = tmp_path / "params.json"
    exit_code = main(["--history", str(history), "--out", str(out)])
    assert exit_code == 1
    assert "calibration failed" in capsys.readouterr().err
    assert not out.exists()


def test_cli_help_runs_offline() -> None:
    completed = subprocess.run(
        [sys.executable, str(SRC_DIR / "calibrate.py"), "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0
    assert "--history" in completed.stdout
    assert "--out" in completed.stdout
    assert "--candidates" in completed.stdout
