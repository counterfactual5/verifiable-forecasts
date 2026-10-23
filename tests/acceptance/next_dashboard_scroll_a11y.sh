#!/usr/bin/env bash
# R2 acceptance: every visible .table-scroll that overflows sideways is a named, focusable region
# (tabindex=0, role=region, aria-label with its card title and 滚动) and one that fits has no tabindex —
# at 1280 and 375 on the Agents, Rounds and Chain sub-pages and after a 1280->375->1280 resize; the visible
# hint carries Chinese text and an arrow; at 375 Tab reaches an overflowing table and ArrowRight scrolls it.
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
  const shown = (el) => !!el && getComputedStyle(el).display !== "none" && el.getBoundingClientRect().height > 0;
  const tables = [...document.querySelectorAll(".table-scroll")].filter((w) => w.offsetParent !== null && w.clientWidth > 0).map((w) => {
    const title = (w.closest(".card, section")?.querySelector("h2, h3")?.textContent ?? "").replace(/\s+/g, " ").trim();
    return { title, over: w.scrollWidth > w.clientWidth + 1, tabindex: w.getAttribute("tabindex"),
      role: w.getAttribute("role"), label: w.getAttribute("aria-label") ?? "" };
  });
  const hints = [...document.querySelectorAll(".scroll-hint")].filter(shown).map((h) => h.textContent.trim());
  return { tables, hints };
});

const judge = (tag, { tables, hints }) => {
  for (const t of tables) {
    const name = t.title.slice(0, 40) || "?";
    if (t.over) {
      check(t.tabindex === "0" && t.role === "region", `${tag}: "${name}" overflows and is a focusable region (tabindex=${t.tabindex}, role=${t.role})`);
      check(t.title.length > 0 && t.label.includes(t.title.slice(0, 6)) && t.label.includes("滚动"), `${tag}: "${name}" aria-label names its card and 滚动 ("${t.label}")`);
    } else {
      check(t.tabindex === null, `${tag}: "${name}" fits and has no tabindex (${t.tabindex})`);
    }
  }
  for (const h of hints) check(/[\u4e00-\u9fff]/.test(h) && h.includes("→"), `${tag}: visible scroll hint has Chinese text and an arrow ("${h}")`);
  return tables.some((t) => t.over);
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
      const any = judge(`@${width} #/${view}`, await inspect(page));
      if (view === "rounds") check(any, `@${width} #/rounds: at least one table overflows (the case this stage is about)`);
    }
    await page.close();
  }

  const page = await browser.newPage({ viewport: { width: 375, height: 900 } });
  await page.goto(`${base}/dashboard/?data=sample-replay.json#/rounds`);
  await page.waitForSelector("#app table", { state: "attached", timeout: 15000 });
  await page.waitForTimeout(300);
  let reached = false;
  for (let i = 0; i < 200 && !reached; i++) {
    await page.keyboard.press("Tab");
    reached = await page.evaluate(() => {
      const a = document.activeElement;
      return !!a && a.classList.contains("table-scroll") && a.scrollWidth > a.clientWidth + 1;
    });
  }
  check(reached, "@375 #/rounds: Tab reaches an overflowing table");
  if (reached) {
    for (let i = 0; i < 3; i++) await page.keyboard.press("ArrowRight");
    await page.waitForTimeout(300);
    const left = await page.evaluate(() => document.activeElement.scrollLeft);
    check(left > 0, `@375 #/rounds: ArrowRight scrolls the focused table (scrollLeft ${left})`);
  }

  await page.setViewportSize({ width: 1280, height: 900 });
  await page.waitForTimeout(400);
  judge("resize 375->1280 #/rounds", await inspect(page));
  await page.setViewportSize({ width: 375, height: 900 });
  await page.waitForTimeout(400);
  judge("resize 1280->375 #/rounds", await inspect(page));
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.waitForTimeout(400);
  judge("resize 375->1280 again #/rounds", await inspect(page));
  await page.close();
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
