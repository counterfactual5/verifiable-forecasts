"""Backtest report CLI: run the forecast bots over a history and report metrics.

Usage (from ``agents/``)::

    uv run python scripts/run_backtest.py [--history path.csv] [--bots naive,ewma]
        [--window 50] [--bounds 1000000000,...] [--tsfm-command ARG,...]
        [--tsfm-timeout SECS] [--out path.md] [--json]

The history is a CSV with columns ``block,base_fee_wei,ts`` or, when no path is
given or the file is missing, the built-in deterministic LCG fixture (same
generator constants as ``tests/test_m1_acceptance.py``, replicated here so the
CLI never imports the test suite). All metrics come from
``agents_bots.backtest.run_backtest``; this script only wires arguments, bots
and output together. Exit codes: 0 on success (even when tsfm is unavailable,
which is noted in the report), 1 on bad arguments or a malformed CSV.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path

# pythonpath=src in pyproject applies to pytest only; make src/ importable for
# `uv run python scripts/...` too. The sys.path setup must precede the
# agents_bots import, hence the non-top-level imports below.
_AGENTS_DIR = Path(__file__).resolve().parent.parent
_SRC_DIR = _AGENTS_DIR / "src"
if str(_SRC_DIR) not in sys.path:
    sys.path.insert(0, str(_SRC_DIR))

# Default report path lives under agents/docs/ regardless of the caller's cwd.
DEFAULT_OUT = _AGENTS_DIR / "docs" / "backtest_report.md"

# The default bot list leaves tsfm out on purpose: every forecast step spawns a
# fresh runner process, and each process cold-loads the TimesFM model, so a
# full backtest with tsfm costs one model load per step. Pass
# --bots naive,ewma,tsfm to include it.
DEFAULT_BOTS = "naive,ewma"
DEFAULT_BOUNDS = "1000000000,1500000000,2500000000,4000000000"
KNOWN_BOTS = ("naive", "ewma", "tsfm")

# Seconds the tsfm runner process may take before it counts as unavailable.
DEFAULT_TSFM_TIMEOUT = 120.0

# Deterministic LCG history fixture (600 blocks in the ~0.5-3 gwei range).
LCG_MOD = 2**31
LCG_MULTIPLIER = 1103515245
LCG_INCREMENT = 12345
LCG_SEED = 123456789
FIXTURE_BLOCKS = 600


def lcg_history(n_blocks: int = FIXTURE_BLOCKS) -> list[int]:
    """Base-fee history in wei from the deterministic LCG fixture."""
    seed = LCG_SEED
    values: list[int] = []
    for _ in range(n_blocks):
        seed = (seed * LCG_MULTIPLIER + LCG_INCREMENT) % LCG_MOD
        values.append(500_000_000 + seed % 2_500_000_000)
    return values


def load_csv_history(path: Path) -> list[int]:
    """Read base_fee_wei values (oldest first) from a block,base_fee_wei,ts CSV.

    Raises ValueError on anything but a well-formed file: missing header
    columns, non-integer or negative fees, or zero data rows.
    """
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.reader(handle)
        try:
            header = next(reader)
        except StopIteration:
            raise ValueError(f"{path}: empty CSV file") from None
        names = [column.strip().lower() for column in header]
        required = ("block", "base_fee_wei", "ts")
        missing = [column for column in required if column not in names]
        if missing:
            raise ValueError(
                f"{path}: header missing column(s) {', '.join(missing)}; "
                f"expected {', '.join(required)}"
            )
        fee_col = names.index("base_fee_wei")
        values: list[int] = []
        for lineno, row in enumerate(reader, start=2):
            if not row or all(not cell.strip() for cell in row):
                continue
            if fee_col >= len(row):
                raise ValueError(f"{path}:{lineno}: missing base_fee_wei value")
            text = row[fee_col].strip()
            if not text.isdigit():
                raise ValueError(f"{path}:{lineno}: base_fee_wei {text!r} is not a wei integer")
            values.append(int(text))
    if not values:
        raise ValueError(f"{path}: no data rows")
    return values


def parse_bots(text: str) -> list[str]:
    """Comma-separated bot list -> deduplicated known bot names, in order."""
    bots: list[str] = []
    for token in text.split(","):
        name = token.strip()
        if not name:
            continue
        if name not in KNOWN_BOTS:
            raise ValueError(
                f"--bots: unknown bot {name!r} (known: {', '.join(KNOWN_BOTS)})"
            )
        if name not in bots:
            bots.append(name)
    if not bots:
        raise ValueError("--bots: expected at least one bot")
    return bots


def parse_int_list(text: str, flag: str) -> list[int]:
    """Comma-separated non-negative integer list (wei amounts)."""
    values: list[int] = []
    for token in text.split(","):
        token = token.strip()
        if not token.isdigit():
            raise ValueError(f"--{flag}: {token!r} is not a wei integer")
        values.append(int(token))
    if not values:
        raise ValueError(f"--{flag}: expected at least one value")
    return values


def parse_command(text: str) -> list[str] | None:
    """Comma- or space-separated argv string -> argv list (None when empty)."""
    tokens = [tok for part in text.split(",") for tok in part.split()]
    return tokens or None


def load_tsfm(command: list[str] | None, timeout: float):
    """Return (forecast wrapper passing ``command`` and ``timeout``, error class)."""
    from agents_bots import tsfm

    def forecast(history, horizon: int = 1, bounds=()):
        return tsfm.forecast(
            history, horizon=horizon, bounds=bounds, command=command, timeout=timeout
        )

    return forecast, tsfm.TsfmUnavailable


class _Parser(argparse.ArgumentParser):
    """argparse exits 2 on bad flags; this CLI is pinned to exit 1 instead."""

    def error(self, message: str) -> None:
        self.exit(1, f"{self.prog}: error: {message}\n")


def build_parser() -> argparse.ArgumentParser:
    parser = _Parser(
        prog="run_backtest.py",
        description=(
            "Run the forecast bots over a base-fee history and write/report "
            "backtest metrics (agents_bots.backtest.run_backtest)."
        ),
    )
    parser.add_argument(
        "--history",
        type=Path,
        metavar="path.csv",
        default=None,
        help=(
            "CSV history (columns block,base_fee_wei,ts); a missing file "
            "falls back to the built-in LCG fixture"
        ),
    )
    parser.add_argument(
        "--window",
        type=int,
        default=50,
        help="walk-forward warm-up length in blocks (default: %(default)s)",
    )
    parser.add_argument(
        "--bounds",
        default=DEFAULT_BOUNDS,
        metavar="WEI,...",
        help=(
            "comma-separated strictly increasing bucket bounds in wei "
            "(default: %(default)s)"
        ),
    )
    parser.add_argument(
        "--bots",
        default=DEFAULT_BOTS,
        metavar="naive,ewma,tsfm",
        help="comma-separated subset of the bots (default: %(default)s)",
    )
    parser.add_argument(
        "--tsfm-command",
        default=None,
        metavar="ARGV",
        help=(
            "TimesFM runner argv, comma- or space-separated "
            "(default: the model venv runner)"
        ),
    )
    parser.add_argument(
        "--tsfm-timeout",
        type=float,
        default=DEFAULT_TSFM_TIMEOUT,
        metavar="SECS",
        help=(
            "seconds the tsfm runner process may take before it counts as "
            "unavailable (default: %(default)s)"
        ),
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=DEFAULT_OUT,
        metavar="path.md",
        help="markdown report path (default: %(default)s)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="print metrics as JSON to stdout instead of the table and report file",
    )
    return parser


def _fmt(value: int | float) -> str:
    """Fixed 6-decimal float without trailing zeros, so runs stay diff-stable."""
    if isinstance(value, int):
        return str(value)
    return f"{value:.6f}".rstrip("0").rstrip(".")


def render_report(
    source: str,
    n_blocks: int,
    window: int,
    bounds: list[int],
    results: dict[str, dict],
    notes: list[str],
) -> str:
    """Markdown report: fixture description, one row per bot, method notes."""
    n_buckets = len(bounds) + 1
    win_net = (n_buckets + 1) / 2 - 1
    metric_cols = ("log_score_mean", "brier", "hit_rate", "cumulative_pnl", "steps")
    lines = [
        "# Basefee bot backtest report",
        "",
        "Generated by `scripts/run_backtest.py` via `agents_bots.backtest.run_backtest`.",
        "",
        "## Fixture",
        "",
        f"- Source: {source}",
        f"- Blocks: {n_blocks}",
        f"- Window: {window}",
        f"- Bounds (wei): {', '.join(str(b) for b in bounds)} — {n_buckets} buckets",
        "",
        "## Results",
        "",
        "| bot | log_score_mean | brier | hit_rate | cumulative_pnl | steps |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for name, metrics in results.items():
        cells = " | ".join(_fmt(metrics[col]) for col in metric_cols)
        lines.append(f"| {name} | {cells} |")
    lines += [
        "",
        "`log_score_mean` is the per-step mean of the integer log score on the 1e18 scale"
        " (see Method).",
        "",
        "## Method",
        "",
        "- Chronological walk-forward split: step `t` (for `t` in `[window, len(history))`)"
        " trains on the strict prefix `history[:t]` and is scored against `history[t]`,"
        " the block immediately after that prefix. Prefixes grow one block per step and"
        " never contain the scored value — no step sees future information.",
        "- Probability vectors are integers on the e18 probability scale over"
        " `len(bounds) + 1` half-open buckets (bucket `i` = `[bounds[i-1], bounds[i])`),"
        " each vector summing to exactly 1e18 — the same shape and validation the"
        " onchain `recordPrediction` applies.",
        "- Log score: integer-only `ln(p_win) * 1e18` with the same algorithm as the"
        " onchain scorer; `p_win = 0` is floored at `-18e18`. Offline and onchain"
        " settlement scores therefore agree within the documented error bound"
        " (< 1e9 absolute on the 1e18-scaled result).",
        "- Brier: mean of `(p_win / 1e18 - 1)^2` on the realized bucket. Hit rate:"
        " fraction of steps where `argmax(probs)` equals the realized bucket"
        " (argmax ties broken toward the lowest bucket index).",
        f"- PnL model (as implemented in `agents_bots.backtest`): parimutuel pool —"
        f" each step bets stake 1 on the argmax bucket against one equal-stake silent"
        f" bot per bucket, so the pool holds `stake * (n_buckets + 1)`; a hit pays"
        f" `stake * (n_buckets + 1) / 2`, a miss pays 0, and"
        f" `cumulative_pnl = payouts - steps * stake` (with {n_buckets} buckets:"
        f" {win_net:+g} per hit, -1 per miss).",
        "- The default bot list is `naive,ewma`: every forecast step spawns a"
        " fresh runner process, and each process cold-loads the TimesFM model, so"
        " a tsfm backtest costs one model load per step. Pass"
        " `--bots naive,ewma,tsfm` to include it.",
    ]
    if notes:
        lines += ["", "### Notes", ""]
        lines.extend(f"- {note}" for note in notes)
    lines.append("")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    try:
        bots = parse_bots(args.bots)
        bounds = parse_int_list(args.bounds, "bounds")
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if any(a >= b for a, b in zip(bounds, bounds[1:], strict=False)):
        print("error: --bounds must be strictly increasing", file=sys.stderr)
        return 1
    if args.window < 1:
        print("error: --window must be >= 1", file=sys.stderr)
        return 1
    if args.tsfm_timeout <= 0:
        print("error: --tsfm-timeout must be > 0", file=sys.stderr)
        return 1
    tsfm_command = parse_command(args.tsfm_command) if args.tsfm_command else None

    notes: list[str] = []
    if args.history is None:
        history = lcg_history()
        source = "built-in LCG fixture (deterministic)"
    elif args.history.is_file():
        try:
            history = load_csv_history(args.history)
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        source = f"CSV `{args.history}`"
    else:
        history = lcg_history()
        source = "built-in LCG fixture (deterministic)"
        notes.append(
            f"history file `{args.history}` not found — used the built-in LCG fixture instead"
        )

    forecasters: dict = {}
    # Imported here (not at module top) because the sys.path setup above must
    # run first for `uv run python scripts/...` to see src/.
    from agents_bots.backtest import backtest_table, run_backtest

    tsfm_errors: tuple[type[Exception], ...] = ()
    if "naive" in bots:
        from agents_bots.naive import forecast as naive_forecast

        forecasters["naive"] = naive_forecast
    if "ewma" in bots:
        from agents_bots.ewma import forecast as ewma_forecast

        forecasters["ewma"] = ewma_forecast
    if "tsfm" in bots:
        try:
            forecast, tsfm_errors = load_tsfm(tsfm_command, args.tsfm_timeout)
            forecasters["tsfm"] = forecast
        except ImportError as exc:
            notes.append(f"tsfm unavailable ({exc}) — dropped from this report")

    results: dict[str, dict] = {}
    for name in bots:
        if name not in forecasters:
            continue
        try:
            if name == "tsfm":
                # The first forecast call decides availability: if the model
                # process is down, tsfm is dropped with a note instead of
                # failing the report (degradation logic lives in pipeline.py).
                forecasters[name](history[: args.window], horizon=1, bounds=bounds)
            results[name] = run_backtest(
                forecasters[name], history, bounds, window=args.window
            )
        except tsfm_errors as exc:
            notes.append(f"tsfm unavailable ({exc}) — dropped from this report")
        except ValueError as exc:
            print(f"error: {exc}", file=sys.stderr)
            return 1
        except Exception as exc:
            # A bot that dies mid-run (a killed runner process, an OOM) must not
            # take the whole report down: the other bots still have results.
            notes.append(f"{name} failed ({type(exc).__name__}: {exc}) — dropped from this report")

    if not results:
        print("error: no bot produced results", file=sys.stderr)
        return 1

    if args.json:
        payload = {
            "meta": {
                "source": source,
                "blocks": len(history),
                "window": args.window,
                "bounds": bounds,
                "bots": list(results),
                "notes": notes,
            },
            "bots": results,
        }
        print(json.dumps(payload, indent=2))
        return 0

    for name, metrics in results.items():
        print(f"== {name} ==")
        print(backtest_table(metrics))
        print()
    out_path = args.out if args.out.is_absolute() else Path.cwd() / args.out
    try:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(
            render_report(source, len(history), args.window, bounds, results, notes),
            encoding="utf-8",
        )
    except OSError as exc:
        print(f"error: cannot write report to {out_path}: {exc}", file=sys.stderr)
        return 1
    print(f"report written to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
