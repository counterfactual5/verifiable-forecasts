#!/usr/bin/env bash
# R1 acceptance: on #/agents at 1280 and 375, each reproducible row's Verification cell is a one-line summary
# plus exactly one <details> that holds the recompute command (hidden until its summary is clicked), the row
# is at most 1.6x the tallest zk row, nothing in the cell is clipped by overflow / line-clamp / max-height,
# the TimesFM row shows 非商用 without expanding, and the page throws no error.
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
const replay = require(require("path").join(process.cwd(), "dashboard/sample-replay.json"));
const agents = replay.agents.map((a) => ({ agent: a.agent, tier: a.tier, cmd: a.recompute_command ?? null, license: a.license ?? "" }));

const measure = (page, info) => page.evaluate((info) => {
  const table = [...document.querySelectorAll("#app table")].find((t) => /Verification/i.test(t.querySelector("tr")?.textContent ?? "") && /Σ ln p/.test(t.textContent));
  if (!table) return null;
  const head = [...table.querySelector("tr").children].map((c) => c.textContent.trim());
  const vi = head.findIndex((h) => /^Verification$/i.test(h));
  const clipped = (el) => [el, ...el.querySelectorAll("*")].some((n) => {
    const s = getComputedStyle(n);
    return s.overflow.includes("hidden") || s.overflowY === "hidden" || (s.webkitLineClamp && s.webkitLineClamp !== "none") || s.maxHeight !== "none";
  });
  return [...table.querySelectorAll("tr")].slice(1).map((tr) => {
    const name = tr.querySelector("td b")?.textContent.trim();
    const a = info.find((x) => x.agent === name);
    if (!a) return null;
    const cell = tr.children[vi];
    const details = cell.querySelectorAll("details");
    const d = details[0];
    let cmdNode = null;
    if (d && a.cmd) cmdNode = [...d.querySelectorAll("*")].reverse().find((n) => !n.closest("summary") && n.textContent.includes(a.cmd)) ?? null;
    return { name, tier: a.tier, timesfm: /^TimesFM/i.test(a.license), height: tr.getBoundingClientRect().height,
      nDetails: details.length, cmdInDetails: !!(d && a.cmd && d.textContent.includes(a.cmd)),
      cmdHidden: cmdNode ? cmdNode.getClientRects().length === 0 : null, clipped: clipped(cell), text: cell.innerText };
  }).filter(Boolean);
}, info);

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const width of [1280, 375]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e)));
    await page.goto(`${base}/dashboard/?data=sample-replay.json#/agents`);
    await page.waitForSelector("#app table", { state: "attached", timeout: 15000 });
    await page.waitForTimeout(400);
    const rows = await measure(page, agents);
    check(!!rows && rows.length === agents.length, `@${width}: found the Agents table with every agent row (${rows ? rows.length : 0}/${agents.length})`);
    if (!rows) { await page.close(); continue; }
    const zkMax = Math.max(...rows.filter((r) => r.tier === "zk").map((r) => r.height));
    const repro = rows.filter((r) => r.tier === "reproducible");
    check(repro.length === 3, `@${width}: three reproducible rows (${repro.map((r) => r.name).join(", ")})`);
    for (const r of repro) {
      check(r.height <= zkMax * 1.6, `@${width} ${r.name}: row ${r.height.toFixed(0)}px <= 1.6 x tallest zk row ${zkMax.toFixed(0)}px`);
      check(r.nDetails === 1, `@${width} ${r.name}: Verification cell has exactly one <details> (${r.nDetails})`);
      check(r.cmdInDetails, `@${width} ${r.name}: the recompute command is text inside the <details>`);
      check(r.cmdHidden === true, `@${width} ${r.name}: the recompute command is hidden before expanding`);
      check(!r.clipped, `@${width} ${r.name}: nothing in the cell is clipped by overflow, line-clamp or max-height`);
      if (r.timesfm) check(r.text.includes("非商用"), `@${width} ${r.name}: 非商用 visible without expanding`);
    }
    const first = repro[0];
    if (first && first.nDetails === 1) {
      const row = page.locator("#app tr", { has: page.locator("td b", { hasText: first.name }) }).first();
      await row.locator("details > summary").first().click();
      await page.waitForTimeout(200);
      const shown = await row.locator("details").first().evaluate((d, cmd) => {
        const n = [...d.querySelectorAll("*")].reverse().find((x) => !x.closest("summary") && x.textContent.includes(cmd));
        return !!n && n.getClientRects().length > 0;
      }, agents.find((a) => a.agent === first.name).cmd);
      check(shown, `@${width} ${first.name}: clicking the summary shows the recompute command`);
    }
    check(errors.length === 0, `@${width}: no page errors (${errors.join("; ")})`);
    await page.close();
  }
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
