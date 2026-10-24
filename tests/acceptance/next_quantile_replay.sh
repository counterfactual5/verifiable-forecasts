#!/usr/bin/env bash
# Quantile replay acceptance (vol-replay/v2, demo/fork_round.py):
# - deploys VolMarket with the quantile levels and outputScaleBits 12, creates rounds with the
#   training-period baseline quantiles (agents/models/baseline_quantiles.json, validated: market
#   levels, on the 2^-12 grid, strictly increasing), deploys VolFeeConsumer with
#   baselineScore = -train mean loss, reads getRoundScoring / getPrediction / getPredictionLoss,
#   ERC-8004 tag1 "pinball";
# - summarize() turns per-round pinball rows into mean_pinball_loss / mean_excess / total_excess /
#   coverage50 / coverage80 / beat_baseline_rounds and baseline_mean_pinball_loss;
# - a v2 replay JSON (REPLAY_JSON, else demo/out/fork_replay.json when it is v2) carries every field
#   the dashboard reads, with integers that agree with their floats and the pinball mirror.
# FORK_ROUND=<file> checks another fork_round.py (fail-first against the previous version).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
fail=0
fr="${FORK_ROUND:-demo/fork_round.py}"
tmp="$root/docs/.local/tmp/quantile_replay"
mkdir -p "$tmp" && cp "$fr" "$tmp/fork_round.py"

res=$(cd "$root/agents" && PYTHONPATH="$root/agents:$tmp:$root/demo" uv run --project "$root/agents" python - "$tmp" "$root" <<'EOF' 2>&1
import inspect, json, sys
from pathlib import Path
check = lambda c, m: print(("ok - " if c else "not ok - ") + m)
try:
    import fork_round as fr
except Exception as e:  # noqa: BLE001
    check(False, f"fork_round imports ({type(e).__name__}: {e})"); sys.exit(0)
from vol_agents import contract_math as cm
src = inspect.getsource(fr)
fr.REPO = Path(sys.argv[2])
fr.BASELINE_FILE = fr.REPO / "agents" / "models" / "baseline_quantiles.json"
check('"vol-replay/v2"' in src, "writes schema vol-replay/v2")
check(getattr(fr, "REPUTATION_TAG1", None) == "pinball", "ERC-8004 tag1 is pinball")
check("({int_list(LEVELS_E18)},{cm.OUTPUT_SCALE_BITS})" in src and "MAX_DEVIATION_BPS, MAX_FEED_AGE," in src, "VolMarket constructor gets quantile levels and outputScaleBits")
check('createRound(uint64,uint256[],int256[])' in src, "createRound passes the baseline quantiles")
for sig in ("getRoundScoring(uint256)(int256,uint256,int256[])", "getPredictionLoss(uint256,address)(uint256,uint256)",
            "getPrediction(uint256,address)(bool,uint256,int256[],int256)", "FeeRecorded(uint256,uint24,uint256,int256[])"):
    check(sig in src, f"reads {sig.split('(')[0]} with the v2 ABI")
check('fee["baseline_score_e18"]' in src, "VolFeeConsumer gets baselineScore")

tmp = Path(sys.argv[1])
if hasattr(fr, "load_baseline"):
    b = fr.load_baseline()
    q = b["quantiles_e18"]
    check(len(q) == cm.K and all(v % cm.OUTPUT_UNIT_E18 == 0 for v in q) and all(y > x for x, y in zip(q, q[1:])),
          "baseline quantiles: K values on the 2^-12 grid, strictly increasing")
    raw = json.loads((fr.BASELINE_FILE).read_text())
    bad = dict(raw, quantiles_e18=[raw["quantiles_e18"][1], raw["quantiles_e18"][0]] + raw["quantiles_e18"][2:])
    (tmp / "bad.json").write_text(json.dumps(bad))
    try:
        fr.load_baseline(tmp / "bad.json"); check(False, "non-increasing baseline rejected")
    except SystemExit:
        check(True, "non-increasing baseline rejected")
else:
    check(False, "load_baseline reads agents/models/baseline_quantiles.json")

W = 10**18
def row(loss, base, q, y):
    return {"entered": True, "pinball_loss": loss, "excess": base - loss, "beat_baseline": base > loss,
            "covered50": q[1] <= y <= q[3], "covered80": q[0] <= y <= q[4], "predictor_reward_wei": "0"}
BQ = [4.5, 5.5, 6.4, 7.3, 8.0]
rounds = []
for i, (y, la, lb) in enumerate([(6.0, 0.30, 0.25), (8.5, 0.40, 0.50), (5.0, 0.35, 0.35)]):
    base = [0.33, 0.45, 0.38][i]
    rounds.append({"outcome": {"voided": False, "winning_bucket": 2}, "ln_rv": y, "ln_rv_e18": str(int(y * W)),
                   "baseline_loss": base, "baseline_quantiles_e18": [str(int(v * W)) for v in BQ],
                   "features_match_mainnet": True, "rv_matches_mainnet": True,
                   "fee": {"mirror_matches": True, "mirror": {"equal_weight_fallback": False}, "fixed_bps": 5,
                           "prev_hour_bps": 4, "forecast_bps": 3, "fair_bps": 3.5},
                   "agents": {"a": row(la, base, [5, 5.8, 6.2, 7, 7.6], y), "b": row(lb, base, [4, 6.1, 6.3, 6.5, 9], y)}})
class A:  # noqa: D101
    def __init__(self, n): self.name = n
try:
    s = fr.summarize(rounds, [A("a"), A("b")], {"a": {}, "b": {}})
    a = s["agents"]["a"]
    check(abs(a["mean_pinball_loss"] - 0.35) < 1e-9 and abs(a["total_excess"] - (0.03 + 0.05 + 0.03)) < 1e-9,
          f"summary mean_pinball_loss / total_excess ({a.get('mean_pinball_loss')}, {a.get('total_excess')})")
    check(a["beat_baseline_rounds"] == 3 and s["agents"]["b"]["beat_baseline_rounds"] == 2, "summary beat_baseline_rounds")
    check(abs(a["coverage80"] - 2 / 3) < 1e-3 and abs(a["coverage50"] - 1 / 3) < 1e-3, "summary coverage50 / coverage80")
    check(abs(s["baseline_mean_pinball_loss"] - (0.33 + 0.45 + 0.38) / 3) < 1e-6, "summary baseline_mean_pinball_loss")
    check("uniform_total_log_score" not in s, "no uniform log-score baseline in v2 summary")
except Exception as e:  # noqa: BLE001
    check(False, f"summarize on pinball rows ({type(e).__name__}: {e})")
EOF
)
[[ $? -eq 0 ]] || fail=1
printf '%s\n' "$res"
grep -q '^not ok' <<<"$res" && fail=1
grep -q '^ok' <<<"$res" || fail=1

json="${REPLAY_JSON:-demo/out/fork_replay.json}"
[[ $json = /* ]] || json="$root/$json"
if [[ -f "$json" ]] && python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("schema") == "vol-replay/v2" else 1)' "$json"; then
  res=$(cd "$root/agents" && uv run python - "$json" <<'EOF' 2>&1
import json, sys
from vol_agents import contract_math as cm
check = lambda c, m: print(("ok - " if c else "not ok - ") + m)
d = json.load(open(sys.argv[1]))
p, s = d["params"], d["summary"]
check(p["quantile_levels"] == [0.1, 0.25, 0.5, 0.75, 0.9] and p["output_scale_bits"] == 12, "params quantile_levels / output_scale_bits")
levels = [int(v) for v in p["quantile_levels_e18"]]
ok_rounds = ok_agents = True
for r in d["rounds"]:
    if r["outcome"]["voided"]:
        continue
    y = int(r["ln_rv_e18"]); bq = [int(v) for v in r["baseline_quantiles_e18"]]
    ok_rounds &= abs(r["ln_rv"] - y / 1e18) < 1e-12 and int(r["baseline_loss_e18"]) == cm.pinball_e18(y, bq, levels)
    for n, a in r["agents"].items():
        if not a["entered"]:
            continue
        q = [int(v) for v in a["quantiles_e18"]]
        ok_agents &= a["outputs"] == [v // cm.OUTPUT_UNIT_E18 for v in q] and all(b > x for x, b in zip(q, q[1:]))
        loss = int(a["pinball_loss_e18"])
        ok_agents &= loss == cm.pinball_e18(y, q, levels) and int(a["score_e18"]) == -loss
        ok_agents &= int(a["excess_e18"]) == max(0, int(r["baseline_loss_e18"]) - loss)
        ok_agents &= a["beat_baseline"] == (int(a["excess_e18"]) > 0)
        ok_agents &= a["covered50"] == (q[1] <= y <= q[3]) and a["covered80"] == (q[0] <= y <= q[4])
        ok_agents &= all(k in a for k in ("prove_seconds", "proof_cached", "reveal_gas", "forecast_source", "predictor_reward_wei"))
check(ok_rounds, "rounds: ln_rv / baseline_loss_e18 agree with the pinball mirror")
check(ok_agents, "agents: quantiles / outputs / pinball_loss / score / excess / coverage agree with the mirror")
check(all(k in s for k in ("baseline_mean_pinball_loss", "features_match_mainnet", "rv_matches_mainnet")), "summary v2 keys")
check(all(all(k in a for k in ("mean_pinball_loss", "mean_excess", "total_excess", "beat_baseline_rounds", "coverage50", "coverage80"))
          and a["erc8004"]["tag1"] == "pinball" for a in s["agents"].values()), "summary per agent v2 keys, ERC-8004 tag1 pinball")
check(s["features_match_mainnet"] and s["rv_matches_mainnet"], "fork features and RV match mainnet")
check(all(r["fee"]["mirror_matches"] for r in d["rounds"]), "fee mirror matches on-chain every round")
check(all(t["honest_proof_verifies"] and not t["tampered_output_verifies"] for t in d["tamper_checks"]), "tamper check: honest verifies, tampered rejected")
EOF
)
  [[ $? -eq 0 ]] || fail=1
  printf '%s\n' "$res"
  grep -q '^not ok' <<<"$res" && fail=1
else
  echo "SKIP - no vol-replay/v2 replay JSON (REPLAY_JSON or demo/out/fork_replay.json)"
fi
[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
