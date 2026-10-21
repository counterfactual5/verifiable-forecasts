"""Probability-vector helpers shared by every forecast bot.

Conventions fixed here and stated once (they mirror the contract):

* ``PROB_SCALE = 10**18``: a probability of 1.0 is the integer ``10**18``.
  ``BaseFeeMarket.recordPrediction`` requires ``len(bounds) + 1`` entries in
  ``[0, 1e18]`` summing to exactly ``1e18``.
* Buckets are half-open intervals over base fees in wei, matching
  ``BaseFeeMarket.bucketOf``: bucket ``i = [bounds[i-1], bounds[i])``, bucket 0
  is ``(-inf, bounds[0])`` and the last bucket is ``[bounds[n-1], +inf)``.
"""

from __future__ import annotations

from collections.abc import Sequence
from fractions import Fraction
from typing import Final

PROB_SCALE: Final[int] = 10**18

# M1 demo bucket bounds in wei (1, 1.5, 2.5, 4 gwei). Production callers pass
# the calibrated bounds from the analysis output instead of this default.
DEFAULT_BOUNDS: Final[tuple[int, ...]] = (
    1_000_000_000,
    1_500_000_000,
    2_500_000_000,
    4_000_000_000,
)


def bucket_of(value: int, bounds: Sequence[int]) -> int:
    """Index of the half-open bucket containing ``value`` (base fee in wei).

    Returns the number of bounds that are ``<= value``, which reproduces
    ``BaseFeeMarket.bucketOf`` for strictly increasing ``bounds``: bucket 0
    catches ``value < bounds[0]``, bucket ``i`` catches
    ``bounds[i-1] <= value < bounds[i]``, and the return value ``len(bounds)``
    catches ``value >= bounds[-1]``.
    """
    return sum(1 for b in bounds if b <= value)


def weights_to_probs(weights: Sequence[float]) -> list[int]:
    """Convert non-negative float weights to integer probabilities on the 1e18 scale.

    Returns one entry per weight, each in ``[0, PROB_SCALE]``, summing to
    exactly ``PROB_SCALE`` (10**18), so the vector satisfies
    ``recordPrediction``. Largest-remainder method on exact rational arithmetic
    (``Fraction`` holds each float's exact binary value, so rounding drift can
    never push the sum off 1e18): each weight gets
    ``floor(weight / total * 1e18)`` and the missing units go to the largest
    fractional parts, ties resolved toward the lower index. An all-zero input
    splits ``1e18`` as evenly as possible, leftover units to the lowest indexes.

    Raises:
        ValueError: on empty ``weights`` or any negative weight.
    """
    if not weights:
        raise ValueError("weights must be non-empty")
    if any(w < 0 for w in weights):
        raise ValueError("weights must be non-negative")

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
    # Ties on the fractional part go to the lower index.
    order = sorted(range(n), key=lambda i: (-fracs[i], i))
    for i in order[: PROB_SCALE - sum(probs)]:
        probs[i] += 1
    return probs


def normalize_weights(values: Sequence[float]) -> list[float]:
    """Divide non-negative values by their sum.

    Returns ``0.0`` for every entry when the sum is zero; the result is meant
    to feed ``weights_to_probs``, which applies the 1e18 scaling.
    """
    total = sum(values)
    if total == 0:
        return [0.0 for _ in values]
    return [v / total for v in values]
