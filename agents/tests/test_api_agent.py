"""Commit-only TSFM API agent: response conversion to the contract's probability scale, the HTTP
adapter against a local mock server (no outside requests), and one anvil round in which the agent
commits, reveals without a proof, is scored and claims its predictor share."""

import json
import math
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from vol_agents import api_agent as api
from vol_agents import contract_math as cm
from vol_agents.chain import DEV_KEYS, Anvil, address_of, as_int
from vol_agents.round import WINDOW_TICKS, history_ticks

BOUNDS = list(cm.BOUNDS)
FEATURES = cm.features_from_segment_ticks(history_ticks())
SECRET = "test-key-not-real"


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
        "/quantiles": {"quantiles": [{"level": 0.1, "value": 30.0},
                                     {"level": 0.5, "value": 60.0},
                                     {"level": 0.9, "value": 100.0}]},
    }
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    yield srv
    srv.shutdown()


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
    probs = api.probs_from_quantiles([0.1, 0.3, 0.5, 0.7, 0.9], [8, 20, 45, 110, 200], BOUNDS)
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
    assert probs[4] == pytest.approx(1 - cdf(110))


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
    want = api.probs_from_quantiles([0.1, 0.5, 0.9], [30.0, 60.0, 100.0], BOUNDS)
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
                             config=api.ApiConfig(url=_url(server, "/quantiles"), key=SECRET))
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
        assert forecast["source"] == "tsfm-api" and forecast["proof"] == "0x"
        assert server.requests[-1]["body"]["round"]["start"] == start
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
