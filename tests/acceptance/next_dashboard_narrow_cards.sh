#!/usr/bin/env bash
# At 320/360 every card and the load-failure box stays inside the viewport: body hides horizontal overflow, so a
# grid column wider than the screen is clipped silently and the page scroll width never shows it.
# Covers the replay views, the single-round view and the ?data= error state. Last line: elements past the viewport (target 0).
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
// Third field: elements each view rendered before the fix; fewer means cards were hidden, not fitted.
const CASES = [
  ["?data=sample-replay.json", "", 2],
  ["?data=sample-replay.json", "#/agents", 2],
  ["?data=sample-replay.json", "#/rounds", 5],
  ["?data=sample-replay.json", "#/fee", 2],
  ["?data=sample-replay.json", "#/chain", 4],
  ["?data=sample-round.json", "", 7],
  ["?data=missing.json", "", 1],
];
let total = 0;

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const width of [320, 360]) {
    for (const [query, hash, expected] of CASES) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      await page.goto(`${base}/dashboard/${query}${hash}`);
      await page.waitForFunction(() => document.querySelector("#app .card, #app .load-failed"), null, { timeout: 15000 }).catch(() => {});
      await page.waitForTimeout(300);
      const r = await page.evaluate(() => {
        const vw = document.documentElement.clientWidth;
        const els = [...document.querySelectorAll("#app > *, .card, .load-failed")]
          .filter((e) => e.getClientRects().length > 0);
        const out = els.filter((e) => { const q = e.getBoundingClientRect(); return q.right > vw + 0.5 || q.left < -0.5; })
          .map((e) => `${e.className || e.tagName}@${Math.round(e.getBoundingClientRect().right)}`);
        return { n: els.length, out };
      });
      await page.close();
      const tag = `${query}${hash} @${width}`;
      if (r.n < expected) { console.log(`not ok - ${tag}: ${r.n} of ${expected} cards rendered`); total += expected - r.n; continue; }
      console.log(`${r.out.length ? "not ok" : "ok"} - ${tag}: ${r.out.length}/${r.n} past the viewport ${r.out.slice(0, 3).join(", ")}`);
      total += r.out.length;
    }
  }
  await browser.close();
  console.log(total);
  process.exit(total === 0 ? 0 : 1);
})().catch((e) => { console.log("not ok - " + e.message); console.log(99); process.exit(1); });
EOF
