"""Offline backtest engine for the forecast bots.

Scores a forecaster over a chronological walk-forward split of a base-fee
history. Every forecast call receives only a strict prefix of the history
(``history[:t]``) and is scored against ``history[t]``, the block immediately
after that prefix, so no step can see the value it is scored against
(no future information).

All probabilities follow the onchain convention of ``BaseFeeMarket``: integers
scaled by 1e18 (PROB_SCALE), each vector having ``len(bounds) + 1`` entries in
[0, 1e18] summing to exactly 1e18. The log score reproduces the contract's
``log1e18`` in pure integer arithmetic, so offline scores and onchain
settlement scores agree within the documented error bound (< 1e9 absolute on a
1e18-scaled result).
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence

from agents_bots.probability import PROB_SCALE, bucket_of

# ln(2) scaled by 1e18, same constant as BaseFeeMarket.LN2_1E18.
_LN2_1E18 = 693_147_180_559_945_309

# p_win = 0 is floored at ln(1e-18)*1e18 = -18e18, mirroring the settlement
# floor in BaseFeeMarket._settle.
_LOG_FLOOR = -18 * PROB_SCALE


def log_score_int(p_win_scaled: int) -> int:
    """ln(p_win_scaled / 1e18) * 1e18 in pure integer arithmetic.

    Same algorithm shape as the onchain scorer ``BaseFeeMarket.log1e18``:
    range reduction by doubling into m in [0.5e18, 1e18), then
    ln(m/1e18) = 2*artanh((m-1e18)/(m+1e18)) via 24 series terms
    (|y| <= 1/3 gives fast convergence). Absolute error < 1e9 on the
    1e18-scaled result, matching the contract's bound; the only deviation
    from Solidity is floor vs truncated integer division of the (negative)
    series terms, which stays well inside that bound.

    p_win_scaled == 0 returns the -18e18 floor. Values outside [0, 1e18]
    raise ValueError. No floats, no ``math.log``.
    """
    if p_win_scaled < 0 or p_win_scaled > PROB_SCALE:
        raise ValueError(f"p_win_scaled {p_win_scaled} outside [0, 1e18]")
    if p_win_scaled == 0:
        return _LOG_FLOOR

    # Range reduction: x = m * 2^-e with m/1e18 in [0.5, 1).
    e = 0
    m = p_win_scaled
    while m * 2 < PROB_SCALE:
        m *= 2
        e += 1

    # y = (m - 1) / (m + 1) scaled 1e18, in [-1/3, 0].
    num = m - PROB_SCALE
    den = m + PROB_SCALE
    y = (num * PROB_SCALE) // den
    y2 = (y * y) // PROB_SCALE  # <= 1/9
    term = y
    series_sum = 0
    for k in range(24):
        series_sum += term // (2 * k + 1)
        term = (term * y2) // PROB_SCALE
        if term == 0:
            break
    ln = 2 * series_sum - e * _LN2_1E18
    if ln > 0:  # ln(p <= 1) must be <= 0; rounding cannot push it positive
        ln = 0
    return ln


def run_backtest(
    forecast_fn,
    history: Sequence[int],
    bounds: Sequence[int],
    window: int = 50,
    stake: int = 1,
) -> dict:
    """Walk-forward backtest of ``forecast_fn`` over ``history``.

    No-future-information guarantee: step t (t in ``range(window, len(history))``)
    calls ``forecast_fn(history[:t], horizon=1, bounds=list(bounds))`` — a strict,
    chronologically growing prefix — and scores the returned probability vector
    against ``history[t]``, the block right after that prefix.

    Metrics (per the 1e18 probability scale):
    - ``log_score``: int sum of ``log_score_int(p_win)`` over all steps
      (compatible with the onchain settlement score);
    - ``log_score_mean``: float mean of the same per-step scores;
    - ``brier``: float mean of ((p_win/1e18) - 1)^2; ``brier_sum`` keeps the
      raw integer sum of (p_win - 1e18)^2;
    - ``hit_rate``: fraction of steps where argmax(probs) equals the realized
      bucket (argmax ties broken toward the lowest bucket index);
    - ``cumulative_pnl``: parimutuel-style float PnL — each step bets ``stake``
      on the argmax bucket against one equal-stake silent bot per bucket
      (``n_buckets`` silent bots, so the pool holds ``stake * (n_buckets + 1)``).
      If the argmax bucket wins, payout = ``stake * (n_buckets + 1) / 2``
      (our stake plus the silent bot's stake share of the pool), else 0;
      ``cumulative_pnl = sum(payouts) - steps * stake``.

    Raises ValueError unless ``window >= 1``, ``len(history) > window`` and
    ``bounds`` is non-empty and strictly increasing.
    """
    bounds = list(bounds)
    if window < 1:
        raise ValueError(f"window must be >= 1, got {window}")
    if len(history) <= window:
        raise ValueError(f"history of {len(history)} blocks must be longer than window {window}")
    if not bounds:
        raise ValueError("bounds must be non-empty")
    for i in range(len(bounds) - 1):
        if bounds[i] >= bounds[i + 1]:
            raise ValueError(
                f"bounds must be strictly increasing, got {bounds[i]} >= {bounds[i + 1]}"
            )

    n_buckets = len(bounds) + 1
    win_payout = stake * (n_buckets + 1) / 2  # see PnL model in the docstring

    log_score = 0
    brier_sum = 0
    hits = 0
    pnl = 0.0
    steps = 0
    for t in range(window, len(history)):
        prefix = history[:t]
        realized = history[t]
        probs = forecast_fn(prefix, horizon=1, bounds=bounds)
        win_bucket = bucket_of(realized, bounds)
        p_win = probs[win_bucket]

        log_score += log_score_int(p_win)
        brier_sum += (p_win - PROB_SCALE) ** 2

        best = max(range(n_buckets), key=probs.__getitem__)
        if best == win_bucket:
            hits += 1
            pnl += win_payout
        steps += 1

    return {
        "log_score": log_score,
        "log_score_mean": log_score / steps,
        "brier": brier_sum / PROB_SCALE**2 / steps,
        "brier_sum": brier_sum,
        "hit_rate": hits / steps,
        "cumulative_pnl": pnl - steps * stake,
        "steps": steps,
        "window": window,
    }


def backtest_table(results: Mapping) -> str:
    """Render a metrics dict from ``run_backtest`` as a plain-text table.

    One line per metric, dependency-free; used by the report CLI.
    """
    lines = [f"{'metric':<16} {'value':>14}"]
    lines.append("-" * len(lines[0]))
    for key, value in results.items():
        lines.append(f"{key:<16} {value!r:>14}")
    return "\n".join(lines)
