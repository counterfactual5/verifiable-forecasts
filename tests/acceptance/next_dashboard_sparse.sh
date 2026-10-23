#!/usr/bin/env bash
# R1 acceptance: a sparse live replay (1 settled round + the pending hour, e.g. HOURS=1) renders without
# console errors on any of the 6 sub-pages at 1280 and 390, and a single-value line chart gets an axis
# scaled to the value (span >= 5% of it) instead of the degenerate v ± 1; the 24-round sample keeps
# its realized-vol axis as before.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/dashboard_sparse"
mkdir -p "$tmp"
python3 - dashboard/sample-replay.json "$tmp" <<'PY'
import json, sys, time
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
now = int(time.time())
first = d["rounds"][0]
d["rounds"] = [first]
start = now // 3600 * 3600
agents = {a["agent"]: {"entered": True, "probs": first["agents"][a["agent"]]["probs"]} for a in d["agents"]}
d.update({"live": True, "generated_at": now - 60, "next_run_at": start + 3600 + 420,
          "pending_round": {"id": first["id"] + 1, "start": start, "end": start + 3600,
                            "window_utc": [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start)),
                                           time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start + 3600))],
                            "features_match_mainnet": True, "agents": agents}})
json.dump(d, open(out + "/one.json", "w"))
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
res=$(NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); process.exit(1); }
const base = process.argv[2];
const check = (cond, msg) => console.log((cond ? "ok - " : "not ok - ") + msg);
const fs = require("fs");
const VIEWS = ["overview", "live", "rounds", "agents", "fee", "chain"];
// y-axis tick labels of the realized-vol card (right-aligned axis text)
const rvTicks = (page) => page.evaluate(() => {
  const card = [...document.querySelectorAll(".card")].find((c) => /每小时真实波动率/.test(c.querySelector("h2, h3")?.textContent ?? ""));
  if (!card) return null;
  return [...card.querySelectorAll("svg text.ax[text-anchor=end]")].map((t) => Number(t.textContent.replace(/[^\d.\-]/g, "")));
});
(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const d = JSON.parse(fs.readFileSync("docs/.local/tmp/dashboard_sparse/one.json", "utf8"));
  const r0 = d.rounds[0], v = r0.outcome.realized_vol ?? r0.real_realized_vol;
  for (const width of [1280, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    page.on("console", (m) => { if (m.type() === "error" && !/favicon/.test(m.location()?.url ?? "")) errors.push(m.text()); });
    for (const view of VIEWS) {
      await page.goto(`${base}/dashboard/?data=../docs/.local/tmp/dashboard_sparse/one.json#/${view}`);
      await page.waitForSelector("#app svg", { state: "attached", timeout: 15000 });
      await page.waitForTimeout(250);
    }
    for (const view of VIEWS) {
      await page.evaluate((h) => { location.hash = h; }, `#/${view}`);
      await page.waitForTimeout(250);
    }
    await page.setViewportSize({ width: width + 40, height: 900 });
    await page.waitForTimeout(300);
    await page.setViewportSize({ width, height: 900 });
    await page.waitForTimeout(300);
    check(errors.length === 0, `@${width}: 1 round + pending: no console errors or page errors across ${VIEWS.length} sub-pages ${JSON.stringify(errors.slice(0, 3))}`);
    const t = await rvTicks(page);
    const span = t && t.length ? Math.max(...t) - Math.min(...t) : 0;
    check(t && t.length >= 2 && span >= 0.05 * v && Math.min(...t) <= v && Math.max(...t) >= v,
      `@${width}: single-round RV axis spans >= 5% of RV ${v} and contains it (ticks ${JSON.stringify(t)})`);
    await page.close();
  }
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.goto(`${base}/dashboard/?data=sample-replay.json#/live`);
  await page.waitForSelector("#app svg", { state: "attached", timeout: 15000 });
  const t = await rvTicks(page);
  check(JSON.stringify(t) === JSON.stringify([0, 2000, 4000, 6000, 8000]), `24-round sample: RV axis unchanged (${JSON.stringify(t)})`);
  await browser.close();
})().catch((e) => { console.log("not ok - " + e); process.exit(1); });
EOF
)
printf '%s\n' "$res"
grep -q '^not ok' <<<"$res" && { echo FAIL; exit 1; }
echo PASS
