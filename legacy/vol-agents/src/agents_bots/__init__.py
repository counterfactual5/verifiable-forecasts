"""Forecast bots for the basefee market (M1): naive and EWMA baselines.

Every bot exposes ``forecast(history, horizon, bounds) -> list[int]`` returning
integer probabilities on the 1e18 scale over ``len(bounds) + 1`` half-open
buckets; see ``agents_bots.probability`` for the shared conventions.
"""

__all__ = ["ewma", "naive", "probability"]
