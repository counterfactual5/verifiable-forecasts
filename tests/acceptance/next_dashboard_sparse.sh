#!/usr/bin/env bash
# R1 acceptance: a sparse live replay (1 settled round + the pending hour, e.g. HOURS=1) renders without
# console errors on any of the 6 sub-pages at 1280 and 390. The Live view's per-round chart plots each
# agent's p_win (probability on the realized bucket) against a dashed uniform 1/5 line: with one round
# its axis still holds every p_win and the line; on the 24-round sample the dashed line sits at 20% on
# the axis, there is one series per agent, the hover tooltip lists that round's p_win high to low, and
# the old realized-vol vs median chart is gone.
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
// The p_win card: y-axis tick labels (percent) with their y, and the y of the dashed uniform line.
const pwinAxis = (page) => page.evaluate(() => {
  const card = [...document.querySelectorAll(".card")].find((c) => /押中程度/.test(c.querySelector("h2, h3")?.textContent ?? ""));
  if (!card) return null;
  const ticks = [...card.querySelectorAll("svg text.ax[text-anchor=end]")].map((t) => ({ v: parseFloat(t.textContent) / 100, y: Number(t.getAttribute("y")) - 4 }));
  const dash = card.querySelector("svg > line[stroke-dasharray]");
  return { ticks, dashY: dash ? Number(dash.getAttribute("y1")) : null, series: card.querySelectorAll("svg g.series > path").length,
    legend: card.querySelectorAll(".chart + .sub .nowrap").length, text: card.textContent.replace(/\s+/g, " ") };
});
const at = (ticks, yv) => {
  const [a, b] = [ticks[0], ticks[ticks.length - 1]];
  return a.v + (yv - a.y) * (b.v - a.v) / (b.y - a.y);
};
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
    const ax = await pwinAxis(page);
    const pw = d.agents.map((a) => r0.agents[a.agent]?.p_win).filter((x) => x != null);
    const tv = ax ? ax.ticks.map((t) => t.v) : [];
    check(ax && tv.length >= 2 && Math.min(...tv) <= Math.min(0.2, ...pw) && Math.max(...tv) >= Math.max(0.2, ...pw) && Math.max(...tv) <= 1,
      `@${width}: single-round p_win axis holds every p_win ${JSON.stringify(pw.map((x) => x.toFixed(3)))} and the 20% line (ticks ${JSON.stringify(tv)})`);
    await page.close();
  }
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  await page.goto(`${base}/dashboard/?data=sample-replay.json#/live`);
  await page.waitForSelector("#app svg", { state: "attached", timeout: 15000 });
  const s = JSON.parse(fs.readFileSync("dashboard/sample-replay.json", "utf8"));
  const ax = await pwinAxis(page);
  check(ax && ax.dashY != null && Math.abs(at(ax.ticks, ax.dashY) - 1 / (s.params.bounds.length + 1)) < 0.005,
    `24-round sample: dashed reference line at uniform 20% (${ax && ax.dashY != null ? (at(ax.ticks, ax.dashY) * 100).toFixed(2) : "none"}%)`);
  check(ax && ax.series === s.agents.length && ax.legend === s.agents.length, `24-round sample: one p_win series and legend entry per agent (${ax?.series}/${ax?.legend})`);
  check(ax && /p_win/.test(ax.text) && /瞎猜/.test(ax.text) && /uniform/i.test(ax.text) && /Probability on the realized bucket/.test(ax.text),
    "24-round sample: bilingual title and caption explain p_win vs uniform");
  const old = await page.evaluate(() => [...document.querySelectorAll(".card h2")].some((h) => /每小时真实波动率|forecast median/.test(h.textContent)));
  check(!old, "24-round sample: the realized-vol vs forecast-median chart is gone");
  const i = 5, chart = page.locator("section.card", { hasText: "押中程度" }).locator(".chart svg");
  await chart.scrollIntoViewIfNeeded();
  const box = await chart.boundingBox(), W = Number((await chart.getAttribute("viewBox")).split(" ")[2]), k = box.width / W;
  await page.mouse.move(box.x + (70 + i * (W - 86) / (s.rounds.length - 1)) * k, box.y + box.height / 2);
  await page.waitForTimeout(200);
  const tip = await page.evaluate(() => [...document.querySelectorAll(".chart.hover .tip .r b")].map((b) => parseFloat(b.textContent) / 100));
  const want = s.agents.map((a) => s.rounds[i].agents[a.agent].p_win).sort((x, y) => y - x);
  check(tip.length === want.length && tip.every((v, j) => Math.abs(v - want[j]) < 0.0006),
    `24-round sample: hover on round ${i} lists its p_win high to low (${tip.map((v) => v.toFixed(3))} vs ${want.map((v) => v.toFixed(3))})`);
  await browser.close();
})().catch((e) => { console.log("not ok - " + e); process.exit(1); });
EOF
)
printf '%s\n' "$res"
grep -q '^not ok' <<<"$res" && { echo FAIL; exit 1; }
echo PASS
