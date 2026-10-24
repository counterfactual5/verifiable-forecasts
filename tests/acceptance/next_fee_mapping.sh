#!/usr/bin/env bash
# Variance-to-fee mapping selector in the consumer selection panel on #/fee:
# - linear (default) still reproduces the on-chain recorded fee of every round within 1 bps;
# - power law fee = c·E[var]^α uses α, c from an OLS of ln fair on ln rv over the replay's calibration hours
#   (params.fee_consumer.calibration.hours_data, all before the first round), never the displayed window,
#   and changes the line and the MAE; the caption names the constants and their source;
# - shrink w=0 equals fixed 5 bps exactly, w=1 equals linear exactly;
# - every mapping's MAE is shown next to fixed and on-chain; no console errors; no overflow at 375 / 390 / 1440 px.
# DASHBOARD_HTML=<file> checks another index.html (fail-first).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/fee_mapping"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
cp dashboard/sample-replay.json "$tmp/dashboard/sample-replay.json"
cp dashboard/sample-replay.json "$tmp/dashboard/live-replay.json"

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
const d = JSON.parse(fs.readFileSync(`${tmp}/dashboard/sample-replay.json`, "utf8"));
const errs = [];
const check = (cond, msg) => { console.log(`${cond ? "ok" : "not ok"} - ${msg}`); if (!cond) errs.push(msg); };

const hours = d.params.fee_consumer.calibration.hours_data.filter((h) => h.rv > 0 && h.fair_bps > 0);
check(hours.every((h) => h.start + 3600 <= d.rounds[0].start), "calibration hours all end before the first displayed round");
const tx = hours.map((h) => Math.log(h.rv)), ty = hours.map((h) => Math.log(h.fair_bps));
const mean = (v) => v.reduce((a, b) => a + b, 0) / v.length, mx = mean(tx), my = mean(ty);
const alpha = tx.reduce((s, x, i) => s + (x - mx) * (ty[i] - my), 0) / tx.reduce((s, x) => s + (x - mx) ** 2, 0);
const c = Math.exp(my - alpha * mx);

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const open = async (width) => {
    const ctx = await browser.newContext({ viewport: { width, height: 900 } });
    const page = await ctx.newPage();
    const problems = [];
    page.on("pageerror", (e) => problems.push(e.message));
    page.on("console", (m) => { if (m.type() === "error") problems.push(m.text()); });
    await page.goto(`${base}/dashboard/#/fee`);
    await page.waitForSelector("#app section", { state: "attached", timeout: 15000 });
    await page.waitForTimeout(200);
    return { page, ctx, problems };
  };
  const fees = (page) => page.evaluate(() => {
    const el = document.querySelector("#sel-card [data-sel-fees]");
    return el ? JSON.parse(el.dataset.selFees) : null;
  });
  const mae = (page, k) => page.evaluate((k) => document.querySelector(`#sel-card [data-sel-mae="${k}"]`)?.textContent ?? null, k);
  const mapMae = (page, k) => page.evaluate((k) => document.querySelector(`#sel-card [data-sel-map-mae="${k}"]`)?.textContent ?? null, k);
  const same = (a, b) => Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((v, i) => v === b[i]);

  const { page, ctx, problems } = await open(1440);
  const card = page.locator("#sel-card");
  const text = (await card.count()) ? await card.innerText() : "";
  check(text.includes("映射方式"), "mapping selector label");
  for (const s of ["线性（链上现用）", "幂律", "收缩"]) check(text.includes(s), `mapping option ${s}`);
  check(text.includes("前端用回放数据重算，不是链上输出。幂律参数来自"), "mapping caption: front-end recomputation, not on-chain output");
  check(text.includes("calibration.hours_data") && text.includes("fee_analysis.py"), "caption names the power-law source");
  check(text.includes("24 轮小样本，未做显著性检验"), "caption: small sample, no significance test");
  check(!/最优|最好|最佳|best/i.test(text), "no best-model / best-mapping claim");

  const linRadio = page.locator('#sel-card input[name="sel-map"][value="linear"]');
  check(await linRadio.count() === 1 && await linRadio.isChecked(), "linear is the default mapping");
  const onchain = d.rounds.map((r) => (r.fee?.onchain?.fee_pips != null ? r.fee.onchain.fee_pips / 100 : null));
  const lin = await fees(page);
  const worst = Array.isArray(lin) ? Math.max(...lin.map((v, i) => (v == null || onchain[i] == null ? Infinity : Math.abs(v - onchain[i])))) : Infinity;
  check(worst <= 1, `default linear reproduces on-chain fee per round within 1 bps (max diff ${worst})`);
  const maeOn = await mae(page, "onchain"), maeFixed = await mae(page, "fixed");
  check((await mae(page, "sel")) === maeOn && (await mapMae(page, "linear")) === maeOn, "linear MAE equals on-chain MAE");

  const shown = await page.evaluate(() => { const c = document.querySelector("#sel-card [data-pow-alpha]"); return { a: Number(c?.dataset.powAlpha), c: Number(c?.dataset.powC) }; });
  check(Math.abs(shown.a - alpha) < 1e-9 && Math.abs(shown.c - c) / c < 1e-9, `power-law constants α=${shown.a} c=${shown.c} equal the training-hour OLS (α=${alpha.toFixed(4)} c=${c.toFixed(5)})`);
  check(alpha >= 0.3 && alpha <= 0.7, `α ${alpha.toFixed(3)} in the offline-analysis elasticity range`);
  check(text.includes(alpha.toFixed(2)) && text.includes(c.toPrecision(3)), "caption shows α and c");

  const setMap = async (k) => { await page.locator(`#sel-card input[name="sel-map"][value="${k}"]`).check(); await page.waitForTimeout(100); };
  const setW = async (w) => { await page.locator('#sel-card input[name="sel-w"]').fill(String(w)); await page.waitForTimeout(100); };
  const report = {};
  const pick = async (mode) => {
    await page.locator(`#sel-card input[name="sel-mode"][value="${mode}"]`).check();
    await page.locator('#sel-card input[name="sel-weight"][value="rep"]').check();
    await page.waitForTimeout(100);
    report[mode] = { linear: await mapMae(page, "linear"), power: await mapMae(page, "power"), shrink: await mapMae(page, "shrink"), fixed: await mae(page, "fixed"), onchain: await mae(page, "onchain") };
  };

  await setMap("power");
  const pow = await fees(page);
  check(Array.isArray(pow) && !same(pow, lin), "power law changes the line");
  check((await mae(page, "sel")) !== maeOn && (await mae(page, "sel")) === (await mapMae(page, "power")), "power law changes the MAE");
  const evs = await page.evaluate(() => JSON.parse(document.querySelector("#sel-card [data-sel-ev]")?.dataset.selEv ?? "null"));
  if (Array.isArray(evs) && Array.isArray(pow)) {
    const lo = d.params.fee_consumer.min_fee_pips, hi = d.params.fee_consumer.max_fee_pips;
    const want = evs.map((e) => (e == null ? null : Math.min(hi, Math.max(lo, Math.floor(c * e ** alpha * 100))) / 100));
    check(same(want, pow), "power-law line = clamp(c·E[var]^α) with the documented constants");
  } else check(false, "per-round E[var] exposed");

  await setMap("shrink");
  const wIn = page.locator('#sel-card input[name="sel-w"]');
  check(await wIn.count() === 1 && Number(await wIn.inputValue()) === 0.5, "shrink slider defaults to w = 0.5");
  const fixedBps = d.params.fee_consumer.fixed_fee_pips / 100;
  await setW(0);
  const s0 = await fees(page);
  check(Array.isArray(s0) && s0.every((v) => v === fixedBps), "shrink w=0 equals fixed 5 bps exactly");
  check((await mae(page, "sel")) === maeFixed, "shrink w=0 MAE equals fixed MAE");
  await setW(1);
  check(same(await fees(page), lin), "shrink w=1 equals linear exactly");
  await setW(0.5);
  const s5 = await fees(page);
  check(Array.isArray(s5) && s5.every((v, i) => Math.abs(v - (0.5 * lin[i] + 0.5 * fixedBps)) < 1e-9), "shrink w=0.5 is the midpoint");
  const hover = await page.evaluate(() => {
    const el = document.querySelector("#sel-card svg");
    if (!el) return false;
    const r = el.getBoundingClientRect();
    return { x: r.left + r.width * 0.6, y: r.top + r.height / 2 };
  });
  if (hover) {
    await page.mouse.move(hover.x, hover.y);
    await page.waitForTimeout(150);
    const tip = await page.evaluate(() => !!document.querySelector("#sel-card .chart.hover") && (document.querySelector("#sel-card .chart .tip")?.textContent ?? "").includes("收缩"));
    check(tip, "hover shows a tooltip naming the chosen mapping");
  } else check(false, "chart rendered");

  for (const mode of ["all", "zk", "reproducible"]) await pick(mode);
  console.log(`# MAE vs fair (bps, 按信誉, shrink w=0.5): ${JSON.stringify(report)}`);
  console.log(`# power law α=${alpha} c=${c} (bps per tick²^α), ${hours.length} calibration hours`);
  check(problems.length === 0, `no console errors (${problems.join(" | ")})`);
  await ctx.close();

  for (const w of [375, 390, 1440]) {
    const o = await open(w);
    await o.page.locator('#sel-card input[name="sel-map"][value="shrink"]').check().catch(() => {});
    await o.page.waitForTimeout(100);
    const over = await o.page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    const inside = await o.page.evaluate(() => {
      const c = document.querySelector("#sel-card");
      if (!c) return false;
      const r = c.getBoundingClientRect();
      return r.left >= 0 && r.right <= document.documentElement.clientWidth + 0.5;
    });
    check(over <= 0 && inside, `no horizontal overflow at ${w}px with the slider shown (page ${over}px)`);
    check(o.problems.length === 0, `no console errors at ${w}px`);
    await o.ctx.close();
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log(`not ok - ${e.message}`); console.log("FAIL"); process.exit(1); });
EOF
