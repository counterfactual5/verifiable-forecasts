#!/usr/bin/env bash
# Overview KPI labels never break an agent name or a number across lines (e.g. "timestral-" / "209m") at
# 320/375/768/1280, and no bold text runs past its tile's content edge (#summary clips it silently).
# Last line: failing checks (target 0).
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
  for (const width of [320, 375, 768, 1280]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    await page.goto(`${base}/dashboard/?data=sample-replay.json`);
    await page.waitForSelector("#summary .kpi", { timeout: 15000 }).catch(() => {});
    await page.waitForTimeout(300);
    const r = await page.evaluate(() => {
      const lines = (el) => new Set([...el.getClientRects()].map((q) => Math.round(q.top))).size;
      const bs = [...document.querySelectorAll("#summary .kpi b")];
      return {
        count: bs.length,
        broken: bs.filter((b) => lines(b) > 1).map((b) => b.textContent),
        overflow: [...document.querySelectorAll("#summary .kpi")].filter((k) => k.scrollWidth > k.clientWidth).length,
        pastEdge: bs.filter((b) => {
          const k = b.closest(".kpi");
          return b.getBoundingClientRect().right > k.getBoundingClientRect().right - parseFloat(getComputedStyle(k).paddingRight) + 0.5;
        }).map((b) => b.textContent),
      };
    });
    check(r.count > 0, `@${width}: KPI labels hold bold names/numbers (${r.count})`);
    check(r.broken.length === 0, `@${width}: no KPI name or number split across lines (${JSON.stringify(r.broken)})`);
    check(r.overflow === 0, `@${width}: no KPI tile overflows (${r.overflow})`);
    check(r.pastEdge.length === 0, `@${width}: no bold KPI text past its tile's content edge (${JSON.stringify(r.pastEdge)})`);
    await page.close();
  }
  await browser.close();
  console.log(fail);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e); console.log(99); process.exit(1); });
EOF
