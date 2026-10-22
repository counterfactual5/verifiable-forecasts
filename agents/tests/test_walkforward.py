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


def _params(tmp_path, cut, bounds=(20, 60, 120, 260), until=None):
    path = tmp_path / str(cut) / "vol_params.json"
    path.parent.mkdir(parents=True)
    path.write_text(json.dumps({"bounds": list(bounds), "until": cut if until is None else until}))
    return path


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


def test_params_must_be_calibrated_up_to_the_cut(tmp_path):
    cut = 1_700_100_000
    assert wf.load_params(_params(tmp_path, cut), cut)[0] == (20, 60, 120, 260)
    with pytest.raises(ValueError, match="--until"):
        wf.load_params(_params(tmp_path, cut + 1, until=cut), cut + 1)
    with pytest.raises(ValueError, match="increasing"):
        wf.load_params(_params(tmp_path, cut + 2, bounds=(20, 20, 120, 260)), cut + 2)


def test_each_fold_labels_with_its_own_bounds(samples):
    t0, s = samples
    cut = t0 + 2 * DAY
    low = wf.evaluate_fold(s, cut, (5, 10, 20, 40), steps=5, test_s=DAY)
    high = wf.evaluate_fold(s, cut, (500, 1000, 2000, 4000), steps=5, test_s=DAY)
    assert low["bounds"] == [5, 10, 20, 40]
    assert low["bucket_share"]["test"] != high["bucket_share"]["test"]
    _, test = wf.fold_split(s, cut, DAY)
    assert high["bucket_share"]["test"] == wf.tr.shares(wf.bucket((500, 1000, 2000, 4000), test.rv))
    assert cm.BOUNDS not in {tuple(low["bounds"]), tuple(high["bounds"])}
    assert low["baselines"]["uniform"]["log_score"] == round(float(np.log(1 / cm.BUCKETS)), 4)
    assert set(low["models"]) == {spec.name for spec in wf.tr.SPECS}


def test_model_card_table_is_generated_from_the_committed_report():
    report = json.loads(wf.OUT.read_text())
    assert [f["cut"][:10] for f in report["folds"]] == [wf.tr.utc(c)[:10] for c in wf.CUTS]
    assert report["mean_log_score"] == wf.summary(report["folds"])
    assert wf.card_block(wf.CARD) == wf.render(report)
