#!/usr/bin/env bash
# R2 acceptance: every visible .table-scroll that actually overflows (scrollWidth > clientWidth) has a
# visible .scroll-hint right above it, and one that fits shows none — at 1280 and 375, on the Agents,
# Rounds and Chain sub-pages, both on first render and after a resize; no page overflow at 375.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const base = process.argv[2];
let fail = 0;
const check = (cond, msg) => { console.log((cond ? "ok - " : "not ok - ") + msg); if (!cond) fail = 1; };
const VIEWS = ["agents", "rounds", "chain"];

const inspect = (page) => page.evaluate(() => {
  const shown = (el) => !!el && getComputedStyle(el).display !== "none" && getComputedStyle(el).visibility !== "hidden" && el.getBoundingClientRect().height > 0;
  return [...document.querySelectorAll(".table-scroll")].filter((w) => w.offsetParent !== null && w.clientWidth > 0).map((w) => {
    const prev = w.previousElementSibling, hint = prev && prev.classList.contains("scroll-hint") ? prev : null;
    const title = w.closest(".card, section")?.querySelector("h2, h3")?.textContent.trim().slice(0, 40) ?? "?";
    return { title, over: w.scrollWidth > w.clientWidth + 1, sw: w.scrollWidth, cw: w.clientWidth,
      hint: shown(hint), above: shown(hint) && hint.getBoundingClientRect().bottom <= w.getBoundingClientRect().top + 1 };
  });
});

const judge = (tag, ts) => {
  for (const t of ts) {
    if (t.over) check(t.hint && t.above, `${tag}: "${t.title}" overflows (${t.sw} > ${t.cw}) and shows a scroll hint above it`);
    else check(!t.hint, `${tag}: "${t.title}" fits (${t.sw} <= ${t.cw}) and shows no scroll hint`);
  }
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const width of [1280, 375]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    for (const view of VIEWS) {
      await page.goto(`${base}/dashboard/?data=sample-replay.json#/${view}`);
      await page.waitForSelector("#app table", { state: "attached", timeout: 15000 });
      await page.waitForTimeout(300);
      const ts = await inspect(page);
      if (width === 1280 && view === "rounds") check(ts.some((t) => /^Rounds/.test(t.title) && t.over), `@1280: the Rounds table overflows its card (the case this stage is about)`);
      judge(`@${width} #/${view}`, ts);
      if (width === 375) {
        const ov = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
        check(ov <= 0, `@${width} #/${view}: no horizontal page overflow (${ov}px)`);
      }
    }
    await page.close();
  }
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  for (const view of ["agents", "rounds"]) {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto(`${base}/dashboard/?data=sample-replay.json#/${view}`);
    await page.waitForSelector("#app table", { state: "attached", timeout: 15000 });
    await page.waitForTimeout(300);
    await page.setViewportSize({ width: 1600, height: 900 });
    await page.waitForTimeout(400);
    judge(`resize 1280->1600 #/${view}`, await inspect(page));
    await page.setViewportSize({ width: 375, height: 900 });
    await page.waitForTimeout(400);
    judge(`resize 1600->375 #/${view}`, await inspect(page));
  }
  await page.close();
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
