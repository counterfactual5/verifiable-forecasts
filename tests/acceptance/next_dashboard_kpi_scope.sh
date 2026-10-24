#!/usr/bin/env bash
# The overview KPI "best" tile (best over all agents) states its all-agent scope (全部 / all); the #/agents cumulative-score
# takeaway gives per-tier counts in nats and names no agent; the KPI's nats margin matches its own
# best-minus-uniform numbers (also with a different uniform baseline, so it is computed, not typed in); the tile does
# not overflow at 375/768/1280. Last line: failing checks (target 0).
set -uo pipefail
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
disown "$srv"
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log(99); process.exit(1); }
const base = process.argv[2];
let fail = 0;
const check = (cond, msg) => { console.log((cond ? "ok - " : "not ok - ") + msg); if (!cond) fail++; };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const runs = [[375, null], [768, null], [1280, null], [1280, -40.25]];
  for (const [width, uniform] of runs) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    if (uniform !== null) {
      await page.route("**/sample-replay.json", async (route) => {
        const res = await route.fetch();
        const d = await res.json();
        d.summary.uniform_total_log_score = uniform;
        await route.fulfill({ response: res, json: d });
      });
    }
    await page.goto(`${base}/dashboard/?data=sample-replay.json`);
    await page.waitForSelector("#app svg", { timeout: 15000 }).catch(() => {});
    await page.waitForTimeout(300);
    const r = await page.evaluate(() => {
      const norm = (s) => s.replace(/\s+/g, " ").trim();
      const kpi = [...document.querySelectorAll("#summary .kpi")].find((k) => /best/i.test(k.textContent));
      const hero = document.querySelector("#excess-card .takeaway");
      return {
        kpi: kpi ? norm(kpi.textContent) : null,
        hero: hero ? norm(hero.textContent) : null,
        heroNamesAgent: hero ? /agent-/.test([...hero.childNodes].filter((n) => !n.classList?.contains("badge")).map((n) => n.textContent).join("")) : null,
        tileExcess: kpi ? kpi.scrollWidth - kpi.clientWidth : null,
        pageExcess: document.documentElement.scrollWidth - document.documentElement.clientWidth,
      };
    });
    const at = `@${width}${uniform === null ? "" : ` uniform ${uniform}`}`;
    check(r.kpi !== null && r.hero !== null, `${at}: KPI best tile and #/agents takeaway present`);
    if (r.kpi === null || r.hero === null) { await page.close(); continue; }
    const unit = (t) => /\bnats\b/.test(t);
    check(unit(r.kpi), `${at}: KPI uses nats like the hero (${r.kpi})`);
    check(/全部|\ball\b/i.test(r.kpi), `${at}: KPI names its all-agent scope (${r.kpi})`);
    check(/\bzk\b/.test(r.hero) && unit(r.hero) && !r.heroNamesAgent, `${at}: hero keeps per-tier zk scope and nats, names no agent (${r.hero})`);
    const nums = (r.kpi.match(/(?<![\w-])[-−]\d+(\.\d+)?/g) || []).map((s) => Number(s.replace("−", "-")));
    const margin = r.kpi.match(/([+\-−])(\d+(\.\d+)?)\s*nats/);
    const m = margin ? (margin[1] === "+" ? 1 : -1) * Number(margin[2]) : NaN;
    check(nums.length >= 2 && Math.abs(m - (nums[0] - nums[nums.length - 1])) <= 0.2,
      `${at}: KPI nats margin matches best minus uniform (${margin?.[0]} vs ${nums.join(", ")})`);
    check(r.tileExcess <= 0 && r.pageExcess <= 0, `${at}: no overflow (tile ${r.tileExcess}, page ${r.pageExcess})`);
    await page.close();
  }
  await browser.close();
  console.log(fail);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e); console.log(99); process.exit(1); });
EOF
