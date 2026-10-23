"""Post-processing in `repro_runner.predict`: per-step quantiles are clamped at zero before being
summed across steps, and crossing sums are rearranged upward. Fake `torch` and `chronos` modules
stand in for the model, so these tests need neither VOL_REPRO_PYTHON nor downloaded weights."""

import contextlib
import sys
import types

from vol_agents import repro_runner as rr

FEATURES = [128 * k for k in range(rr.N_FEATURES)]


class _FakeQuantiles:
    def __init__(self, steps):
        self._steps = steps

    def __getitem__(self, idx):
        assert idx == 0
        return types.SimpleNamespace(tolist=lambda: [list(s) for s in self._steps])


def _install_fakes(monkeypatch, steps):
    calls = {}

    class Pipeline:
        def predict_quantiles(self, context, prediction_length, quantile_levels):
            calls["context"] = context
            calls["prediction_length"] = prediction_length
            calls["quantile_levels"] = quantile_levels
            return _FakeQuantiles(steps), None

    class BaseChronosPipeline:
        @staticmethod
        def from_pretrained(path, **kwargs):
            calls["path"] = path
            return Pipeline()

    torch = types.ModuleType("torch")
    torch.float32 = "float32"
    torch.set_num_threads = lambda n: None
    torch.use_deterministic_algorithms = lambda flag: None
    torch.tensor = lambda data, dtype=None: ("tensor", data, dtype)
    torch.no_grad = contextlib.nullcontext
    chronos = types.ModuleType("chronos")
    chronos.BaseChronosPipeline = BaseChronosPipeline

    monkeypatch.setitem(sys.modules, "torch", torch)
    monkeypatch.setitem(sys.modules, "chronos", chronos)
    monkeypatch.setattr(rr, "artifact_paths", lambda: None)
    # predict() writes HF_HUB_OFFLINE; registering it with monkeypatch restores it afterwards
    monkeypatch.setenv("HF_HUB_OFFLINE", "1")
    return calls


def _steps(first, rest):
    assert len(first) == len(rest) == len(rr.QUANTILE_LEVELS)
    return [first] + [rest] * (rr.PREDICTION_LENGTH - 1)


def test_negative_step_quantiles_are_clamped_before_summing(monkeypatch):
    assert rr.PREDICTION_LENGTH == 11 and len(rr.QUANTILE_LEVELS) == 9
    steps = _steps([-2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0, 2.5],
                   [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25])
    calls = _install_fakes(monkeypatch, steps)

    out = rr.predict(FEATURES)

    # clamped first step [0, 0, 0, 0, .5, 1, 1.5, 2, 2.5] plus 10 * the rest
    assert out["values"] == [2.5, 5.0, 7.5, 10.0, 13.0, 16.0, 19.0, 22.0, 25.0]
    assert out["levels"] == list(rr.QUANTILE_LEVELS)
    assert calls["path"] == str(rr.snapshot_dir())
    assert calls["prediction_length"] == rr.PREDICTION_LENGTH
    assert calls["quantile_levels"] == list(rr.QUANTILE_LEVELS)
    assert calls["context"][1] == [rr.series_from_features(FEATURES)]


def test_crossing_sums_are_rearranged_upward(monkeypatch):
    steps = _steps([4.0, 0.0, 9.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
                   [1.0, 1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 3.0, 3.0])
    _install_fakes(monkeypatch, steps)

    out = rr.predict(FEATURES)

    # clamped sums [14, 10, 19, 10, 20, 20, 20, 30, 30] cross at levels 0.2 and 0.4
    assert out["values"] == [14.0, 14.0, 19.0, 19.0, 20.0, 20.0, 20.0, 30.0, 30.0]
