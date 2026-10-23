#!/usr/bin/env bash
# The header live badge (fresh "LIVE" and stale "实时数据已过期 … 小时前") stays inside the viewport at
# 320/375/414/768/1280: body hides horizontal overflow, so a badge wider than the screen is cut off silently.
# The status dot stays on the first text line and "（N 小时前）" never splits across lines. The ui_check gate never loads live data, so a stale live dataset is injected here.
# Last line: total px of badge past the viewport's right edge, summed over cases (target 0).
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
let total = 0, fail = 0;

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const now = Math.floor(Date.now() / 1000);
  const cases = [["stale", now - 14 * 3600], ["fresh", now - 600]];
  for (const [label, generatedAt] of cases) {
    for (const width of [320, 375, 414, 768, 1280]) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      await page.route("**/sample-replay.json", async (route) => {
        const res = await route.fetch();
        const d = await res.json();
        d.live = true;
        d.generated_at = generatedAt;
        d.next_run_at = now + 1800;
        await route.fulfill({ response: res, body: JSON.stringify(d), headers: { ...res.headers(), "content-type": "application/json" } });
      });
      await page.goto(`${base}/dashboard/?data=sample-replay.json`);
      await page.waitForSelector("#live-badge", { timeout: 15000 }).catch(() => {});
      await page.waitForTimeout(300);
      const r = await page.evaluate(() => {
        const b = document.getElementById("live-badge");
        if (!b) return null;
        const vw = document.documentElement.clientWidth;
        const inView = (rs) => rs.length > 0 && rs.every((q) => q.width > 0 && q.left >= -0.5 && q.right <= vw + 0.5);
        const rects = [...b.getClientRects(), b.getBoundingClientRect()];
        const cs = getComputedStyle(b);
        let ageVisible = null, ageLines = null;
        const walker = document.createTreeWalker(b, NodeFilter.SHOW_TEXT);
        for (let n; (n = walker.nextNode());) {
          const i = n.data.indexOf("小时前");
          if (i < 0) continue;
          const range = document.createRange();
          range.setStart(n, i); range.setEnd(n, i + 3);
          ageVisible = inView([...range.getClientRects()]);
          const paren = document.createRange();
          paren.setStart(n, Math.max(0, n.data.lastIndexOf("（", i))); paren.setEnd(n, i + 4);
          ageLines = new Set([...paren.getClientRects()].map((q) => Math.round(q.top))).size;
        }
        const en = b.querySelector(".en");
        const first = document.createTreeWalker(b, NodeFilter.SHOW_TEXT).nextNode();
        const head = document.createRange();
        head.setStart(first, 0); head.setEnd(first, 1);
        return {
          firstLineGap: Math.round(head.getBoundingClientRect().top - b.getBoundingClientRect().top),
          text: b.textContent,
          past: Math.max(0, ...rects.map((q) => Math.ceil(q.right - vw))),
          fontSize: cs.fontSize,
          clipped: cs.overflow !== "visible" || cs.textOverflow !== "clip" || b.scrollWidth > b.clientWidth + 1,
          ageVisible,
          ageLines,
          enVisible: !!en && inView([...en.getClientRects()]),
        };
      });
      await page.close();
      if (!r) { console.log(`not ok - ${label} @${width}: no #live-badge rendered`); fail++; continue; }
      const stale = /已过期/.test(r.text) && /\d+\s小时前/.test(r.text);
      const bad = [];
      if (stale !== (label === "stale")) bad.push(`wrong badge (${r.text})`);
      if (r.fontSize !== "12px") bad.push(`font-size ${r.fontSize}`);
      if (r.clipped) bad.push("badge clips its own text");
      if (label === "stale" && r.ageVisible !== true) bad.push("'小时前' not inside the viewport");
      if (label === "stale" && r.ageLines !== 1) bad.push(`'（N 小时前）' split across ${r.ageLines} lines`);
      if (!r.enVisible) bad.push("English line not inside the viewport");
      if (r.firstLineGap > 6) bad.push(`badge text starts ${r.firstLineGap}px below the top: the status dot sits alone on line 1`);
      if (bad.length) { console.log(`not ok - ${label} @${width}: ${bad.join("; ")}`); fail += bad.length; }
      console.log(`${r.past === 0 ? "ok" : "not ok"} - ${label} @${width}: badge ${r.past}px past the viewport`);
      total += r.past;
    }
  }
  await browser.close();
  const out = total + fail;
  console.log(out);
  process.exit(out === 0 ? 0 : 1);
})();
EOF
