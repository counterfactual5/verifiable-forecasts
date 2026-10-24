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


# MarketMath.expWad on anvil (MarketMathHarness), bit for bit
EXP_WAD_ONCHAIN = {
    0: E18,
    E18: 2718281828459045222,
    -E18: 367879441171442320,
    6802394763324311192: 900000000000000400384,
    60 * E18: 114200738981568432182289306956157274397081600,
    -20 * E18: 2061153622,
    -41999999999999999999: 0,
    4691400000000000000: 109005680985062189824,
    123456789012345678: 1131401114526201512,
    -987654321098765432: 372449313672523958,
    7276611328125000000: 1446079424318681864192,
}


def test_exp_wad_mirrors_the_contract_bit_for_bit():
    for x, want in EXP_WAD_ONCHAIN.items():
        assert fs.exp_wad(x) == want, x
    assert fs.exp_wad(-42 * E18 - 1) == 0
    with pytest.raises(ValueError):
        fs.exp_wad(fs.EXP_MAX + 1)


def test_midpoint_weights_cover_the_unit_interval():
    w = fs.midpoint_weights([E18 // 10, E18 // 4, E18 // 2, 3 * E18 // 4, 9 * E18 // 10])
    assert w == [E18 // 8, E18 // 5, E18 // 4, E18 // 5, E18 // 8]
    assert sum(w) == 9 * E18 // 10


def test_expected_var_and_fee_for_var_agree():
    # every quantile at ln 900: E[RV] = 900 tick^2 up to expWad's rounding
    q = 6802394763324311192
    ev = fs.expected_var_e18([q] * 5)
    assert ev == 900000000000000400384
    assert fs.fee_pips(ev, 2 * E18, 0, 10**6) == fs.fee_for_var(900, 2 * E18, 0, 10**6) == 1800
    # midpoint-weighted mean of exp(q_k)
    mix = [0, E18, -E18, 60 * E18, 4691400000000000000]
    w = [E18 // 8, E18 // 5, E18 // 4, E18 // 5, E18 // 8]
    want = sum(o * EXP_WAD_ONCHAIN[m] for o, m in zip(w, mix, strict=True)) // sum(w)
    assert fs.expected_var_e18(mix) == want


def test_mix_is_vincentization_truncated_toward_zero():
    qs = [[-5, 10, 20, 30, 41], [-6, 12, 22, 31, 40]]
    # (2 * -5 + -6) / 3 = -16 / 3 truncates to -5 (Solidity sdiv), not floor -6
    assert fs.mix_e18(qs, [2, 1]) == [-5, 32 // 3, 62 // 3, 91 // 3, 122 // 3]
    assert fs.mix_e18(qs, [1, 1]) == [-5, 11, 21, 30, 40]


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
    ln900 = 6802394763324311192
    forecasts = [{"quantiles": [ln900 - 2 * E18] * 5, "reputation": (False, 0)},
                 {"quantiles": [ln900 + 2 * E18] * 5, "reputation": (True, 0)}]
    levels = [E18 // 10, E18 // 4, E18 // 2, 3 * E18 // 4, 9 * E18 // 10]
    q = fs.mirror_quote(forecasts, -E18, True, levels, E18, 0, 10_000)
    assert q["equal_weight_fallback"] and q["weights"] == [1, 1]
    assert q["mix_e18"] == [ln900] * 5
    assert q["expected_var_e18"] == 900000000000000400384
    assert q["fee_pips"] == 900
    # reputation above the baseline weighs the second forecast only
    forecasts[0]["reputation"] = (True, -2 * E18)
    q = fs.mirror_quote(forecasts, -E18, True, levels, E18, 0, 10_000)
    assert not q["equal_weight_fallback"] and q["mix_e18"] == [ln900 + 2 * E18] * 5


def test_reputation_mean_decoding():
    assert fs.reputation_mean(0, -E18, 18) == (False, 0)
    assert fs.reputation_mean(3, -15, 1) == (True, -15 * 10**17)
    assert fs.reputation_mean(3, -15, 19) == (False, 0)


def test_reputation_mean_decimals_bounds():
    assert fs.reputation_mean(3, -15, 18) == (True, -15)
    assert fs.reputation_mean(3, -15, 0) == (True, -15 * E18)


def test_reputation_mean_count_fits_uint64():
    assert fs.reputation_mean(2**64 - 1, -E18, 18) == (True, -E18)
    assert fs.reputation_mean(2**64, -E18, 18) == (False, 0)


@pytest.mark.parametrize("value,want", [
    (2**127 - 1, (True, 2**127 - 1)),
    (-(2**127), (True, -(2**127))),
    (2**127, (False, 0)),
    (-(2**127) - 1, (False, 0)),
])
def test_reputation_mean_value_fits_int128(value, want):
    assert fs.reputation_mean(1, value, 18) == want


@pytest.mark.parametrize("has_registry", [True, False])
def test_forecast_weights_rejects_no_revealed_forecasts(has_registry):
    with pytest.raises(ValueError, match="no revealed forecasts"):
        fs.forecast_weights([], -E18, has_registry)


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
