#!/usr/bin/env bash
# R2 acceptance: the 24h mainnet-fork replay records VolFeeConsumer's fee on-chain each round between
# the reveal deadline and startTime, mirrors it in Python, and compares three fee strategies (fixed
# 5 bps, previous hour's realized vol, forecast) against the LVR break-even fair fee by mean absolute
# error; the replay's existing fields stay intact.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

mod=agents/vol_agents/fee_strategies.py
t=agents/tests/test_fee_strategies.py
json=dashboard/sample-replay.json
cd "$root"
[[ -f $mod ]] && ok "$mod exists" || { bad "$mod exists"; echo FAIL; exit 1; }
[[ -f $t ]] && ok "$t exists" || { bad "$t exists"; echo FAIL; exit 1; }

grep -q 'VolFeeConsumer' demo/fork_round.py && ok "replay deploys VolFeeConsumer" || bad "replay deploys VolFeeConsumer"
grep -qE '^\s*(from|import)\s+analysis' demo/fork_round.py && bad "demo does not import analysis" || ok "demo does not import analysis"

out=$(cd agents && uv run pytest tests/test_fee_strategies.py -q 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "fee module pytest green" || { bad "fee module pytest green (rc $rc)"; printf '%s\n' "$out" | tail -20; }

if [[ -f demo/out/fork_replay.json ]]; then
    cmp -s demo/out/fork_replay.json "$json" && ok "sample-replay.json is the latest fork_replay.json" \
        || bad "sample-replay.json is the latest fork_replay.json"
fi

res=$(cd agents && uv run python - "$root/$json" <<'EOF' 2>&1
import json, math, sys
from vol_agents.fee_strategies import expected_var_e18, fee_pips, fee_for_var

d = json.load(open(sys.argv[1]))
assert d["schema"] == "vol-replay/v1", d["schema"]
rounds = d["rounds"]
assert len(rounds) == 24, f"{len(rounds)} rounds"

old_round_keys = {"h", "start", "id", "features", "features_match_mainnet", "bets", "agents", "end",
                  "window_utc", "mainnet", "real_segment_ticks", "real_realized_vol", "real_bucket",
                  "rv_matches_mainnet", "outcome", "chainlink", "fee_split"}
old_summary_keys = {"rounds", "settled", "voided", "bucket_counts", "uniform_total_log_score",
                    "features_match_mainnet", "rv_matches_mainnet", "agents"}
s = d["summary"]
assert old_summary_keys <= set(s), f"summary lost {old_summary_keys - set(s)}"
assert s["rv_matches_mainnet"] is True and s["features_match_mainnet"] is True, "summary mainnet match"

p = d["params"]
fc = p["fee_consumer"]
bucket_var = [int(v) for v in fc["bucket_var"]]
fpv = int(fc["fee_per_var_e18"])
lo, hi = int(fc["min_fee_pips"]), int(fc["max_fee_pips"])
assert len(bucket_var) == 5 and bucket_var == sorted(bucket_var), bucket_var
assert 0 <= lo <= hi, (lo, hi)
assert int(fc["fixed_fee_pips"]) == 500, "fixed strategy is the pool's real 5 bps tier"
cal = fc["calibration"]["window"]
assert cal[1] <= d["replay"]["start"], f"calibration window {cal} reaches into the replay"
assert d["contracts"].get("fee_consumer", "").startswith("0x"), "fee_consumer address"
reveal_lead = int(p["reveal_lead_s"])

strategies = ("fixed", "prev_hour", "forecast")
errs = {k: [] for k in strategies}
for r in rounds:
    h = r["h"]
    assert old_round_keys <= set(r), f"h={h} lost {old_round_keys - set(r)}"
    assert r["rv_matches_mainnet"] is True and r["features_match_mainnet"] is True, f"h={h} mainnet match"
    f = r["fee"]
    on, mi = f["onchain"], f["mirror"]
    ts = int(on["timestamp"])
    assert r["start"] - reveal_lead <= ts < r["start"], f"h={h} recorded at {ts}, start {r['start']}"
    assert isinstance(on["block"], int) and on["tx"].startswith("0x"), f"h={h} record tx"
    mix = [int(x) for x in on["mix_e18"]]
    assert len(mix) == 5 and sum(mix) == 10**18, f"h={h} mix {mix}"
    assert [int(x) for x in mi["mix_e18"]] == mix, f"h={h} mirror mix differs"
    ev = expected_var_e18(mix, bucket_var)
    assert ev == int(on["expected_var_e18"]), f"h={h} expected var {ev} != {on['expected_var_e18']}"
    fee = fee_pips(ev, fpv, lo, hi)
    assert fee == int(on["fee_pips"]) == int(mi["fee_pips"]), f"h={h} fee {fee} on {on['fee_pips']} mirror {mi['fee_pips']}"
    assert f["forecast_bps"] == fee / 100, f"h={h} forecast_bps"
    assert f["fixed_bps"] == 5, f"h={h} fixed_bps"
    ph = f["prev_hour"]
    assert ph["window"][1] <= ts, f"h={h} prev_hour window {ph['window']} ends after the fee time {ts}"
    assert f["prev_hour_bps"] == fee_for_var(int(ph["realized_vol"]), fpv, lo, hi) / 100, f"h={h} prev_hour_bps"
    fair = f["fair_bps"]
    assert isinstance(fair, (int, float)) and math.isfinite(fair) and fair >= 0, f"h={h} fair {fair}"
    for k in strategies:
        errs[k].append(abs(f[f"{k}_bps"] - fair))

fs = s["fee_strategies"]
assert fs["rounds"] == 24, fs
for k in strategies:
    mae = sum(errs[k]) / len(errs[k])
    assert abs(fs["mae_bps"][k] - mae) < 1e-3, f"{k} mae {fs['mae_bps'][k]} != recomputed {mae}"
print("MAE bps " + " ".join(f"{k}={fs['mae_bps'][k]:.4f}" for k in strategies))
EOF
); prc=$?
if [[ $prc -eq 0 ]]; then ok "replay fee records and MAE recompute ($res)"; else bad "replay fee records and MAE recompute"; printf '%s\n' "$res" | tail -8; fi

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
