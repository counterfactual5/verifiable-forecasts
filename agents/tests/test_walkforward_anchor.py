import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from vol_agents import contract_math as cm

MODELS_DIR = Path(__file__).resolve().parent.parent / "models"
DEPLOYED_CUT = 1791417600
WALKFORWARD = json.loads((MODELS_DIR / "walkforward.json").read_text())
EVAL = json.loads((MODELS_DIR / "eval.json").read_text())
BASELINE = json.loads((MODELS_DIR / "baseline_quantiles.json").read_text())


def _deployed_fold():
    cut = datetime.fromtimestamp(DEPLOYED_CUT, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    (fold,) = [f for f in WALKFORWARD["folds"] if f["cut"] == cut]
    return fold


@pytest.mark.parametrize("model", ["linear_abs", "mlp16", "mlp32_abs"])
def test_deployed_fold_reproduces_the_validation_score(model):
    expected = EVAL["validation_models"][model]["mean_pinball"]
    assert _deployed_fold()["models"][model]["mean_pinball"] == expected


def test_deployed_fold_baseline_is_close_to_the_deployed_one():
    """Same training period; the deployed baseline reads analysis' swap windows (300 s step),
    the fold its 60 s grid rounds, so the quantiles agree to a few hundredths of a ln unit."""
    deployed = [int(v) / cm.WAD for v in BASELINE["quantiles_e18"]]
    fold = _deployed_fold()["baseline_quantiles"]
    assert max(abs(a - b) for a, b in zip(deployed, fold, strict=True)) < 0.05
