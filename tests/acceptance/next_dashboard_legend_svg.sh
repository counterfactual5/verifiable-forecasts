#!/usr/bin/env bash
# R2 acceptance: chart legends draw their line style as an inline svg swatch instead of the text glyphs ━ ┈ ┅.
# On every sample-replay.json view and on sample-round.json: no legend text holds those glyphs, every legend entry
# has an svg.swatch <line> whose stroke is a plotted line's colour in the same card and whose stroke-dasharray
# equals that line's (both empty for solid), each visible swatch is at least 16px wide, and the page throws no error.
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

const inspect = (page) => page.evaluate(() => {
  const norm = (c) => { const d = document.createElement("div"); d.style.color = c; document.body.appendChild(d); const v = getComputedStyle(d).color; d.remove(); return v; };
  const dash = (el) => (el.getAttribute("stroke-dasharray") ?? "").trim().replace(/[\s,]+/g, " ");
  const shown = (el) => el.getClientRects().length > 0;
  const glyphText = [...document.querySelectorAll("#app .sub")].filter(shown).map((s) => s.innerText).filter((t) => /[━┈┅]/.test(t));
  const entries = [...document.querySelectorAll("#app .sub span.nowrap")].filter(shown)
    .filter((sp) => sp.querySelector("svg.swatch") || /^[━┈┅]/.test(sp.textContent.trim()));
  const segment = [...document.querySelectorAll("#app .sub")].filter(shown).filter((s) => /segment mean tick/.test(s.textContent));
  const swatches = [...document.querySelectorAll("#app svg.swatch")].filter(shown);
  const bad = [];
  for (const sw of swatches) {
    const line = sw.querySelector("line");
    if (!line) { bad.push("swatch without <line>"); continue; }
    const card = sw.closest(".card, section") ?? document.querySelector("#app");
    const stroke = norm(line.getAttribute("stroke") ?? "");
    const plotted = [...card.querySelectorAll("svg:not(.swatch) path")].filter((p) => p.getAttribute("fill") === "none" && norm(p.getAttribute("stroke") ?? "") === stroke);
    const name = (sw.closest("span.nowrap, .sub")?.textContent ?? "").trim().slice(0, 30);
    if (!plotted.length) bad.push(`${name}: no plotted line with stroke ${stroke}`);
    else if (!plotted.some((p) => dash(p) === dash(line))) bad.push(`${name}: dasharray "${dash(line)}" vs plotted "${plotted.map(dash).join("|")}"`);
    if (sw.getBoundingClientRect().width < 16) bad.push(`${name}: swatch ${sw.getBoundingClientRect().width.toFixed(1)}px wide`);
    if (sw.getAttribute("aria-hidden") !== "true") bad.push(`${name}: swatch not aria-hidden`);
  }
  const noSwatch = entries.filter((sp) => !sp.querySelector("svg.swatch")).map((sp) => sp.textContent.trim().slice(0, 30));
  const segSwatches = segment.map((s) => {
    const plotted = [...(s.closest(".card, section") ?? document).querySelectorAll("svg:not(.swatch) path")].filter((p) => p.getAttribute("fill") === "none").length;
    return [s.querySelectorAll("svg.swatch").length, plotted];
  });
  return { glyphText: glyphText.map((t) => t.slice(0, 60)), entries: entries.length, noSwatch, swatches: swatches.length, bad, segSwatches };
});

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const runs = ["", "#/live", "#/rounds", "#/agents", "#/fee", "#/chain"].map((v) => ["sample-replay.json", v]).concat([["sample-round.json", ""]]);
  let total = 0, segmentSeen = false;
  for (const [data, view] of runs) {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e)));
    await page.goto(`${base}/dashboard/?data=${data}${view}`);
    await page.waitForSelector("#app svg", { timeout: 15000, state: "attached" });
    await page.waitForTimeout(300);
    const r = await inspect(page);
    const tag = `${data}${view}`;
    check(r.glyphText.length === 0, `${tag}: no legend text uses ━ ┈ ┅ ${JSON.stringify(r.glyphText.slice(0, 2))}`);
    check(r.noSwatch.length === 0, `${tag}: every legend entry has an svg.swatch (${r.entries - r.noSwatch.length}/${r.entries}) ${JSON.stringify(r.noSwatch.slice(0, 3))}`);
    check(r.bad.length === 0, `${tag}: every swatch matches a plotted line's colour and dasharray, is >= 16px wide and aria-hidden ${JSON.stringify(r.bad.slice(0, 3))}`);
    if (r.segSwatches.length) { segmentSeen = true; check(r.segSwatches.every(([n, p]) => n >= 1 && n === p), `${tag}: the segment chart legend has one swatch per plotted line (${JSON.stringify(r.segSwatches)})`); }
    check(errors.length === 0, `${tag}: no page errors (${errors.join("; ")})`);
    total += r.swatches;
    await page.close();
  }
  check(segmentSeen, "the single-round segment chart legend was found");
  check(total > 0, `swatches found across the views (${total})`);
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
