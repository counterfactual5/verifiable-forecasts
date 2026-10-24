#!/usr/bin/env bash
# Pending-round label acceptance: the live nowcast's current-hour panel names the pending round's own
# window from the JSON in UTC ("当前小时 · 待结算（HH:00–HH:00 UTC，整点后结算）"; narrow screens keep the
# window and UTC), and a caption below the chart says fork-replay forecasts are committed before the window
# in fork-chain time while in real time the hourly run creates the round inside the window. A copy of the
# data with the window moved 5 hours must change the label. Label stays inside the chart; no overflow at
# 375 / 390 / 1440 px. DASHBOARD_HTML=<file> checks another index.html (fail-first).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/pending_label"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
sed -n "/<<'PY'$/,/^PY$/p" tests/acceptance/next_dashboard_quantile.sh | sed '1d;$d' > "$tmp/to_v2.py"
python3 "$tmp/to_v2.py" dashboard/sample-replay.json "$tmp/dashboard" || { echo "not ok - v2 fixture"; echo FAIL; exit 1; }
python3 - "$tmp/dashboard" <<'PY'
import json, sys, datetime as dt
out = sys.argv[1]
d = json.load(open(out + "/v2.json"))
pr = d["pending_round"]
iso = lambda t: dt.datetime.fromtimestamp(t, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
start = int(dt.datetime.strptime(pr["window_utc"][0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc).timestamp()) + 5 * 3600
pr["window_utc"] = [iso(start), iso(start + 3600)]
json.dump(d, open(out + "/v2shift.json", "w"))
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp" >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$tmp" <<'EOF'
const fs = require("fs");
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const [base, tmp] = process.argv.slice(2);
const errs = [];
const check = (cond, msg) => { console.log(`${cond ? "ok" : "not ok"} - ${msg}`); if (!cond) errs.push(msg); };

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const probe = async (data, width) => {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, hasTouch: width < 600, isMobile: width < 600, reducedMotion: "reduce" });
    const page = await ctx.newPage();
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(e.message));
    await page.goto(`${base}/dashboard/?data=${data}#/live`);
    await page.waitForSelector("#nowcast svg", { state: "attached", timeout: 15000 });
    await page.waitForTimeout(150);
    const r = await page.evaluate(() => {
      const nc = document.getElementById("nowcast"), svg = nc.querySelector("svg"), vb = svg.viewBox.baseVal;
      const label = [...svg.querySelectorAll("text.ax")].find((t) => /待结算/.test(t.textContent));
      const bb = label?.getBBox(), card = nc.getBoundingClientRect();
      const note = nc.querySelector(".nc-note"), nb = note?.getBoundingClientRect();
      return { label: label?.textContent ?? "", inside: !!bb && bb.x + bb.width <= vb.width - 2, labelRight: bb ? bb.x + bb.width : null, vbw: vb.width,
        note: note?.textContent.replace(/\s+/g, " ") ?? "", noteAfterSvg: !!note && !!(svg.compareDocumentPosition(note) & Node.DOCUMENT_POSITION_FOLLOWING),
        noteFits: !!nb && nb.left >= card.left - 1 && nb.right <= card.right + 1,
        sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth };
    });
    await ctx.close();
    return { ...r, pageErrors };
  };

  for (const data of ["v2.json", "v2shift.json"]) {
    const d = JSON.parse(fs.readFileSync(`${tmp}/dashboard/${data}`, "utf8"));
    const [h0, h1] = d.pending_round.window_utc.map((s) => s.slice(11, 16)), win = `${h0}–${h1} UTC`;
    for (const w of [1440, 390, 375]) {
      const r = await probe(data, w);
      if (w === 1440) check(r.label === `当前小时 · 待结算（${win}，整点后结算）`, `${data} ${w} px: label names the pending window ${win} (got "${r.label}")`);
      else check(r.label.includes(win) && r.label.includes("待结算"), `${data} ${w} px: narrow label keeps ${win} and 待结算 (got "${r.label}")`);
      check(r.inside, `${data} ${w} px: label inside the chart (${r.labelRight?.toFixed(1)} <= ${r.vbw})`);
      check(/分叉回放/.test(r.note) && /分叉链时间/.test(r.note) && /窗口开始前提交/.test(r.note) && /每小时一次的运行/.test(r.note) && /窗口内创建/.test(r.note) && r.noteAfterSvg,
            `${data} ${w} px: caption below the chart explains fork-time vs real-time (got "${r.note}")`);
      check(r.noteFits && r.sw <= r.cw, `${data} ${w} px: caption fits the card, no page overflow (${r.sw} <= ${r.cw})`);
      check(r.pageErrors.length === 0, `${data} ${w} px: no page errors (${r.pageErrors.join("; ")})`);
    }
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log("FAIL"); process.exit(1); });
EOF
