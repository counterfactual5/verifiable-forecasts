#!/usr/bin/env bash
# Consumer-side model selection on #/fee: the panel recomputes VolFeeConsumer's fee per round in the browser
# from the replay JSON for a chosen subset (all / zk only / reproducible only / custom checkboxes) and
# weighting (reputation / equal).
# - default (all + reputation) reproduces the on-chain recorded fee of every round within 1 bps;
# - zk only changes the line and the MAE; a custom checkbox subset recomputes too;
# - the panel says it is a front-end recomputation, not on-chain output;
# - no console errors, no horizontal overflow at 375 / 390 / 1440 px.
# DASHBOARD_HTML=<file> checks another index.html (fail-first).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/consumer_selector"
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

  const { page, ctx, problems } = await open(1440);
  const card = page.locator("#sel-card");
  check(await card.count() === 1 && await card.isVisible(), "consumer selector panel visible on #/fee");
  const text = (await card.count()) ? await card.innerText() : "";
  check(text.includes("消费方自选模型"), "panel title");
  check(text.includes("前端用回放数据重算，不是链上输出") && text.includes("全部 + 按信誉"), "panel says it is a front-end recomputation");
  for (const s of ["全部", "只用 zk 档", "只用可复现档", "自选", "按信誉", "等权"]) check(text.includes(s), `option ${s}`);

  const onchain = d.rounds.map((r) => r.fee?.onchain?.fee_pips != null ? r.fee.onchain.fee_pips / 100 : null);
  const def = await fees(page);
  check(Array.isArray(def) && def.length === d.rounds.length, "per-round fees exposed for every round");
  if (Array.isArray(def)) {
    const diffs = def.map((v, i) => (v == null || onchain[i] == null ? Infinity : Math.abs(v - onchain[i])));
    const worst = Math.max(...diffs);
    check(worst <= 1, `all + reputation reproduces the on-chain fee per round within 1 bps (max diff ${worst.toFixed(4)} bps)`);
  }
  const maeAllRep = await mae(page, "sel"), maeOn = await mae(page, "onchain"), maeFixed = await mae(page, "fixed");
  check(maeAllRep != null && maeAllRep === maeOn, `default MAE equals on-chain MAE (${maeAllRep} vs ${maeOn})`);
  check(maeFixed != null && Math.abs(Number(maeFixed) - d.summary.fee_strategies.mae_bps.fixed) < 0.006, `fixed 5 bps MAE ${maeFixed}`);

  const report = {};
  const pick = async (mode, weight) => {
    await page.locator(`#sel-card input[name="sel-mode"][value="${mode}"]`).check();
    await page.locator(`#sel-card input[name="sel-weight"][value="${weight}"]`).check();
    await page.waitForTimeout(100);
    return { f: await fees(page), m: await mae(page, "sel") };
  };
  for (const mode of ["all", "zk", "reproducible"]) for (const w of ["rep", "equal"]) report[`${mode}/${w}`] = (await pick(mode, w)).m;
  console.log(`# MAE vs fair (bps): ${JSON.stringify(report)} · fixed ${maeFixed} · on-chain ${maeOn}`);
  const zk = await pick("zk", "rep");
  check(JSON.stringify(zk.f) !== JSON.stringify(def), "zk only changes the per-round line");
  check(zk.m != null && zk.m !== maeAllRep, `zk only changes the MAE (${zk.m} vs ${maeAllRep})`);

  const src = page.locator('#sel-card input[name="sel-src"][value="live"]');
  check(await src.count() === 1, "live replay offered as a data source");
  if (await src.count()) {
    await src.check();
    await page.waitForTimeout(100);
    check(JSON.stringify(await fees(page)) === JSON.stringify(zk.f), "live source recomputes from live-replay.json (same rounds here)");
    await page.locator('#sel-card input[name="sel-src"][value="fixed"]').check();
  }

  await page.locator('#sel-card input[name="sel-mode"][value="custom"]').check();
  await page.waitForTimeout(100);
  const boxes = page.locator('#sel-card input[name="sel-agent"]');
  check(await boxes.count() === d.agents.length, "one checkbox per agent");
  for (let i = 0; i < await boxes.count(); i++) await boxes.nth(i).uncheck();
  await boxes.nth(0).check();
  await page.waitForTimeout(100);
  const one = await fees(page);
  const a0 = d.agents[0].agent;
  const solo = d.rounds.map((r) => {
    const q = r.agents[a0]?.quantiles_e18;
    if (!q) return null;
    const lv = d.params.fee_consumer.levels_e18.map(Number).map((x) => x / 1e18);
    const w = lv.map((t, k) => (k + 1 < lv.length ? lv[k + 1] : 1) - (k ? lv[k - 1] : 0));
    const ev = q.reduce((s, v, k) => s + w[k] * Math.exp(Number(v) / 1e18), 0) / w.reduce((a, b) => a + b, 0);
    const raw = Math.floor(ev * Number(d.params.fee_consumer.fee_per_var_e18) / 1e18);
    return Math.min(d.params.fee_consumer.max_fee_pips, Math.max(d.params.fee_consumer.min_fee_pips, raw)) / 100;
  });
  const soloDiff = Array.isArray(one) ? Math.max(...one.map((v, i) => (v == null || solo[i] == null ? Infinity : Math.abs(v - solo[i])))) : Infinity;
  check(soloDiff <= 0.011, `single-agent checkbox subset equals that agent's own fee (max diff ${soloDiff})`);
  await boxes.nth(1).check();
  await page.waitForTimeout(100);
  check(JSON.stringify(await fees(page)) !== JSON.stringify(one), "adding a checkbox recomputes");
  for (let i = 0; i < await boxes.count(); i++) await boxes.nth(i).uncheck();
  await page.waitForTimeout(100);
  check(await page.locator("#sel-card [data-sel-empty]").count() === 1, "empty selection shows a notice instead of a line");
  check(problems.length === 0, `no console errors (${problems.join(" | ")})`);
  await ctx.close();

  for (const w of [375, 390, 1440]) {
    const o = await open(w);
    const over = await o.page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    const inside = await o.page.evaluate(() => {
      const c = document.querySelector("#sel-card");
      if (!c) return false;
      const r = c.getBoundingClientRect();
      return r.left >= 0 && r.right <= document.documentElement.clientWidth + 0.5;
    });
    check(over <= 0 && inside, `no horizontal overflow at ${w}px (page ${over}px)`);
    const look = await o.page.evaluate(() => {
      const c = document.querySelector("#sel-card");
      if (!c) return null;
      const s = getComputedStyle(c), rgb = (s.backgroundColor.match(/[\d.]+/g) || []).slice(0, 3).map(Number);
      return { light: rgb.reduce((a, b) => a + b, 0) / 3 > 200, soft: parseFloat(s.borderTopWidth) <= 1 };
    });
    check(look && look.light && look.soft, `light panel, no hard outline at ${w}px`);
    check(o.problems.length === 0, `no console errors at ${w}px`);
    await o.ctx.close();
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log(`not ok - ${e.message}`); console.log("FAIL"); process.exit(1); });
EOF
