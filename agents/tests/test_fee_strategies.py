import math

import pytest

from vol_agents import fee_strategies as fs

E18 = 10**18


def test_fee_is_linear_then_clamped():
    fpv = 2 * E18  # 2 pips per tick^2
    assert fs.fee_for_var(300, fpv, 100, 10_000) == 600
    assert fs.fee_for_var(10, fpv, 100, 10_000) == 100
    assert fs.fee_for_var(6_000, fpv, 100, 10_000) == 10_000
    assert fs.fee_pips(299 * E18 + E18 // 2, fpv, 0, 10_000) == 599


def test_fee_overflow_clamps_to_max_instead_of_reverting():
    fpv = 3 * E18
    big = fs.UINT256_MAX // fpv + 1
    assert fs.fee_pips(big, fpv, 100, 10_000) == 10_000
    assert fs.fee_pips(big, 0, 100, 10_000) == 100


def test_expected_var_and_fee_for_var_agree():
    bucket_var = [100, 300, 600, 1200, 2500]
    mix = [0, 0, E18, 0, 0]
    assert fs.expected_var_e18(mix, bucket_var) == 600 * E18
    assert fs.fee_pips(600 * E18, 5 * E18 // 3, 0, 10**6) == fs.fee_for_var(600, 5 * E18 // 3,
                                                                           0, 10**6)


def test_mix_rounds_down_and_last_bucket_takes_remainder():
    probs = [[E18 // 3, E18 // 3, E18 // 3, 0, E18 - 3 * (E18 // 3)],
             [0, E18 // 2, 0, E18 // 2, 0]]
    mix = fs.mix_e18(probs, [2, 1])
    assert mix[0] == 2 * (E18 // 3) // 3
    assert mix[1] == (2 * (E18 // 3) + E18 // 2) // 3
    assert mix[3] == (E18 // 2) // 3
    assert sum(mix) == E18
    assert mix[4] == E18 - sum(mix[:4])


def test_weights_are_reputation_above_baseline():
    base = -1_609 * E18 // 1000
    w, fallback = fs.forecast_weights([(True, -E18), (True, -2 * E18)], base, True)
    assert (w, fallback) == ([base * -1 - E18, 0], False)


@pytest.mark.parametrize("reps,has_registry", [
    ([(True, -E18), (False, 0)], True),        # one revealed model unrated
    ([(False, 0), (True, -E18)], True),
    ([(True, -2 * E18), (True, -3 * E18)], True),  # every weight 0
    ([(True, -E18), (True, -E18)], False),     # no registry
])
def test_equal_weight_fallback(reps, has_registry):
    w, fallback = fs.forecast_weights(reps, -1_609 * E18 // 1000, has_registry)
    assert fallback and w == [1, 1]


def test_mirror_quote_end_to_end():
    forecasts = [{"probs": [E18, 0, 0, 0, 0], "reputation": (False, 0)},
                 {"probs": [0, 0, 0, 0, E18], "reputation": (True, 0)}]
    q = fs.mirror_quote(forecasts, -E18, True, [100, 200, 300, 400, 500], E18, 0, 10_000)
    assert q["equal_weight_fallback"]
    assert q["mix_e18"] == [E18 // 2, 0, 0, 0, E18 // 2]
    assert q["expected_var_e18"] == 300 * E18
    assert q["fee_pips"] == 300


def test_reputation_mean_decoding():
    assert fs.reputation_mean(0, -E18, 18) == (False, 0)
    assert fs.reputation_mean(3, -15, 1) == (True, -15 * 10**17)
    assert fs.reputation_mean(3, -15, 19) == (False, 0)


@pytest.mark.parametrize("fee_ts", [100_000 - 30, 100_000 - 1, 100_000 - 300, 100_000 - 299])
def test_prev_hour_window_never_passes_fee_time(fee_ts):
    origin = 100_000 - 18 * 300
    lo, hi = fs.prev_hour_window(fee_ts, origin)
    assert hi <= fee_ts < hi + 300
    assert hi - lo == 12 * 300 and (hi - origin) % 300 == 0


def test_prev_hour_window_at_round_start_grid():
    start = 3600 * 1000
    assert fs.prev_hour_window(start - 30, start - 5400) == (start - 13 * 300, start - 300)


def test_hourly_variance_corrects_for_window_means():
    # 11 diffs of 5-minute means, each with 2/3 of the point variance: 11 -> 12 * 3/2 = 18.
    assert fs.hourly_variance(11) == pytest.approx(18 * fs.LN_TICK**2, rel=1e-12)
    assert fs.hourly_variance(5, n_segments=6) == pytest.approx(9 * fs.LN_TICK**2, rel=1e-12)


def test_fair_fee_hand_computed():
    # P = 1 (sqrtPriceX96 = 2^96), L = 1e6: V = 2e6. rv = 1100 tick^2 -> 1800 tick^2 per hour.
    var_h = 1800 * math.log(1.0001) ** 2
    want = var_h / 8 * 2e6 / 5e6
    assert fs.fair_fee(1100, 10**6, 2**96, 5 * 10**6) == pytest.approx(want, rel=1e-12)
    with pytest.raises(ValueError):
        fs.fair_fee(1100, 10**6, 2**96, 0)


def test_calibrate_ratio_of_sums_and_monotone_buckets():
    hours = [{"rv": 100, "fair_pips": 50}, {"rv": 300, "fair_pips": 250},
             {"rv": 2000, "fair_pips": 900}]
    fpv, bucket_var, sources = fs.calibrate(hours)
    assert fpv == 1200 * E18 // 2400
    assert bucket_var == [100, 300, 665, 1284, 2000]
    assert bucket_var == sorted(bucket_var)
    assert sources[2] == "edge rule"


def test_mae_and_summary():
    rows = [{"fair_bps": 1.0, "fixed_bps": 5, "prev_hour_bps": 2.0, "forecast_bps": 1.5},
            {"fair_bps": 3.0, "fixed_bps": 5, "prev_hour_bps": 1.0, "forecast_bps": 3.0}]
    s = fs.strategy_summary(rows)
    assert s["rounds"] == 2
    assert s["mae_bps"] == {"fixed": 3.0, "prev_hour": 1.5, "forecast": 0.25}
    assert s["mean_bps"] == {"fair": 2.0, "fixed": 5.0, "prev_hour": 1.5, "forecast": 2.25}
