"""One-shot orchestration of the base fee analysis: fetch, calibrate, write params.

``pipeline.py`` is the composition root of the ``analysis`` subproject. It wires the
two existing modules together and owns no calibration math of its own:

* :mod:`fetch_fee_history` optionally pulls mainnet base fees into a CSV.
* :mod:`calibrate` turns that CSV into the parameter file the contract consumes.

The one piece of logic this module owns is the *bucket semantics* of the contract,
:func:`bucket_of`, which mirrors ``BaseFeeMarket.bucketOf``:

* bucket ``0`` is ``(-inf, bounds[0])``;
* bucket ``i`` is ``[bounds[i-1], bounds[i])``;
* the last bucket is ``[bounds[n-1], +inf)``.

A value that is exactly equal to a bound belongs to the bucket that *starts* at that
bound, so ``bounds[i]`` itself is never in bucket ``i``. The committed fixture
``contracts/test/fixtures/basefee_bucket_cases.json`` pins that behaviour down for
both sides of the boundary.

Every number that leaves this module is an integer in wei; no float reaches a file.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Final

import fetch_fee_history
from calibrate import (
    DEFAULT_CANDIDATES,
    REPORT_NAME,
    calibrate,
    load_history,
    parse_candidates,
    write_params,
    write_report,
)

DEFAULT_HISTORY: Final[Path] = Path("data/basefee_history.csv")
DEFAULT_OUT: Final[Path] = Path("data/params.json")
REQUIRED_PARAM_FIELDS: Final[tuple[str, ...]] = (
    "window_k",
    "bounds_wei",
    "quantiles",
    "samples",
    "method",
)
# The contract accepts at most 32 bounds (BaseFeeMarket.createRound).
MAX_BOUNDS: Final[int] = 32
REPO_ROOT: Final[Path] = Path(__file__).resolve().parents[2]
DEFAULT_FIXTURE: Final[Path] = (
    REPO_ROOT / "contracts" / "test" / "fixtures" / "basefee_bucket_cases.json"
)


def validate_bounds(bounds: Sequence[int]) -> tuple[int, ...]:
    """Check a bounds array against the contract's rules and return it as a tuple.

    The contract rejects empty arrays, arrays longer than 32 entries, a non-positive
    first bound and any bound that does not strictly exceed its predecessor. It also
    works in ``int256`` only, so a float bound is not a bound here either.
    """

    values = tuple(bounds)
    if not values:
        raise ValueError("bounds must not be empty")
    if len(values) > MAX_BOUNDS:
        raise ValueError(f"bounds must hold at most {MAX_BOUNDS} entries")
    for index, bound in enumerate(values):
        if isinstance(bound, bool) or not isinstance(bound, int):
            raise ValueError(f"bounds[{index}] must be an integer, got {type(bound).__name__}")
        if bound <= 0:
            raise ValueError(f"bounds[{index}] must be positive, got {bound}")
        if index and bound <= values[index - 1]:
            raise ValueError(
                f"bounds must be strictly increasing: bounds[{index}]={bound} "
                f"is not above bounds[{index - 1}]={values[index - 1]}"
            )
    return values


def bucket_of(value: int, bounds: Sequence[int]) -> int:
    """Return the bucket index of ``value`` under the contract's half-open intervals.

    Bucket ``0`` is ``value < bounds[0]``, bucket ``i`` is
    ``bounds[i-1] <= value < bounds[i]`` and the final bucket is
    ``value >= bounds[-1]``. The bounds are validated first, so an empty or
    non-increasing array is an error instead of a silent answer.
    """

    values = validate_bounds(bounds)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"value must be an integer, got {type(value).__name__}")
    bucket = 0
    for bound in values:
        if value < bound:
            break
        bucket += 1
    return bucket


def load_bucket_cases(path: str | Path) -> tuple[list[int], list[tuple[int, int]]]:
    """Load and validate the committed bucket case fixture.

    The schema is exactly ``bounds_wei``, ``cases`` and ``semantics``; anything else
    is an error, so a silently reshaped fixture cannot pass unnoticed. The returned
    pairs are ``(value_wei, bucket)``.
    """

    fixture_path = Path(path)
    try:
        raw = fixture_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ValueError(f"cannot read bucket case fixture {fixture_path}: {exc}") from exc
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{fixture_path}: bucket case fixture is not valid JSON") from exc
    if not isinstance(payload, dict):
        raise ValueError(f"{fixture_path}: bucket case fixture must be a JSON object")

    expected_fields = {"bounds_wei", "cases", "semantics"}
    if set(payload) != expected_fields:
        raise ValueError(
            f"{fixture_path}: fixture must have exactly the fields "
            f"{sorted(expected_fields)}, got {sorted(payload)}"
        )

    semantics = payload["semantics"]
    if not isinstance(semantics, str) or not semantics.strip():
        raise ValueError(f"{fixture_path}: semantics must be a non-empty string")

    raw_bounds = payload["bounds_wei"]
    if not isinstance(raw_bounds, list):
        raise ValueError(f"{fixture_path}: bounds_wei must be a list")
    try:
        bounds = list(validate_bounds(raw_bounds))
    except ValueError as exc:
        raise ValueError(f"{fixture_path}: {exc}") from exc

    raw_cases = payload["cases"]
    if not isinstance(raw_cases, list) or not raw_cases:
        raise ValueError(f"{fixture_path}: cases must be a non-empty list")

    cases: list[tuple[int, int]] = []
    for index, case in enumerate(raw_cases):
        if not isinstance(case, dict) or set(case) != {"value_wei", "bucket"}:
            raise ValueError(
                f"{fixture_path}: case {index} must have exactly the fields "
                "'value_wei' and 'bucket'"
            )
        for field in ("value_wei", "bucket"):
            item = case[field]
            if isinstance(item, bool) or not isinstance(item, int):
                raise ValueError(
                    f"{fixture_path}: case {index} field {field!r} must be an integer, "
                    f"got {type(item).__name__}"
                )
        cases.append((case["value_wei"], case["bucket"]))
    return bounds, cases


def check_bucket_cases(bounds: Sequence[int], cases: Sequence[tuple[int, int]]) -> None:
    """Verify every ``(value, bucket)`` pair against :func:`bucket_of`."""

    values = validate_bounds(bounds)
    for value, expected in cases:
        actual = bucket_of(value, values)
        if actual != expected:
            raise ValueError(
                f"bucket case mismatch for value {value}: fixture says bucket "
                f"{expected}, contract semantics say bucket {actual}"
            )


def verify_bucket_fixture(path: str | Path) -> int:
    """Load the fixture and check every case against the contract semantics.

    Returns the number of cases checked. A schema problem or a disagreeing case
    raises ``ValueError``.
    """

    bounds, cases = load_bucket_cases(path)
    check_bucket_cases(bounds, cases)
    return len(cases)


def validate_params(payload: Mapping[str, object]) -> None:
    """Check the params payload against the contract-facing output contract.

    The contract and the forecasters read these fields verbatim, so a missing field
    or a non-integer bound is an error rather than something to repair downstream.
    """

    missing = [field for field in REQUIRED_PARAM_FIELDS if field not in payload]
    if missing:
        raise ValueError(f"params payload is missing fields: {', '.join(missing)}")

    window_k = payload["window_k"]
    if isinstance(window_k, bool) or not isinstance(window_k, int) or window_k <= 0:
        raise ValueError("params payload field 'window_k' must be a positive integer")

    samples = payload["samples"]
    if isinstance(samples, bool) or not isinstance(samples, int) or samples <= 0:
        raise ValueError("params payload field 'samples' must be a positive integer")

    bounds = payload["bounds_wei"]
    if not isinstance(bounds, list):
        raise ValueError("params payload field 'bounds_wei' must be a list")
    try:
        validate_bounds(bounds)
    except ValueError as exc:
        raise ValueError(f"params payload field 'bounds_wei' is invalid: {exc}") from exc

    quantiles = payload["quantiles"]
    if not isinstance(quantiles, dict) or not quantiles:
        raise ValueError("params payload field 'quantiles' must be a non-empty object")
    for key, value in quantiles.items():
        if isinstance(value, bool) or not isinstance(value, int):
            raise ValueError(f"params payload quantile {key!r} must be an integer")

    method = payload["method"]
    if not isinstance(method, str) or not method.strip():
        raise ValueError("params payload field 'method' must be a non-empty string")


def build_parser() -> argparse.ArgumentParser:
    """Build the command line parser of the pipeline."""

    parser = argparse.ArgumentParser(
        prog="pipeline.py",
        description=(
            "Run the base fee pipeline: an optional fetch step, then calibration into "
            "the params JSON the contract consumes."
        ),
        epilog=(
            "Without --from/--to the run is fully offline: an existing history CSV is "
            "read and nothing touches the network."
        ),
    )
    parser.add_argument(
        "--history",
        default=str(DEFAULT_HISTORY),
        help=(
            "history CSV with columns block,base_fee_wei,ts; the fetch step writes "
            f"into this file too (default: {DEFAULT_HISTORY})"
        ),
    )
    parser.add_argument(
        "--out",
        default=str(DEFAULT_OUT),
        help=f"output params JSON path (default: {DEFAULT_OUT})",
    )
    parser.add_argument(
        "--rpc",
        default=fetch_fee_history.DEFAULT_RPC_URL,
        help=(
            "JSON-RPC endpoint for the optional fetch step "
            f"(default: {fetch_fee_history.DEFAULT_RPC_URL})"
        ),
    )
    parser.add_argument(
        "--from",
        dest="from_block",
        type=int,
        default=None,
        help="first block of the optional fetch step, inclusive",
    )
    parser.add_argument(
        "--to",
        dest="to_block",
        type=int,
        default=None,
        help="last block of the optional fetch step, inclusive",
    )
    parser.add_argument(
        "--candidates",
        default=",".join(str(value) for value in DEFAULT_CANDIDATES),
        help="comma-separated candidate window lengths",
    )
    parser.add_argument(
        "--fixture",
        default=None,
        help=(
            "bucket case fixture to verify against the contract semantics "
            f"(default: {DEFAULT_FIXTURE})"
        ),
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """Run fetch (optional) and calibration, then write the params JSON."""

    parser = build_parser()
    args = parser.parse_args(argv)

    if (args.from_block is None) != (args.to_block is None):
        parser.error("--from and --to must be given together")

    history_path = Path(args.history)
    out_path = Path(args.out)

    if args.from_block is not None:
        fetch_code = fetch_fee_history.main(
            [
                "--rpc",
                args.rpc,
                "--from",
                str(args.from_block),
                "--to",
                str(args.to_block),
                "--out",
                str(history_path),
            ]
        )
        if fetch_code != 0:
            return fetch_code
    elif not history_path.exists():
        parser.error(
            f"history file not found: {history_path}; pass an existing --history or "
            "add --from/--to to fetch one"
        )

    try:
        rows = load_history(history_path)
        candidates = parse_candidates(args.candidates)
        result = calibrate(rows, candidates)
        payload = result.as_params()
        validate_params(payload)
    except ValueError as exc:
        parser.error(str(exc))

    params_path = write_params(result, out_path)
    report_path = write_report(
        result,
        params_path.with_name(REPORT_NAME),
        history=str(history_path),
        row_count=len(rows),
    )
    print(
        f"window_k={result.window_k} samples={result.samples} bounds_wei={list(result.bounds_wei)}"
    )
    print(f"wrote {params_path} and {report_path}")

    fixture_path = Path(args.fixture) if args.fixture else DEFAULT_FIXTURE
    if fixture_path.exists():
        try:
            checked = verify_bucket_fixture(fixture_path)
        except ValueError as exc:
            parser.error(str(exc))
        print(f"checked {checked} bucket cases against {fixture_path}")
    elif args.fixture is not None:
        parser.error(f"bucket case fixture not found: {fixture_path}")
    else:
        print(f"bucket case fixture not found at {fixture_path}; skipping", file=sys.stderr)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
