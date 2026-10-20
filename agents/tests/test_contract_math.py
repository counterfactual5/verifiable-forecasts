import json
from pathlib import Path

import numpy as np

from vol_agents import contract_math as cm
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
    assert tuple(cases["bounds"]) == cm.BOUNDS
    checked = 0
    for c in cases["cases"]:
        tl = c["timeline"]
        regular = tl["offsets"] == [k * cm.DELTA for k in range(cm.N_SEGMENTS)]
        if c["missing"] or not regular:
            continue
        assert cm.realized_vol(tl["ticks"]) == c["rv"], c["name"]
        assert cm.bucket_of(c["rv"]) == c["bucket"], c["name"]
        checked += 1
    assert checked >= 2


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
