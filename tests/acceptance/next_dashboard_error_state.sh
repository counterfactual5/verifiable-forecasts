#!/usr/bin/env bash
# A failed ?data= load is announced (role=alert naming the source) and offers a way back to the default view whose
# href never carries the user's ?data value; the message stays text. Last line: defect count (target 0).
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
  const open = async (query) => {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    let dialogs = 0;
    page.on("dialog", (d) => { dialogs++; d.dismiss().catch(() => {}); });
    await page.goto(`${base}/dashboard/${query}`);
    await page.waitForFunction(() => document.getElementById("error") || document.querySelector("#app svg"),
      null, { timeout: 15000 }).catch(() => {});
    await page.waitForTimeout(400);
    const s = await page.evaluate(() => ({
      alerts: [...document.querySelectorAll('[role="alert"]')].map((e) => e.textContent),
      links: [...document.querySelectorAll("a[href]")].map((a) => a.href),
      error: document.getElementById("error")?.textContent ?? null,
      errorChildren: document.getElementById("error")?.children.length ?? 0,
      pwn: !!document.getElementById("pwn") || !!window.__pwned,
    }));
    await page.close();
    return { ...s, dialogs };
  };

  let s = await open("?data=missing.json");
  check(s.alerts.some((t) => /missing\.json/.test(t)), `role=alert names missing.json (alerts ${JSON.stringify(s.alerts)})`);
  const home = s.links.filter((h) => { const u = new URL(h); return u.pathname === "/dashboard/" && !u.searchParams.has("data"); });
  check(home.length > 0, `link to default view /dashboard/ without ?data (links ${JSON.stringify(s.links)})`);
  check(!s.links.some((h) => /missing\.json/.test(h)), "no link href carries the ?data param");
  check(s.error !== null && /missing\.json/.test(s.error), `#error text names missing.json (${s.error})`);

  s = await open(`?data=${encodeURIComponent('<img src=x onerror="window.__pwned=1">')}`);
  check(!s.pwn && s.errorChildren === 0 && s.dialogs === 0 && !s.links.some((h) => /onerror|%3Cimg|<img/i.test(h)),
    `markup case: nothing injected, no link carries the param (children ${s.errorChildren}, pwn ${s.pwn})`);

  await browser.close();
  console.log(defects);
  process.exit(defects ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log(99); process.exit(1); });
EOF
