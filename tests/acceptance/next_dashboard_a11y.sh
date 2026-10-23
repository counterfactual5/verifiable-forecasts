#!/usr/bin/env bash
# R8 acceptance: dashboard charts carry an accessible name, round scores say above/below the uniform
# baseline without relying on red/green, and the single-round probability bars reach 3:1 contrast
# against their card; no horizontal overflow at 375 px.
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
  for (const [data, width] of [["sample-replay.json", 1280], ["sample-round.json", 1280], ["sample-replay.json", 375]]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    await page.goto(`${base}/dashboard/?data=${data}`);
    await page.waitForSelector("#app svg", { timeout: 15000 });
    const r = await page.evaluate(() => {
      const svgs = [...document.querySelectorAll("#app svg")];
      const labels = svgs.map((s) => (s.getAttribute("aria-label") || "").trim());
      const unnamed = svgs.filter((s, i) => s.getAttribute("role") !== "img" || labels[i].length < 10).length;
      const offTopic = svgs.filter((s, i) => {
        const card = s.closest(".card");
        const h = (card?.querySelector("h2")?.textContent || "").trim().toLowerCase().slice(0, 10);
        const legend = [...(card?.querySelectorAll(".sub span") || [])].map((x) => x.nextSibling?.textContent?.trim()).filter(Boolean);
        const l = labels[i].toLowerCase();
        return !(h && l.includes(h)) && !legend.some((n) => l.includes(n.toLowerCase()));
      }).length;
      const distinct = new Set(labels).size === labels.length;
      const imgs = document.querySelectorAll('#app [role="img"]').length;
      return { n: svgs.length, unnamed, offTopic, distinct, imgs, overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
    });
    check(r.n > 0 && r.unnamed === 0, `${data} @${width}: every chart svg has role=img and a descriptive aria-label (${r.unnamed}/${r.n} missing)`);
    check(r.n > 0 && r.distinct && r.offTopic === 0, `${data} @${width}: chart labels are distinct and name their card title or a series (${r.offTopic} off-topic)`);
    if (data === "sample-replay.json") check(r.imgs > r.n, `${data} @${width}: the div-drawn winning-buckets chart is exposed as role=img too (${r.imgs} role=img vs ${r.n} svg)`);
    check(r.overflow <= 0, `${data} @${width}: no horizontal overflow (${r.overflow}px)`);

    if (data === "sample-replay.json" && width === 1280) {
      const t = await page.evaluate(() => {
        const table = [...document.querySelectorAll("#app table")].find((tb) => /Settle gas/.test(tb.textContent));
        if (!table) return null;
        const head = [...table.rows[0].cells].map((c) => c.textContent.trim());
        const from = head.findIndex((h) => /Feed age/.test(h)) + 1, to = head.findIndex((h) => /Settle gas/.test(h));
        const cells = [];
        for (const row of [...table.rows].slice(1)) for (let i = from; i < to; i++) cells.push(row.cells[i].textContent.trim());
        
        const note = [...table.closest(".card").querySelectorAll(".sub")].map((x) => x.textContent).join(" ");
        return { cells, greenOnly: /\b(green|red)\b/i.test(note), cols: to - from };
      });
      check(t && t.cols >= 4, "rounds table has the agent score columns");
      if (t) {
        const uniform = -Math.log(5);
        const scored = t.cells.filter((c) => /-?\d+\.\d+/.test(c));
        const wrong = scored.filter((c) => {
          const v = parseFloat(c.match(/-?\d+\.\d+/)[0]);
          return v > uniform ? !c.includes("▲") : !c.includes("▼");
        });
        check(scored.length >= 24 && wrong.length === 0, `every score carries ▲ (above uniform) or ▼ (not above) (${wrong.length}/${scored.length} wrong)`);
        check(!t.greenOnly, "the rounds caption no longer explains scores by colour alone");
      }
    }

    if (data === "sample-round.json") {
      const ratio = await page.evaluate(() => {
        const lum = (c) => {
          const [r, g, b] = c.match(/\d+(\.\d+)?/g).slice(0, 3).map(Number).map((v) => {
            v /= 255; return v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
          });
          return 0.2126 * r + 0.7152 * g + 0.0722 * b;
        };
        const bars = [...document.querySelectorAll(".probs div:not(.win)")];
        if (!bars.length) return null;
        let el = bars[0].parentElement, bg = "rgba(0, 0, 0, 0)";
        while (el && /rgba\(0, 0, 0, 0\)|transparent/.test(bg)) { bg = getComputedStyle(el).backgroundColor; el = el.parentElement; }
        const a = lum(getComputedStyle(bars[0]).backgroundColor), b = lum(bg);
        return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
      });
      check(ratio != null && ratio >= 3, `non-winning probability bars reach 3:1 against their card (${ratio && ratio.toFixed(2)})`);
    }
    await page.close();
  }
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
