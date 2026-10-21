"""M1 acceptance probe: unified forecast interface, backtest, TSFM fallback.

This file is the M1 acceptance test pinned by the roadmap (docs/plans/路线图.md,
M1 预测机器人与回测). It is red until the agents package implements:

- one probability-vector interface ``forecast(history, horizon, bounds)`` shared by
  the naive, EWMA and TimesFM bots, probabilities scaled by 1e18 and summing to
  exactly 1e18;
- an offline backtest over a chronological split (no future information) that
  reports log score, Brier score, hit rate and cumulative PnL;
- graceful degradation: when the TimesFM inference process fails, the pipeline
  still completes with EWMA/naive.

Public contract pinned here (package layout is up to the implementation, as long
as these import paths exist):

- ``agents_bots.naive.forecast(history, horizon, bounds) -> list[int]``
- ``agents_bots.ewma.forecast(history, horizon, bounds) -> list[int]``
- ``agents_bots.tsfm.forecast(history, horizon, bounds, command=None) -> list[int]``
- ``agents_bots.backtest.run_backtest(forecast_fn, history, bounds, window) -> dict``
- ``agents_bots.pipeline.run_all_bots(history, horizon, bounds, tsfm_command=None) -> dict``

``history`` is a sequence of base-fee values in wei (ints), ``bounds`` are the
bucket bounds in wei (bucket i = [bounds[i-1], bounds[i]), half-open, matching
BaseFeeMarket.bucketOf), and every probability vector has ``len(bounds) + 1``
entries in [0, 1e18] summing to exactly 1e18.
"""

from __future__ import annotations

import subprocess
import sys

PROB_SCALE = 10**18

# Deterministic history fixture shared by every bot and the backtest: a fixed
# LCG series in the ~0.5–3 gwei range, 600 blocks. Same fixture for all bots.
_LCG_MOD = 2**31
_history_seed = 123456789
HISTORY: list[int] = []
for _ in range(600):
    _history_seed = (_history_seed * 1103515245 + 12345) % _LCG_MOD
    HISTORY.append(500_000_000 + (_history_seed % 2_500_000_000))

BOUNDS = [1_000_000_000, 1_500_000_000, 2_500_000_000, 4_000_000_000]


def _check_prob_vector(name: str, probs: list[int], n_bounds: int) -> None:
    assert isinstance(probs, list), f"{name}: forecast must return a list, got {type(probs)}"
    assert len(probs) == n_bounds + 1, (
        f"{name}: expected {n_bounds + 1} probabilities (one per bucket), got {len(probs)}"
    )
    for i, p in enumerate(probs):
        assert isinstance(p, int), f"{name}: probs[{i}] must be int (1e18 scale), got {type(p)}"
        assert 0 <= p <= PROB_SCALE, f"{name}: probs[{i}]={p} outside [0, 1e18]"
    total = sum(probs)
    assert total == PROB_SCALE, f"{name}: probs must sum to exactly 1e18, got {total}"


def test_naive_interface() -> None:
    from agents_bots.naive import forecast

    probs = forecast(HISTORY, horizon=1, bounds=BOUNDS)
    _check_prob_vector("naive", probs, len(BOUNDS))


def test_ewma_interface() -> None:
    from agents_bots.ewma import forecast

    probs = forecast(HISTORY, horizon=1, bounds=BOUNDS)
    _check_prob_vector("ewma", probs, len(BOUNDS))


def test_tsfm_interface_with_stub_runner() -> None:
    """TimesFM runs in a separate process speaking a JSON stdio protocol.

    The command must be injectable so the suite stays offline and deterministic:
    a tiny inline python stub stands in for the real TimesFM inference process.
    """
    from agents_bots.tsfm import forecast

    stub = [
        sys.executable,
        "-c",
        "import json,sys\n"
        "req=json.loads(sys.stdin.readline())\n"
        "n=len(req['bounds'])+1\n"
        "w=req.get('weights') or [1]*(n-1)+[1]\n"
        "t=sum(w)\n"
        "probs=[p*t//1_000_000_000 for p in w]\n"
        "probs[-1]+=t-sum(probs)\n"
        "sys.stdout.write(json.dumps({'probs':[p*1_000_000_000 for p in probs]}))\n",
    ]
    probs = forecast(HISTORY, horizon=1, bounds=BOUNDS, command=stub)
    _check_prob_vector("tsfm", probs, len(BOUNDS))


def test_backtest_reports_all_metrics() -> None:
    from agents_bots.backtest import run_backtest
    from agents_bots.naive import forecast

    metrics = run_backtest(forecast, HISTORY, BOUNDS, window=50)
    assert isinstance(metrics, dict), "run_backtest must return a metrics dict"
    for key in ("log_score", "brier", "hit_rate", "cumulative_pnl"):
        assert key in metrics, f"metrics missing {key!r}: got {sorted(metrics)}"
        assert isinstance(metrics[key], (int, float)), f"metrics[{key!r}] not numeric"
    assert 0.0 <= metrics["hit_rate"] <= 1.0, "hit_rate is a ratio in [0, 1]"


def test_backtest_uses_strict_prefixes_no_future_leakage() -> None:
    """Every forecast call must see only a strict prefix of the history.

    Instruments the forecaster to record the history length it received; the
    realized outcome scored at each step is the block right after that prefix,
    so any call seeing the value it is scored against is future leakage.
    """
    from agents_bots.backtest import run_backtest

    seen_lengths: list[int] = []

    def recording_forecast(history, horizon, bounds):
        seen_lengths.append(len(history))
        # weight only the bucket containing the last seen value
        last = history[-1]
        idx = sum(1 for b in bounds if last >= b)
        probs = [0] * (len(bounds) + 1)
        probs[idx] = PROB_SCALE
        return probs

    window = 50
    run_backtest(recording_forecast, HISTORY, BOUNDS, window=window)

    assert seen_lengths, "run_backtest never called the forecaster"
    assert seen_lengths == sorted(seen_lengths), "history prefixes must grow monotonically"
    first_len = seen_lengths[0]
    assert first_len >= window, f"first prefix {first_len} shorter than window {window}"
    assert seen_lengths[-1] < len(HISTORY), "last prefix must not cover the full history"
    for i, n in enumerate(seen_lengths):
        assert n == first_len + i, (
            f"step {i} saw history of length {n}, expected {first_len + i}: "
            "the split must advance one block per step (chronological, no gaps)"
        )


def test_tsfm_failure_degrades_to_ewma_naive() -> None:
    """When the TimesFM inference process fails, the demo still completes."""
    from agents_bots.pipeline import run_all_bots

    failing = [sys.executable, "-c", "import sys; sys.stderr.write('boom'); sys.exit(1)"]
    results = run_all_bots(HISTORY, horizon=1, bounds=BOUNDS, tsfm_command=failing)
    assert isinstance(results, dict), "run_all_bots must return a per-bot result dict"
    for bot in ("naive", "ewma"):
        assert bot in results, f"{bot} result missing: got {sorted(results)}"
        _check_prob_vector(bot, results[bot], len(BOUNDS))
    tsfm_state = results.get("tsfm")
    assert tsfm_state is not None, "tsfm entry must exist even when it fails"
    assert not isinstance(tsfm_state, list) or tsfm_state == [], (
        "tsfm failed: its entry must not be a probability vector"
    )
