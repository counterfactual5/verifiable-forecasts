"""Offline, deterministic tests for the analysis pipeline and the bucket semantics.

The suite never touches the network: the pipeline is exercised in its offline mode
against a history CSV written by the test, and the bucket cases come from the
committed fixture under ``contracts/test/fixtures/``.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

import pipeline
from calibrate import MAX_INT256, MAX_WINDOW_BLOCKS, METHOD
from pipeline import (
    DEFAULT_FIXTURE,
    REQUIRED_PARAM_FIELDS,
    bucket_of,
    build_parser,
    check_bucket_cases,
    load_bucket_cases,
    main,
    validate_bounds,
    validate_params,
    verify_bucket_fixture,
)

SRC_DIR = Path(__file__).resolve().parents[1] / "src"
REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = REPO_ROOT / "contracts" / "test" / "fixtures" / "basefee_bucket_cases.json"


def write_history(path: Path, rows: list[tuple[int, int, int]]) -> Path:
    """Write a history CSV with the schema the calibrator expects."""

    lines = ["block,base_fee_wei,ts"]
    lines.extend(f"{block},{fee},{ts}" for block, fee, ts in rows)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def fee_path(count: int = 120) -> list[tuple[int, int, int]]:
    """A fee path whose window-mean spread shrinks as the window grows."""

    return [
        (
            index + 1,
            1_000_000_000 + ((index * 7919) % 97) * 10_000_000,
            1_700_000_000 + index,
        )
        for index in range(count)
    ]


# --- bucket semantics ---------------------------------------------------------------


def test_bucket_of_matches_the_half_open_interval_rule() -> None:
    bounds = [10, 20, 30]
    assert bucket_of(0, bounds) == 0
    assert bucket_of(9, bounds) == 0
    assert bucket_of(10, bounds) == 1
    assert bucket_of(19, bounds) == 1
    assert bucket_of(20, bounds) == 2
    assert bucket_of(29, bounds) == 2
    assert bucket_of(30, bounds) == 3
    assert bucket_of(31, bounds) == 3


def test_bucket_of_puts_a_bound_in_the_bucket_that_starts_there() -> None:
    bounds = [10, 20, 30]
    for index, bound in enumerate(bounds):
        assert bucket_of(bound, bounds) == index + 1


def test_bucket_of_handles_a_single_bound() -> None:
    assert bucket_of(4, [10]) == 0
    assert bucket_of(10, [10]) == 1


def test_bucket_of_rejects_invalid_bounds() -> None:
    with pytest.raises(ValueError, match="must not be empty"):
        bucket_of(1, [])
    with pytest.raises(ValueError, match="strictly increasing"):
        bucket_of(1, [10, 10])
    with pytest.raises(ValueError, match="strictly increasing"):
        bucket_of(1, [20, 10])
    with pytest.raises(ValueError, match="must be positive"):
        bucket_of(1, [0, 10])
    with pytest.raises(ValueError, match="must be positive"):
        bucket_of(1, [-5, 10])


def test_bucket_of_rejects_non_integer_input() -> None:
    with pytest.raises(ValueError, match="must be an integer"):
        bucket_of(1.5, [10])
    with pytest.raises(ValueError, match="must be an integer"):
        bucket_of(1, [10.5])


def test_validate_bounds_accepts_a_strictly_increasing_positive_array() -> None:
    assert validate_bounds([1, 2, 3]) == (1, 2, 3)


def test_validate_bounds_rejects_more_than_the_contract_allows() -> None:
    with pytest.raises(ValueError, match="at most 32"):
        validate_bounds(list(range(1, 34)))


def test_validate_bounds_accepts_int256_max_and_rejects_one_above() -> None:
    assert validate_bounds([MAX_INT256]) == (MAX_INT256,)
    assert validate_bounds([1, MAX_INT256]) == (1, MAX_INT256)
    with pytest.raises(ValueError, match="int256 maximum"):
        validate_bounds([MAX_INT256 + 1])
    with pytest.raises(ValueError, match="int256 maximum"):
        validate_bounds([1, MAX_INT256 + 1])


def test_bucket_of_accepts_int256_max_and_rejects_one_above() -> None:
    assert bucket_of(MAX_INT256, [MAX_INT256]) == 1
    assert bucket_of(MAX_INT256 - 1, [MAX_INT256]) == 0
    with pytest.raises(ValueError, match="int256 maximum"):
        bucket_of(1, [MAX_INT256 + 1])


# --- committed fixture ---------------------------------------------------------------


def test_fixture_file_exists_and_has_the_documented_schema() -> None:
    assert FIXTURE_PATH.exists()
    payload = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    assert set(payload) == {"bounds_wei", "cases", "semantics"}
    assert isinstance(payload["semantics"], str) and payload["semantics"].strip()
    assert isinstance(payload["bounds_wei"], list)
    assert isinstance(payload["cases"], list)


def test_fixture_bounds_are_positive_strictly_increasing_integers() -> None:
    payload = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    bounds = payload["bounds_wei"]
    assert all(isinstance(bound, int) and not isinstance(bound, bool) for bound in bounds)
    assert all(bound > 0 for bound in bounds)
    assert bounds == sorted(set(bounds))


def test_fixture_cases_use_integer_values() -> None:
    payload = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    for case in payload["cases"]:
        assert set(case) == {"value_wei", "bucket"}
        assert isinstance(case["value_wei"], int) and not isinstance(case["value_wei"], bool)
        assert isinstance(case["bucket"], int) and not isinstance(case["bucket"], bool)


def test_every_fixture_case_agrees_with_the_contract_semantics() -> None:
    bounds, cases = load_bucket_cases(FIXTURE_PATH)
    assert cases
    for value, expected in cases:
        assert bucket_of(value, bounds) == expected, f"value {value} landed in the wrong bucket"


def test_verify_bucket_fixture_reports_the_case_count() -> None:
    bounds, cases = load_bucket_cases(FIXTURE_PATH)
    assert verify_bucket_fixture(FIXTURE_PATH) == len(cases)
    assert len(cases) == len(json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))["cases"])


def test_check_bucket_cases_rejects_a_wrong_expectation() -> None:
    with pytest.raises(ValueError, match="bucket case mismatch"):
        check_bucket_cases([10, 20], [(10, 0)])


def test_load_bucket_cases_rejects_a_foreign_schema(tmp_path: Path) -> None:
    path = tmp_path / "bad.json"
    path.write_text(json.dumps({"bounds_wei": [1, 2], "cases": []}), encoding="utf-8")
    with pytest.raises(ValueError, match="exactly the fields"):
        load_bucket_cases(path)


def test_load_bucket_cases_rejects_non_integer_case_fields(tmp_path: Path) -> None:
    path = tmp_path / "bad.json"
    path.write_text(
        json.dumps(
            {
                "bounds_wei": [1, 2],
                "cases": [{"value_wei": 1.5, "bucket": 0}],
                "semantics": "half-open",
            }
        ),
        encoding="utf-8",
    )
    with pytest.raises(ValueError, match="must be an integer"):
        load_bucket_cases(path)


def test_default_fixture_points_at_the_committed_file() -> None:
    assert DEFAULT_FIXTURE == FIXTURE_PATH


# --- params payload -------------------------------------------------------------------


def test_validate_params_accepts_a_calibration_payload() -> None:
    payload = {
        "window_k": 50,
        "bounds_wei": [1000000000, 1500000000],
        "quantiles": {"50": 1200000000},
        "samples": 200,
        "method": METHOD,
    }
    validate_params(payload)


def test_validate_params_rejects_missing_fields() -> None:
    with pytest.raises(ValueError, match="missing fields"):
        validate_params({"window_k": 50})


def test_validate_params_rejects_non_integer_bounds() -> None:
    payload = {
        "window_k": 50,
        "bounds_wei": [1000000000, 1500000000.5],
        "quantiles": {"50": 1200000000},
        "samples": 200,
        "method": METHOD,
    }
    with pytest.raises(ValueError, match="bounds_wei"):
        validate_params(payload)


def test_validate_params_rejects_non_increasing_bounds() -> None:
    payload = {
        "window_k": 50,
        "bounds_wei": [1500000000, 1000000000],
        "quantiles": {"50": 1200000000},
        "samples": 200,
        "method": METHOD,
    }
    with pytest.raises(ValueError, match="bounds_wei"):
        validate_params(payload)


def test_validate_params_window_k_limit_is_the_contract_window_limit() -> None:
    payload = {
        "window_k": MAX_WINDOW_BLOCKS,
        "bounds_wei": [1000000000],
        "quantiles": {"50": 1000000000},
        "samples": 1,
        "method": METHOD,
    }
    assert MAX_WINDOW_BLOCKS == 256
    validate_params(payload)
    payload["window_k"] = MAX_WINDOW_BLOCKS + 1
    with pytest.raises(ValueError, match="window_k"):
        validate_params(payload)


def test_validate_params_rejects_a_bound_above_int256_max() -> None:
    payload = {
        "window_k": 50,
        "bounds_wei": [1000000000, MAX_INT256 + 1],
        "quantiles": {"50": 1000000000},
        "samples": 200,
        "method": METHOD,
    }
    with pytest.raises(ValueError, match="int256 maximum"):
        validate_params(payload)


# --- offline pipeline run ---------------------------------------------------------------


def test_pipeline_offline_run_writes_params_with_the_output_contract(tmp_path: Path) -> None:
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "nested" / "params.json"
    exit_code = main(["--history", str(history), "--out", str(out), "--fixture", str(FIXTURE_PATH)])
    assert exit_code == 0
    assert out.exists()
    payload = json.loads(out.read_text(encoding="utf-8"))
    for field in REQUIRED_PARAM_FIELDS:
        assert field in payload
    assert isinstance(payload["window_k"], int) and payload["window_k"] > 0
    assert isinstance(payload["samples"], int) and payload["samples"] > 0
    assert payload["method"] == METHOD
    assert all(isinstance(bound, int) for bound in payload["bounds_wei"])
    assert payload["bounds_wei"] == sorted(set(payload["bounds_wei"]))
    assert len(payload["bounds_wei"]) >= 2


def test_pipeline_offline_run_creates_parent_directories(tmp_path: Path) -> None:
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "a" / "b" / "c" / "params.json"
    exit_code = main(["--history", str(history), "--out", str(out)])
    assert exit_code == 0
    assert out.exists()
    assert out.parent.is_dir()


def test_pipeline_offline_run_writes_the_calibration_report(tmp_path: Path) -> None:
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    assert main(["--history", str(history), "--out", str(out)]) == 0
    assert (out.parent / "calibration.md").exists()


def test_pipeline_bounds_are_usable_by_the_bucket_semantics(tmp_path: Path) -> None:
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    assert main(["--history", str(history), "--out", str(out)]) == 0
    payload = json.loads(out.read_text(encoding="utf-8"))
    bounds = payload["bounds_wei"]
    median = payload["quantiles"]["50"]
    bucket = bucket_of(median, bounds)
    assert 0 <= bucket <= len(bounds)
    if bucket == 0:
        assert median < bounds[0]
    elif bucket == len(bounds):
        assert median >= bounds[-1]
    else:
        assert bounds[bucket - 1] <= median < bounds[bucket]


def test_pipeline_offline_run_never_needs_a_network(tmp_path: Path) -> None:
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    # An unroutable RPC endpoint proves the offline path ignores --rpc entirely.
    exit_code = main(
        [
            "--history",
            str(history),
            "--out",
            str(out),
            "--rpc",
            "http://127.0.0.1:1/never",
        ]
    )
    assert exit_code == 0
    assert out.exists()


def test_pipeline_fails_without_a_history_file(tmp_path: Path) -> None:
    with pytest.raises(SystemExit):
        main(["--history", str(tmp_path / "missing.csv"), "--out", str(tmp_path / "p.json")])


def test_pipeline_rejects_a_half_given_block_range(tmp_path: Path) -> None:
    history = write_history(tmp_path / "history.csv", fee_path())
    with pytest.raises(SystemExit):
        main(["--history", str(history), "--from", "1"])


def test_pipeline_fetch_step_is_wired_to_the_fetcher(tmp_path: Path, monkeypatch) -> None:
    """The network mode must delegate to the fetcher instead of fetching itself."""

    recorded: dict[str, list[str]] = {}

    def fake_fetch(argv: list[str]) -> int:
        recorded["argv"] = argv
        return 0

    monkeypatch.setattr(pipeline.fetch_fee_history, "main", fake_fetch)
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    exit_code = main(
        [
            "--history",
            str(history),
            "--out",
            str(out),
            "--rpc",
            "http://127.0.0.1:1/never",
            "--from",
            "10",
            "--to",
            "20",
        ]
    )
    assert exit_code == 0
    assert recorded["argv"][recorded["argv"].index("--rpc") + 1] == "http://127.0.0.1:1/never"
    assert recorded["argv"][recorded["argv"].index("--from") + 1] == "10"
    assert recorded["argv"][recorded["argv"].index("--to") + 1] == "20"
    assert recorded["argv"][recorded["argv"].index("--out") + 1] == str(history)
    assert out.exists()


def test_pipeline_stops_when_the_fetch_step_fails(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(pipeline.fetch_fee_history, "main", lambda argv: 2)
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    exit_code = main(["--history", str(history), "--out", str(out), "--from", "10", "--to", "20"])
    assert exit_code == 2
    assert not out.exists()


# --- fixture gate ----------------------------------------------------------------------


def record_fetch_calls(monkeypatch) -> list[list[str]]:
    calls: list[list[str]] = []

    def fake_fetch(argv: list[str]) -> int:
        calls.append(argv)
        return 0

    monkeypatch.setattr(pipeline.fetch_fee_history, "main", fake_fetch)
    return calls


def assert_nothing_written(out: Path) -> None:
    assert not out.exists()
    assert not (out.parent / "calibration.md").exists()


def test_pipeline_wrong_explicit_fixture_fails_before_fetch_and_writes(
    tmp_path: Path, monkeypatch
) -> None:
    calls = record_fetch_calls(monkeypatch)
    fixture = tmp_path / "wrong.json"
    fixture.write_text(
        json.dumps(
            {
                "bounds_wei": [10, 20],
                "cases": [{"value_wei": 10, "bucket": 0}],
                "semantics": "half-open",
            }
        ),
        encoding="utf-8",
    )
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    with pytest.raises(SystemExit) as excinfo:
        main(
            [
                "--history",
                str(history),
                "--out",
                str(out),
                "--fixture",
                str(fixture),
                "--from",
                "10",
                "--to",
                "20",
            ]
        )
    assert excinfo.value.code != 0
    assert calls == []
    assert_nothing_written(out)


def test_pipeline_missing_explicit_fixture_fails_before_fetch_and_writes(
    tmp_path: Path, monkeypatch
) -> None:
    calls = record_fetch_calls(monkeypatch)
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    with pytest.raises(SystemExit) as excinfo:
        main(
            [
                "--history",
                str(history),
                "--out",
                str(out),
                "--fixture",
                str(tmp_path / "missing.json"),
                "--from",
                "10",
                "--to",
                "20",
            ]
        )
    assert excinfo.value.code != 0
    assert calls == []
    assert_nothing_written(out)


def test_pipeline_missing_default_fixture_fails_before_fetch_and_writes(
    tmp_path: Path, monkeypatch
) -> None:
    calls = record_fetch_calls(monkeypatch)
    monkeypatch.setattr(pipeline, "DEFAULT_FIXTURE", tmp_path / "no" / "fixture.json")
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    with pytest.raises(SystemExit) as excinfo:
        main(["--history", str(history), "--out", str(out), "--from", "10", "--to", "20"])
    assert excinfo.value.code != 0
    assert calls == []
    assert_nothing_written(out)


def test_pipeline_missing_default_fixture_fails_offline_too(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(pipeline, "DEFAULT_FIXTURE", tmp_path / "no" / "fixture.json")
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    with pytest.raises(SystemExit) as excinfo:
        main(["--history", str(history), "--out", str(out)])
    assert excinfo.value.code != 0
    assert_nothing_written(out)


def test_pipeline_single_bound_calibration_runs_end_to_end(tmp_path: Path) -> None:
    constant = [(index + 1, 1_000_000_000, 1_700_000_000 + index) for index in range(300)]
    history = write_history(tmp_path / "history.csv", constant)
    out = tmp_path / "params.json"
    assert main(["--history", str(history), "--out", str(out)]) == 0
    payload = json.loads(out.read_text(encoding="utf-8"))
    assert payload["bounds_wei"] == [1_000_000_000]
    validate_params(payload)
    assert bucket_of(999_999_999, payload["bounds_wei"]) == 0
    assert bucket_of(1_000_000_000, payload["bounds_wei"]) == 1
    assert (out.parent / "calibration.md").exists()


# --- CLI ---------------------------------------------------------------------------------


def test_pipeline_cli_help_runs_offline() -> None:
    completed = subprocess.run(
        [sys.executable, str(SRC_DIR / "pipeline.py"), "--help"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0
    assert "--history" in completed.stdout
    assert "--out" in completed.stdout
    assert "--rpc" in completed.stdout
    assert "--from" in completed.stdout
    assert "--to" in completed.stdout


def test_pipeline_parser_exposes_the_documented_options() -> None:
    help_text = build_parser().format_help()
    for option in ("--history", "--out", "--rpc", "--from", "--to", "--candidates"):
        assert option in help_text


def test_pipeline_cli_offline_run_writes_params(tmp_path: Path) -> None:
    history = write_history(tmp_path / "history.csv", fee_path())
    out = tmp_path / "params.json"
    completed = subprocess.run(
        [
            sys.executable,
            str(SRC_DIR / "pipeline.py"),
            "--history",
            str(history),
            "--out",
            str(out),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    payload = json.loads(out.read_text(encoding="utf-8"))
    assert payload["bounds_wei"]
    assert isinstance(payload["window_k"], int)
