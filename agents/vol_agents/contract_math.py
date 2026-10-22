"""Off-chain mirror of the VolMarket arithmetic the agents depend on.

Features (VolMarket._features): 17 segment means b_j = floorDiv(C_{j+1} - C_j, delta) before
createRound, f_j = b_{j+1} - b_j, x_int_j = clamp(f_j, -64, 64) * 128; the model input is
x = x_int / 4096 (EZKL input_scale 12). Negative public inputs are encoded as R - |x|.

Realized vol (VolMarket._realizedVol): over the nSegments + 1 checkpoints of the window,
rv = floor(sum (mean_{i+1} - mean_i)^2 * (nSegments - 1) / m); bucket = #bounds <= rv.

Commitment (VolMarket.commitPrediction): keccak256(abi.encode(roundId, modelId, outputs[5], salt,
sender)); every field is a static 32-byte word, so the preimage is 9 words.
"""

R = 21888242871839275222246405745257275088548364400416034343698204186575808495617
DELTA = 300
N_SEGMENTS = 12
N_FEATURES = 16
BUCKETS = 5
SCALE = 4096
CLAMP = 64
MULT = 128
BOUNDS = (8, 20, 45, 110)
PROB_SCALE = 10**18  # VolMarket probabilities: 1e18 = 1
MAX_OUTPUT = (2**256 - 1) // PROB_SCALE  # VolMarket.MAX_OUTPUT, below R / 2


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


def bucket_of(rv, bounds=BOUNDS):
    return sum(1 for b in bounds if b <= rv)


def encode(x: int) -> int:
    return x if x >= 0 else R - (-x)


def le_hex_to_int(h: str) -> int:
    return int.from_bytes(bytes.fromhex(h.removeprefix("0x")), "little")


def commitment_preimage(round_id: int, model_id: int, outputs, salt: bytes, sender: str) -> bytes:
    """abi.encode(uint256, uint256, uint256[5], bytes32, address)."""
    assert len(outputs) == BUCKETS and len(salt) == 32
    words = [round_id, model_id, *outputs]
    out = b"".join(int(w).to_bytes(32, "big") for w in words)
    return out + salt + int(sender, 16).to_bytes(32, "big")


def probs_from_outputs(outputs):
    """VolMarket.revealPrediction: 1e18-scaled shares, the last bucket takes the remainder."""
    total = sum(outputs)
    probs = [o * PROB_SCALE // total for o in outputs[:-1]]
    return probs + [PROB_SCALE - sum(probs)]
