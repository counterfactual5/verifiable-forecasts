"""Off-chain mirror of VolFeeConsumer and the fee strategies the mainnet-fork replay compares.

Contract mirror (integer only, VolFeeConsumer.quote / _fee / _mix / _forecasts):
- mix[b] = floor(sum_i w_i * p_i[b] / W) for b < 4, the last bucket takes the remainder;
- w_i = max(reputation mean_i - baselineLogScore, 0); every revealed forecast weighs 1 when the
  market has no registry, any revealed model has no reputation, or all weights are 0;
- expectedVarE18 = sum_b mix[b] * bucketVar[b]; fee = expectedVarE18 * feePerVarE18 / 1e36 pips,
  clamped to [minFee, maxFee], maxFee when the product overflows uint256.

Fair fee (LVR break-even, Milionis et al. 2022): a CPMM loses sigma^2 / 8 of its value per unit
time to arbitrage; with concentrated liquidity the value at risk is the virtual 2 * L * sqrt(P).
The fee that pays that loss back over an hour is fair = LVR_hour / volume_hour.
"""

import math

from vol_agents import contract_math as cm

# Probability scale: forecast probs, the mix and log scores / reputation means are 1e18 = 1.
PROB_SCALE = 10**18
# expectedVarE18 (tick^2 * 1e18) times feePerVarE18 (pips per tick^2 * 1e18) carries 1e36.
VAR_FEE_SCALE = 10**36
UINT256_MAX = 2**256 - 1
REPUTATION_DECIMALS = 18
# Uniswap v3 fee units: 1 pip = 1e-6 of the swap amount, so 100 pips = 1 bp.
PIPS_PER_BPS = 100
PIPS = 10**6
# One tick is a factor 1.0001 of price, i.e. ln(1.0001) of log price.
LN_TICK = math.log(1.0001)
Q96 = 2**96
FAIR_DEFINITION = ("LVR break-even fee: (sigma_hour^2 / 8) * 2*L*sqrt(P) / hour's swap volume "
                   "in token1, sigma_hour^2 = real realized_vol * 18/11 * ln(1.0001)^2 (12/11 "
                   "to a full hour, 3/2 for the 2/3 variance of window-mean differences)")


def expected_var_e18(mix_e18, bucket_var):
    """sum_b mix[b] * bucketVar[b]: tick^2 scaled by 1e18."""
    return sum(int(m) * int(v) for m, v in zip(mix_e18, bucket_var, strict=True))


def fee_pips(expected_var_e18, fee_per_var_e18, min_fee, max_fee):
    if fee_per_var_e18 != 0 and expected_var_e18 > UINT256_MAX // fee_per_var_e18:
        return max_fee
    raw = expected_var_e18 * fee_per_var_e18 // VAR_FEE_SCALE
    return min(max(raw, min_fee), max_fee)


def fee_for_var(var_tick2, fee_per_var_e18, min_fee, max_fee):
    """Fee for a known variance in tick^2, the mix being all mass on that variance."""
    return fee_pips(int(var_tick2) * PROB_SCALE, fee_per_var_e18, min_fee, max_fee)


def reputation_mean(count, value, decimals):
    """VolFeeConsumer._decodeTupleSummary: (found, mean in 1e18) from a mainnet ERC-8004
    getSummary (count, value, decimals)."""
    if count == 0 or count > 2**64 - 1 or decimals > REPUTATION_DECIMALS:
        return False, 0
    if not -(2**127) <= value <= 2**127 - 1:
        return False, 0
    return True, value * 10 ** (REPUTATION_DECIMALS - decimals)


def forecast_weights(reputations, baseline, has_registry):
    """VolFeeConsumer._forecasts weights for the revealed forecasts, in predictor order.

    `reputations` holds (found, mean) per revealed forecast. Returns (weights, equal_fallback).
    Once one forecast has no reputation the contract stops reading the rest, which only matters
    because the result is then the equal-weight fallback anyway."""
    rated = has_registry
    weights = []
    for found, mean in reputations:
        w = 0
        if rated:
            rated = found
            if found and mean > baseline:
                w = mean - baseline
        weights.append(w)
    if not reputations:
        raise ValueError("no revealed forecasts")
    if not rated or sum(weights) == 0:
        return [1] * len(reputations), True
    return weights, False


def mix_e18(probs, weights):
    """VolFeeConsumer._mix: weighted mean of 1e18-scaled forecasts, rounded down per bucket, the
    last bucket taking the remainder so the mix sums to exactly 1e18."""
    total = sum(weights)
    mix = []
    for b in range(cm.BUCKETS - 1):
        mix.append(sum(w * int(p[b]) for w, p in zip(weights, probs, strict=True)) // total)
    return mix + [PROB_SCALE - sum(mix)]


def mirror_quote(forecasts, baseline, has_registry, bucket_var, fee_per_var_e18, min_fee,
                 max_fee):
    """Full VolFeeConsumer.quote from on-chain inputs. `forecasts` holds dicts with the revealed
    probs (1e18) and the model's reputation (found, mean)."""
    weights, fallback = forecast_weights([f["reputation"] for f in forecasts], baseline,
                                         has_registry)
    mix = mix_e18([f["probs"] for f in forecasts], weights)
    ev = expected_var_e18(mix, bucket_var)
    return {"fee_pips": fee_pips(ev, fee_per_var_e18, min_fee, max_fee), "mix_e18": mix,
            "expected_var_e18": ev, "weights": weights, "equal_weight_fallback": fallback}


def prev_hour_window(fee_ts, grid_origin, step=cm.DELTA, n_segments=cm.N_SEGMENTS):
    """The n_segments most recent complete grid segments at fee_ts: [from, to) with to the last
    grid time <= fee_ts, so no segment ends after the fee is set."""
    to = grid_origin + (fee_ts - grid_origin) // step * step
    return to - n_segments * step, to


def hourly_variance(rv_tick2, n_segments=cm.N_SEGMENTS):
    """Log-price variance over one hour from VolMarket's realized vol.

    rv sums n - 1 squared differences of consecutive time-averaged 5-minute ticks. For a
    Brownian log price the difference of adjacent window means has 2/3 of the point-to-point
    variance over the same spacing (Working 1960), so E[rv] = (n - 1) * 2/3 * sigma^2_5min and
    the hour's variance is rv * 3n / (2(n - 1)) (18/11 for n = 12), times ln(1.0001)^2 from
    tick^2 to log price^2."""
    return rv_tick2 * 3 * n_segments / (2 * (n_segments - 1)) * LN_TICK**2


def virtual_value_token1(liquidity, sqrt_price_x96):
    """2 * L * sqrt(P) in token1 base units (P = token1 per token0 in base units)."""
    return 2 * liquidity * sqrt_price_x96 / Q96


def fair_fee(rv_tick2, liquidity, sqrt_price_x96, volume_token1):
    """LVR break-even fee as a fraction of swap volume; volume in token1 base units."""
    if volume_token1 <= 0:
        raise ValueError("no swap volume")
    lvr = hourly_variance(rv_tick2) / 8 * virtual_value_token1(liquidity, sqrt_price_x96)
    return lvr / volume_token1


def calibrate(hours, bounds=cm.BOUNDS):
    """feePerVarE18 and bucketVar from calibration hours, each {rv, fair_pips}.

    feePerVarE18 is the ratio of sums: fee_for_var(rv) totals the fair fee over the hours.
    bucketVar[b] is the mean rv of the hours in bucket b; an empty bucket takes the midpoint of
    its bounds (bucket 0: half its upper bound, bucket 4: 1.5x its lower bound), then a running
    max keeps it non-decreasing."""
    total_rv = sum(h["rv"] for h in hours)
    if total_rv == 0:
        raise ValueError("calibration hours have no realized variance")
    fpv = round(sum(h["fair_pips"] for h in hours) * PROB_SCALE / total_rv)
    edges = [0, *bounds]
    fallback = [(edges[b] + edges[b + 1]) // 2 for b in range(len(bounds))] + [
        bounds[-1] * 3 // 2]
    bucket_var, sources = [], []
    for b in range(len(bounds) + 1):
        inside = [h["rv"] for h in hours if cm.bucket_of(h["rv"], bounds) == b]
        if inside:
            bucket_var.append(round(sum(inside) / len(inside)))
            sources.append(f"mean of {len(inside)} h")
        else:
            bucket_var.append(fallback[b])
            sources.append("edge rule")
    for b in range(1, len(bucket_var)):
        bucket_var[b] = max(bucket_var[b], bucket_var[b - 1])
    return fpv, bucket_var, sources


def mae(values, reference):
    return sum(abs(v - r) for v, r in zip(values, reference, strict=True)) / len(values)


def strategy_summary(fee_rows, strategies=("fixed", "prev_hour", "forecast")):
    fair = [f["fair_bps"] for f in fee_rows]
    out = {"rounds": len(fee_rows), "fair": FAIR_DEFINITION,
           "mae_bps": {k: mae([f[f"{k}_bps"] for f in fee_rows], fair) for k in strategies},
           "mean_bps": {"fair": sum(fair) / len(fair)}}
    for k in strategies:
        out["mean_bps"][k] = sum(f[f"{k}_bps"] for f in fee_rows) / len(fee_rows)
    return out
