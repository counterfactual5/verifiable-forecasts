import json
from datetime import UTC, datetime
from pathlib import Path

import pytest

from vol_agents import contract_math as cm

MODELS_DIR = Path(__file__).resolve().parent.parent / "models"
DEPLOYED_CUT = 1791417600
WALKFORWARD = json.loads((MODELS_DIR / "walkforward.json").read_text())
EVAL = json.loads((MODELS_DIR / "eval.json").read_text())


def _deployed_fold():
    cut = datetime.fromtimestamp(DEPLOYED_CUT, UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    (fold,) = [f for f in WALKFORWARD["folds"] if f["cut"] == cut]
    return fold


@pytest.mark.parametrize("model", ["linear_abs", "mlp16", "mlp32_abs"])
def test_deployed_fold_reproduces_the_validation_score(model):
    expected = EVAL["selection"]["validation_log_score"][model]["real"]
    assert round(_deployed_fold()["models"][model]["log_score"], 4) == round(expected, 4)


def test_deployed_fold_uses_the_deployed_bounds():
    assert tuple(_deployed_fold()["bounds"]) == cm.BOUNDS
