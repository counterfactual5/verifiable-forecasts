#!/usr/bin/env bash
# Name acceptance: the dashboard is "可验证预测协议 / Verifiable Forecast Protocol" in <title>, the header and
# the overview claim, with the tagline "让 AI 预测事前锁定、事后验证、按结果记信誉" and its English line under the
# header, for the replay views (every tab's document.title) and the single-round page; the old
# "Verifiable AI Forecasts" / "可验证 AI 预测协议" names are gone. No overflow at 375 px.
# DASHBOARD_HTML=<file> checks another index.html (fail-first).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/dashboard_name"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
cp dashboard/sample-replay.json dashboard/sample-round.json "$tmp/dashboard/"

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
const ZH = "可验证预测协议", EN = "Verifiable Forecast Protocol";
const TAG = "让 AI 预测事前锁定、事后验证、按结果记信誉", TAG_EN = "Lock AI forecasts ex ante, verify them ex post, score reputation by outcome.";
const OLD = /Verifiable AI Forecasts|可验证 AI 预测协议/;
const html = fs.readFileSync(`${tmp}/dashboard/index.html`, "utf8");
check(new RegExp(`<title>[^<]*${ZH}[^<]*${EN}[^<]*</title>`).test(html), "static <title> names the protocol in Chinese and English");
check(!OLD.test(html), "old project names are gone from index.html");
(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const [data, views] of [["sample-replay.json", ["overview", "live", "rounds", "agents", "fee", "chain"]], ["sample-round.json", [null]]]) {
    for (const w of [1440, 375]) {
      const page = await browser.newPage({ viewport: { width: w, height: 900 } });
      const pageErrors = [];
      page.on("pageerror", (e) => pageErrors.push(e.message));
      await page.goto(`${base}/dashboard/?data=${data}`);
      await page.waitForSelector("#app section", { state: "attached", timeout: 15000 });
      for (const v of views) {
        if (v) { await page.evaluate((v) => { location.hash = `#/${v}`; }, v); await page.waitForTimeout(150); }
        const r = await page.evaluate(() => ({ title: document.title, h1: document.querySelector("h1")?.textContent ?? "",
          head: document.querySelector("header")?.innerText ?? "", claim: document.querySelector(".claim")?.textContent ?? null,
          ov: document.documentElement.scrollWidth - document.documentElement.clientWidth }));
        const tag = `${data}${v ? ` #/${v}` : ""} @${w}`;
        check(r.title.includes(ZH) && r.title.includes(EN) && !OLD.test(r.title), `${tag}: title "${r.title}"`);
        check(r.h1.includes(ZH) && r.h1.includes(EN) && !OLD.test(r.h1), `${tag}: header "${r.h1}"`);
        check(r.head.includes(TAG) && r.head.replace(/\s+/g, " ").includes(TAG_EN), `${tag}: tagline under the header (zh + en)`);
        if (v === "overview") check(r.claim && r.claim.includes(ZH) && !OLD.test(r.claim), `${tag}: overview claim "${r.claim}"`);
        check(r.ov <= 0, `${tag}: no horizontal overflow (${r.ov})`);
      }
      check(pageErrors.length === 0, `${data} @${w}: no page errors (${pageErrors.join("; ")})`);
      await page.close();
    }
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log("FAIL"); process.exit(1); });
EOF
