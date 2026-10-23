#!/usr/bin/env bash
# R13 acceptance: in the replay rounds table, agent column headers carry their series colour only in a
# dot, so header text never reads as the green/red up-down colours; on narrow screens the Round
# column stays pinned on an opaque background while the table scrolls, the wide Agents tables keep
# their first column unpinned, and the scroll hint sits above the table; no overflow.
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

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const html = require("fs").readFileSync("dashboard/index.html", "utf8");
  const pal = (((html.match(/const PALETTE = \[([^\]]*)\]/) || [])[1] || "").match(/#[0-9a-fA-F]{6}/g) || []);
  for (const width of [1280, 375]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    await page.goto(`${base}/dashboard/?data=sample-replay.json`);
    await page.waitForSelector("#app svg", { timeout: 15000 });
    const r = await page.evaluate((pal) => {
      const norm = (c) => { const d = document.createElement("div"); d.style.color = c; document.body.appendChild(d); const v = getComputedStyle(d).color; d.remove(); return v; };
      const palN = pal.map(norm);
      const table = [...document.querySelectorAll("#app table")].find((t) => /^\s*Round\s*$/.test(t.querySelector("th")?.textContent || ""));
      if (!table) return { found: false };
      const ths = [...table.querySelectorAll("tr:first-child th")];
      const coloredText = ths.filter((th) => palN.includes(getComputedStyle(th).color)).map((th) => th.textContent.trim());
      const dotted = ths.filter((th) => [...th.querySelectorAll("span")].some((sp) => sp.textContent.trim() === "●" && palN.includes(getComputedStyle(sp).color))).length;
      const firstCells = [...table.querySelectorAll("tr")].map((tr) => tr.children[0]).filter(Boolean);
      const sticky = firstCells.filter((c) => getComputedStyle(c).position === "sticky").length;
      const opaque = firstCells.filter((c) => { const m = getComputedStyle(c).backgroundColor.match(/rgba?\(([^)]+)\)/); if (!m) return false; const p = m[1].split(",").map(Number); return p.length === 3 || p[3] === 1; }).length;
      const agentsTable = [...document.querySelectorAll("#app table")].find((t) => /^\s*Agent\s*$/.test(t.querySelector("th")?.textContent || ""));
      const agentsPinned = agentsTable ? [...agentsTable.querySelectorAll("tr")].filter((tr) => tr.children[0] && getComputedStyle(tr.children[0]).position === "sticky").length : -1;
      const wrap = table.closest(".table-scroll");
      const card = table.closest(".card");
      const hint = card ? card.querySelector(".scroll-hint") : null;
      const hintVisible = !!hint && getComputedStyle(hint).display !== "none";
      return { found: true, coloredText, dotted, sticky, opaque, agentsPinned, cells: firstCells.length,
        hintVisible, hintAbove: hintVisible && hint.getBoundingClientRect().bottom <= wrap.getBoundingClientRect().top + 1,
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
    }, pal);
    check(r.found, `@${width}: rounds table found`);
    if (!r.found) { await page.close(); continue; }
    check(r.coloredText.length === 0, `@${width}: no rounds-table header text uses a series colour ${JSON.stringify(r.coloredText)}`);
    check(r.dotted >= 4, `@${width}: agent headers carry a series-coloured ● dot (${r.dotted})`);
    if (width === 375) {
      check(r.cells > 1 && r.sticky === r.cells, `@${width}: the Round column is sticky in every row (${r.sticky}/${r.cells})`);
      check(r.opaque === r.cells, `@${width}: the pinned Round cells have an opaque background (${r.opaque}/${r.cells})`);
      check(r.agentsPinned === 0, `@${width}: the Agents table first column is not pinned (${r.agentsPinned})`);
      check(r.hintAbove, `@${width}: the scroll hint is visible above the table`);
    }
    check(r.overflow <= 0, `@${width}: no horizontal overflow (${r.overflow}px)`);
    await page.close();
  }
  const page = await browser.newPage({ viewport: { width: 375, height: 900 } });
  await page.goto(`${base}/dashboard/?data=sample-round.json`);
  await page.waitForSelector("#app svg", { timeout: 15000 });
  const pinned = await page.evaluate(() => [...document.querySelectorAll("#app table tr")].filter((tr) => tr.children[0] && getComputedStyle(tr.children[0]).position === "sticky").length);
  check(pinned === 0, `single-round @375: no table pins its first column (${pinned})`);
  await page.close();
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
