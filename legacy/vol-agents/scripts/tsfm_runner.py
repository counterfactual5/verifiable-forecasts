"""TimesFM protocol runner: the process side of agents_bots.tsfm.

Runs INSIDE the model venv (~/Work/chronos-experiment/.venv, python 3.12 with
timesfm installed) — never imported by the agents package. It reads one JSON
request line on stdin, runs the model, and writes one JSON response line on
stdout (see agents_bots.tsfm for the schema, a data contract whose field names
must not change):

    request  (stdin, one line):  {"history": [wei ints], "horizon": int,
                                  "bounds": [wei ints], "weights": [1e9-scale ints]}
    response (stdout, one line): {"probs": [1e18-scale ints]} on success,
                                 {"error": "<msg>"} on any failure

This script may only import timesfm/numpy lazily inside main() so that plain
syntax checks pass in interpreters (and repos) where the model stack is absent;
module top level is stdlib-only.

Error policy, fixed here and matched by the client: on ANY exception the runner
still writes one ``{"error": ...}`` line and exits 0 — the client turns a
response without a "probs" key into TsfmUnavailable, so one code path carries
both model failures and protocol failures and stderr stays free for library
banners. A non-zero exit would say less (the message would be lost).

bucket_of and the largest-remainder 1e18 scaling are inlined copies of
agents_bots.probability on purpose: this script runs in a separate venv that
cannot import agents_bots, so sharing code across the boundary is impossible
(separate venv, no shared imports — duplicate ~20 lines, do not "fix").
"""

from __future__ import annotations

import json
import math
import os
import sys
from fractions import Fraction
from typing import TextIO

# Probability scale: a probability of 1.0 is the integer 10**18, matching
# BaseFeeMarket.recordPrediction and agents_bots.probability.PROB_SCALE.
PROB_SCALE = 10**18

MODEL_ID = "google/timesfm-3.0-pytorch"


def _bucket_of(value: int, bounds: list[int]) -> int:
    """Inline copy of agents_bots.probability.bucket_of (see module docstring).

    Half-open buckets matching BaseFeeMarket.bucketOf: bucket ``i`` covers
    ``[bounds[i-1], bounds[i])`` via "count of bounds <= value".
    """
    return sum(1 for b in bounds if b <= value)


def _weights_to_probs(weights: list[float]) -> list[int]:
    """Inline copy of agents_bots.probability.weights_to_probs (see module docstring).

    Largest-remainder scaling to the 1e18 probability scale on exact rational
    arithmetic: each weight gets ``floor(w / total * 1e18)``, the missing units
    go to the largest fractional parts (ties toward the lower index), so the
    result sums to exactly 10**18 with no rounding drift.
    """
    n = len(weights)
    exact = [Fraction(w) for w in weights]
    total = sum(exact)
    if total == 0:
        base, leftover = divmod(PROB_SCALE, n)
        return [base + 1 if i < leftover else base for i in range(n)]
    probs = []
    fracs = []
    for w in exact:
        scaled = w * PROB_SCALE / total
        floor = scaled.numerator // scaled.denominator
        probs.append(floor)
        fracs.append(scaled - floor)
    order = sorted(range(n), key=lambda i: (-fracs[i], i))
    for i in order[: PROB_SCALE - sum(probs)]:
        probs[i] += 1
    return probs


def _read_request(stdin: TextIO) -> dict:
    """Parse and validate the request line (schema in the module docstring)."""
    line = stdin.readline()
    if not line.strip():
        raise ValueError("no request line on stdin")
    request = json.loads(line)
    if not isinstance(request, dict):
        raise ValueError("request is not a JSON object")
    history = request.get("history")
    horizon = request.get("horizon")
    bounds = request.get("bounds")
    if not isinstance(history, list) or not history:
        raise ValueError("history must be a non-empty list of ints (wei)")
    if any(isinstance(v, bool) or not isinstance(v, int) for v in history):
        raise ValueError("history entries must be ints (wei)")
    if isinstance(horizon, bool) or not isinstance(horizon, int) or horizon < 1:
        raise ValueError("horizon must be an int >= 1")
    if not isinstance(bounds, list) or not bounds:
        raise ValueError("bounds must be a non-empty list of ints (wei)")
    if any(isinstance(b, bool) or not isinstance(b, int) for b in bounds):
        raise ValueError("bounds entries must be ints (wei)")
    return request


def _forecast_probs(history: list[int], horizon: int, bounds: list[int]) -> list[int]:
    """Run TimesFM and turn its point forecasts into a bucket probability vector.

    Predicts ``horizon`` steps ahead, averages the point forecasts into one
    float, buckets it (floored to int wei first, like the EWMA bot) and smears
    weight 1.0 on that bucket plus 0.5 on each adjacent bucket that exists
    (indices clipped, same shape as the EWMA bot with spread=1), then scales to
    the 1e18 probability scale.

    Imports numpy/timesfm lazily (module docstring); HF_HUB_OFFLINE must be set
    before timesfm loads so from_pretrained never touches the network.
    """
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    import numpy as np
    from timesfm import TimesFM3Forecaster

    forecaster = TimesFM3Forecaster.from_pretrained(MODEL_ID)
    out = forecaster.predict(
        np.asarray(history, dtype=np.float32), horizon=horizon, return_quantiles=True
    )
    mean = float(np.asarray(out.forecast).mean())

    center = _bucket_of(math.floor(mean), bounds)
    weights = [0.0] * (len(bounds) + 1)
    weights[center] = 1.0
    if center - 1 >= 0:
        weights[center - 1] = 0.5
    if center + 1 <= len(bounds):
        weights[center + 1] = 0.5
    return _weights_to_probs(weights)


def main(stdin: TextIO = sys.stdin, stdout: TextIO = sys.stdout) -> int:
    """Serve exactly one request; streams are parameters for testability.

    Always writes one JSON line and returns exit status 0 — including on
    failure, as ``{"error": ...}`` (policy documented in the module docstring).
    """
    try:
        request = _read_request(stdin)
        probs = _forecast_probs(
            request["history"], request["horizon"], request["bounds"]
        )
        payload: dict[str, object] = {"probs": probs}
    except Exception as exc:
        # Protocol boundary: model and validation failures alike become one
        # {"error": ...} line, exit 0 (policy in the module docstring).
        payload = {"error": f"{type(exc).__name__}: {exc}"[:500]}
    stdout.write(json.dumps(payload) + "\n")
    stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
