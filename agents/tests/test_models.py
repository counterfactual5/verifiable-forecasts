import json

import numpy as np
import onnx
import onnxruntime as ort
import pytest

from vol_agents import contract_math as cm
from vol_agents.build import VERIFIER_DIR, build, model_names, run_step, verifier_name
from vol_agents.ezkl_step import OUT, ROOT, paths

MODELS = model_names()


def test_two_to_three_distinct_models():
    assert 2 <= len(MODELS) <= 3
    blobs = {(ROOT / "models" / m / "model.onnx").read_bytes() for m in MODELS}
    assert len(blobs) == len(MODELS)


HOLDOUT = json.loads((ROOT / "tests" / "fixtures" / "real_holdout.json").read_text())


def test_holdout_matches_the_quantile_levels():
    assert tuple(HOLDOUT["quantile_levels"]) == cm.QUANTILE_LEVELS
    assert len(HOLDOUT["rv"]) >= 100


def _holdout_quantiles(model):
    x = (np.array(HOLDOUT["features"]) * cm.MULT / cm.SCALE).astype(np.float32)
    sess = ort.InferenceSession(str(paths(model)["onnx"]))
    return np.concatenate([sess.run(None, {"x": row[None]})[0] for row in x])


@pytest.mark.parametrize("model", MODELS)
def test_model_beats_climatological_baseline_on_real_test_rounds(model):
    """Mean pinball loss on held-out real rounds of the test period, which the baseline and the
    weights never saw, against the training-period climatological quantiles createRound uses."""
    y = np.array([cm.ln_rv(rv) for rv in HOLDOUT["rv"]])
    q = _holdout_quantiles(model)
    loss = np.mean([cm.pinball(v, row) for v, row in zip(y, q, strict=True)])
    base = np.mean([cm.pinball(v, HOLDOUT["baseline_quantiles"]) for v in y])
    assert loss < base - 0.02, (loss, base)


@pytest.mark.parametrize("model", MODELS)
def test_models_export_to_ezkl(model):
    p = paths(model)
    m = onnx.load(p["onnx"])
    onnx.checker.check_model(m)
    assert [o.name for o in m.graph.output] == ["y"]

    sess = ort.InferenceSession(str(p["onnx"]))
    x = np.random.default_rng(1).uniform(-2, 2, (20, cm.N_FEATURES)).astype(np.float32)
    q = np.stack([sess.run(None, {"x": row[None]})[0][0] for row in x])
    assert q.shape == (20, cm.K)
    assert np.all(np.diff(q, axis=1) >= 2 / 4096 - 1e-6), "monotone head keeps two grid steps"

    committed = VERIFIER_DIR / f"{verifier_name(model)}.sol"
    before = committed.read_text() if committed.exists() else None
    assert (p["onnx"].parent / "settings.json").exists(), "calibrated settings are pinned"
    sol = build(model)
    assert sol == committed
    if before is not None:
        assert sol.read_text() == before, "rebuild must reproduce the committed verifier"
    assert f"contract {verifier_name(model)} {{" in sol.read_text()
    s = json.loads(p["settings"].read_text())
    ra = s["run_args"]
    assert ra["input_scale"] == 12
    assert ra["logrows"] <= 15
    assert s["model_output_scales"] == [cm.OUTPUT_SCALE_BITS]
    assert (ra["input_visibility"], ra["output_visibility"], ra["param_visibility"]) == (
        "Public", "Public", "Fixed")
    assert p["compiled"].exists() and p["pk"].exists() and p["vk"].exists()

    # the circuit agrees with onnxruntime on a contract-shaped input
    work = OUT / model / "check"
    work.mkdir(parents=True, exist_ok=True)
    x_int = [((j * 7) % 9 - 4) * cm.MULT for j in range(cm.N_FEATURES)]
    xin = cm.model_input(x_int)
    (work / "input.json").write_text(json.dumps({"input_data": [xin]}))
    run_step(model, "witness", work)
    w = json.loads((work / "witness.json").read_text())
    assert [cm.le_hex_to_int(h) for h in w["inputs"][0]] == [cm.encode(v) for v in x_int]
    outputs = [cm.decode(cm.le_hex_to_int(h)) for h in w["outputs"][0]]
    assert cm.valid_outputs(outputs), outputs
    ref = sess.run(None, {"x": np.asarray([xin], np.float32)})[0][0]
    np.testing.assert_allclose(np.array(outputs) / 2**cm.OUTPUT_SCALE_BITS, ref, atol=0.02)
