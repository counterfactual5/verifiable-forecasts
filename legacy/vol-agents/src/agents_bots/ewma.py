"""EWMA forecast bot.

Exponentially weighted mean over the base-fee history with fixed decay
``alpha``; the final mean is the point estimate, smeared over its half-open
bucket and the neighboring buckets so the bot is not a pure point mass.
"""

from __future__ import annotations

import math
from collections.abc import Sequence

from agents_bots.probability import DEFAULT_BOUNDS, bucket_of, weights_to_probs


def forecast(
    history: Sequence[int],
    horizon: int = 1,
    bounds: Sequence[int] = DEFAULT_BOUNDS,
    alpha: float = 0.2,
    spread: int = 1,
) -> list[int]:
    """EWMA forecast over the bucket probability vector.

    Iterates ``m = alpha * value + (1 - alpha) * m`` starting at
    ``m = history[0]`` (float internal math; history stays integer wei and no
    float ever enters a wei value — ``m`` is only used for bucketing, floored
    to an int first). The final ``m`` selects the center bucket under the
    half-open rule ``bucket i = [bounds[i-1], bounds[i])``. Weight
    ``1 / (distance + 1)`` goes on every bucket within ``spread`` of the center
    (``spread = 1``: 1.0 on the center bucket, 0.5 on each adjacent bucket
    that exists), indices clipped to the valid range ``[0, len(bounds)]``.
    Returns ``len(bounds) + 1`` integer probabilities on the 1e18 scale
    (``PROB_SCALE``) summing to exactly 1e18.

    Args:
        history: base-fee values in wei, oldest first; must be non-empty.
        horizon: blocks ahead to forecast; only 1 is modeled, the parameter
            exists for interface uniformity across bots. Must be >= 1.
        bounds: strictly increasing bucket bounds in wei.
        alpha: decay factor in ``(0, 1]``; higher weights recent blocks more.
        spread: how many buckets around the center receive weight; >= 1.

    Raises:
        ValueError: on empty ``history`` or ``bounds``, ``horizon < 1``,
            ``alpha`` outside ``(0, 1]`` or ``spread < 1``.
    """
    if not history:
        raise ValueError("history must be non-empty")
    if not bounds:
        raise ValueError("bounds must be non-empty")
    if horizon < 1:
        raise ValueError("horizon must be >= 1")
    if not 0 < alpha <= 1:
        raise ValueError("alpha must be in (0, 1]")
    if spread < 1:
        raise ValueError("spread must be >= 1")

    m = float(history[0])
    for value in history[1:]:
        m = alpha * value + (1.0 - alpha) * m

    center = bucket_of(math.floor(m), bounds)
    weights = [0.0] * (len(bounds) + 1)
    for offset in range(-spread, spread + 1):
        idx = center + offset
        if 0 <= idx <= len(bounds):
            weights[idx] += 1.0 / (abs(offset) + 1)
    return weights_to_probs(weights)
