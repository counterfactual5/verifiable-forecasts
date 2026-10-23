#!/usr/bin/env bash
# R12 acceptance: the replay view opens with a summary line above the first card whose figures are
# taken from the replay JSON as-is: settled/rounds, agents beating the uniform baseline, the best agent
# against uniform, tampered proofs rejected, and the lowest-MAE fee strategy next to the forecast MAE
# (the forecast-driven fee is not the most accurate and must not be shown as such); no overflow.
# Variant files prove the figures are read rather than hardcoded, and a replay without fee data still
# renders the summary without the fee part.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/dashboard_summary"
mkdir -p "$tmp"
python3 - dashboard/sample-replay.json "$tmp" <<'PY'
import json, sys
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
d["summary"]["settled"] = d["summary"]["settled"] - 1
d["summary"]["fee_strategies"]["mae_bps"]["fixed"] = 9.99
json.dump(d, open(out + "/altered.json", "w"))
d = json.load(open(src))
d["summary"].pop("fee_strategies", None)
d["params"].pop("fee_consumer", None)
d["contracts"].pop("fee_consumer", None)
for r in d["rounds"]:
    r.pop("fee", None)
json.dump(d, open(out + "/nofee.json", "w"))
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const base = process.argv[2];
let fail = 0;
const check = (cond, msg) => { console.log((cond ? "ok - " : "not ok - ") + msg); if (!cond) fail = 1; };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const d = JSON.parse(require("fs").readFileSync("dashboard/sample-replay.json", "utf8"));
  const s = d.summary, u = s.uniform_total_log_score;
  const ag = Object.entries(s.agents);
  const best = ag.reduce((a, b) => (b[1].total_log_score > a[1].total_log_score ? b : a));
  const beat = ag.filter(([, v]) => v.total_log_score > u).length;
  const rej = d.tamper_checks.filter((t) => t.tampered_output_verifies === false).length;
  const mae = s.fee_strategies.mae_bps;
  const low = Object.entries(mae).reduce((a, b) => (b[1] < a[1] ? b : a));
  const want = [`${s.settled}/${s.rounds}`, `${beat}/${ag.length}`, best[0].replace("agent-", ""), best[1].total_log_score.toFixed(1), u.toFixed(1),
    `${rej}/${d.tamper_checks.length}`, low[0].replace("_", " "), low[1].toFixed(2), mae.forecast.toFixed(2)];
  for (const width of [1280, 375]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    await page.goto(`${base}/dashboard/?data=sample-replay.json`);
    await page.waitForSelector("#app svg", { timeout: 15000 });
    const r = await page.evaluate(() => {
      const el = document.querySelector("#summary");
      const first = document.querySelector("#app .card");
      return { found: !!el, text: el ? el.textContent.replace(/\s+/g, " ") : "", top: el ? el.getBoundingClientRect().top : 1e9,
        above: !!el && !!first && el.getBoundingClientRect().bottom <= first.getBoundingClientRect().top + 1,
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
    });
    check(r.found && r.above, `@${width}: #summary sits above the first card`);
    check(r.top < 900, `@${width}: the summary is on the first screen (top ${Math.round(r.top)}px)`);
    const missing = want.filter((w) => !r.text.includes(w));
    check(missing.length === 0, `@${width}: the summary quotes ${JSON.stringify(want)} (missing ${JSON.stringify(missing)})`);
    check(r.overflow <= 0, `@${width}: no horizontal overflow (${r.overflow}px)`);
    await page.close();
  }
  const summaryOf = async (data) => {
    const pg = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const errors = [];
    pg.on("pageerror", (e) => errors.push(e.message));
    await pg.goto(`${base}/dashboard/?data=${data}`);
    await pg.waitForSelector("#app svg", { timeout: 15000 });
    const r = await pg.evaluate(() => ({ text: document.querySelector("#summary")?.textContent.replace(/\s+/g, " ") ?? null, error: !!document.querySelector("#error") }));
    await pg.close();
    return { ...r, errors };
  };
  const alt = await summaryOf("../docs/.local/tmp/dashboard_summary/altered.json");
  const altLow = Object.entries({ ...mae, fixed: 9.99 }).reduce((a, b) => (b[1] < a[1] ? b : a));
  check(alt.text !== null && alt.text.includes(`${s.settled - 1}/${s.rounds}`) && alt.text.includes(altLow[0].replace("_", " ")) && !alt.text.includes(low[1].toFixed(2)),
    `altered replay: the summary follows the data (${s.settled - 1}/${s.rounds}, lowest MAE ${altLow[0]}) ${JSON.stringify(alt.text)}`);
  const nf = await summaryOf("../docs/.local/tmp/dashboard_summary/nofee.json");
  check(nf.text !== null && !/MAE/.test(nf.text) && !nf.error && nf.errors.length === 0, `no fee data: the summary renders without the fee part and no error ${JSON.stringify(nf.text)} ${JSON.stringify(nf.errors)}`);
  const page = await browser.newPage({ viewport: { width: 375, height: 900 } });
  await page.goto(`${base}/dashboard/?data=sample-round.json`);
  await page.waitForSelector("#app svg", { timeout: 15000 });
  const o = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  check(o <= 0, `single-round @375: no horizontal overflow (${o}px)`);
  await page.close();
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
