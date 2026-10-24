#!/usr/bin/env bash
# Small multiples acceptance: with a vol-replay/v2 replay the rounds view replaces the forecast heat strip
# with one compact fan per forecaster (reputation-weighted consensus first, then each agent): wide and 50%
# bands, a median line in the row colour, realized RV as a black line with points, all rows on one hour axis
# and one log RV scale, vertically aligned, each ending with aligned columns: interval coverage, mean 80% width
# (geometric mean of q90/q10, "×") and mean pinball loss (summary, "—" for the consensus), matching the JSON.
# Realized RV is black in the consensus row and thin grey in agent rows; settled hours outside a row's 80%
# band are larger vermilion dots and their read-out says "outside 80%".
# Hovering / tapping an hour shows median, bounds and realized RV; clicking a column selects that round.
# A v1 replay keeps the heat strip. No overflow at 375 / 390 / 1440 px.
# DASHBOARD_HTML=<file> checks another index.html (fail-first); SHOT_DIR=<dir> saves 1440 / 390 screenshots.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/smallmult"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
cp dashboard/sample-replay.json "$tmp/dashboard/v1.json"
sed -n "/<<'PY'$/,/^PY$/p" tests/acceptance/next_dashboard_quantile.sh | sed '1d;$d' > "$tmp/to_v2.py"
python3 "$tmp/to_v2.py" dashboard/sample-replay.json "$tmp/dashboard" || { echo "not ok - v2 fixture"; echo FAIL; exit 1; }

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
const d = JSON.parse(fs.readFileSync(`${tmp}/dashboard/v2.json`, "utf8"));
const names = d.agents.map((a) => a.agent);
const hours = d.rounds.map((r) => ({ t: r.window_utc[0].slice(11, 16), v: r.outcome?.realized_vol ?? r.real_realized_vol, settled: !r.outcome?.voided,
  c: r.fee.onchain.mix_quantiles_e18.map((x) => Math.exp(Number(x) / 1e18)),
  q: Object.fromEntries(names.map((n) => { const ra = r.agents[n]; return [n, ra && ra.entered !== false && ra.quantiles ? ra.quantiles.map(Math.exp) : null]; })) }));
const cov = (get) => { const xs = hours.filter((x) => x.settled && get(x)), v = (x) => Math.max(1, x.v);
  const inside = (a, z) => xs.filter((x) => { const q = get(x); return q[a] <= v(x) && v(x) <= q[z]; }).length;
  return { n: xs.length, wide: inside(0, 4), mid: inside(1, 3) }; };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const open = async (data, width, touch = false) => {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, hasTouch: touch, isMobile: touch, reducedMotion: "reduce", deviceScaleFactor: shots ? 2 : 1 });
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(e.message));
    await page.goto(`${base}/dashboard/?data=${data}#/rounds`);
    await page.waitForSelector("#app section.card", { state: "attached", timeout: 15000 });
    await page.evaluate(() => setRound(0, false));
    await page.waitForTimeout(150);
    return { page, ctx, pageErrors };
  };

  {
    const { page, ctx, pageErrors } = await open("v2.json", 1440);
    const st = await page.evaluate(() => {
      const rows = [...document.querySelectorAll("#heat .sm-row[data-row]")];
      return { heat: document.querySelectorAll("#heat .hm i").length, rows: rows.map((r) => {
        const s = r.querySelector("svg"), b = s?.getBoundingClientRect(), p = (c) => r.querySelector(c)?.getAttribute("d") ?? "";
        const cv = r.querySelector("[data-cov]"), wd = r.querySelector("[data-width]"), ls = r.querySelector("[data-loss]");
        const dot = (c) => ({ fill: c.getAttribute("fill"), r: +c.getAttribute("r") });
        return { id: r.dataset.row, left: b?.left, sw: b?.width, lo: s?.dataset.lo, hi: s?.dataset.hi, wide: p(".nc-band-wide"), mid: p(".nc-band-50"),
          med: p(".sm-med"), real: p(".sm-real"), realStroke: r.querySelector(".sm-real")?.getAttribute("stroke"), dots: r.querySelectorAll("svg circle").length,
          cov: cv && { n: +cv.dataset.n, wide: +cv.dataset.wide, mid: +cv.dataset.mid, text: cv.textContent.replace(/\s+/g, " ") },
          width: wd && { text: wd.textContent.trim(), x: wd.getBoundingClientRect().left }, loss: ls && { text: ls.textContent.trim(), x: ls.getBoundingClientRect().left },
          out: [...r.querySelectorAll("svg circle.sm-out")].map(dot), inn: [...r.querySelectorAll("svg circle:not(.sm-out)")].map(dot) };
      }) };
    });
    const ids = st.rows.map((r) => r.id);
    check(st.heat === 0, "v2: heat strip cells gone");
    check(ids[0] === "consensus" && JSON.stringify(ids.slice(1)) === JSON.stringify(names), `v2: rows = consensus then each agent (${ids.join(", ")})`);
    check(st.rows.every((r) => /Z/.test(r.wide) && /Z/.test(r.mid) && /M/.test(r.med)), "v2: every row has wide and 50% bands and a median line");
    const nv = hours.filter((h) => h.v != null).length;
    const grey = (c) => /^#[0-9a-f]{6}$/i.test(c || "") && c.toLowerCase() !== "#1b1a17" && (() => { const [r, g, b] = [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16)); return Math.max(r, g, b) - Math.min(r, g, b) < 40 && r > 120; })();
    check(st.rows.every((r) => r.dots === nv && (r.real.match(/[ML]/g) || []).length === nv), `v2: every row draws realized RV with ${nv} points`);
    check(st.rows[0].realStroke === "#1b1a17" && st.rows.slice(1).every((r) => grey(r.realStroke)), `v2: realized line black in the consensus row, thin grey in agent rows (${st.rows.map((r) => r.realStroke).join(" ")})`);
    const ln = (x) => Math.log(x);
    check(new Set(st.rows.map((r) => `${r.lo}/${r.hi}`)).size === 1, "v2: rows share one log RV scale");
    check(st.rows.every((r) => Math.abs(r.left - st.rows[0].left) < 1 && Math.abs(r.sw - st.rows[0].sw) < 1), `v2: rows are vertically aligned on one hour axis (${st.rows.map((r) => `${Math.round(r.left)}/${Math.round(r.sw)}`).join(" ")})`);
    for (const r of st.rows) {
      const want = cov(r.id === "consensus" ? (x) => x.c : (x) => x.q[r.id]);
      check(r.cov && r.cov.n === want.n && r.cov.wide === want.wide && r.cov.mid === want.mid && r.cov.text.includes(`80%: ${want.wide}/${want.n} · 50%: ${want.mid}/${want.n}`),
            `v2: ${r.id} coverage 80% ${want.wide}/${want.n}, 50% ${want.mid}/${want.n} (got ${r.cov?.text})`);
      const get = r.id === "consensus" ? (x) => x.c : (x) => x.q[r.id];
      const xs = hours.filter((x) => x.settled && get(x));
      const ratio = Math.exp(xs.reduce((s, x) => s + ln(get(x)[4]) - ln(get(x)[0]), 0) / xs.length);
      check(r.width && r.width.text.includes(`×${ratio.toFixed(1)}`), `v2: ${r.id} mean 80% width ×${ratio.toFixed(1)} (got ${r.width?.text})`);
      const loss = r.id === "consensus" ? null : d.summary.agents[r.id].mean_pinball_loss;
      check(r.loss && (loss == null ? /—/.test(r.loss.text) : r.loss.text.includes(loss.toFixed(3))), `v2: ${r.id} loss ${loss == null ? "—" : loss.toFixed(3)} (got ${r.loss?.text})`);
      const outN = xs.filter((x) => { const v = Math.max(1, x.v), q = get(x); return v < q[0] || v > q[4]; }).length;
      check(r.out.length === outN && r.out.every((o) => /vermil|#d8431b/i.test(o.fill) && r.inn.every((i) => o.r > i.r)),
            `v2: ${r.id} ${outN} settled hours outside 80% drawn as larger vermilion dots (${r.out.length})`);
    }
    check(st.rows.every((r) => Math.abs(r.width.x - st.rows[0].width.x) < 1 && Math.abs(r.loss.x - st.rows[0].loss.x) < 1), "v2: width and loss columns aligned across rows");
    const cardText = await page.locator("#smult-card").innerText();
    check(cardText.includes("朱红点 = 实际值落在 80% 区间外；覆盖率要和区间宽度一起看（区间越宽越容易覆盖）；loss 越低越准。") && /q90\/q10/.test(cardText) && /ln RV/.test(cardText),
          "v2: caption explains vermilion dots, coverage vs width, loss; column units stated");
    const oi = hours.findIndex((x) => x.settled && (Math.max(1, x.v) < x.c[0] || Math.max(1, x.v) > x.c[4]));
    if (oi >= 0) {
      const oh = page.locator(`#heat .sm-row[data-row="consensus"] .sm-hit[data-h="${oi}"]`);
      await oh.scrollIntoViewIfNeeded(); await page.waitForTimeout(100);
      const ob = await oh.boundingBox();
      await page.mouse.move(ob.x + ob.width / 2, ob.y + ob.height / 2); await page.waitForTimeout(120);
      const ot = await page.evaluate(() => document.getElementById("tipbox")?.innerText ?? "");
      check(/outside 80%/.test(ot), `v2: read-out at ${hours[oi].t} says outside 80% (${ot.replace(/\s+/g, " ").slice(0, 100)})`);
    }
    const i = 7, h = hours[i];
    const hit = page.locator(`#heat .sm-row[data-row="consensus"] .sm-hit[data-h="${i}"]`);
    let text = "";
    if (await hit.count()) {
      await hit.scrollIntoViewIfNeeded(); await page.waitForTimeout(100);
      const b = await hit.boundingBox();
      await page.mouse.move(b.x + b.width / 2, b.y + b.height / 2); await page.waitForTimeout(120);
      text = (await page.evaluate(() => document.getElementById("tipbox")?.innerText ?? "")).replace(/\s+/g, " ");
      await page.mouse.click(b.x + b.width / 2, b.y + b.height / 2); await page.waitForTimeout(150);
    }
    check(text.includes(`${h.t} UTC`) && text.includes(`median ${fmt(h.c[2])} tick²`) && text.includes(`${fmt(h.c[0])}–${fmt(h.c[4])}`) && text.includes(String(h.v)),
          `v2: hour read-out ${h.t} UTC consensus median ${fmt(h.c[2])}, bounds, realized ${h.v} (got ${text.slice(0, 140)})`);
    check(await page.evaluate(() => STATE.round) === i, `v2: clicking column ${i} selects round ${i}`);
    check(pageErrors.length === 0, `v2: no page errors (${pageErrors.join("; ")})`);
    if (shots) await page.locator("#smult-card").screenshot({ path: `${shots}/smallmult-1440.png` });
    await ctx.close();
  }
  {
    const { page, ctx, pageErrors } = await open("v1.json", 1440);
    const st = await page.evaluate(() => ({ heat: document.querySelectorAll("#heat .hm i").length, rows: document.querySelectorAll("#heat .sm-row").length }));
    check(st.heat > 0 && st.rows === 0, `v1: heat strip unchanged (${st.heat} cells, ${st.rows} fan rows)`);
    check(pageErrors.length === 0, "v1: no page errors");
    await ctx.close();
  }
  for (const w of [375, 390]) {
    const { page, ctx, pageErrors } = await open("v2.json", w, true);
    const [sw, cw] = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
    check(sw <= cw, `${w} px: no page overflow (${sw} <= ${cw})`);
    const fit = await page.evaluate(() => { const c = document.getElementById("smult-card"); return c && c.scrollWidth <= c.clientWidth; });
    check(fit, `${w} px: small multiples card does not scroll sideways`);
    const hit = page.locator('#heat .sm-row[data-row="consensus"] .sm-hit[data-h="3"]');
    await hit.scrollIntoViewIfNeeded(); await page.waitForTimeout(100);
    const b = await hit.boundingBox();
    await page.touchscreen.tap(b.x + b.width / 2, b.y + b.height / 2); await page.waitForTimeout(150);
    const tip = await page.evaluate(() => { const e = document.getElementById("tipbox"); const r = e?.getBoundingClientRect();
      return e && e.classList.contains("on") ? { text: e.innerText, inView: r.left >= 0 && r.right <= document.documentElement.clientWidth } : null; });
    check(tip && tip.text.includes(`${hours[3].t} UTC`) && tip.inView, `${w} px: tapping an hour shows its read-out inside the viewport`);
    check(pageErrors.length === 0, `${w} px: no page errors`);
    if (shots && w === 390) await page.locator("#smult-card").screenshot({ path: `${shots}/smallmult-390.png` });
    await ctx.close();
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log("FAIL"); process.exit(1); });
EOF
