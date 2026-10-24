import json

import pytest

from vol_agents import agent as ag
from vol_agents import contract_math as cm

FEATS = [(-1) ** i * (i + 1) * cm.MULT for i in range(cm.N_FEATURES)]
OUTPUTS = [-4096, 3, 8192, 20000, 30000]


class FakeChain:
    def call(self, market, sig, round_id):
        return [[str(v) for v in FEATS]]


def le_hex(v):
    return "0x" + v.to_bytes(32, "little").hex()


@pytest.fixture
def cached_agent(tmp_path, monkeypatch):
    monkeypatch.setattr(ag, "OUT", tmp_path / "out")
    monkeypatch.setattr(ag.Agent, "onnx_quantiles", lambda self, x: [0.0] * cm.K)
    a = ag.Agent(name="agent-linear_abs", model="linear_abs", key="0x01", address="0x0",
                 proof_cache=tmp_path / "cache")
    d = a.cache_dir(FEATS)
    d.mkdir(parents=True)
    proof = {"instances": [[le_hex(cm.encode(v)) for v in FEATS + OUTPUTS]],
             "hex_proof": "0xabcd"}
    (d / "proof.json").write_text(json.dumps(proof))
    (d / "timing.json").write_text(json.dumps({"seconds": 12.5, "peak_mb": 1100.0}))
    return a


def test_cached_proof_is_reused_without_proving(cached_agent, monkeypatch):
    def no_prove(*a, **k):
        raise AssertionError("proved although the proof is cached")

    monkeypatch.setattr(ag, "run_step", no_prove)
    f = cached_agent.prepare(FakeChain(), "0xMarket", 7)
    assert f["outputs"] == OUTPUTS and f["proof"] == "0xabcd"
    assert cached_agent.timings["prove"] == {"seconds": 12.5, "peak_mb": 1100.0, "cached": True}
    assert (ag.OUT / "rounds" / "0xmarket-7" / "agent-linear_abs" / "proof.json").exists()


def test_cache_key_depends_on_features(cached_agent):
    other = [v + cm.MULT for v in FEATS]
    assert cached_agent.cache_dir(other) != cached_agent.cache_dir(FEATS)


def test_cache_layout_is_model_then_sha256_of_onnx_and_features(cached_agent):
    import hashlib

    onnx = (ag.ROOT / "models" / "linear_abs" / "model.onnx").read_bytes()
    key = hashlib.sha256(onnx + json.dumps(FEATS).encode()).hexdigest()[:32]
    assert cached_agent.cache_dir(FEATS) == cached_agent.proof_cache / "linear_abs" / key


def test_non_increasing_cached_outputs_rejected(cached_agent, monkeypatch):
    d = cached_agent.cache_dir(FEATS)
    proof = json.loads((d / "proof.json").read_text())
    proof["instances"][0][-1] = le_hex(cm.encode(OUTPUTS[-2]))
    (d / "proof.json").write_text(json.dumps(proof))
    with pytest.raises(RuntimeError, match="not acceptable"):
        cached_agent.prepare(FakeChain(), "0xMarket", 8)
