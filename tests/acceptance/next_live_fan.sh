#!/usr/bin/env bash
# Live fan acceptance: the left panel of the live nowcast (past 24 hours) is a consensus fan chart:
# wide and 50% bands plus a dashed vermilion median of the consensus the fee consumer read (on-chain
# mix_quantiles_e18, else the Vincentized mean recomputed from the reveals with the round's weights), each
# agent's median as a thin line in its colour, and realized RV as a black line with points. Legend buttons
# isolate one agent (its own bands replace the fan, other medians fade; again or "consensus" returns), also
# from the keyboard. One coverage line gives, per agent and for the consensus, the settled hours whose
# realized RV fell inside the wide and 50% intervals, matching the JSON. Hover / tap read-outs give hour,
# realized RV and the consensus (or isolated agent's) median and bounds. The current-hour panel keeps one
# glyph per entered agent. No overflow at 375 / 390 / 1440 px.
# DASHBOARD_HTML=<file> checks another index.html (fail-first); SHOT_DIR=<dir> saves 1440 / 390 screenshots.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/live_fan"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
sed -n "/<<'PY'$/,/^PY$/p" tests/acceptance/next_dashboard_quantile.sh | sed '1d;$d' > "$tmp/to_v2.py"
python3 "$tmp/to_v2.py" dashboard/sample-replay.json "$tmp/dashboard" || { echo "not ok - v2 fixture"; echo FAIL; exit 1; }
python3 - "$tmp/dashboard" <<'PY'
import json, sys
out = sys.argv[1]
d = json.load(open(out + "/v2.json"))
for r in d["rounds"]:
    for side in ("onchain", "mirror"):
        r["fee"][side].pop("mix_quantiles_e18", None)
json.dump(d, open(out + "/v2nomix.json", "w"))
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp" >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$tmp" "${SHOT_DIR:-}" <<'EOF'
const fs = require("fs");
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const [base, tmp, shots] = process.argv.slice(2);
const errs = [];
const check = (cond, msg) => { console.log(`${cond ? "ok" : "not ok"} - ${msg}`); if (!cond) errs.push(msg); };
const fmt = (v) => (v >= 100 ? v.toFixed(0) : v.toFixed(1));

const expected = (d) => {
  const band = d.schema === "vol-replay/v2" ? "80%" : "90%";
  const names = d.agents.map((a) => a.agent);
  const past = d.rounds.slice(-24).map((r) => {
    const m = r.fee?.mirror, mq = r.fee?.onchain?.mix_quantiles_e18 ?? m?.mix_quantiles_e18;
    let c = null;
    if (mq) c = mq.map((x) => Math.exp(Number(x) / 1e18));
    else {
      const w = m?.weights?.length === names.length && !m.equal_weight_fallback ? m.weights.map(Number) : null;
      const xs = names.map((n, i) => ({ ra: r.agents[n], w: w ? w[i] : 1 })).filter(({ ra, w }) => ra && ra.entered !== false && ra.quantiles && w > 0);
      const tw = xs.reduce((s, x) => s + x.w, 0);
      if (tw) c = [0, 1, 2, 3, 4].map((k) => Math.exp(xs.reduce((s, x) => s + x.w * x.ra.quantiles[k], 0) / tw));
    }
    const q = Object.fromEntries(names.map((n) => { const ra = r.agents[n]; return [n, ra && ra.entered !== false && ra.quantiles ? ra.quantiles.map(Math.exp) : null]; }));
    return { t: r.window_utc[0].slice(11, 16), v: r.outcome?.realized_vol ?? r.real_realized_vol, settled: !r.outcome?.voided, c, q };
  }).filter((x) => x.v != null);
  const cov = (get) => {
    const xs = past.filter((x) => x.settled && get(x)), v = (x) => Math.max(1, x.v);
    const inside = (a, z) => xs.filter((x) => { const q = get(x); return q[a] <= v(x) && v(x) <= q[z]; }).length;
    return { n: xs.length, wide: inside(0, 4), mid: inside(1, 3) };
  };
  return { band, past, names, cov: Object.fromEntries([["consensus", cov((x) => x.c)], ...names.map((n) => [n, cov((x) => x.q[n])])]) };
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const open = async (data, width, touch = false) => {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, hasTouch: touch, isMobile: touch, reducedMotion: "reduce", deviceScaleFactor: shots ? 2 : 1 });
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(e.message));
    await page.goto(`${base}/dashboard/?data=${data}#/live`);
    await page.waitForSelector("#nowcast svg", { state: "attached", timeout: 15000 });
    await page.waitForTimeout(150);
    return { page, ctx, pageErrors };
  };
  const tip = (page) => page.evaluate(() => { const b = document.getElementById("tipbox"); return b && b.classList.contains("on") ? b.innerText.replace(/\s+/g, " ") : ""; });
  const hoverHour = async (page, i, touch = false) => {
    const hit = page.locator(`#nowcast .nc-hit[data-i="${i}"]`);
    if (!(await hit.count())) return "";
    await hit.scrollIntoViewIfNeeded(); await page.waitForTimeout(100);
    const b = await hit.boundingBox();
    if (touch) await page.touchscreen.tap(b.x + b.width / 2, b.y + b.height / 2); else await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2);
    await page.waitForTimeout(120);
    return tip(page);
  };

  for (const data of ["v2.json", "v2nomix.json"]) {
    const d = JSON.parse(fs.readFileSync(`${tmp}/dashboard/${data}`, "utf8"));
    const E = expected(d);
    const { page, ctx, pageErrors } = await open(data, 1440);
    const nc = page.locator("#nowcast");
    const st = await page.evaluate(() => {
      const nc = document.getElementById("nowcast"), q = (s) => nc.querySelector(s);
      const vis = (e) => !!e && getComputedStyle(e).display !== "none" && getComputedStyle(e.parentElement).display !== "none";
      return {
        wide: q("[data-fan] path.nc-band-wide")?.getAttribute("d") ?? "", mid: q("[data-fan] path.nc-band-50")?.getAttribute("d") ?? "",
        fanVis: vis(q("[data-fan]")),
        cmed: q("[data-fan] path.nc-cmed") && [q("[data-fan] path.nc-cmed").getAttribute("stroke"), q("[data-fan] path.nc-cmed").getAttribute("stroke-dasharray")],
        real: q("path.nc-real")?.getAttribute("stroke"), realPts: (q("path.nc-real")?.getAttribute("d").match(/[ML]/g) || []).length,
        dots: nc.querySelectorAll("svg circle").length,
        lines: [...nc.querySelectorAll("[data-agent-line]")].map((p) => ({ a: p.dataset.agentLine, stroke: p.getAttribute("stroke"), w: Number(p.getAttribute("stroke-width")), pts: (p.getAttribute("d").match(/[ML]/g) || []).length })),
        keys: [...nc.querySelectorAll("button[data-iso]")].map((b) => b.dataset.iso),
        now: nc.querySelectorAll("svg g[data-agent]").length,
      };
    });
    check(/Z/.test(st.wide) && /Z/.test(st.mid) && st.fanVis, `${data}: consensus fan has a wide and a 50% band, shown by default`);
    check(st.cmed && /vermil|#d8431b/i.test(st.cmed[0]) && st.cmed[1], `${data}: consensus median is a dashed vermilion line (${st.cmed})`);
    check(st.real === "#1b1a17" && st.realPts === E.past.length && st.dots === E.past.length, `${data}: realized RV is a black line with ${E.past.length} points (${st.realPts}/${st.dots})`);
    const withQ = E.names.filter((n) => E.past.some((x) => x.q[n]));
    check(st.lines.length === withQ.length && st.lines.every((l) => l.w <= 1.6 && l.pts >= 2) && new Set(st.lines.map((l) => l.stroke)).size === st.lines.length,
          `${data}: one thin median line per agent in its own colour (${st.lines.length}/${withQ.length})`);
    check(st.keys[0] === "" && withQ.every((n) => st.keys.includes(n)), `${data}: legend has consensus + one button per agent`);
    check(st.now === Object.values(d.pending_round.agents).filter((a) => a.entered).length, `${data}: current-hour panel keeps one glyph per entered agent`);

    const i = Math.floor(E.past.length / 2), x = E.past[i];
    let t = await hoverHour(page, i);
    check(t.includes(`${x.t} UTC`) && t.includes(String(x.v)) && t.includes(`consensus median ${fmt(x.c[2])} tick²`) && t.includes(`${fmt(x.c[0])}–${fmt(x.c[4])}`) && t.includes(`${fmt(x.c[1])}–${fmt(x.c[3])}`),
          `${data}: hour read-out = ${x.t} UTC, RV ${x.v}, consensus median ${fmt(x.c[2])} and bounds (got ${t.replace(/\s+/g, " ").slice(0, 160)})`);

    const a0 = withQ[1] ?? withQ[0];
    await page.locator(`#nowcast button[data-iso="${a0}"]`).click();
    await page.waitForTimeout(100);
    const iso = await page.evaluate((a0) => {
      const nc = document.getElementById("nowcast");
      return { fan: getComputedStyle(nc.querySelector("[data-fan]")).display, band: getComputedStyle(nc.querySelector(`[data-agent-band="${a0}"]`)).display,
        others: [...nc.querySelectorAll("[data-agent-band]")].filter((g) => g.dataset.agentBand !== a0).every((g) => getComputedStyle(g).display === "none"),
        fade: [...nc.querySelectorAll("[data-agent-line]")].filter((p) => p.dataset.agentLine !== a0).every((p) => Number(getComputedStyle(p).opacity) < 0.3),
        sel: Number(getComputedStyle(nc.querySelector(`[data-agent-line="${a0}"]`)).opacity),
        pressed: nc.querySelector(`button[data-iso="${a0}"]`).getAttribute("aria-pressed") };
    }, a0);
    check(iso.fan === "none" && iso.band !== "none" && iso.others && iso.fade && iso.sel > 0.9 && iso.pressed === "true",
          `${data}: clicking ${a0} isolates it (${JSON.stringify(iso)})`);
    t = await hoverHour(page, i);
    const qa = x.q[a0];
    check(qa && t.includes(`median ${fmt(qa[2])} tick²`) && t.includes(a0.replace("agent-", "")), `${data}: isolated read-out shows ${a0} median ${qa && fmt(qa[2])} (got ${t.replace(/\s+/g, " ").slice(0, 120)})`);
    await page.locator(`#nowcast button[data-iso="${a0}"]`).click();
    await page.waitForTimeout(100);
    check(await page.evaluate(() => getComputedStyle(document.querySelector("#nowcast [data-fan]")).display !== "none"), `${data}: clicking ${a0} again returns to the consensus`);
    await page.locator(`#nowcast button[data-iso="${a0}"]`).focus();
    await page.keyboard.press("Enter");
    await page.waitForTimeout(100);
    const kb = await page.evaluate(() => getComputedStyle(document.querySelector("#nowcast [data-fan]")).display);
    await page.locator('#nowcast button[data-iso=""]').focus();
    await page.keyboard.press("Space");
    await page.waitForTimeout(100);
    const back = await page.evaluate(() => [getComputedStyle(document.querySelector("#nowcast [data-fan]")).display, document.querySelector('#nowcast button[data-iso=""]').getAttribute("aria-pressed")]);
    check(kb === "none" && back[0] !== "none" && back[1] === "true", `${data}: keyboard Enter isolates, Space on consensus returns (${kb} / ${back})`);

    const covs = await page.evaluate(() => Object.fromEntries([...document.querySelectorAll("#nowcast [data-cov]")].map((s) => [s.dataset.cov, { n: +s.dataset.n, wide: +s.dataset.wide, mid: +s.dataset.mid, text: s.textContent.replace(/\s+/g, " ") }])));
    for (const [k, c] of Object.entries(E.cov)) {
      if (!E.names.includes(k) && k !== "consensus") continue;
      const g = covs[k];
      const name = k === "consensus" ? "consensus" : k.replace("agent-", "");
      check(g && g.n === c.n && g.wide === c.wide && g.mid === c.mid && g.text.includes(`${name} ${E.band}: ${c.wide}/${c.n} · 50%: ${c.mid}/${c.n}`),
            `${data}: coverage ${name} ${E.band} ${c.wide}/${c.n}, 50% ${c.mid}/${c.n} (got ${g?.text})`);
    }
    const covLine = await page.locator("#nc-cov").innerText().catch(() => "");
    check(covLine && !/[\u3400-\u9fff]/.test(covLine), `${data}: coverage line uses English metric names only`);
    const text = await nc.innerText();
    check(/覆盖率/.test(text) && /黑线 = 链上实际 RV/.test(text), `${data}: one-line Chinese caption explains bands, black line and coverage`);
    check(pageErrors.length === 0, `${data}: no page errors (${pageErrors.join("; ")})`);
    if (shots && data === "v2.json") await nc.screenshot({ path: `${shots}/live-fan-1440.png` });
    await ctx.close();
  }

  for (const w of [375, 390]) {
    const d = JSON.parse(fs.readFileSync(`${tmp}/dashboard/v2.json`, "utf8"));
    const E = expected(d);
    const { page, ctx, pageErrors } = await open("v2.json", w, true);
    const [sw, cw] = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
    check(sw <= cw, `${w} px: no page overflow (${sw} <= ${cw})`);
    const fit = await page.evaluate(() => { const nc = document.getElementById("nowcast"), r = nc.getBoundingClientRect();
      return [...nc.querySelectorAll("button[data-iso], #nc-cov")].every((e) => { const b = e.getBoundingClientRect(); return b.left >= r.left - 1 && b.right <= r.right + 1; }); });
    check(fit, `${w} px: legend buttons and coverage line fit the card`);
    const i = E.past.length - 2, t = await hoverHour(page, i, true);
    check(t.includes(`${E.past[i].t} UTC`) && t.includes("consensus median"), `${w} px: tapping an hour shows its read-out (${t.replace(/\s+/g, " ").slice(0, 80)})`);
    const inView = await page.evaluate(() => { const b = document.getElementById("tipbox")?.getBoundingClientRect(); return !!b && b.left >= 0 && b.right <= document.documentElement.clientWidth; });
    check(inView, `${w} px: read-out inside the viewport`);
    await page.locator(`#nowcast button[data-iso="${E.names[0]}"]`).tap();
    await page.waitForTimeout(100);
    check(await page.evaluate(() => getComputedStyle(document.querySelector("#nowcast [data-fan]")).display === "none"), `${w} px: tapping a legend item isolates the agent`);
    check(pageErrors.length === 0, `${w} px: no page errors`);
    if (shots && w === 390) {
      await page.locator('#nowcast button[data-iso=""]').tap();
      await page.waitForTimeout(100);
      await page.locator("#nowcast").screenshot({ path: `${shots}/live-fan-390.png` });
    }
    await ctx.close();
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log("FAIL"); process.exit(1); });
EOF
