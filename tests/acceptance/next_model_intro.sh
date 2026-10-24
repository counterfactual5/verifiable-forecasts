#!/usr/bin/env bash
# Model intro acceptance: the 验证档位 section (#/agents) introduces the three zk models from
# agents/MODEL_CARD.md: inputs are the 16 on-chain features from observe(), outputs 5 quantiles of ln(RV),
# weights fixed in circuit + verifier, trained on mainnet data only; a table row per model with its
# structure and parameter count (linear_abs 85, mlp16 357, mlp32_abs 709) and the monotone quantile head;
# the reason (each forecast needs a zk proof, ~55 万 gas on-chain). The 可复现 card names timesfm-3.0 /
# timestral-209m / chronos-2 without "托管推理". No best-model claim. No overflow at
# 375 / 390 / 1440 px. DASHBOARD_HTML=<file> checks another index.html (fail-first).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/model_intro"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
cp dashboard/sample-replay.json "$tmp/dashboard/"

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp" >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const [base] = process.argv.slice(2);
const errs = [];
const check = (cond, msg) => { console.log(`${cond ? "ok" : "not ok"} - ${msg}`); if (!cond) errs.push(msg); };
const MODELS = [["linear_abs", "85", /绝对值/], ["mlp16", "357", /有符号/], ["mlp32_abs", "709", /绝对值/]];

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const w of [1440, 390, 375]) {
    const ctx = await browser.newContext({ viewport: { width: w, height: 900 }, hasTouch: w < 600, isMobile: w < 600, reducedMotion: "reduce" });
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(e.message));
    await page.goto(`${base}/dashboard/?data=sample-replay.json#/agents`);
    await page.waitForSelector("#tiers", { state: "visible", timeout: 15000 });
    await page.waitForTimeout(150);
    const r = await page.evaluate(() => {
      const sec = document.getElementById("tiers"), sb = sec.getBoundingClientRect();
      const rows = [...sec.querySelectorAll("table tr")].map((tr) => tr.textContent.replace(/\s+/g, " "));
      const repro = [...sec.querySelectorAll(".tier")].find((t) => /可复现/.test(t.querySelector("h3")?.textContent ?? ""));
      const spill = [...sec.querySelectorAll("*")].filter((el) => { const b = el.getBoundingClientRect(); return b.width && (b.left < sb.left - 1 || b.right > sb.right + 1); })
        .map((el) => el.tagName + "." + el.className);
      return { text: sec.textContent.replace(/\s+/g, " "), rows, repro: repro?.textContent.replace(/\s+/g, " ") ?? "", spill,
        sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth };
    });
    const t = r.text;
    for (const [name, params, shape] of MODELS) {
      const row = r.rows.find((s) => s.includes(name));
      check(!!row && new RegExp(`(^|\\D)${params}(\\D|$)`).test(row) && shape.test(row) && /单调/.test(row),
            `${w} px: ${name} row has ${params} params, its input, the monotone head (got "${row ?? ""}")`);
    }
    check(/observe\(\)/.test(t) && /16 个特征/.test(t) && /ln\s*\(?RV\)?/.test(t) && /5 个分位数/.test(t), `${w} px: inputs and outputs stated`);
    check(/写死/.test(t) && /电路/.test(t) && /验证合约/.test(t) && /主网/.test(t) && /真实数据/.test(t), `${w} px: fixed weights and mainnet-only training stated`);
    check(/zk 证明/.test(t) && /55 万 gas/.test(t), `${w} px: reason (zk proof, ~55 万 gas) stated`);
    check(/timesfm-3\.0/.test(r.repro) && /timestral-209m/.test(r.repro) && /chronos-2/.test(r.repro), `${w} px: 可复现 card names the three open-weight models`);
    check(!/托管推理/.test(t), `${w} px: no 托管推理`);
    check(!/最好|最佳|最强|更好/.test(t), `${w} px: no best-model or cross-tier claim`);
    check(r.spill.length === 0 && r.sw <= r.cw, `${w} px: nothing spills out of the section, no page overflow (${r.sw} <= ${r.cw}; ${r.spill.slice(0, 3).join(", ")})`);
    check(pageErrors.length === 0, `${w} px: no page errors (${pageErrors.join("; ")})`);
    await ctx.close();
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log("FAIL"); process.exit(1); });
EOF
