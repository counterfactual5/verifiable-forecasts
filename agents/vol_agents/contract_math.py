"""Off-chain mirror of the VolMarket arithmetic the agents depend on.

Features (VolMarket._features): 17 segment means b_j = floorDiv(C_{j+1} - C_j, delta) before
createRound, f_j = b_{j+1} - b_j, x_int_j = clamp(f_j, -64, 64) * 128; the model input is
x = x_int / 4096 (EZKL input_scale 12). Negative public inputs are encoded as R - |x|.

Realized vol (VolMarket._realizedVol): over the nSegments + 1 checkpoints of the window,
rv = floor(sum (mean_{i+1} - mean_i)^2 * (nSegments - 1) / m); bucket = #bounds <= rv.

Commitment (VolMarket.commitPrediction): keccak256(abi.encode(roundId, modelId, int256[] outputs,
salt, sender)); outputs is dynamic, so the head holds its offset and the tail its length and words.

Quantile forecasts: K signed outputs[k] = q_k * 2^OUTPUT_SCALE_BITS (q_k in ln tick^2 units of the
target y = ln(max(RV, RV_FLOOR))); onchain value q_e18 = outputs[k] * (1e18 >> OUTPUT_SCALE_BITS).
Scored by the pinball loss at QUANTILE_LEVELS_E18 (pinball_e18 mirrors MarketMath.pinball).
"""

import math
from decimal import Decimal, localcontext

R = 21888242871839275222246405745257275088548364400416034343698204186575808495617
DELTA = 300
N_SEGMENTS = 12
N_FEATURES = 16
BUCKETS = 5
SCALE = 4096
CLAMP = 64
MULT = 128
# tick^2: p20/p40/p60/p80 of the hourly realized vol in the training period (2026-09-10 .. 10-08,
# analysis vol_calibrate.py --until); passed to createRound, never stored in the contract
BOUNDS = (202, 474, 856, 1712)
PROB_SCALE = 10**18  # VolMarket probabilities: 1e18 = 1
MAX_OUTPUT = (2**256 - 1) // PROB_SCALE  # VolMarket.MAX_OUTPUT, below R / 2

WAD = 10**18  # 1e18 = 1.0 for quantile levels, ln values and losses
OUTPUT_SCALE_BITS = 12  # outputs are q * 2^12, equal to EZKL model_output_scales [12]
OUTPUT_UNIT_E18 = WAD >> OUTPUT_SCALE_BITS  # exact: 1e18 = 2^18 * 5^18, so 244_140_625_000_000
QUANTILE_LEVELS = (0.1, 0.25, 0.5, 0.75, 0.9)
QUANTILE_LEVELS_E18 = tuple(int(Decimal(str(t)) * WAD) for t in QUANTILE_LEVELS)
K = len(QUANTILE_LEVELS)
Q_MIN_E18 = -20 * WAD  # VolMarket rejects any quantile outside [Q_MIN, Q_MAX] (1e18 ln units)
Q_MAX_E18 = 60 * WAD
RV_FLOOR = 1  # tick^2: y = ln(max(RV, 1)), so RV = 0 scores as y = 0


def floor_div(a: int, b: int) -> int:
    return a // b


def tick_cumulatives(segment_ticks, delta=DELTA):
    c = [0]
    for t in segment_ticks:
        c.append(c[-1] + int(t) * delta)
    return c


def features_from_segment_ticks(segment_ticks, delta=DELTA):
    """Contract features (x_int) from the 17 constant-tick segments before createRound."""
    assert len(segment_ticks) == N_FEATURES + 1
    return features_from_cumulatives(tick_cumulatives(segment_ticks, delta), delta)


def features_from_cumulatives(c, delta=DELTA):
    """Contract features (x_int) from the 18 tickCumulatives observed at createRound."""
    assert len(c) == N_FEATURES + 2
    means = [floor_div(c[j + 1] - c[j], delta) for j in range(len(c) - 1)]
    out = []
    for j in range(len(means) - 1):
        f = max(-CLAMP, min(CLAMP, means[j + 1] - means[j]))
        out.append(f * MULT)
    return out


def model_input(x_int):
    return [x / SCALE for x in x_int]


def realized_vol(window_ticks, n_segments=N_SEGMENTS):
    """RV over a fully readable window of n_segments constant-tick segments."""
    assert len(window_ticks) == n_segments
    diffs = [window_ticks[i + 1] - window_ticks[i] for i in range(n_segments - 1)]
    m = len(diffs)
    return sum(d * d for d in diffs) * (n_segments - 1) // m


def realized_vol_from_cumulatives(c, delta=DELTA):
    """RV of a fully readable window from its nSegments + 1 checkpoint tickCumulatives."""
    means = [floor_div(c[k + 1] - c[k], delta) for k in range(len(c) - 1)]
    return realized_vol(means, len(means))


def bucket_of(rv, bounds=BOUNDS):
    return sum(1 for b in bounds if b <= rv)


def encode(x: int) -> int:
    return x if x >= 0 else R - (-x)


def decode(f: int) -> int:
    """Inverse of encode: field elements above R / 2 are negative."""
    assert 0 <= f < R
    return f - R if f > R // 2 else f


def le_hex_to_int(h: str) -> int:
    return int.from_bytes(bytes.fromhex(h.removeprefix("0x")), "little")


def _word(x: int) -> bytes:
    return int(x).to_bytes(32, "big", signed=True)


def commitment_preimage(round_id: int, model_id: int, outputs, salt: bytes, sender: str) -> bytes:
    """abi.encode(uint256, uint256, int256[], bytes32, address)."""
    assert len(salt) == 32
    head = _word(round_id) + _word(model_id) + _word(5 * 32) + salt
    head += int(sender, 16).to_bytes(32, "big")
    return head + _word(len(outputs)) + b"".join(_word(o) for o in outputs)


def ln_rv(rv: int) -> float:
    """Target y = ln(max(RV, RV_FLOOR)), natural log of tick^2."""
    return math.log(max(int(rv), RV_FLOOR))


def ln_rv_e18(rv: int) -> int:
    """floor(ln(max(RV, 1)) * 1e18) to 40 digits; MarketMath.lnWad approximates it."""
    with localcontext() as ctx:
        ctx.prec = 60
        return int((Decimal(max(int(rv), RV_FLOOR)).ln() * WAD).to_integral_value("ROUND_FLOOR"))


def outputs_to_e18(outputs) -> list[int]:
    return [int(o) * OUTPUT_UNIT_E18 for o in outputs]


def quantize_quantiles(q) -> list[int]:
    """Float quantiles (ln units) to outputs on the 2^-12 grid, strictly increasing."""
    out = []
    for v in q:
        o = round(float(v) * (1 << OUTPUT_SCALE_BITS))
        out.append(o if not out else max(o, out[-1] + 1))
    return out


def valid_outputs(outputs, k=K) -> bool:
    """VolMarket.revealPrediction's checks: length K, strictly increasing, within [Q_MIN, Q_MAX]."""
    e18 = outputs_to_e18(outputs)
    return (len(e18) == k and all(a < b for a, b in zip(e18, e18[1:], strict=False))
            and all(Q_MIN_E18 <= v <= Q_MAX_E18 for v in e18))


def pinball(y: float, q, levels=QUANTILE_LEVELS) -> float:
    """Mean pinball loss over the K levels (float)."""
    return sum(t * (y - v) if y >= v else (1 - t) * (v - y)
               for v, t in zip(q, levels, strict=True)) / len(levels)


def pinball_e18(y_e18: int, q_e18, levels_e18=QUANTILE_LEVELS_E18) -> int:
    """MarketMath.pinball: per level u = y - q, rho = floor(tau * u / 1e18) if u >= 0 else
    floor((1e18 - tau) * (-u) / 1e18); L = floor(sum rho / K). All terms are non-negative."""
    total = 0
    for v, t in zip(q_e18, levels_e18, strict=True):
        u = y_e18 - v
        total += t * u // WAD if u >= 0 else (WAD - t) * (-u) // WAD
    return total // len(levels_e18)


def probs_from_outputs(outputs):
    """VolMarket.revealPrediction: 1e18-scaled shares, the last bucket takes the remainder."""
    total = sum(outputs)
    probs = [o * PROB_SCALE // total for o in outputs[:-1]]
    return probs + [PROB_SCALE - sum(probs)]
