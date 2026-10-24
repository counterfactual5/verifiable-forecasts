#!/usr/bin/env bash
# Single-round v2 wording: with a vol-replay/v2 replay the rounds view must not imply agents reveal bucket
# probabilities. The flow caption says the per-bucket mass is derived from each agent's quantiles for the
# betting view and that the 5 buckets are parimutuel betting pools only; its canvas label and bucket
# read-out say the same. The settle stage shows each agent's pinball loss and its excess vs climatology,
# never "ln p". A v1 replay keeps the revealed-probability caption and "ln p =".
# DASHBOARD_HTML=<file> checks another index.html (fail-first).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/round_v2"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
cp tests/acceptance/fixtures/sample-replay-v1.json "$tmp/dashboard/v1.json"
sed -n "/<<'PY'$/,/^PY$/p" tests/acceptance/next_dashboard_quantile.sh | sed '1d;$d' > "$tmp/to_v2.py"
python3 "$tmp/to_v2.py" dashboard/sample-replay.json "$tmp/dashboard" || { echo "not ok - v2 fixture"; echo FAIL; exit 1; }

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp" >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$tmp" <<'EOF'
const fs = require("fs");
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const [base, tmp] = process.argv.slice(2);
const errs = [];
const check = (cond, msg) => { console.log(`${cond ? "ok" : "not ok"} - ${msg}`); if (!cond) errs.push(msg); };
(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const data of ["v2.json", "v1.json"]) {
    const d = JSON.parse(fs.readFileSync(`${tmp}/dashboard/${data}`, "utf8"));
    const v2 = data === "v2.json";
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(e.message));
    await page.goto(`${base}/dashboard/?data=${data}#/rounds`);
    await page.waitForSelector("#flow", { state: "attached", timeout: 15000 });
    const ri = d.rounds.findIndex((r) => !r.outcome.voided);
    await page.evaluate((ri) => setRound(ri, false), ri);
    await page.waitForTimeout(200);
    const cap = await page.locator(".flowcard .flow-cap").innerText();
    const label = await page.locator("#flow").getAttribute("aria-label");
    const settle = (await page.locator('.pl-stage[data-stage="3"]').innerText()).replace(/\s+/g, " ");
    if (v2) {
      check(/derived from quantiles/i.test(cap) && /parimutuel/i.test(cap) && /下注池/.test(cap) && !/按各自揭示的概率/.test(cap),
            `v2: flow caption says bucket mass is derived from quantiles and buckets are parimutuel pools only (${cap.replace(/\s+/g, " ").slice(0, 160)})`);
      check(/derived from quantiles/i.test(label) && /parimutuel/i.test(label), `v2: flow canvas label (${label?.slice(0, 120)})`);
      const r = d.rounds[ri];
      const ok = d.agents.every((a) => { const ra = r.agents[a.agent]; return ra?.pinball_loss == null
        || (settle.includes(ra.pinball_loss.toFixed(3)) && settle.includes(`${ra.excess > 0 ? "+" : ""}${ra.excess.toFixed(3)}`)); });
      check(ok && /pinball loss/.test(settle) && /vs climatology/.test(settle) && !/ln p/.test(settle), `v2: settle stage shows pinball loss and excess vs climatology per agent, no ln p (${settle.slice(0, 200)})`);
      const geo = await page.evaluate(() => {
        const c = document.getElementById("flow"), r = c.getBoundingClientRect();
        const g = flowGeom(c.clientWidth, c.clientHeight, STATE.model.rounds[STATE.round].agents.length);
        return { x: r.left + g.bx, y: r.top + g.by(2) };
      });
      await page.locator("#flow").scrollIntoViewIfNeeded(); await page.waitForTimeout(100);
      const g2 = await page.evaluate(() => { const c = document.getElementById("flow"), r = c.getBoundingClientRect();
        const g = flowGeom(c.clientWidth, c.clientHeight, STATE.model.rounds[STATE.round].agents.length); return { x: r.left + g.bx, y: r.top + g.by(2) }; });
      await page.mouse.move(g2.x, g2.y); await page.waitForTimeout(120);
      const tip = await page.evaluate(() => document.getElementById("tipbox")?.innerText ?? "");
      check(/derived from quantiles/i.test(tip), `v2: bucket read-out marks the mass as derived from quantiles (${tip.replace(/\s+/g, " ").slice(0, 100)})`);
    } else {
      check(/按各自揭示的概率流向 5 个波动率档位/.test(cap), "v1: flow caption keeps revealed bucket probabilities");
      check(/ln p = /.test(settle), "v1: settle stage keeps ln p");
    }
    check(pageErrors.length === 0, `${data}: no page errors (${pageErrors.join("; ")})`);
    await page.close();
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log("FAIL"); process.exit(1); });
EOF
