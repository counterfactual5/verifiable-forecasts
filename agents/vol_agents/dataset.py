"""Real training samples from the pool's tick history, in the contract's units.

The input is the tick-cumulative grid that analysis/ exports from Uniswap V3 Swap logs
(`vol_calibrate.py --export-grid`, CSV `timestamp,tick_cumulative`, one row every 60 s). It is read
as a file; agents/ never imports analysis/. The grid's cumulative differs from the pool oracle's by
one constant, which cancels in every difference below.

A sample is one hypothetical round opened at grid time T with startTime = T + LEAD_S:
- features: the 18 cumulatives at T - 17Δ .. T through cm.features_from_cumulatives (the
  contract's floorDiv, CLAMP and MULT);
- label: the realized vol of the 13 cumulatives at startTime + kΔ (cm.realized_vol_from_cumulatives)
  bucketed under the round's bounds;
- lag_rv: the same realized vol over the hour that ends at T (unclamped), for the baselines.
"""

import csv
from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import contract_math as cm

# demo/fork_round.py opens each round one segment before its start, so the feature segments line
# up with the previous rounds' window segments
LEAD_S = cm.DELTA


@dataclass(frozen=True)
class Samples:
    t_open: np.ndarray  # createRound time T, unix seconds
    x_int: np.ndarray  # (n, 16) contract features
    raw_diff: np.ndarray  # (n, 16) segment-mean differences before CLAMP, ticks
    rv: np.ndarray  # window realized vol, tick^2
    lag_rv: np.ndarray  # realized vol of the hour ending at T, tick^2

    def __len__(self):
        return len(self.rv)

    def take(self, mask):
        return Samples(*(a[mask] for a in (self.t_open, self.x_int, self.raw_diff, self.rv,
                                            self.lag_rv)))


def load_grid(path):
    with Path(path).open(newline="") as f:
        rows = list(csv.reader(f))
    if rows[0] != ["timestamp", "tick_cumulative"]:
        raise ValueError(f"{path}: expected header timestamp,tick_cumulative, got {rows[0]}")
    grid = {int(t): int(c) for t, c in rows[1:]}
    if not grid:
        raise ValueError(f"{path}: empty grid")
    return grid


def build_samples(grid, stride=60, lead=LEAD_S, delta=cm.DELTA):
    """Every round whose 18 history and 13 window checkpoints all lie on the grid."""
    times = sorted(grid)
    first, last = times[0], times[-1]
    hist_span = (cm.N_FEATURES + 1) * delta
    t = first + hist_span
    out = {"t_open": [], "x_int": [], "raw_diff": [], "rv": [], "lag_rv": []}
    while t + lead + cm.N_SEGMENTS * delta <= last:
        hist = [grid.get(t - (cm.N_FEATURES + 1 - i) * delta) for i in range(cm.N_FEATURES + 2)]
        win = [grid.get(t + lead + k * delta) for k in range(cm.N_SEGMENTS + 1)]
        if None not in hist and None not in win:
            means = [cm.floor_div(hist[j + 1] - hist[j], delta) for j in range(len(hist) - 1)]
            out["t_open"].append(t)
            out["x_int"].append(cm.features_from_cumulatives(hist, delta))
            out["raw_diff"].append([means[j + 1] - means[j] for j in range(len(means) - 1)])
            out["rv"].append(cm.realized_vol_from_cumulatives(win, delta))
            out["lag_rv"].append(
                cm.realized_vol_from_cumulatives(hist[-(cm.N_SEGMENTS + 1):], delta))
        t += stride
    return Samples(*(np.asarray(out[k], np.int64) for k in Samples.__dataclass_fields__))


def reads(t_open, lead=LEAD_S, delta=cm.DELTA):
    """First and last second a sample opened at t_open reads."""
    return t_open - (cm.N_FEATURES + 1) * delta, t_open + lead + cm.N_SEGMENTS * delta


def split_by_time(t_open, cuts, lead=LEAD_S, delta=cm.DELTA):
    """Chronological period masks at the given cut timestamps: period i holds the samples whose
    whole read span lies in [cuts[i-1], cuts[i]). Samples straddling a cut are dropped, so no
    second is read by two periods and nothing before a cut depends on data after it."""
    first, last = reads(t_open, lead, delta)
    edges = [-np.inf, *cuts, np.inf]
    return [(first >= lo) & (last < hi) for lo, hi in zip(edges, edges[1:], strict=False)]
