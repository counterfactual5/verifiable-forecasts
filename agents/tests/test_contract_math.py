import json
import subprocess
from pathlib import Path

import numpy as np

from vol_agents import contract_math as cm
from vol_agents import dataset as ds
from vol_agents.train import synth

FIXTURES = Path(__file__).resolve().parents[2] / "contracts" / "test" / "fixtures"


def test_features_match_contract_fixture():
    fx = json.loads((FIXTURES / "spike_model_proof.json").read_text())
    assert cm.features_from_segment_ticks(fx["segmentTicks"], fx["delta"]) == fx["features"]
    want = [int(h, 16) for h in fx["instances"][:16]]
    assert [cm.encode(x) for x in fx["features"]] == want


def test_features_clamp_and_floor():
    ticks = [0, 100, 99, -1, -2] + [-2] * 12
    f = cm.features_from_segment_ticks(ticks)
    assert f[:4] == [64 * 128, -1 * 128, -64 * 128, -1 * 128]
    assert all(abs(x) <= cm.CLAMP * cm.MULT for x in f)


def test_features_floor_negative_non_divisible():
    # segment sums -301 and 299 over delta=300: floorDiv gives means -2 and 0, truncation -1 and 0
    c = [0, -301, -2] + [-2 + 300 * k for k in range(1, 16)]
    f = cm.features_from_cumulatives(c)
    assert f[0] == 2 * cm.MULT


def test_realized_vol_matches_shared_cases():
    cases = json.loads((FIXTURES / "vol_rv_cases.json").read_text())
    checked = 0
    for c in cases["cases"]:
        tl = c["timeline"]
        regular = tl["offsets"] == [k * cm.DELTA for k in range(cm.N_SEGMENTS)]
        if c["missing"] or not regular:
            continue
        assert cm.realized_vol(tl["ticks"]) == c["rv"], c["name"]
        assert cm.bucket_of(c["rv"], cases["bounds"]) == c["bucket"], c["name"]
        checked += 1
    assert checked >= 2


def test_realized_vol_from_cumulatives_matches_shared_cases():
    cases = json.loads((FIXTURES / "vol_rv_cases.json").read_text())
    checked = 0
    for c in cases["cases"]:
        if c["missing"]:
            continue
        assert cm.realized_vol_from_cumulatives(c["tickCumulatives"], cases["delta"]) == c["rv"]
        checked += 1
    assert checked >= 4  # includes negative_floor, whose ticks change inside a segment


def test_bounds_are_four_strictly_increasing():
    assert len(cm.BOUNDS) == cm.BUCKETS - 1
    assert all(a < b for a, b in zip(cm.BOUNDS, cm.BOUNDS[1:], strict=False))


def test_synthetic_features_use_contract_formula():
    rng = np.random.default_rng(0)
    x, y, x_int, win = synth(50, rng)
    for i in range(5):
        ticks = np.concatenate([[0], np.cumsum(x_int[i] // cm.MULT)]).tolist()
        # unclamped increments reproduce the contract features when all |f| <= 64
        if np.all(np.abs(x_int[i]) < cm.CLAMP * cm.MULT):
            assert cm.features_from_segment_ticks(ticks) == x_int[i].tolist()
        window = np.concatenate([[0], np.cumsum(win[i])]).tolist()
        assert cm.bucket_of(cm.realized_vol(window)) == y[i]


def test_commitment_preimage_matches_abi_encode():
    outputs = [-4096, -1, 0, 3, 2**200]
    salt = bytes(range(32))
    sender = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
    want = subprocess.run(
        ["cast", "abi-encode", "f(uint256,uint256,int256[],bytes32,address)", "7", "3",
         "[" + ",".join(map(str, outputs)) + "]", "0x" + salt.hex(), sender],
        capture_output=True, text=True, check=True,
    ).stdout.strip()
    assert "0x" + cm.commitment_preimage(7, 3, outputs, salt, sender).hex() == want


def test_quantile_scales():
    assert cm.OUTPUT_UNIT_E18 == 244_140_625_000_000
    assert cm.OUTPUT_UNIT_E18 << cm.OUTPUT_SCALE_BITS == cm.WAD
    assert cm.QUANTILE_LEVELS_E18 == (10**17, 25 * 10**16, 5 * 10**17, 75 * 10**16, 9 * 10**17)
    assert (cm.Q_MIN_E18, cm.Q_MAX_E18) == (-20 * 10**18, 60 * 10**18)


def test_decode_inverts_encode():
    for x in (0, 1, -1, 4096, -8192, 2**100, -(2**100)):
        assert cm.decode(cm.encode(x)) == x
    assert cm.decode(cm.R // 2) == cm.R // 2 and cm.decode(cm.R // 2 + 1) < 0


def test_ln_rv_floor():
    assert cm.ln_rv(0) == 0.0 and cm.ln_rv(1) == 0.0 and cm.ln_rv_e18(0) == 0
    assert cm.ln_rv_e18(2) == 693147180559945309
    assert abs(cm.ln_rv(1000) - np.log(1000)) < 1e-12
    assert cm.ln_rv_e18(2**200) == 138629436111989061883  # 200 ln 2 = 138.629436111989061883...


def test_quantize_quantiles_strictly_increasing():
    out = cm.quantize_quantiles([1.0, 1.0, 1.0001, 2.5, 2.5])
    assert out == [4096, 4097, 4098, 10240, 10241]
    assert cm.valid_outputs(out)
    assert not cm.valid_outputs([1, 1, 2, 3, 4])
    assert not cm.valid_outputs([0, 1, 2, 3, 61 * 4096])
    assert not cm.valid_outputs([0, 1, 2, 3])


def test_pinball_integer_mirror_matches_float():
    rng = np.random.default_rng(5)
    for _ in range(200):
        out = sorted(rng.choice(np.arange(-4096, 60000), cm.K, replace=False).tolist())
        rv = int(rng.integers(0, 50000))
        y_e18 = cm.ln_rv_e18(rv)
        got = cm.pinball_e18(y_e18, cm.outputs_to_e18(out))
        want = cm.pinball(cm.ln_rv(rv), [o / 4096 for o in out])
        assert abs(got / 1e18 - want) < 1e-12
    # u >= 0 uses tau, u < 0 uses 1 - tau; each term and the mean are floored
    q = [0, 0, 0, 0, 3 * cm.WAD]
    assert cm.pinball_e18(cm.WAD, q) == (10**17 + 25 * 10**16 + 5 * 10**17 + 75 * 10**16
                                         + 10**17 * 2) // 5
    assert cm.pinball_e18(1, [0, 2, 3, 4, 5]) == (0 + 0 + 0 + 0 + 0) // 5


def _tick_path(seconds, rng):
    """Pool tick per second, changing at irregular moments (as Swaps do); it starts at 0 so that
    segment means cross zero and floorDiv differs from truncation."""
    ticks = np.empty(seconds, np.int64)
    t, tick = 0, 0
    while t < seconds:
        run = int(rng.integers(1, 400))
        ticks[t : t + run] = tick
        tick += int(rng.integers(-90, 91))
        t += run
    return ticks


def test_real_samples_follow_the_contract_round():
    rng = np.random.default_rng(3)
    t0 = 1_700_000_040  # a multiple of 60, like the exported grid
    ticks = _tick_path(6 * 3600, rng)
    cum = np.concatenate([[0], np.cumsum(ticks)])
    grid = {t0 + k: int(cum[k]) for k in range(0, len(cum), 60)}
    s = ds.build_samples(grid, stride=600)
    assert len(s) > 10

    def means(start, n):
        # segment means straight from the per-second ticks, floored like the contract
        return [int(ticks[start + j * cm.DELTA : start + (j + 1) * cm.DELTA].sum()) // cm.DELTA
                for j in range(n)]

    clamped = 0
    for i in range(len(s)):
        t = int(s.t_open[i]) - t0
        hist = means(t - 17 * cm.DELTA, 17)
        assert s.x_int[i].tolist() == cm.features_from_segment_ticks(hist)
        assert s.raw_diff[i].tolist() == [b - a for a, b in zip(hist, hist[1:], strict=False)]
        assert s.rv[i] == cm.realized_vol(means(t + ds.LEAD_S, cm.N_SEGMENTS))
        assert s.lag_rv[i] == cm.realized_vol(hist[-cm.N_SEGMENTS:])
        clamped += int(np.any(np.abs(s.raw_diff[i]) > cm.CLAMP))
    assert clamped > 0  # the path is rough enough to exercise CLAMP


def test_time_split_periods_share_no_second():
    t_open = np.arange(0, 2000) * 60 + 1_700_000_000
    cuts = [1_700_030_000, 1_700_060_000]
    masks = ds.split_by_time(t_open, cuts)
    assert len(masks) == 3 and all(m.sum() > 0 for m in masks)
    assert not np.any(masks[0] & masks[1]) and not np.any(masks[1] & masks[2])
    for i, cut in enumerate(cuts):
        first, last = ds.reads(t_open)
        assert last[masks[i]].max() < cut <= first[masks[i + 1]].min()
