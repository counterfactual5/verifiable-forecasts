#!/usr/bin/env bash
# Hover acceptance: every chart shows exact values on hover (mouse) and on tap (touch, 390 px), in a soft
# paper tooltip that stays inside the viewport.
# - line charts (overview, forecasters, fee, fee residual, live per-round): the read-out names the round
#   time ("HH:MM UTC"), each series and the value its point title carries, plus the chart's unit;
# - the live nowcast (past glyphs, realized RV dots, current-hour bands) and the overview consensus bar:
#   agent / median / interval in tick² with the hour;
# - the forecast heat strip cells, the winning-bucket bars and the probability-flow canvas (buckets, agents,
#   AMM fee node) on the rounds view; the single-round segment chart of sample-round.json.
# DASHBOARD_HTML=<file> checks another index.html (fail-first).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/dashboard_hover"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
cp tests/acceptance/fixtures/sample-replay-v1.json "$tmp/dashboard/v1.json"
cp dashboard/sample-round.json "$tmp/dashboard/round.json"
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
const v1 = JSON.parse(fs.readFileSync(`${tmp}/dashboard/v1.json`, "utf8"));
const v2 = JSON.parse(fs.readFileSync(`${tmp}/dashboard/v2.json`, "utf8"));
const errs = [];
const check = (cond, msg) => { console.log(`${cond ? "ok" : "not ok"} - ${msg}`); if (!cond) errs.push(msg); };
const fmtTick = (v) => (v >= 100 ? v.toFixed(0) : v.toFixed(1));
const UNITS = { "fee-card": "bps", "excess-card": null };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const open = async (data, route, width = 1440, touch = false) => {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, hasTouch: touch, isMobile: touch });
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(e.message));
    await page.goto(`${base}/dashboard/?data=${data}${route ? `#/${route}` : ""}`);
    await page.waitForSelector("#app section", { state: "attached", timeout: 15000 });
    await page.waitForTimeout(150);
    return { page, ctx, pageErrors };
  };
  // The visible tooltip: a line chart's own read-out or the shared box.
  const tipText = (page) => page.evaluate(() => {
    const vis = [...document.querySelectorAll(".chart.hover .tip, #tipbox")].filter((e) => getComputedStyle(e).opacity > 0.5 && e.offsetWidth);
    return vis.map((e) => e.innerText).join("\n");
  });
  const tipInView = (page) => page.evaluate(() => {
    const vis = [...document.querySelectorAll(".chart.hover .tip, #tipbox")].filter((e) => getComputedStyle(e).opacity > 0.5 && e.offsetWidth);
    const vw = document.documentElement.clientWidth;
    return vis.length > 0 && vis.every((e) => { const r = e.getBoundingClientRect(); return r.left >= 0 && r.right <= vw; });
  });
  const tipLooks = (page) => page.evaluate(() => {
    const e = [...document.querySelectorAll(".chart.hover .tip, #tipbox")].find((x) => getComputedStyle(x).opacity > 0.5 && x.offsetWidth);
    if (!e) return null;
    const s = getComputedStyle(e), rgb = (c) => (c.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
    const [r, g, b] = rgb(s.backgroundColor), bw = parseFloat(s.borderTopWidth);
    return { light: (r + g + b) / 3 > 200, soft: bw <= 1, radius: parseFloat(s.borderTopLeftRadius) >= 6 };
  });
  const at = async (page, loc, touch = false) => {
    await loc.scrollIntoViewIfNeeded();
    await page.waitForTimeout(100);
    const b = await loc.boundingBox();
    const x = b.x + b.width / 2, y = b.y + b.height / 2;
    if (touch) await page.touchscreen.tap(x, y); else await page.mouse.move(x, y);
    await page.waitForTimeout(120);
    return tipText(page);
  };
  const atXY = async (page, x, y, touch = false) => {
    if (touch) await page.touchscreen.tap(x, y); else await page.mouse.move(x, y);
    await page.waitForTimeout(120);
    return tipText(page);
  };

  // Line charts on every view: the read-out carries the point titles' values for the hovered round.
  for (const [data, route] of [["v1.json", "agents"], ["v1.json", "fee"], ["v2.json", "agents"], ["v2.json", "live"], ["v2.json", "rounds"]]) {
    const { page, ctx, pageErrors } = await open(data, route);
    const charts = await page.locator("#app .chart:visible").all();
    check(charts.length > 0, `${data} #/${route}: has line charts (${charts.length})`);
    for (const [ci, ch] of charts.entries()) {
      const cardId = await ch.evaluate((e) => e.closest("section")?.id || e.closest("section")?.querySelector("h2")?.textContent.slice(0, 24) || "?");
      const circles = ch.locator("svg circle");
      const n = await circles.count();
      if (!n) continue;
      const dot = circles.nth(Math.floor(n * 0.4));
      const title = await dot.locator("title").textContent();
      const [, label, value] = title.match(/ · (\d\d:\d\d): (.+)$/) || [];
      const text = await at(page, dot);
      check(text.includes(`${label} UTC`) && text.includes(value), `${data} #/${route} chart ${ci} (${cardId}): read-out has ${label} UTC and ${value} (got ${text.replace(/\s+/g, " ").slice(0, 120)})`);
      const unit = await ch.evaluate((e) => e.dataset.unit ?? null);
      check(unit && text.includes(unit), `${data} #/${route} chart ${ci} (${cardId}): read-out states the unit (${unit})`);
      if (cardId === "fee-card" && ci === 0) check(unit === "bps", "fee chart unit is bps");
    }
    check(pageErrors.length === 0, `${data} #/${route}: no page errors (${pageErrors.join("; ")})`);
    await ctx.close();
  }

  // Live nowcast: past glyph, realized RV dot, current-hour band.
  {
    const { page, ctx } = await open("v2.json", "live");
    const hits = page.locator("#nowcast .nc-hit");
    const shown = v2.rounds.slice(-24).filter((r) => (r.outcome?.realized_vol ?? r.real_realized_vol) != null);
    const hr = shown[(await hits.count()) - 3], c50 = Math.exp(Number(hr.fee.onchain.mix_quantiles_e18[2]) / 1e18);
    const t = hr.window_utc[0].slice(11, 16);
    let text = await at(page, hits.nth((await hits.count()) - 3));
    check(/consensus/.test(text) && text.includes(`${t} UTC`) && text.includes(fmtTick(c50)) && text.includes("tick²"),
          `nowcast past hour: ${t} UTC consensus median ${fmtTick(c50)} tick² (got ${text.replace(/\s+/g, " ").slice(0, 140)})`);
    const dots = page.locator("#nowcast svg circle");
    const last = v2.rounds.slice(-24).filter((r) => (r.outcome?.realized_vol ?? r.real_realized_vol) != null).pop();
    text = await at(page, dots.last());
    const rv = String(last.outcome?.realized_vol ?? last.real_realized_vol);
    check(text.includes(rv) && text.includes(last.window_utc[0].slice(11, 16)), `nowcast RV dot: ${rv} tick² at ${last.window_utc[0].slice(11, 16)} (got ${text.replace(/\s+/g, " ").slice(0, 100)})`);
    const band = page.locator("#nowcast g[data-agent]").first();
    const [bag, bq] = await band.evaluate((g) => [g.dataset.agent, Number(g.dataset.q50)]);
    text = await at(page, band.locator("rect").first());
    const hour = v2.pending_round.window_utc[0].slice(11, 16);
    check(text.includes(bag) && text.includes(fmtTick(bq)) && text.includes(hour), `nowcast current band: ${bag} median ${fmtTick(bq)} for ${hour} (got ${text.replace(/\s+/g, " ").slice(0, 120)})`);
    await ctx.close();
  }

  // Overview consensus bar (live pending hour).
  {
    const { page, ctx } = await open("v2.json", "overview");
    const bar = page.locator("#case-snap svg.cs-bar");
    const want = (await page.locator("#case-snap .cs-q b").textContent()).trim();
    const text = await at(page, bar);
    check(text.includes(want) && text.includes("tick²"), `consensus bar: median ${want} tick² (got ${text.replace(/\s+/g, " ").slice(0, 100)})`);
    await ctx.close();
  }

  // Rounds view: heat strip cell, winning-bucket bar, probability-flow canvas.
  {
    const { page, ctx } = await open("v1.json", "rounds");
    const cell = page.locator("#heat .hm i").nth(5 * 7 + 1);
    const want = await cell.evaluate((e) => e.getAttribute("title") ?? e.dataset.tip);
    const prob = (want.match(/: ([\d.]+)/) || [])[1];
    let text = await at(page, cell);
    check(prob && text.includes(prob) && text.includes(v1.rounds[7].window_utc[0].slice(11, 16)), `heat cell: ${prob} at ${v1.rounds[7].window_utc[0].slice(11, 16)} (got ${text.replace(/\s+/g, " ").slice(0, 100)})`);

    const counts = [0, 0, 0, 0, 0];
    v1.rounds.forEach((r) => { if (!r.outcome.voided) counts[r.outcome.winning_bucket]++; });
    const k = counts.indexOf(Math.max(...counts));
    const bar = page.locator("[data-bucket-bar]").nth(k);
    text = (await bar.count()) ? await at(page, bar) : "";
    check(text.includes(`#${k}`) && text.includes(String(counts[k])), `winning-bucket bar #${k}: ${counts[k]} rounds (got ${text.replace(/\s+/g, " ").slice(0, 80)})`);

    const flow = page.locator("#flow");
    await flow.scrollIntoViewIfNeeded();
    await page.waitForTimeout(100);
    await page.evaluate(() => setRound(STATE.round, false));
    const geo = await page.evaluate(() => {
      const c = document.getElementById("flow"), r = c.getBoundingClientRect();
      const g = flowGeom(c.clientWidth, c.clientHeight, STATE.model.rounds[STATE.round].agents.length);
      const m = STATE.model.rounds[STATE.round];
      return { x: r.left, y: r.top, bx: g.bx, by: g.by(2), ax: g.ax, ay: g.ay(0), fx: g.fx, fy: g.fy, label: m.label,
               a0: m.agents[0].name, p02: m.agents[0].probs[2], fee: m.fee };
    });
    text = await atXY(page, geo.x + geo.bx, geo.y + geo.by);
    check(text.includes("#2") && text.includes(`${(geo.p02 * 100).toFixed(1)}%`) && text.includes(`${geo.label} UTC`),
          `flow bucket #2: ${geo.a0} ${(geo.p02 * 100).toFixed(1)}% at ${geo.label} UTC (got ${text.replace(/\s+/g, " ").slice(0, 140)})`);
    text = await atXY(page, geo.x + geo.ax, geo.y + geo.ay);
    check(text.includes(geo.a0) && text.includes(`${(geo.p02 * 100).toFixed(1)}%`), `flow agent ${geo.a0}: per-bucket probabilities (got ${text.replace(/\s+/g, " ").slice(0, 140)})`);
    text = await atXY(page, geo.x + geo.fx, geo.y + geo.fy);
    check(geo.fee == null || (text.includes(geo.fee.toFixed(2)) && text.includes("bps")), `flow AMM node: ${geo.fee?.toFixed(2)} bps (got ${text.replace(/\s+/g, " ").slice(0, 100)})`);
    check(await tipLooks(page).then((s) => s && s.light && s.soft && s.radius), "shared tooltip: light panel, hairline border, rounded");
    await ctx.close();
  }

  // Single-round view (sample-round.json): segment chart dots.
  {
    const { page, ctx, pageErrors } = await open("round.json", "");
    const dot = page.locator("#app svg circle").nth(2);
    const text = (await dot.count()) ? await at(page, dot) : "";
    check(/segment 3/i.test(text) && /tick/.test(text) && /-?\d/.test(text), `segment chart dot: segment 3 tick value (got ${text.replace(/\s+/g, " ").slice(0, 100)})`);
    check(pageErrors.length === 0, "single round: no page errors");
    await ctx.close();
  }

  // Touch at 390 px: tap shows the read-out and keeps it inside the viewport.
  for (const [data, route, sel, what] of [["v1.json", "fee", "#fee-card .chart svg circle >> nth=40", "fee chart"],
                                         ["v1.json", "fee", "#fee-resid .chart svg circle >> nth=20", "residual chart"],
                                         ["v1.json", "agents", "#excess-card .chart svg circle >> nth=10", "forecasters chart"],
                                         ["v1.json", "rounds", "#heat .hm i >> nth=118", "heat cell"],
                                         ["v2.json", "live", "#nowcast g[data-agent] rect >> nth=0", "nowcast band"]]) {
    for (const w of [375, 390]) {
      const { page, ctx } = await open(data, route, w, true);
      const loc = page.locator(sel);
      const text = (await loc.count()) ? await at(page, loc, true) : "";
      check(/\d/.test(text), `${w} px tap ${what}: read-out shown (${text.replace(/\s+/g, " ").slice(0, 60)})`);
      check(await tipInView(page), `${w} px tap ${what}: read-out inside the viewport`);
      const [sw, cw] = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
      check(sw <= cw, `${w} px tap ${what}: no page overflow`);
      await ctx.close();
    }
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log("FAIL"); process.exit(1); });
EOF
