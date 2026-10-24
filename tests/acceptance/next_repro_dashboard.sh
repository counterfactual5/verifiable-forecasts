#!/usr/bin/env bash
# R6 acceptance: the 24-hour replay runs the three reproducible time-series model agents
# (timesfm-3.0, timestral-209m, chronos-2), records tier / model_hash / per-round probs_e18 and the
# real tolerance recompute verdict (every bucket within the recorded tolerance), the
# dashboard shows zk / 可复现-已核验 / 仅提交 badges (and a visible failure badge), and README / DEMO
# numbers follow the new run; the R2 / R3 acceptance keeps passing.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

json=dashboard/sample-replay.json
png=docs/img/dashboard.png
# R5 milestone: the replay JSON and the screenshot must have changed since then
base=41a9900
export VOL_REPRO_PYTHON="${VOL_REPRO_PYTHON:-$HOME/Work/chronos-experiment/.venv/bin/python}"
[[ -x "$VOL_REPRO_PYTHON" ]] && ok "VOL_REPRO_PYTHON executable" || bad "VOL_REPRO_PYTHON executable ($VOL_REPRO_PYTHON)"

python3 - "$json" <<'EOF' && ok "replay JSON: reproducible agent fields" || bad "replay JSON: reproducible agent fields"
import json, re, sys
d = json.load(open(sys.argv[1]))
errs = []
rounds = d["rounds"]
if len(rounds) != 24: errs.append(f"{len(rounds)} rounds")
ag = d["agents"]
zk = [a for a in ag if a.get("tier") == "zk"]
rep = [a for a in ag if a.get("tier") == "reproducible"]
want = ["agent-chronos-2", "agent-timesfm-3.0", "agent-timestral-209m"]
if len(zk) != 3 or sorted(a["agent"] for a in rep) != want: errs.append(f"tiers {[(a['agent'], a.get('tier')) for a in ag]}")
if any(a.get("model_type") is None for a in ag): errs.append("model_type dropped")
for a in rep:
    tol = int(a.get("recompute_tolerance") or 0)
    if not 0 < tol <= 10**15: errs.append(f"{a['agent']} recompute_tolerance {a.get('recompute_tolerance')}")
    if "vol_agents.tsfm_recompute" not in (a.get("recompute_command") or ""): errs.append(f"{a['agent']} recompute_command")
    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", a.get("model_hash") or "") or int(a["model_hash"], 16) == 0:
        errs.append(f"model_hash {a.get('model_hash')}")
    e = d["summary"]["agents"][a["agent"]]["erc8004"]
    if not e["tag2"].endswith("-commit") or e["count"] != 24: errs.append(f"erc8004 {e}")
    for r in rounds:
        ra = r["agents"].get(a["agent"], {})
        pe = ra.get("probs_e18")
        if not (isinstance(pe, list) and len(pe) == 5 and all(isinstance(v, str) for v in pe)
                and sum(int(v) for v in pe) == 10**18):
            errs.append(f"round {r['h']} probs_e18 {pe}"); break
        if ra.get("reproduced") is not True:
            errs.append(f"{a['agent']} round {r['h']} reproduced {ra.get('reproduced')}"); break
        if ra.get("recompute_verdict") not in ("exact", "tolerant") or not 0 <= int(ra.get("recompute_max_abs_diff", -1)) <= tol:
            errs.append(f"{a['agent']} round {r['h']} verdict {ra.get('recompute_verdict')} diff {ra.get('recompute_max_abs_diff')}"); break
        if ra.get("forecast_source") == "placeholder":
            errs.append(f"round {r['h']} placeholder source"); break
for a in zk:
    if not a.get("model_hash") is None and not re.fullmatch(r"0x[0-9a-fA-F]{64}", a["model_hash"]):
        errs.append(f"zk model_hash {a['model_hash']}")
s = d["summary"]
if s["rv_matches_mainnet"] is not True or s["features_match_mainnet"] is not True: errs.append("mainnet match")
if "fee_strategies" not in s or any("fee" not in r for r in rounds): errs.append("fee fields")
print("\n".join(errs)); sys.exit(1 if errs else 0)
EOF

# independent offline recompute of three rounds from their recorded features: timesfm-3.0 reads
# only the 16 features, so it is recomputable from the JSON alone, within the recorded tolerance
mkdir -p "$root/docs/.local"
python3 - "$json" > "$root/docs/.local/tmp_repro_rounds.tsv" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
a = next(a for a in d["agents"] if a["agent"] == "agent-timesfm-3.0")
b = ",".join(map(str, d["params"]["bounds"]))
for h in (0, 11, 23):
    r = d["rounds"][h]
    print(h, ",".join(map(str, r["features"])), b, json.dumps([int(v) for v in r["agents"][a["agent"]]["probs_e18"]]), int(a["recompute_tolerance"]), sep="\t")
EOF
if [[ -s "$root/docs/.local/tmp_repro_rounds.tsv" ]]; then
    while IFS=$'\t' read -r h f b want tol; do
        got=$(cd agents && uv run python -m vol_agents.tsfm_recompute --model timesfm-3.0 --features="$f" --bounds="$b" 2>/dev/null)
        python3 -c "import json,sys; g=json.loads(sys.argv[1]); w=json.loads(sys.argv[2]); t=int(sys.argv[3]); sys.exit(0 if len(g)==5 and all(abs(x-y)<=t for x,y in zip(g,w)) and sum(g)==10**18 else 1)" "$got" "$want" "$tol" 2>/dev/null \
            && ok "round $h offline recompute equals probs_e18" || bad "round $h offline recompute equals probs_e18 (got ${got:-nothing})"
    done < "$root/docs/.local/tmp_repro_rounds.tsv"
else bad "round features for offline recompute"; fi
rm -f "$root/docs/.local/tmp_repro_rounds.tsv"

tmp="$root/docs/.local/tmp/repro_dashboard"
mkdir -p "$tmp"
python3 - "$json" "$tmp/failed.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
name = "agent-timesfm-3.0"
d["rounds"][5]["agents"][name]["reproduced"] = False
json.dump(d, open(sys.argv[2], "w"))
EOF

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
res=$(NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$root/$json" <<'EOF' 2>&1
const fs = require("fs");
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("FAIL no playwright"); process.exit(1); }
const [base, jsonPath] = process.argv.slice(2);
const d = JSON.parse(fs.readFileSync(jsonPath, "utf8"));
const errs = [];
const check = (cond, msg) => { console.log(`${cond ? "ok" : "not ok"} - ${msg}`); if (!cond) errs.push(msg); };
(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const open = async (data, width) => {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(e.message));
    await page.goto(`${base}/dashboard/?data=${data}#/agents`);
    await page.waitForSelector("#app section.card >> visible=true", { timeout: 15000 });
    return { page, pageErrors };
  };
  const reps = d.agents.filter((a) => a.tier === "reproducible"), rep = reps[0];
  const { page, pageErrors } = await open("sample-replay.json", 1280);
  const text = await page.locator("#app").innerText();
  const zkBadges = await page.locator(".badge.zk").count();
  check(zkBadges >= 3, `at least 3 zk badges (found ${zkBadges})`);
  const repBadge = page.locator(".badge", { hasText: "可复现-已核验" });
  check(reps.length === 3 && await repBadge.count() >= reps.length, `every reproducible agent shows a 可复现-已核验 badge (${await repBadge.count()}/${reps.length})`);
  check(/reproducible/i.test(text), "badge or legend names reproducible");
  const tips = await page.locator(".badge[title]").evaluateAll((els) => els.map((e) => e.title).join(" | "));
  check(/public weights|公开权重/i.test(tips) && /on-?chain features|链上特征/i.test(tips),
        "reproducible badge tooltip says it is recomputed from onchain features with public weights");
  check(reps.length === 3 && reps.every((a) => text.includes(a.agent)), `reproducible agents ${reps.map((a) => a.agent)} listed`);
  check(!/reproduce failed/i.test(text), "no failure badge when every round reproduced");
  check(!/placeholder/i.test(text), "no placeholder label in the replay view");
  check(pageErrors.length === 0, `no page errors (${pageErrors.join("; ")})`);

  const f = await open("../docs/.local/tmp/repro_dashboard/failed.json", 1280);
  const ft = await f.page.locator("#app").innerText();
  check(/reproduce failed/i.test(ft), "a round with reproduced=false shows a reproduce failed badge");
  check(await f.page.locator(".badge.bad", { hasText: /reproduce failed/i }).count() >= 1, "failure badge uses the bad colour");

  const mob = await open("sample-replay.json", 375);
  const ov = await mob.page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
  check(ov[0] <= ov[1], `375 px: scrollWidth ${ov[0]} <= clientWidth ${ov[1]}`);
  check(await mob.page.locator(".badge", { hasText: "可复现-已核验" }).count() >= 1, "375 px: reproducible badge rendered");
  await browser.close();
  console.log(errs.length ? "FAIL" : "DONE");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("FAIL " + e.message); process.exit(1); });
EOF
); nrc=$?
printf '%s\n' "$res" | grep -E '^(ok|not ok) - '
[[ $nrc -eq 0 ]] && ok "dashboard tier badge checks" || { bad "dashboard tier badge checks"; printf '%s\n' "$res" | grep -vE '^(ok) - ' | tail -5; }

git diff --quiet "$base" -- "$json" && bad "$json regenerated since $base" || ok "$json regenerated since $base"
git diff --quiet "$base" -- "$png" && bad "$png regenerated since $base" || ok "$png regenerated since $base"
jt=$(stat -f %m "$json" 2>/dev/null || stat -c %Y "$json"); pt=$(stat -f %m "$png" 2>/dev/null || stat -c %Y "$png")
[[ $pt -ge $jt ]] && ok "$png written after $json" || bad "$png written after $json ($pt < $jt)"

python3 - "$json" <<'EOF' && ok "README / DEMO follow the new replay" || bad "README / DEMO follow the new replay"
import json, re, sys
d = json.load(open(sys.argv[1]))
readme = open("README.md", encoding="utf-8").read()
demo = open("docs/DEMO.md", encoding="utf-8").read()
errs = []
secs = re.split(r"(?m)^## ", readme)
tiers = next((s for s in secs if "verification tiers" in s.split("\n", 1)[0].lower()), None)
if not tiers or "reproducible" not in tiers.lower() or "vol_agents.tsfm_recompute" not in tiers:
    errs.append("README Verification tiers section (reproducible + tsfm_recompute command)")
for name, s in d["summary"]["agents"].items():
    tot = f"{s['mean_pinball_loss']:.3f}"
    for doc, t in (("README", readme), ("DEMO", demo)):
        if tot not in t: errs.append(f"{doc} lacks {name} mean pinball loss {tot}")
for k, v in d["summary"]["fee_strategies"]["mae_bps"].items():
    if f"{v:.2f}" not in readme: errs.append(f"README lacks MAE {k} {v:.2f}")
for doc, t in (("README", readme), ("DEMO", demo)):
    if "【待冻结" in t: errs.append(f"{doc} still has a 【待冻结数字】 placeholder")
    if "agent-tsfm-api" in t: errs.append(f"{doc} still lists agent-tsfm-api")
    for line in t.splitlines():
        l = line.lower()
        if "placeholder" in l and ("fourth" in l or "commit-only agent" in l or "commit-only placeholder" in l or "worst" in l):
            errs.append(f"{doc} still calls the replay agent a placeholder: {line.strip()[:90]}")
print("\n".join(errs)); sys.exit(1 if errs else 0)
EOF

bash tests/acceptance/next_fee_replay.sh >/dev/null 2>&1 && ok "next_fee_replay.sh still passes" || bad "next_fee_replay.sh still passes"
bash tests/acceptance/next_fee_dashboard.sh >/dev/null 2>&1 && ok "next_fee_dashboard.sh still passes" || bad "next_fee_dashboard.sh still passes"
if [[ -n "${UI_CHECK:-}" ]]; then
  bash "$UI_CHECK" run . --no-record >/dev/null 2>&1 && ok "ui smoke passes" || bad "ui smoke passes"
else
  echo "SKIP - ui smoke (UI_CHECK unset)"
fi

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
