"""Demo pipeline: run every M1 bot, degrading instead of failing.

``run_all_bots`` is the single entry point the M1 demo calls: naive, EWMA and
TimesFM over the same history and bucket bounds, one result entry per bot.

Degradation rule: a TimesFM failure never blocks the demo. Naive and EWMA are
the guaranteed fallback (pure stdlib math over in-memory data — for valid
inputs they cannot fail, so a failure there is a real bug and is deliberately
not caught); every TimesFM failure mode (unavailable model backend,
``TsfmUnavailable``, subprocess crash, timeout, malformed output) becomes a
state entry with ``available: False`` while the demo continues on naive/EWMA.

Result shape (deliberate asymmetry): the ``naive`` and ``ewma`` entries are
bare probability vectors — ``list[int]`` with ``len(bounds) + 1`` entries in
``[0, 1e18]`` summing to exactly ``1e18``, on the ``PROB_SCALE = 10**18``
scale defined in ``agents_bots.probability`` — so the demo reads the available
bots directly from the plain entries. The ``tsfm`` entry is always a state
dict ``{"bot": "tsfm", "available": bool, ...}`` (plus ``"probs"`` on success,
``"error"`` on failure): it must stay distinguishable from a probability
vector when the subprocess backend is down.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence

from agents_bots import ewma, naive
from agents_bots.probability import DEFAULT_BOUNDS


def run_all_bots(
    history: Sequence[int],
    horizon: int = 1,
    bounds: Sequence[int] = DEFAULT_BOUNDS,
    tsfm_command: Sequence[str] | None = None,
    tsfm_timeout: float = 120.0,
) -> dict[str, list[int] | dict]:
    """Run the naive, EWMA and TimesFM bots over one history and bucket set.

    Args:
        history: base-fee values in wei, oldest first; forwarded verbatim to
            every bot (validation lives in the bots).
        horizon: blocks ahead to forecast; only 1 is modeled, the parameter
            exists for interface uniformity across bots.
        bounds: strictly increasing bucket bounds in wei; every vector has
            ``len(bounds) + 1`` entries.
        tsfm_command: argv list for the TimesFM inference subprocess, or
            ``None`` for the default model venv command.
        tsfm_timeout: seconds to wait for the TimesFM subprocess.

    Returns:
        ``{"naive": [...], "ewma": [...], "tsfm": {...}}`` in that order. The
        naive/ewma values are bare 1e18-scale probability vectors (see module
        docstring); the tsfm value is a state dict, ``available`` with
        ``"probs"`` or not with ``"error"``.

    Raises:
        Whatever naive/ewma raise: they are the guaranteed fallback, so their
        failures propagate (a failure there is a real bug, not a degradation).
    """
    results: dict[str, list[int] | dict] = {
        "naive": naive.forecast(history, horizon=horizon, bounds=bounds),
        "ewma": ewma.forecast(history, horizon=horizon, bounds=bounds),
    }
    # Lazy import: the TSFM backend is optional, so even its import failure is
    # a degradation, and any exception from the call (TsfmUnavailable included)
    # must become a state entry rather than abort the fallback bots' results.
    try:
        from agents_bots import tsfm

        tsfm_probs = tsfm.forecast(
            history,
            horizon=horizon,
            bounds=bounds,
            command=tsfm_command,
            timeout=tsfm_timeout,
        )
    except Exception as exc:
        results["tsfm"] = {"available": False, "bot": "tsfm", "error": str(exc)}
    else:
        results["tsfm"] = {"available": True, "bot": "tsfm", "probs": tsfm_probs}
    return results


def format_results(results: Mapping[str, list[int] | dict]) -> str:
    """Render a ``run_all_bots`` result for the demo transcript.

    One line per bot in result order: ``"<bot>: <probs>"`` for a probability
    vector or an available state dict, ``"<bot>: unavailable (<error>)"`` for
    an unavailable one. The final line ``"available bots: ..."`` lists the
    bots whose entry is a bare vector or an ``available`` state dict — the
    demo's degradation transcript (TSFM down, naive/EWMA answering) reads off
    this summary.
    """
    lines: list[str] = []
    available: list[str] = []
    for bot, entry in results.items():
        if isinstance(entry, dict):
            if entry.get("available"):
                lines.append(f"{bot}: {entry.get('probs')}")
                available.append(str(bot))
            else:
                lines.append(f"{bot}: unavailable ({entry.get('error', 'unknown error')})")
        else:
            lines.append(f"{bot}: {entry}")
            available.append(str(bot))
    lines.append("available bots: " + ", ".join(available))
    return "\n".join(lines)
