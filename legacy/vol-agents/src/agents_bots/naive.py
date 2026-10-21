"""Naive window-mean forecast bot.

Point forecast: the integer mean of the last ``window`` base fees (wei) is
assumed to persist, and all probability mass goes to the half-open bucket
containing that mean, emitted as integers on the 1e18 scale summing to exactly
1e18.
"""

from __future__ import annotations

from collections.abc import Sequence

from agents_bots.probability import DEFAULT_BOUNDS, bucket_of, weights_to_probs


def forecast(
    history: Sequence[int],
    horizon: int = 1,
    bounds: Sequence[int] = DEFAULT_BOUNDS,
    window: int = 50,
) -> list[int]:
    """Deterministic point forecast over the bucket probability vector.

    Takes the last ``window`` values of ``history`` (all of them when history
    is shorter), computes the integer mean ``sum // len`` (floor division,
    integer-only wei math) and puts weight 1.0 on the half-open bucket
    ``[bounds[i-1], bounds[i])`` containing that mean. Returns ``len(bounds) + 1``
    integer probabilities on the 1e18 scale (``PROB_SCALE``) summing to exactly
    1e18.

    Args:
        history: base-fee values in wei, oldest first; must be non-empty.
        horizon: blocks ahead to forecast; only 1 is modeled (the window mean
            is assumed persistent), the parameter exists for interface
            uniformity across bots. Must be >= 1.
        bounds: strictly increasing bucket bounds in wei.
        window: number of trailing blocks averaged; must be >= 1.

    Raises:
        ValueError: on empty ``history`` or ``bounds``, ``window < 1`` or
            ``horizon < 1``.
    """
    if not history:
        raise ValueError("history must be non-empty")
    if not bounds:
        raise ValueError("bounds must be non-empty")
    if window < 1:
        raise ValueError("window must be >= 1")
    if horizon < 1:
        raise ValueError("horizon must be >= 1")

    recent = history[-window:]
    mean = sum(recent) // len(recent)
    weights = [0.0] * (len(bounds) + 1)
    weights[bucket_of(mean, bounds)] = 1.0
    return weights_to_probs(weights)
