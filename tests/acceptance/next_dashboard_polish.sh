#!/usr/bin/env bash
# R10 acceptance: dashboard layout, colour, legend and mobile polish. Agent line colours never reuse
# the winning-bucket colour, the 1280 px grid of every replay view leaves no half-empty row, legend entries never break
# inside a series name at 375 px, and the single-round probability bars name their buckets without
# relying on colour; no horizontal overflow.
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
  // Every replay view is checked: cards of the views not shown take no space, so rows count rendered cards only.
  const views = ["", "#/live", "#/rounds", "#/agents", "#/fee", "#/chain"];
  const runs = [["sample-round.json", 1280, ""], ["sample-round.json", 375, ""]]
    .concat(views.flatMap((v) => [["sample-replay.json", 1280, v], ["sample-replay.json", 375, v]]));
  for (const [data, width, view] of runs) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    await page.goto(`${base}/dashboard/?data=${data}${view}`);
    await page.waitForSelector("#app svg", { timeout: 15000, state: "attached" });
    await page.waitForFunction(() => !document.querySelector("#app > [data-v]") || document.body.dataset.view, null, { timeout: 15000 });
    const r = await page.evaluate(() => {
      const norm = (c) => { const d = document.createElement("div"); d.style.color = c; document.body.appendChild(d); const v = getComputedStyle(d).color; d.remove(); return v; };
      const win = norm(getComputedStyle(document.documentElement).getPropertyValue("--win").trim());
      const lineColours = [...document.querySelectorAll("#app svg polyline, #app svg path")].map((p) => p.getAttribute("stroke")).filter((s) => s && s !== "none").map(norm);
      const app = document.querySelector("#app");
      const cards = [...app.children].filter((c) => c.classList.contains("card") && c.getClientRects().length);
      const rows = {};
      for (const c of cards) { const t = Math.round(c.getBoundingClientRect().top); (rows[t] = rows[t] || []).push(c); }
      const appW = app.getBoundingClientRect().width;
      const holes = Object.values(rows).filter((cs) => cs.reduce((w, c) => w + c.getBoundingClientRect().width, 0) < appW * 0.9).map((cs) => cs.map((c) => c.querySelector("h2")?.textContent.trim()).join("+"));
      const glyph = /^[━┈┅┄╌]$/;
      const legendBreaks = [...document.querySelectorAll("#app .card .sub span")].filter((sp) => glyph.test(sp.textContent.trim())).map((sp) => {
        let node = sp.nextSibling;
        while (node && node.nodeType !== 3 && !node.textContent.trim()) node = node.nextSibling;
        if (!node) return null;
        const textNode = node.nodeType === 3 ? node : [...node.childNodes].find((n) => n.nodeType === 3);
        if (!textNode) return null;
        const lead = textNode.textContent.match(/^\s*/)[0].length;
        const name = textNode.textContent.slice(lead).split(/\s/)[0];
        if (!name) return null;
        const rg = document.createRange(); rg.setStart(textNode, lead); rg.setEnd(textNode, lead + name.length);
        const tops = new Set([...rg.getClientRects()].filter((x) => x.width > 0).map((x) => Math.round(x.top)));
        return tops.size > 1 ? name : null;
      }).filter(Boolean);
      const legendCount = [...document.querySelectorAll("#app .card .sub span")].filter((sp) => glyph.test(sp.textContent.trim())).length;
      const winVar = getComputedStyle(document.documentElement).getPropertyValue("--win").trim().toLowerCase();
      return { winVar, legendCount, win, clash: lineColours.filter((c) => c === win).length, lines: lineColours.length, holes, legendBreaks,
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
    });
    if (data === "sample-replay.json") check(r.lines > 0 && r.clash === 0, `${data}${view} @${width}: no agent line uses the winning-bucket colour ${r.win} (${r.clash}/${r.lines})`);
    if (width === 1280) check(r.holes.length === 0, `${data}${view} @${width}: no grid row is left half empty ${JSON.stringify(r.holes)}`);
    check(r.winVar === "#a371f7", `${data}${view} @${width}: the winning-bucket colour --win stays #a371f7 (${r.winVar})`);
    if (data === "sample-replay.json" && width === 375) check(r.legendCount > 0, `${data}${view} @${width}: legend entries are found (${r.legendCount})`);
    if (width === 375) check(r.legendBreaks.length === 0, `${data}${view} @${width}: no legend entry breaks inside its name ${JSON.stringify(r.legendBreaks.slice(0, 3))}`);
    check(r.overflow <= 0, `${data}${view} @${width}: no horizontal overflow (${r.overflow}px)`);

    if (data === "sample-round.json" && width === 1280) {
      const p = await page.evaluate(() => {
        const groups = [...document.querySelectorAll("#app .probs")];
        const named = groups.filter((g) => g.getAttribute("role") === "img" && (g.getAttribute("aria-label") || "").match(/\d+(\.\d+)?\s*%/g)?.length >= 5).length;
        const head = [...document.querySelectorAll("#app th")].map((th) => th.textContent).join(" ");
        const outcomeNamed = groups.filter((g) => /outcome/i.test(g.getAttribute("aria-label") || "")).length;
        return { n: groups.length, named, outcomeNamed, colourHead: /purple|violet|magenta|lilac|green|red|blue|colou?r/i.test(head), outcomeHead: /outcome/i.test(head) };
      });
      check(p.n > 0 && p.named === p.n, `single-round probability bars are role=img with all five bucket percentages (${p.named}/${p.n})`);
      check(p.n > 0 && p.outcomeNamed === p.n, `single-round probability labels name the outcome bucket (${p.outcomeNamed}/${p.n})`);
      check(p.outcomeHead && !p.colourHead, "single-round table headers name the outcome without a colour word");
    }
    await page.close();
  }
  const html = require("fs").readFileSync("dashboard/index.html", "utf8");
  const pal = ((html.match(/const PALETTE = \[([^\]]*)\]/) || [])[1] || "").match(/#[0-9a-fA-F]{6}/g) || [];
  const fee = ["#ffa657", "#56d4dd", "#e6edf3", "#8b949e", "#a371f7"];
  const lower = pal.map((c) => c.toLowerCase());
  check(lower.length >= 4 && new Set(lower).size === lower.length && !lower.some((c) => fee.includes(c)),
    `PALETTE colours are pairwise distinct and differ from --win and the fee-card series ${JSON.stringify(lower)}`);
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
