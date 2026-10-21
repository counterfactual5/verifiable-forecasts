"""TimesFM adapter: client for the out-of-process inference runner.

The model never runs in this interpreter. :func:`forecast` spawns ``command``
(by default the model venv's python executing ``agents/scripts/tsfm_runner.py``),
writes one JSON request line to its stdin and reads one JSON response line from
its stdout. Every way that process can fail — missing executable, non-zero
exit, timeout, unparseable or invalid output — surfaces as
:class:`TsfmUnavailable`: a malformed or crashed runner is an availability
failure, not a crash of the bot. This module never retries; callers decide.

JSON stdio protocol (data contract — field names must not change):

    request  (client -> runner stdin, one line, "\\n"-terminated):
        {"history": [<base fee in wei (int)>, ...],
         "horizon": <blocks ahead (int)>,
         "bounds":  [<bucket bound in wei (int)>, ...],
         "weights": [<hint on the 1e9 scale (int)>, ...]}
    "weights" carries exactly ``len(bounds) + 1`` entries in ``[0, 1e9]``
    summing to exactly ``1e9``; this client always sends a uniform split. The
    real runner ignores the hint and derives its own distribution from the
    model, but the pinned M1 acceptance stub builds its response by scaling
    the hint by 1e9, so a hint that does not sum to exactly 1e9 would make
    stubbed runs return an invalid vector.

    response (runner -> client stdout, one line, "\\n"-terminated):
        {"probs": [<probability on the 1e18 scale (int)>, ...]}
        {"error": "<message>"}     -- runner failed; carries no "probs" key

The response vector has ``len(bounds) + 1`` entries in ``[0, 1e18]`` summing
to exactly ``1e18`` — the probability scale ``BaseFeeMarket.recordPrediction``
enforces (1.0 == 10**18). The client reads the runner's JSON as the last
non-empty stdout line so library banners printed above it are ignored.

Stdlib-only on purpose, so the client stays importable and stub-testable no
matter what happens to the rest of the package.
"""

from __future__ import annotations

import json
import os
import subprocess
from collections.abc import Sequence
from typing import Final

# Probability scale of the response vector: a probability of 1.0 is the
# integer 10**18. Same value as agents_bots.probability.PROB_SCALE, restated
# here to keep this module stdlib-only.
PROB_SCALE: Final[int] = 10**18

# Scale of the request "weights" hint (see module docstring): the hint is a
# probability vector on a 1e9 scale, so the acceptance stub's ``hint * 1e9``
# response lands exactly on the 1e18 probability scale.
WEIGHT_SCALE: Final[int] = 10**9

# Interpreter of the model venv that has timesfm installed; the default
# command runs the protocol runner with it.
DEFAULT_MODEL_PYTHON: Final[str] = os.path.expanduser(
    "~/Work/chronos-experiment/.venv/bin/python"
)

# The runner script, resolved relative to this file (src/agents_bots/ ->
# ../../scripts/tsfm_runner.py) so the default command works from any cwd.
_RUNNER_PATH: Final[str] = os.path.normpath(
    os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "tsfm_runner.py"
    )
)

_DEFAULT_COMMAND: Final[tuple[str, str]] = (DEFAULT_MODEL_PYTHON, _RUNNER_PATH)

# M1 demo bucket bounds in wei (1, 1.5, 2.5, 4 gwei); same values as
# agents_bots.probability.DEFAULT_BOUNDS, restated to keep this module
# stdlib-only. Production callers pass the calibrated bounds instead.
_DEFAULT_BOUNDS: Final[tuple[int, ...]] = (
    1_000_000_000,
    1_500_000_000,
    2_500_000_000,
    4_000_000_000,
)


class TsfmUnavailable(RuntimeError):
    """The TimesFM inference process is unusable.

    Raised when the runner command cannot start, times out, exits non-zero,
    or answers with anything but a valid ``{"probs": [...]}`` line. Callers
    should degrade to the naive/EWMA bots, not crash.
    """


def _uniform_weights(n_buckets: int) -> list[int]:
    """Uniform hint on the WEIGHT_SCALE (1e9) scale, summing to exactly 1e9."""
    base, leftover = divmod(WEIGHT_SCALE, n_buckets)
    return [base + 1 if i < leftover else base for i in range(n_buckets)]


def forecast(
    history: Sequence[int],
    horizon: int = 1,
    bounds: Sequence[int] = _DEFAULT_BOUNDS,
    command: Sequence[str] | None = None,
    timeout: float = 120.0,
) -> list[int]:
    """Forecast via the TimesFM runner subprocess (JSON over stdio).

    Spawns ``command`` (argv list), sends the request schema documented in the
    module docstring on stdin, reads the response line from stdout and
    validates it: ``probs`` must be ``len(bounds) + 1`` ints on the 1e18
    probability scale, each in ``[0, 1e18]``, summing to exactly ``1e18``.
    ``command=None`` uses ``[DEFAULT_MODEL_PYTHON, <agents/scripts/tsfm_runner.py>]``.

    No retry happens here; callers own that policy.

    Args:
        history: base-fee values in wei (ints), oldest first; non-empty.
        horizon: blocks ahead to forecast; >= 1.
        bounds: bucket bounds in wei (ints), half-open buckets
            ``i = [bounds[i-1], bounds[i])`` matching ``BaseFeeMarket.bucketOf``.
        command: argv of the runner subprocess; injectable so tests can stub
            the model process (keeps the suite offline and deterministic).
        timeout: seconds to wait for the runner before giving up.

    Returns:
        ``len(bounds) + 1`` integer probabilities on the 1e18 scale summing
        to exactly ``1e18``.

    Raises:
        ValueError: on empty ``history``/``bounds``, ``horizon < 1`` or a
            non-int entry (the request schema carries ints only).
        TsfmUnavailable: on any subprocess or protocol failure.
    """
    hist = list(history)
    bnd = list(bounds)
    if not hist:
        raise ValueError("history must be non-empty")
    if any(isinstance(v, bool) or not isinstance(v, int) for v in hist):
        raise ValueError("history entries must be ints (wei)")
    if horizon < 1:
        raise ValueError("horizon must be >= 1")
    if not bnd:
        raise ValueError("bounds must be non-empty")
    if any(isinstance(b, bool) or not isinstance(b, int) for b in bnd):
        raise ValueError("bounds entries must be ints (wei)")

    cmd = list(command) if command is not None else list(_DEFAULT_COMMAND)
    n_buckets = len(bnd) + 1
    request = (
        json.dumps(
            {
                "history": hist,
                "horizon": horizon,
                "bounds": bnd,
                "weights": _uniform_weights(n_buckets),
            }
        )
        + "\n"
    )

    try:
        # The command is caller-scoped by design: the caller (or the default
        # model-venv argv) fully controls the argv, never user input.
        completed = subprocess.run(
            cmd,
            input=request,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise TsfmUnavailable(f"tsfm runner timed out after {timeout:g}s") from exc
    except subprocess.SubprocessError as exc:
        # Covers CalledProcessError and every other subprocess failure mode
        # beyond timeout; check=False makes the non-zero-exit path explicit
        # below instead.
        raise TsfmUnavailable(f"tsfm runner subprocess failed: {exc}") from exc
    except OSError as exc:
        raise TsfmUnavailable(f"tsfm runner command could not start {cmd[0]!r}: {exc}") from exc

    if completed.returncode != 0:
        err_lines = (completed.stderr or "").strip().splitlines()
        detail = err_lines[-1][:200] if err_lines else "no stderr output"
        raise TsfmUnavailable(f"tsfm runner exited with {completed.returncode}: {detail}")

    out_lines = [line for line in (completed.stdout or "").splitlines() if line.strip()]
    if not out_lines:
        raise TsfmUnavailable("tsfm runner wrote no JSON to stdout")
    raw = out_lines[-1]
    try:
        response = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise TsfmUnavailable(f"tsfm runner stdout is not valid JSON: {raw[:120]!r}") from exc

    if not isinstance(response, dict):
        raise TsfmUnavailable(f"tsfm runner response is not a JSON object: {raw[:120]!r}")
    probs = response.get("probs")
    if probs is None:
        error = response.get("error")
        reason = f": {error}" if isinstance(error, str) and error else ""
        raise TsfmUnavailable(f"tsfm runner returned no probabilities{reason}")
    if not isinstance(probs, list) or len(probs) != n_buckets:
        raise TsfmUnavailable(
            f"tsfm runner probs must be a list of {n_buckets} ints, got {probs!r:.120}"
        )
    for i, p in enumerate(probs):
        if isinstance(p, bool) or not isinstance(p, int):
            raise TsfmUnavailable(f"tsfm runner probs[{i}] is not an int: {type(p).__name__}")
        if not 0 <= p <= PROB_SCALE:
            raise TsfmUnavailable(f"tsfm runner probs[{i}]={p} outside [0, 1e18]")
    total = sum(probs)
    if total != PROB_SCALE:
        raise TsfmUnavailable(f"tsfm runner probs sum to {total}, expected exactly 1e18")
    return probs
