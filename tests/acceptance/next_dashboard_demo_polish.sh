#!/usr/bin/env bash
# Demo polish: the tab shows an inline favicon (no /favicon.ico 404); in the live badge each time token
# ("最近更新 MM/DD HH:MM", "最近更新 HH:MM", "下一轮约 HH:MM") stays on one line at 320/375/1280; the error card's
# lead -> message and message -> link gaps are even (within 2px) and at most 16px. Last line: defect count (target 0).
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
let defects = 0;
const check = (cond, msg) => { console.log((cond ? "ok - " : "DEFECT - ") + msg); if (!cond) defects++; };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const newPage = async (width) => {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    page.errors = [];
    page.missing = [];
    page.on("pageerror", (e) => page.errors.push(e.message));
    page.on("response", (r) => { if (r.status() === 404 && !/missing\.json/.test(r.url())) page.missing.push(r.url()); });
    return page;
  };

  let page = await newPage(1280);
  await page.goto(`${base}/dashboard/`);
  await page.waitForSelector("#app svg", { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(400);
  const icon = await page.evaluate(() => document.querySelector('link[rel~="icon"]')?.getAttribute("href") ?? null);
  check(icon !== null && icon.startsWith("data:"), `link[rel~=icon] with a data: href (${icon && icon.slice(0, 40)})`);
  check(page.missing.length === 0, `no 404 requests (${JSON.stringify(page.missing)})`);
  check(page.errors.length === 0, `no page errors on load (${JSON.stringify(page.errors)})`);
  await page.close();

  const now = Math.floor(Date.now() / 1000);
  const cases = [
    ["stale", now - 14 * 3600, [/最近更新\s\d{2}\/\d{2}\s\d{2}:\d{2}/]],
    ["fresh", now - 600, [/最近更新\s\d{2}:\d{2}/, /下一轮约\s\d{2}:\d{2}/]],
  ];
  for (const [label, generatedAt, tokens] of cases) {
    for (const width of [320, 375, 1280]) {
      page = await newPage(width);
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
      const r = await page.evaluate((sources) => {
        const b = document.getElementById("live-badge");
        if (!b) return null;
        const vw = document.documentElement.clientWidth;
        const out = sources.map((src) => {
          const re = new RegExp(src);
          const walker = document.createTreeWalker(b, NodeFilter.SHOW_TEXT);
          for (let n; (n = walker.nextNode());) {
            const m = re.exec(n.data);
            if (!m) continue;
            const range = document.createRange();
            range.setStart(n, m.index); range.setEnd(n, m.index + m[0].length);
            return { src, lines: new Set([...range.getClientRects()].map((q) => Math.round(q.top))).size };
          }
          return { src, lines: null };
        });
        const past = Math.max(0, ...[...b.getClientRects()].map((q) => Math.ceil(q.right - vw)));
        return { tokens: out, past };
      }, tokens.map((t) => t.source));
      if (!r) check(false, `${label} @${width}: #live-badge rendered`);
      else {
        for (const t of r.tokens) check(t.lines === 1, `${label} @${width}: /${t.src}/ on one line (lines ${t.lines})`);
        check(r.past === 0, `${label} @${width}: badge inside the viewport (${r.past}px past)`);
      }
      check(page.errors.length === 0, `${label} @${width}: no page errors (${JSON.stringify(page.errors)})`);
      await page.close();
    }
  }

  for (const width of [375, 1280]) {
    page = await newPage(width);
    await page.goto(`${base}/dashboard/?data=missing.json`);
    await page.waitForSelector("#error", { timeout: 15000 }).catch(() => {});
    await page.waitForTimeout(300);
    const g = await page.evaluate(() => {
      const box = document.querySelector(".load-failed");
      if (!box) return null;
      const textBox = (el) => {
        const range = document.createRange();
        range.selectNodeContents(el);
        const rs = [...range.getClientRects()].filter((q) => q.height > 0);
        return { top: Math.min(...rs.map((q) => q.top)), bottom: Math.max(...rs.map((q) => q.bottom)) };
      };
      const [lead, msg, link] = [box.querySelector(".sub"), box.querySelector("#error"), box.querySelector("a")].map((e) => e && textBox(e));
      if (!lead || !msg || !link) return null;
      return { first: Math.round(msg.top - lead.bottom), second: Math.round(link.top - msg.bottom) };
    });
    if (!g) check(false, `error @${width}: lead, #error and link rendered`);
    else check(Math.abs(g.first - g.second) <= 2 && g.first <= 16 && g.second <= 16,
      `error @${width}: gaps lead->message ${g.first}px, message->link ${g.second}px (even within 2px, each <= 16px)`);
    await page.close();
  }

  await browser.close();
  console.log(defects);
  process.exit(defects ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log(99); process.exit(1); });
EOF
