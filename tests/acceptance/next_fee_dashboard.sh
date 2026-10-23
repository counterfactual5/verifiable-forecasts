#!/usr/bin/env bash
# R3 acceptance: the replay dashboard shows a per-round fee comparison card (fair LVR fee vs fixed 5 bps,
# previous-hour and forecast strategies) with a legend, tooltips and MAE figures that match the replay
# JSON; no horizontal overflow at 375 px; the card disappears when the JSON carries no fee data while the
# other cards still render; the screenshot and the README consumer section are updated.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

json=dashboard/sample-replay.json
python3 -c "import json,sys; d=json.load(open('$json')); sys.exit(0 if 'fee_strategies' in d['summary'] else 1)" \
    && ok "$json carries fee data" || { bad "$json carries fee data"; echo FAIL; exit 1; }

tmp="$root/docs/.local/tmp/fee_dashboard"
mkdir -p "$tmp"
python3 - "$json" "$tmp/nofee.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
d["summary"].pop("fee_strategies", None)
d["params"].pop("fee_consumer", None)
d["contracts"].pop("fee_consumer", None)
for r in d["rounds"]:
    r.pop("fee", None)
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
    await page.goto(`${base}/dashboard/?data=${data}`);
    await page.waitForSelector("#app section.card", { timeout: 15000 });
    return { page, pageErrors };
  };

  const { page, pageErrors } = await open("sample-replay.json", 1280);
  const card = page.locator("#fee-card");
  check(await card.count() === 1, "fee comparison card #fee-card rendered");
  const paths = await card.locator("svg path").count();
  check(paths === 4, `fee chart has 4 lines (found ${paths})`);
  const legend = (await card.count()) === 1 ? (await card.innerText()).toLowerCase() : "";
  for (const k of ["fair", "fixed", "prev", "forecast"]) check(legend.includes(k), `legend names the ${k} series`);
  const titles = await card.locator("svg circle title").allTextContents();
  const series = { fair: "fair_bps", fixed: "fixed_bps", prev: "prev_hour_bps", forecast: "forecast_bps" };
  for (const i of [0, 11, 23]) {
    const r = d.rounds[i], label = r.window_utc[0].slice(11, 16);
    for (const [k, field] of Object.entries(series)) {
      const hit = titles.filter((s) => s.toLowerCase().includes(k) && s.includes(` · ${label}: `));
      const v = hit.length ? parseFloat(hit[0].split(": ").pop()) : NaN;
      check(hit.length === 1 && Math.abs(v - r.fee[field]) < 0.006,
            `tooltip ${k} @ ${label} = ${r.fee[field]} (got ${hit[0] ?? "none"})`);
    }
  }
  for (const k of ["fixed", "prev_hour", "forecast"]) {
    const el = card.locator(`[data-mae="${k}"]`);
    const txt = (await el.count()) === 1 ? await el.innerText() : "";
    const v = parseFloat(txt.replace(/[^0-9.\-]/g, ""));
    check(Math.abs(v - d.summary.fee_strategies.mae_bps[k]) < 0.006, `MAE ${k} shown ${txt || "none"} = ${d.summary.fee_strategies.mae_bps[k]}`);
  }
  const withFee = await page.locator("#app section.card").count();
  check(pageErrors.length === 0, `no page errors (${pageErrors.join("; ")})`);

  const mob = await open("sample-replay.json", 375);
  const ov = await mob.page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
  check(ov[0] <= ov[1], `375 px: scrollWidth ${ov[0]} <= clientWidth ${ov[1]}`);
  check(await mob.page.locator("#fee-card").count() === 1, "375 px: fee card rendered");

  const nf = await open("../docs/.local/tmp/fee_dashboard/nofee.json", 1280);
  check(await nf.page.locator("#fee-card").count() === 0, "no fee data: fee card absent");
  const without = await nf.page.locator("#app section.card").count();
  check(without === withFee - 1 && without > 0, `no fee data: the other ${without} cards render (with fee ${withFee})`);
  check(await nf.page.locator("#error").count() === 0 && nf.pageErrors.length === 0, "no fee data: no error");
  await browser.close();
  console.log(errs.length ? "FAIL" : "DONE");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("FAIL " + e.message); process.exit(1); });
EOF
); nrc=$?
printf '%s\n' "$res" | grep -E '^(ok|not ok) - '
[[ $nrc -eq 0 ]] && ok "dashboard fee card checks" || { bad "dashboard fee card checks"; printf '%s\n' "$res" | grep -vE '^(ok) - ' | tail -5; }

png=docs/img/dashboard.png
ref=$(git log -1 --format=%ct -- "$json" 2>/dev/null || echo 0)
# A screenshot committed together with the data keeps an mtime older than that commit, so a clean
# screenshot is judged by its own commit time instead.
if git diff --quiet HEAD -- "$png" 2>/dev/null && [[ -n "$(git log -1 --format=%ct -- "$png" 2>/dev/null)" ]]; then
    pc=$(git log -1 --format=%ct -- "$png")
    [[ $pc -ge $ref ]] && ok "$png committed with or after the fee data" || bad "$png committed with or after the fee data ($pc < $ref)"
else
    mt=$(stat -f %m "$png" 2>/dev/null || stat -c %Y "$png" 2>/dev/null || echo 0)
    [[ $mt -gt $ref ]] && ok "$png newer than the fee data commit" || bad "$png newer than the fee data commit ($mt <= $ref)"
fi

python3 - <<'EOF' && ok "README consumer section: simulated, lending collateral roadmap" || bad "README consumer section: simulated, lending collateral roadmap"
import re, sys
t = open("README.md", encoding="utf-8").read()
secs = re.split(r"(?m)^## ", t)
sec = next((s for s in secs if "consumer" in s.split("\n", 1)[0].lower()), None)
sys.exit(0 if sec and "simulated" in sec.lower() and re.search(r"collateral", sec, re.I) and re.search(r"roadmap", sec, re.I) else 1)
EOF

bash ~/.agents/skills/goal/scripts/ui_check.sh run . --no-record >/dev/null 2>&1 && ok "ui smoke passes" || bad "ui smoke passes"

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
