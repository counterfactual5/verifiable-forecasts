import json

import numpy as np
import onnx
import onnxruntime as ort
import pytest

from vol_agents import contract_math as cm
from vol_agents.build import VERIFIER_DIR, build, model_names, run_step, verifier_name
from vol_agents.ezkl_step import OUT, ROOT, paths
from vol_agents.train import synth

MODELS = model_names()


def test_two_to_three_distinct_models():
    assert 2 <= len(MODELS) <= 3
    blobs = {(ROOT / "models" / m / "model.onnx").read_bytes() for m in MODELS}
    assert len(blobs) == len(MODELS)


@pytest.mark.parametrize("model", MODELS)
def test_model_is_trained(model):
    x, y, _, _ = synth(4000, np.random.default_rng(12345))
    sess = ort.InferenceSession(str(paths(model)["onnx"]))
    probs = np.concatenate([sess.run(None, {"x": row[None]})[0] for row in x])
    freq = np.bincount(y, minlength=cm.BUCKETS) / len(y)
    prior = -np.mean(np.log(np.maximum(freq[y], 1e-12)))
    loss = -np.mean(np.log(np.maximum(probs[np.arange(len(y)), y], 1e-12)))
    assert loss < prior - 0.3, (loss, prior)


@pytest.mark.parametrize("model", MODELS)
def test_models_export_to_ezkl(model):
    p = paths(model)
    m = onnx.load(p["onnx"])
    onnx.checker.check_model(m)
    assert [o.name for o in m.graph.output] == ["y"]
    assert m.graph.node[-1].op_type == "Softmax"

    sess = ort.InferenceSession(str(p["onnx"]))
    x = np.random.default_rng(1).uniform(-2, 2, (20, cm.N_FEATURES)).astype(np.float32)
    probs = np.stack([sess.run(None, {"x": row[None]})[0][0] for row in x])
    assert probs.shape == (20, cm.BUCKETS)
    assert np.all(probs >= 0)
    np.testing.assert_allclose(probs.sum(axis=1), 1.0, atol=1e-5)

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
    outs = np.array([cm.le_hex_to_int(h) for h in w["outputs"][0]], float) / cm.SCALE
    ref = sess.run(None, {"x": np.asarray([xin], np.float32)})[0][0]
    np.testing.assert_allclose(outs, ref, atol=0.02)
