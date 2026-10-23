"""Commit-only TSFM API agent: response conversion to the contract's probability scale, the HTTP
adapter against a local mock server (no outside requests), and one anvil round in which the agent
commits, reveals without a proof, is scored and claims its predictor share."""

import json
import math
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import numpy as np
import pytest

from vol_agents import api_agent as api
from vol_agents import contract_math as cm
from vol_agents import history
from vol_agents import tsfm_forecast as sf
from vol_agents import tsfm_recompute as sr
from vol_agents.chain import DEV_KEYS, Anvil, address_of, as_int
from vol_agents.round import WINDOW_TICKS, history_ticks

BOUNDS = list(cm.BOUNDS)
FEATURES = cm.features_from_segment_ticks(history_ticks())
SECRET = "test-key-not-real"
OTHER_KEYS = [f"0x{i:064x}" for i in (11, 12, 13)]  # offchain-only test signers
INFO = {"market": "0x0", "id": 7, "start": 1792562400, "delta_s": cm.DELTA,
        "n_segments": cm.N_SEGMENTS}


def _forecast_reply(centers, width=0.05):
    """A /forecast answer whose step k has every quantile within width of centers[k],
    rows deliberately out of time order."""
    rows = []
    for k, c in enumerate(centers):
        rows.append({"unique_id": "round-7", "ds": f"2026-10-21T06:{5 * k:02d}:00Z", "y_hat": c,
                     "intervals": {str(lv): {"lo": c - width * lv / 100,
                                             "hi": c + width * lv / 100}
                                   for lv in sf.LEVELS}})
    return {"model_used": "remote-model", "forecast": rows[::-1]}


class _Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.requests.append({"path": self.path, "headers": dict(self.headers),
                                     "body": body})
        reply = self.server.replies.get(self.path)
        if reply is None:
            self.send_response(500)
            self.end_headers()
            return
        data = json.dumps(reply).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


@pytest.fixture(scope="module")
def server():
    srv = HTTPServer(("127.0.0.1", 0), _Handler)
    srv.requests = []
    srv.replies = {
        "/probs": {"bucket_probs": [1, 1, 2, 4, 2]},
        "/quantiles": {"quantiles": [{"level": 0.1, "value": 600.0},
                                     {"level": 0.5, "value": 1200.0},
                                     {"level": 0.9, "value": 2000.0}]},
        # 11 window differences of 20 ticks at remote-model's spread 0.5: RV ~ 11 * 10^2 = 1100
        "/v1/forecast": _forecast_reply([500.0, 500.0] + [20.0] * 11),
    }
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv
    srv.shutdown()


@pytest.fixture(autouse=True)
def no_history_cache(monkeypatch):
    monkeypatch.delenv(history.CACHE_ENV, raising=False)
    monkeypatch.delenv(history.CONTEXT_ENV, raising=False)


def _url(srv, path):
    return f"http://127.0.0.1:{srv.server_address[1]}{path}"


# ---------------------------------------------------------------- conversion

def test_quantize_sums_exactly_and_keeps_every_bucket():
    for probs in ([0.2] * 5, [1, 0, 0, 0, 0], [0.1, 0.2, 0.3, 0.15, 0.25], [1e-30, 1, 1, 1, 3]):
        ints = api.quantize(probs)
        assert sum(ints) == cm.PROB_SCALE
        assert min(ints) >= int(api.MIN_PROB * cm.PROB_SCALE * 0.99)
        # As reveal outputs, the contract turns them into exactly the same probabilities.
        assert cm.probs_from_outputs(ints) == ints
    assert api.quantize([0.2] * 5) == [cm.PROB_SCALE // 5] * 5


def test_quantiles_at_the_bounds_give_their_level_differences():
    probs = api.probs_from_quantiles([0.1, 0.3, 0.5, 0.7, 0.9], [*BOUNDS, 2500], BOUNDS)
    assert probs == pytest.approx([0.1, 0.2, 0.2, 0.2, 0.3])


def test_quantile_interpolation_and_tails():
    # lower tail runs linearly from (0, 0); between quantiles the CDF is linear
    cdf = api.quantile_cdf([0.5, 0.9], [40, 100])
    assert cdf(8) == pytest.approx(0.5 * 8 / 40)
    assert cdf(70) == pytest.approx(0.7)
    # upper tail: exponential through the top two quantiles, so 1 - F halves every scale*ln2
    scale = 60 / math.log(0.5 / 0.1)
    assert cdf(200) == pytest.approx(1 - 0.1 * math.exp(-100 / scale))
    assert cdf(-1) == 0.0
    probs = api.probs_from_quantiles([0.5, 0.9], [40, 100], BOUNDS)
    assert sum(probs) == pytest.approx(1.0)
    assert probs[4] == pytest.approx(1 - cdf(BOUNDS[-1]))


def test_bad_responses_rejected():
    with pytest.raises(ValueError):
        api.probs_from_response({"bucket_probs": [1, 2, 3]}, BOUNDS)
    with pytest.raises(ValueError):
        api.probs_from_response({"bucket_probs": [1, -1, 1, 1, 1]}, BOUNDS)
    with pytest.raises(ValueError):
        api.probs_from_response({"quantiles": [{"level": 0.5, "value": 10}]}, BOUNDS)
    with pytest.raises(ValueError):
        api.probs_from_quantiles([0.5, 0.4], [10, 20], BOUNDS)
    with pytest.raises(ValueError):
        api.probs_from_quantiles([0.4, 0.5], [20, 10], BOUNDS)
    with pytest.raises(ValueError):
        api.probs_from_response({"mean": 3}, BOUNDS)


def test_placeholder_is_deterministic():
    a = api.probs_from_quantiles(*api.placeholder_quantiles(FEATURES), BOUNDS)
    b = api.probs_from_quantiles(*api.placeholder_quantiles(FEATURES), BOUNDS)
    assert a == b and sum(a) == pytest.approx(1.0)
    # the trailing RV is the contract formula over the last 11 feature differences
    diffs = [x // cm.MULT for x in FEATURES][-11:]
    assert api.trailing_realized_vol(FEATURES) == sum(d * d for d in diffs)


def test_config_from_env():
    assert api.ApiConfig.from_env({}) is None
    cfg = api.ApiConfig.from_env({"VOL_TSFM_API_URL": "http://x/y", "VOL_TSFM_API_KEY": "k",
                                  "VOL_TSFM_TIMEOUT_S": "5"})
    assert cfg == api.ApiConfig(url="http://x/y", key="k", timeout_s=5.0)
    assert cfg.schema == api.TSFM and cfg.model == "remote-model"
    cfg = api.ApiConfig.from_env({"VOL_TSFM_API_URL": "http://x/v1", "VOL_TSFM_MODEL": "chronos-2",
                                  "VOL_TSFM_API_SCHEMA": api.REQUEST_SCHEMA})
    assert cfg.model == "chronos-2" and cfg.schema == api.REQUEST_SCHEMA
    with pytest.raises(ValueError):
        api.ApiConfig.from_env({"VOL_TSFM_API_URL": "http://x", "VOL_TSFM_API_SCHEMA": "nope"})


# ---------------------------------------------------------------- tsfm-forecast format

def test_forecast_request_puts_the_features_on_the_round_grid():
    body = sf.build_request(sf.context(FEATURES), INFO, "chronos-2")
    assert body["model"] == "chronos-2" and body["freq"] == "5min"
    assert body["options"] == {"cleaning": {"preset": "raw"}}
    assert body["h"] == cm.N_SEGMENTS + 1
    pts = body["series"]
    assert [p["y"] * cm.MULT for p in pts] == FEATURES
    assert {p["unique_id"] for p in pts} == {"round-7"}
    # the last difference ends at createRound, one segment before the window starts
    assert pts[-1]["ds"] == "2026-10-21T05:55:00Z" and pts[0]["ds"] == "2026-10-21T04:40:00Z"


def test_forecast_quantiles_parse_in_time_order():
    levels, steps = sf.step_quantiles(_forecast_reply([1.0, 2.0, 3.0]))
    assert levels[0] == pytest.approx(0.01) and levels[-1] == pytest.approx(0.99)
    assert len(levels) == 21 and 0.5 in levels
    assert [s[levels.index(0.5)] for s in steps] == [1.0, 2.0, 3.0]
    with pytest.raises(ValueError):
        sf.step_quantiles({"forecast": []})
    with pytest.raises(ValueError):
        sf.step_quantiles({"forecast": [{"ds": "a", "y_hat": 1.0, "intervals": {}}]})


def test_sampled_quantiles_follow_the_cdf_and_exponential_tails():
    levels, values = [0.1, 0.5, 0.9], [-10.0, 0.0, 10.0]
    u = np.array([0.1, 0.3, 0.5, 0.9, 0.99, 0.01])
    x = sf.sample_quantiles(levels, values, u)
    assert x[:4] == pytest.approx([-10.0, -5.0, 0.0, 10.0])
    tail = 10 / math.log(0.5 / 0.1)
    assert x[4] == pytest.approx(10 + tail * math.log(0.1 / 0.01))
    assert x[5] == pytest.approx(-10 - tail * math.log(0.1 / 0.01))


def test_step_samples_sum_into_the_right_bucket_and_skip_the_lead_steps():
    levels, steps = sf.step_quantiles(_forecast_reply([500.0, 500.0] + [8.0] * 11))
    # RV ~ 11 * 8^2 = 704: bucket 2; the two huge lead steps must not count
    p = sf.probs_from_step_quantiles(levels, steps, BOUNDS, cm.N_SEGMENTS - 1)
    assert sum(p) == pytest.approx(1.0) and p[2] > 0.99
    assert min(p) >= sf.MC_PROB_FLOOR * 0.99
    assert p == sf.probs_from_step_quantiles(levels, steps, BOUNDS, cm.N_SEGMENTS - 1)
    # spread 0.5 quarters RV (176: bucket 0); the uniform mix lifts every bucket to mix / 5
    q = sf.probs_from_step_quantiles(levels, steps, BOUNDS, cm.N_SEGMENTS - 1, 0.5, 0.5)
    assert q[0] > 0.59 and min(q) >= 0.1 - 1e-12
    with pytest.raises(ValueError):
        sf.probs_from_step_quantiles(levels, steps[:5], BOUNDS, cm.N_SEGMENTS - 1)


def test_tsfm_agent_over_http(server):
    cfg = api.ApiConfig(url=_url(server, "/v1/"), key=SECRET, model="remote-model")
    agent = api.ApiAgent(name="agent-tsfm", key=DEV_KEYS[1], address=address_of(DEV_KEYS[1]),
                         config=cfg)
    assert agent.source == "tsfm:remote-model"
    probs = agent.api_probs(FEATURES, BOUNDS, INFO)
    req = server.requests[-1]
    assert req["path"] == "/v1/forecast"
    assert req["headers"]["Authorization"] == f"Bearer {SECRET}"
    assert req["body"] == sf.build_request(sf.context(FEATURES), INFO, "remote-model")
    levels, steps = sf.step_quantiles(server.replies["/v1/forecast"])
    assert probs == sf.probs(levels, steps, BOUNDS, cm.N_SEGMENTS, "remote-model")
    assert max(range(5), key=lambda i: probs[i]) == 3
    # the constant uniform mix keeps every bucket at mix / 5 or more
    assert min(probs) >= sf.UNIFORM_MIX / cm.BUCKETS - 1e-12


def test_three_model_agents_are_independent_with_honest_tiers(server):
    cfg = api.ApiConfig(url=_url(server, "/v1"), key=SECRET)
    keys = OTHER_KEYS
    agents = api.tsfm_agents(cfg, keys)
    assert [a.name for a in agents] == ["agent-timesfm-3.0", "agent-timestral-209m",
                                        "agent-chronos-2"]
    assert [a.config.model for a in agents] == ["timesfm-3.0", "timestral-209m", "chronos-2"]
    assert len({a.address for a in agents}) == 3
    assert [a.address for a in agents] == [address_of(k) for k in keys]
    assert [a.tier for a in agents] == [sf.REPRODUCIBLE] * 3
    assert all(a.kind == "commit-only" for a in agents)
    for a in agents:
        h = a.model_hash
        assert h.startswith("0x") and len(h) == 66 and h == sf.model_hash(a.config.model)
    assert len({a.model_hash for a in agents}) == 3
    remote = api.tsfm_agents(cfg, keys[:1], ["remote-model"])[0]
    assert remote.name == "agent-remote-model" and remote.tier == sf.COMMIT_ONLY and remote.model_hash is None
    # one run, three forecasts, each request naming its own model
    for a in agents:
        a.api_probs(FEATURES, BOUNDS, INFO)
        assert server.requests[-1]["body"]["model"] == a.config.model
    assert api.models_from_env({}) == list(sf.DEFAULT_MODELS)
    assert api.models_from_env({"VOL_TSFM_MODELS": " chronos-2 ,remote-model"}) == ["chronos-2",
                                                                                "remote-model"]
    with pytest.raises(ValueError):
        api.models_from_env({"VOL_TSFM_MODELS": "chronos-2,chronos-2"})
    with pytest.raises(ValueError):
        api.tsfm_agents(cfg, keys[:2])


def test_calibration_follows_the_context_source():
    assert sf.calibration("chronos-2") == (0.35, sf.UNIFORM_MIX)
    assert sf.calibration("chronos-2", sf.SWAPS) == history.LONG_CONTEXT_CALIBRATION["chronos-2"]
    assert sf.calibration("unknown-model", sf.SWAPS) == sf.DEFAULT_LONG_CALIBRATION
    # no long-context forecast may drop below a 4% floor per bucket
    for m in sf.MODELS:
        assert sf.calibration(m, sf.SWAPS)[1] >= 0.2


def test_long_context_goes_to_long_context_models_only(server, monkeypatch):
    long_diffs = list(range(-248, 248)) + sf.context(FEATURES)
    calls = []

    def fake_round_context(features, start, delta, env=None):
        calls.append((features, start, delta, (env or {}).get(history.CONTEXT_ENV)))
        return history.Context(long_diffs, sf.SWAPS, None)

    monkeypatch.setattr(api.history, "round_context", fake_round_context)
    cfg = api.ApiConfig(url=_url(server, "/v1"), key=SECRET)
    timesfm, timestral, chronos = api.tsfm_agents(cfg, OTHER_KEYS)
    remote = api.tsfm_agents(cfg, OTHER_KEYS[:1], ["remote-model"])[0]
    levels, steps = sf.step_quantiles(server.replies["/v1/forecast"])

    monkeypatch.setenv(history.CONTEXT_ENV, "64")
    probs = timestral.api_probs(FEATURES, BOUNDS, INFO)
    # a reproducible long-context model sends the length its model_hash registers, whatever
    # $VOL_HISTORY_CONTEXT says
    assert calls == [(FEATURES, INFO["start"], INFO["delta_s"], str(history.DEFAULT_CONTEXT))]
    pts = server.requests[-1]["body"]["series"]
    assert [p["y"] for p in pts] == long_diffs
    # the long series ends on the same createRound segment as the 16 features
    assert pts[-1]["ds"] == "2026-10-21T05:55:00Z"
    assert probs == sf.probs(levels, steps, BOUNDS, cm.N_SEGMENTS, "timestral-209m", sf.SWAPS)
    assert probs != sf.probs(levels, steps, BOUNDS, cm.N_SEGMENTS, "timestral-209m")

    ctx = timesfm.context(FEATURES, INFO)
    assert len(calls) == 1 and ctx.source == sf.ONCHAIN and "onchain features" in ctx.reason
    timesfm.api_probs(FEATURES, BOUNDS, INFO)
    assert len(calls) == 1
    assert [p["y"] * cm.MULT for p in server.requests[-1]["body"]["series"]] == FEATURES

    chronos.context(FEATURES, INFO)
    assert calls[-1][3] == str(history.DEFAULT_CONTEXT)
    remote.context(FEATURES, INFO)
    assert calls[-1][3] == "64"


def test_model_hash_binds_public_weights_parameters_and_code():
    pre = sf.model_hash_preimage("timesfm-3.0")
    assert pre["weights"] == "google/timesfm-3.0-pytorch@43046b85ec22d584a13f8098c2ed39c889e129c2"
    assert pre["postprocess"]["uniform_mix"] == sf.UNIFORM_MIX
    assert pre["postprocess"]["spread"] == sf.MODELS["timesfm-3.0"].spread
    assert len(pre["code_sha256"]) == 64
    assert pre["inference"]["context"]["points"] == 16
    assert pre["postprocess"]["tolerance"] == sf.RECOMPUTE_TOLERANCE == 10**15
    long = sf.model_hash_preimage("chronos-2")
    assert long["inference"]["context"]["points"] == history.DEFAULT_CONTEXT
    assert len(long["inference"]["context"]["history_sha256"]) == 64
    assert long["postprocess"]["long_calibration"] == list(sf.calibration("chronos-2", sf.SWAPS))
    assert len(long["local_runner_sha256"]) == 64
    for m in ("remote-model", "unknown-model"):
        with pytest.raises(ValueError):
            sf.model_hash_preimage(m)


def test_reveal_quantization_sums_exactly_on_the_grid():
    for probs in ([0.2] * 5, [1, 0, 0, 0, 0], [0.1, 0.2, 0.3, 0.15, 0.25], [1e-30, 1, 1, 1, 3],
                  [0.0005, 0.0015, 0.2485, 0.3, 0.4495], [1 / 3, 1 / 3, 1 / 3, 0, 0]):
        ints = sf.quantize_reveal(probs)
        assert sum(ints) == cm.PROB_SCALE
        assert all(v % sf.PROB_QUANTUM == 0 and v >= sf.PROB_QUANTUM for v in ints)
        assert cm.probs_from_outputs(ints) == ints
        # under one step of rounding; up to BUCKETS - 1 steps where the floor lifts empty buckets
        share = [v / sum(probs) for v in probs]
        bound = sf.PROB_QUANTUM if min(share) * cm.PROB_SCALE >= sf.PROB_QUANTUM else (
            (cm.BUCKETS - 1) * sf.PROB_QUANTUM)
        assert all(abs(v - s * cm.PROB_SCALE) <= bound for v, s in zip(ints, share, strict=True))
    assert sf.quantize_reveal([0.2] * 5) == [cm.PROB_SCALE // 5] * 5
    for bad in ([0.2] * 4, [0.5, 0.5, -0.1, 0.1, 0], [math.nan, 1, 1, 1, 1], [0] * 5):
        with pytest.raises(ValueError):
            sf.quantize_reveal(bad)


def test_recompute_tolerance_accepts_one_grid_step_and_rejects_beyond():
    reveal = [10**17, 2 * 10**17, 3 * 10**17, 2 * 10**17, 2 * 10**17]
    eps = sf.RECOMPUTE_TOLERANCE
    assert sf.compare_reveal(reveal, reveal) == (0, sf.EXACT)
    assert sf.compare_reveal(reveal, [reveal[0] + eps, reveal[1] - eps] + reveal[2:]) == (
        eps, sf.TOLERANT)
    assert sf.compare_reveal(reveal, [reveal[0] + eps + 1, reveal[1] - eps - 1] + reveal[2:]) == (
        eps + 1, sf.FAIL)
    with pytest.raises(ValueError):
        sf.compare_reveal(reveal, reveal[:4])


def test_local_recompute_repeats_the_api_forecast(server, tmp_path, monkeypatch):
    """A stand-in for the public-weights runner that answers the same quantiles as the API: the
    recomputed vector must equal what the API agent reveals."""
    reply = server.replies["/v1/forecast"]
    levels, steps = sf.step_quantiles(reply)
    runner = tmp_path / "python"
    runner.write_text("#!/bin/sh\ncat > /dev/null\necho '"
                      + json.dumps({"levels": levels, "steps": steps}) + "'\n")
    runner.chmod(0o755)
    agent = api.tsfm_agents(api.ApiConfig(url=_url(server, "/v1"), key=SECRET),
                            OTHER_KEYS[:1], ["timesfm-3.0"])[0]
    revealed = sf.quantize_reveal(agent.api_probs(FEATURES, BOUNDS, INFO))
    onchain = history.Context(sf.context(FEATURES), sf.ONCHAIN)
    assert sr.recompute_outputs("timesfm-3.0", onchain, BOUNDS, python=str(runner)) == revealed
    got = sr.verify("timesfm-3.0", revealed, [onchain], BOUNDS, cm.N_SEGMENTS, str(runner))
    assert got["verdict"] == sf.EXACT and got["maxAbsDiff"] == 0
    off = [revealed[0] + sf.RECOMPUTE_TOLERANCE + 1, revealed[1] - sf.RECOMPUTE_TOLERANCE - 1]
    got = sr.verify("timesfm-3.0", off + revealed[2:], [onchain], BOUNDS, cm.N_SEGMENTS,
                    str(runner))
    assert got["verdict"] == sf.FAIL and got["maxAbsDiff"] == sf.RECOMPUTE_TOLERANCE + 1
    monkeypatch.delenv("VOL_REPRO_PYTHON", raising=False)
    with pytest.raises(RuntimeError):
        sr.local_step_quantiles("timesfm-3.0", sf.context(FEATURES), cm.N_SEGMENTS)


def test_recompute_falls_back_to_the_onchain_context_the_agent_may_have_used(tmp_path):
    """A long-context agent whose cache was stale revealed from the 16 features: the rebuilt
    512-point context misses, the onchain one matches."""
    reply = _forecast_reply([500.0, 500.0] + [20.0] * 11)
    levels, steps = sf.step_quantiles(reply)
    runner = tmp_path / "python"
    runner.write_text("#!/bin/sh\ncat > /dev/null\necho '"
                      + json.dumps({"levels": levels, "steps": steps}) + "'\n")
    runner.chmod(0o755)
    revealed = sf.quantize_reveal(sf.probs(levels, steps, BOUNDS, cm.N_SEGMENTS, "chronos-2"))
    rebuilt = history.Context([0] * 496 + sf.context(FEATURES), sf.SWAPS)
    onchain = history.Context(sf.context(FEATURES), sf.ONCHAIN)
    got = sr.verify("chronos-2", revealed, [rebuilt, onchain], BOUNDS, cm.N_SEGMENTS,
                    str(runner))
    assert got["contextSource"] == sf.ONCHAIN and got["verdict"] == sf.EXACT
    assert [t["verdict"] for t in got["tried"]] == [sf.FAIL, sf.EXACT]


# ---------------------------------------------------------------- HTTP adapter

def test_api_bucket_probs_response(server):
    cfg = api.ApiConfig(url=_url(server, "/probs"), key=SECRET)
    body = api.build_request(FEATURES, BOUNDS, {"market": "0x0", "id": 7, "start": 1,
                                                "delta_s": cm.DELTA, "n_segments": cm.N_SEGMENTS})
    resp = api.call_api(cfg, body)
    assert api.probs_from_response(resp, BOUNDS) == pytest.approx([0.1, 0.1, 0.2, 0.4, 0.2])
    req = server.requests[-1]
    assert req["headers"]["Authorization"] == f"Bearer {SECRET}"
    sent = req["body"]
    assert sent["schema"] == api.REQUEST_SCHEMA and sent["target"] == "realized_vol_tick2"
    assert sent["bounds_tick2"] == BOUNDS and sent["round"]["id"] == 7
    diffs = sent["history"]["segment_mean_tick_diffs"]
    assert [d * cm.MULT for d in diffs] == FEATURES
    path = sent["history"]["relative_segment_mean_ticks"]
    assert path[0] == 0 and [b - a for a, b in zip(path, path[1:], strict=False)] == diffs


def test_api_quantiles_response_and_custom_key_header(server):
    cfg = api.ApiConfig(url=_url(server, "/quantiles"), key=SECRET, key_header="X-Api-Key")
    resp = api.call_api(cfg, {"schema": api.REQUEST_SCHEMA})
    probs = api.probs_from_response(resp, BOUNDS)
    want = api.probs_from_quantiles([0.1, 0.5, 0.9], [600.0, 1200.0, 2000.0], BOUNDS)
    assert probs == pytest.approx(want)
    assert max(range(5), key=lambda i: probs[i]) == 3
    headers = server.requests[-1]["headers"]
    assert headers["X-Api-Key"] == SECRET and "Authorization" not in headers


def test_api_error_does_not_leak_key(server):
    cfg = api.ApiConfig(url=_url(server, "/missing"), key=SECRET)
    with pytest.raises(RuntimeError) as e:
        api.call_api(cfg, {})
    assert "500" in str(e.value) and SECRET not in str(e.value)


# ---------------------------------------------------------------- onchain, commit-only

COMMIT_LEAD, REVEAL_LEAD = 300, 60
FEE_BPS, SHARE_BPS = 100, 5000
ROUND_SIG = "getRound(uint256)(uint64,bool,bool,uint256,uint256,uint256,uint256[5],uint256[])"
PREDICTION_SIG = "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)"


def test_commit_only_agent_round_and_predictor_share(server):
    owner = DEV_KEYS[0]
    with Anvil() as c:
        token = c.deploy(owner, "test/mocks/MockERC20.sol:MockERC20")
        pool = c.deploy(owner, "test/mocks/MockPool.sol:MockPool")
        market = c.deploy(owner, "src/VolMarket.sol:VolMarket", token, FEE_BPS, SHARE_BPS, pool,
                          cm.DELTA, cm.N_SEGMENTS, COMMIT_LEAD, REVEAL_LEAD)
        key = DEV_KEYS[1]
        agent = api.ApiAgent(name="agent-tsfm", key=key, address=address_of(key),
                             config=api.ApiConfig(url=_url(server, "/v1"), key=SECRET))
        c.send(owner, market, "registerModel(address,address)",
               "0x0000000000000000000000000000000000000000", agent.address)
        agent.model_id = 0
        assert c.call(market, "isZkModel(uint256)(bool)", 0)[0] in (False, "false")

        t0 = c.timestamp() + 1000
        start = t0 + 2 * cm.DELTA
        c.send(owner, pool, "setSegments(uint256,uint256,int24[])", t0 - 17 * cm.DELTA, cm.DELTA,
               "[" + ",".join(map(str, history_ticks())) + "]")
        c.send(owner, pool, "setSegments(uint256,uint256,int24[])", start, cm.DELTA,
               "[" + ",".join(map(str, WINDOW_TICKS)) + "]")
        c.set_next_timestamp(t0)
        c.send(owner, market, "createRound(uint64,uint256[])", start,
               "[" + ",".join(map(str, BOUNDS)) + "]")

        stakes = {DEV_KEYS[2]: (3, 10**18), DEV_KEYS[3]: (0, 3 * 10**18)}
        for k, (bucket, amount) in stakes.items():
            c.send(owner, token, "mint(address,uint256)", address_of(k), amount)
            c.send(k, token, "approve(address,uint256)", market, amount)
            c.send(k, market, "bet(uint256,uint256,uint256)", 0, bucket, amount)

        forecast = agent.commit(c, market, 0)
        assert forecast["source"] == "tsfm:remote-model" and forecast["proof"] == "0x"
        # no $VOL_HISTORY_CACHE: the long-context model falls back to the onchain features
        assert forecast["context_source"] == sf.ONCHAIN and forecast["context_points"] == 16
        assert history.CACHE_ENV in forecast["context_reason"]
        sent = server.requests[-1]["body"]["series"]
        assert sent[-1]["ds"] == sf.iso(start - cm.DELTA)
        assert [p["y"] * cm.MULT for p in sent] == FEATURES
        rec = c.call(market, PREDICTION_SIG, 0, agent.address)
        assert rec[0] in (False, "false")

        c.set_next_timestamp(start - COMMIT_LEAD)
        agent.reveal(c, market, 0)
        rec = c.call(market, PREDICTION_SIG, 0, agent.address)
        assert [as_int(v) for v in rec[2]] == forecast["outputs"]

        c.set_next_timestamp(start + cm.N_SEGMENTS * cm.DELTA + 10)
        c.send(owner, market, "settle(uint256)", 0)
        r = c.call(market, ROUND_SIG, 0)
        assert as_int(r[3]) == 3 and as_int(r[4]) == cm.realized_vol(WINDOW_TICKS)
        score = as_int(c.call(market, PREDICTION_SIG, 0, agent.address)[3])
        assert score > as_int(c.call(market, "baselineLogScore()(int256)")[0])

        fee = 4 * 10**18 * FEE_BPS // 10_000
        share = as_int(c.call(market, "predictorPool(uint256)(uint256)", 0)[0])
        assert share == fee * SHARE_BPS // 10_000
        c.send(key, market, "claimPredictorReward(uint256)", 0)
        got = as_int(c.call(token, "balanceOf(address)(uint256)", agent.address)[0])
        assert got == share, "the only forecaster above the baseline takes the whole share"
        c.send(owner, market, "collectFee(uint256)", 0)
        owner_got = as_int(c.call(token, "balanceOf(address)(uint256)", address_of(owner))[0])
        assert owner_got == fee - share


# ---------------------------------------------------------------- onchain, reproducible

ZERO = "0x0000000000000000000000000000000000000000"


def test_reproducible_agent_round_registers_hash_and_recomputes(server, tmp_path, monkeypatch,
                                                                capsys):
    """Reproducible agents register their modelHash with the three-argument registerModel and
    reveal without a proof; tsfm_recompute re-derives the honest reveal from chain data alone and
    exits non-zero on a reveal beyond tolerance, a foreign modelHash or a failing runner."""
    levels, steps = sf.step_quantiles(server.replies["/v1/forecast"])
    runner = tmp_path / "python"
    runner.write_text("#!/bin/sh\ncat > /dev/null\necho '"
                      + json.dumps({"levels": levels, "steps": steps}) + "'\n")
    runner.chmod(0o755)
    broken = tmp_path / "broken"
    broken.write_text("#!/bin/sh\necho 'no weights' >&2\nexit 3\n")
    broken.chmod(0o755)
    model = "timesfm-3.0"
    owner = DEV_KEYS[0]
    with Anvil() as c:
        token = c.deploy(owner, "test/mocks/MockERC20.sol:MockERC20")
        pool = c.deploy(owner, "test/mocks/MockPool.sol:MockPool")
        market = c.deploy(owner, "src/VolMarket.sol:VolMarket", token, FEE_BPS, SHARE_BPS, pool,
                          cm.DELTA, cm.N_SEGMENTS, COMMIT_LEAD, REVEAL_LEAD)
        cfg = api.ApiConfig(url=_url(server, "/v1"), key=SECRET)
        honest, tampered, foreign = api.tsfm_agents(cfg, DEV_KEYS[1:4], [model] * 3)
        hashes = [honest.model_hash, tampered.model_hash, sf.model_hash("chronos-2")]
        for i, (a, h) in enumerate(zip((honest, tampered, foreign), hashes, strict=True)):
            assert a.tier == sf.REPRODUCIBLE
            c.send(owner, market, "registerModel(address,address,bytes32)", ZERO, a.address, h)
            a.model_id = i
            assert as_int(c.call(market, "verificationTier(uint256)(uint8)", i)[0]) == 1
            assert c.call(market, "modelHash(uint256)(bytes32)", i)[0].lower() == h.lower()

        t0 = c.timestamp() + 1000
        start = t0 + 2 * cm.DELTA
        c.send(owner, pool, "setSegments(uint256,uint256,int24[])", t0 - 17 * cm.DELTA, cm.DELTA,
               "[" + ",".join(map(str, history_ticks())) + "]")
        c.set_next_timestamp(t0)
        c.send(owner, market, "createRound(uint64,uint256[])", start,
               "[" + ",".join(map(str, BOUNDS)) + "]")

        forecast = honest.commit(c, market, 0)
        assert forecast["proof"] == "0x" and forecast["context_source"] == sf.ONCHAIN
        off = list(forecast["outputs"])
        top = max(range(cm.BUCKETS), key=lambda i: off[i])
        low = (top + 1) % cm.BUCKETS
        off[top] -= sf.RECOMPUTE_TOLERANCE + sf.PROB_QUANTUM
        off[low] += sf.RECOMPUTE_TOLERANCE + sf.PROB_QUANTUM
        tampered.commit(c, market, 0, {**forecast, "outputs": off})
        foreign.commit(c, market, 0, dict(forecast))
        c.set_next_timestamp(start - COMMIT_LEAD)
        for a in (honest, tampered, foreign):
            a.reveal(c, market, 0)

        def recompute(model_id, python):
            monkeypatch.setenv("VOL_REPRO_PYTHON", str(python))
            rc = sr.main(["--model", model, "--rpc-url", c.rpc, "--market", market,
                          "--round", "0", "--model-id", str(model_id)])
            out = capsys.readouterr()
            lines = out.out.strip().splitlines()
            return rc, json.loads(lines[-1]) if lines else None, out.err

        rc, got, _ = recompute(0, runner)
        assert rc == 0 and got["verdict"] == sf.EXACT and got["maxAbsDiff"] == 0
        assert got["revealed"] == got["recomputed"] == forecast["outputs"]
        assert got["modelHash"].lower() == honest.model_hash.lower()
        rc, got, _ = recompute(1, runner)
        assert rc == sr.EXIT_MISMATCH and got["verdict"] == sf.FAIL
        assert got["maxAbsDiff"] == sf.RECOMPUTE_TOLERANCE + sf.PROB_QUANTUM
        rc, got, err = recompute(2, runner)
        assert rc == sr.EXIT_MISMATCH and got is None and "model hash mismatch" in err
        rc, got, err = recompute(0, broken)
        assert rc == sr.EXIT_ERROR and got is None and "no weights" in err

    monkeypatch.setenv("VOL_REPRO_PYTHON", str(runner))
    assert sr.main(["--model", model, "--features=" + ",".join(map(str, FEATURES)),
                    "--bounds=" + ",".join(map(str, BOUNDS))]) == 0
    assert json.loads(capsys.readouterr().out) == forecast["outputs"]
