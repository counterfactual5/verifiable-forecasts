import json

import numpy as np
import pytest

from vol_agents import contract_math as cm
from vol_agents import dataset as ds
from vol_agents import walkforward as wf

DAY = 86400


@pytest.fixture(scope="module")
def samples():
    """Four days of a 60 s random-walk grid: enough for every fold below to have both periods."""
    rng = np.random.default_rng(3)
    t0 = 1_700_006_400
    ticks = np.cumsum(rng.normal(0, 3, 4 * DAY // 60)).astype(np.int64)
    grid = {t0 + 60 * i: int(c) for i, c in enumerate(np.cumsum(ticks * 60))}
    return t0, ds.build_samples(grid, stride=60)


def test_folds_never_read_across_their_cut(samples):
    t0, s = samples
    cuts, test_s = [t0 + DAY + 3600, t0 + 2 * DAY, t0 + 3 * DAY - 3600], DAY // 2
    spans = []
    for cut in cuts:
        trn, test = wf.fold_split(s, cut, test_s)
        assert len(trn) and len(test)
        assert ds.reads(trn.t_open)[1].max() < cut
        first, last = ds.reads(test.t_open)
        assert first.min() >= cut and last.max() < cut + test_s
        spans.append((first.min(), last.max()))
    for (_, end), (start, _) in zip(spans, spans[1:], strict=False):
        assert end < start


def test_fold_baseline_comes_from_its_own_training_rounds(samples):
    t0, s = samples
    early = wf.evaluate_fold(s, t0 + DAY + 3600, steps=5, test_s=DAY // 2)
    late = wf.evaluate_fold(s, t0 + 3 * DAY - 3600, steps=5, test_s=DAY // 2)
    trn, test = wf.fold_split(s, t0 + DAY + 3600, DAY // 2)
    q = early["baseline_quantiles"]
    assert q == wf.climatological(wf.tr.targets(trn)).tolist()
    assert all(a < b for a, b in zip(q, q[1:], strict=False))
    assert all(v * 4096 == round(v * 4096) for v in q), "on the 2^-12 output grid"
    assert q != late["baseline_quantiles"]
    want = np.mean([cm.pinball(y, q) for y in wf.tr.targets(test)])
    assert early["baselines"]["climatological"]["mean_pinball"] == round(float(want), 5)
    assert set(early["models"]) == {spec.name for spec in wf.tr.SPECS}


def test_model_card_table_is_generated_from_the_committed_report():
    report = json.loads(wf.OUT.read_text())
    assert [f["cut"][:10] for f in report["folds"]] == [wf.tr.utc(c)[:10] for c in wf.CUTS]
    assert report["mean_pinball"] == wf.summary(report["folds"])
    assert wf.card_block(wf.CARD) == wf.render(report)
