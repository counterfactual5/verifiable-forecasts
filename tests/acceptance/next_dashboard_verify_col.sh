#!/usr/bin/env bash
# R1 acceptance: on #/agents at 1280 and 375, each reproducible row shows a one-line verification summary
# plus exactly one collapsed detail row that holds the recompute command (hidden until ▸ is clicked), the row
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
  const table = [...document.querySelectorAll("#app table")].find((t) => t.querySelector("tr[data-agent]"));
  if (!table) return null;
  const clipped = (el) => [el, ...el.querySelectorAll("*")].some((n) => {
    const s = getComputedStyle(n);
    return s.overflow.includes("hidden") || s.overflowY === "hidden" || (s.webkitLineClamp && s.webkitLineClamp !== "none") || s.maxHeight !== "none";
  });
  return [...table.querySelectorAll("tr[data-agent]")].map((tr) => {
    const name = tr.dataset.agent;
    const a = info.find((x) => x.agent === name);
    if (!a) return null;
    const det = document.querySelector(`tr[data-detail-for="${name}"]`);
    let cmdNode = null;
    if (det && a.cmd) cmdNode = [...det.querySelectorAll("*")].reverse().find((n) => n.textContent.includes(a.cmd)) ?? null;
    return { name, tier: a.tier, timesfm: /^TimesFM/i.test(a.license), height: tr.getBoundingClientRect().height,
      nDetails: det ? 1 : 0, cmdInDetails: !!(det && a.cmd && det.textContent.includes(a.cmd)),
      cmdHidden: cmdNode ? cmdNode.getClientRects().length === 0 : null, clipped: clipped(det ?? tr), text: tr.innerText };
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
      check(r.nDetails === 1, `@${width} ${r.name}: has exactly one collapsed detail row (${r.nDetails})`);
      check(r.cmdInDetails, `@${width} ${r.name}: the recompute command is text inside the detail row`);
      check(r.cmdHidden === true, `@${width} ${r.name}: the recompute command is hidden before expanding`);
      check(!r.clipped, `@${width} ${r.name}: nothing in the cell is clipped by overflow, line-clamp or max-height`);
      if (r.timesfm) check(r.text.includes("非商用"), `@${width} ${r.name}: 非商用 visible without expanding`);
    }
    const first = repro[0];
    if (first && first.nDetails === 1) {
      await page.click(`#app tr[data-agent="${first.name}"] button.agent-toggle`);
      await page.waitForTimeout(200);
      const shown = await page.locator(`#app tr[data-detail-for="${first.name}"]`).evaluate((d, cmd) => {
        const n = [...d.querySelectorAll("*")].reverse().find((x) => x.textContent.includes(cmd));
        return !!n && n.getClientRects().length > 0;
      }, agents.find((a) => a.agent === first.name).cmd);
      check(shown, `@${width} ${first.name}: clicking ▸ shows the recompute command`);
    }
    check(errors.length === 0, `@${width}: no page errors (${errors.join("; ")})`);
    await page.close();
  }
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
