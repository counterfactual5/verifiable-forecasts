#!/usr/bin/env bash
# Fee residual acceptance: below the fee chart the fee card plots, per round, strategy fee minus the
# hindsight fair fee (bps) for forecast (dashed vermilion, as in the main chart), fixed 5 bps and
# prev-hour RV (thin grey) with a 0 line, the same x axis and hover read-out as the main chart, English
# metric names and a one-line Chinese caption. Each strategy tile keeps MAE as the headline and adds the
# bias (mean signed residual) and the rounds beating fixed 5 bps (|residual| < fixed's; "—" on the
# fixed tile). Everything is computed from rounds[].fee, so it must hold for the committed v1 sample, a
# one-round live-style replay, a vol-replay/v2 replay, a replay with a round missing its fee data and,
# when present, the local dashboard/live-replay.json; no overflow at 375 / 390 / 1440 px.
# DASHBOARD_HTML=<file> checks another index.html (fail-first); SHOT_DIR=<dir> saves card screenshots.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/fee_residuals"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
cp dashboard/sample-replay.json "$tmp/dashboard/sample.json"
[[ -f dashboard/live-replay.json ]] && cp dashboard/live-replay.json "$tmp/dashboard/live.json"

# The v2 replay comes from the quantile acceptance's own converter, so both tests share one fixture recipe.
sed -n "/<<'PY'$/,/^PY$/p" tests/acceptance/next_dashboard_quantile.sh | sed '1d;$d' > "$tmp/to_v2.py"
python3 "$tmp/to_v2.py" dashboard/sample-replay.json "$tmp/dashboard" || { echo "not ok - v2 fixture"; echo FAIL; exit 1; }

python3 - dashboard/sample-replay.json "$tmp/dashboard" <<'PY'
import copy, json, sys
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))

def resummarize(x):
    fees = [r["fee"] for r in x["rounds"] if r.get("fee")]
    fs = x["summary"]["fee_strategies"]
    fs["rounds"] = len(fees)
    for k, f in (("fixed", "fixed_bps"), ("prev_hour", "prev_hour_bps"), ("forecast", "forecast_bps")):
        fs["mae_bps"][k] = sum(abs(e[f] - e["fair_bps"]) for e in fees) / len(fees)
    for k, f in (("fair", "fair_bps"), ("fixed", "fixed_bps"), ("prev_hour", "prev_hour_bps"), ("forecast", "forecast_bps")):
        fs["mean_bps"][k] = sum(e[f] for e in fees) / len(fees)

one = copy.deepcopy(d)
one["rounds"] = one["rounds"][-1:]
resummarize(one)
json.dump(one, open(out + "/one.json", "w"))

gap = copy.deepcopy(d)
gap["rounds"][5].pop("fee")
gap["rounds"][9]["fee"]["prev_hour_bps"] = None
json.dump(gap, open(out + "/gap.json", "w"))
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp" >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$tmp" "${SHOT_DIR:-}" <<'EOF'
const fs = require("fs");
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const [base, tmp, shots] = process.argv.slice(2);
const errs = [];
const check = (cond, msg) => { console.log(`${cond ? "ok" : "not ok"} - ${msg}`); if (!cond) errs.push(msg); };
const num = (s) => parseFloat(String(s).replace(/\u2212/g, "-").replace(/[^0-9.+\-]/g, ""));
const CJK = /[\u3000-\u9fff\uff00-\uffef]/;
const NAMES = { forecast: "forecast", fixed: "fixed 5 bps", prev_hour: "prev-hour RV" };
const FIELD = { forecast: "forecast_bps", fixed: "fixed_bps", prev_hour: "prev_hour_bps" };

const sets = ["sample", "one", "v2", "gap"].concat(fs.existsSync(`${tmp}/dashboard/live.json`) ? ["live"] : []);
(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const open = async (name, width) => {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(e.message));
    await page.goto(`${base}/dashboard/?data=${name}.json#/fee`);
    await page.waitForSelector("#app section.card", { state: "attached", timeout: 15000 });
    return { page, pageErrors };
  };
  for (const name of sets) {
    const d = JSON.parse(fs.readFileSync(`${tmp}/dashboard/${name}.json`, "utf8"));
    const res = (k) => d.rounds.map((r) => (r.fee && r.fee[FIELD[k]] != null && r.fee.fair_bps != null ? r.fee[FIELD[k]] - r.fee.fair_bps : null));
    const { page, pageErrors } = await open(name, 1440);
    const card = page.locator("#fee-card"), box = card.locator("#fee-resid");
    check(await box.count() === 1, `${name}: residual block #fee-resid inside the fee card`);
    if (await box.count() !== 1) { await page.close(); continue; }
    check(await box.locator(".chart").count() === 1 && await box.locator(".chart svg path").count() === 3,
          `${name}: residual chart has 3 lines (found ${await box.locator(".chart svg path").count()})`);
    check(await box.locator(".chart svg > line[stroke-dasharray]:not(.guide)").count() === 1, `${name}: residual chart draws a 0 line`);
    const zeroTick = await box.locator(".chart svg text.ax[text-anchor=end]").allTextContents();
    check(zeroTick.some((t) => num(t) === 0), `${name}: residual axis has a 0 tick (${zeroTick.join(" ")})`);

    const fc = await box.locator(".chart svg path[stroke='#d8431b']").count() === 1
      ? await box.locator(".chart svg path[stroke='#d8431b']").evaluate((p) => [p.getAttribute("stroke-dasharray"), p.getAttribute("stroke-width")]) : [];
    check(fc[0] === "7 4" && Number(fc[1]) >= 2.5, `${name}: forecast residual is the dashed vermilion line (${fc.join(" / ")})`);
    const others = await box.locator(".chart svg path:not([stroke='#d8431b'])").evaluateAll((ps) => ps.map((p) => [p.getAttribute("stroke"), Number(p.getAttribute("stroke-width"))]));
    check(others.length === 2 && others.every(([c, w]) => w <= 1.6 && /^#[0-9a-f]{6}$/i.test(c) && (() => {
      const [r, g, b] = [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
      return Math.max(r, g, b) - Math.min(r, g, b) < 48;
    })()), `${name}: fixed / prev-hour residuals are thin grey lines (${JSON.stringify(others)})`);

    const titles = await box.locator(".chart svg circle title").allTextContents();
    const names = new Set(titles.map((s) => s.split(" · ")[0]));
    check(names.size === 3 && Object.values(NAMES).every((n) => names.has(n)), `${name}: residual point titles use English names (${[...names].join(" | ")})`);
    const n = d.rounds.length;
    for (const i of [...new Set([0, Math.floor(n / 2), n - 1, 5, 9].filter((i) => i < n))]) {
      const label = d.rounds[i].window_utc[0].slice(11, 16);
      for (const [k, nm] of Object.entries(NAMES)) {
        const want = res(k)[i];
        const hit = titles.filter((s) => s.startsWith(`${nm} · ${label}: `));
        const ok = want == null ? hit.length === 0 : hit.length === 1 && Math.abs(num(hit[0].split(": ").pop()) - want) < 0.006;
        check(ok, `${name}: residual ${k} @ ${label} = ${want == null ? "none" : want.toFixed(3)} (got ${hit[0] ?? "none"})`);
      }
    }
    const signed = titles.find((s) => num(s.split(": ").pop()) > 0.005);
    check(!signed || /: \+/.test(signed), `${name}: positive residuals carry a + sign (${signed ?? "none"})`);

    const xl = async (loc) => (await loc.locator("svg text.ax[text-anchor=middle]").allTextContents()).join(",");
    const mainX = await xl(card.locator(".chart").first()), resX = await xl(box.locator(".chart"));
    check(mainX.length > 0 && mainX === resX, `${name}: residual x axis matches the fee chart (${resX})`);

    const legend = await box.locator(".chart + .sub").innerText().catch(() => "");
    check(Object.values(NAMES).every((nm) => legend.includes(nm)) && !CJK.test(legend), `${name}: residual legend is English only (${legend.replace(/\s+/g, " ")})`);
    const lead = (await box.innerText()).replace(legend, "");
    check(/残差/.test(lead) && /高于\s*0/.test(lead), `${name}: one-line Chinese caption explains the sign`);

    await box.locator(".chart svg").scrollIntoViewIfNeeded();
    const svgBox = await box.locator(".chart svg").boundingBox();
    await page.mouse.move(svgBox.x + svgBox.width * 0.55, svgBox.y + svgBox.height / 2);
    await page.waitForTimeout(80);
    const rows = await box.locator(".chart.hover .tip .r").count();
    const want = Object.keys(NAMES).filter((k) => res(k).some((v) => v != null)).length;
    check(rows >= 1 && rows <= want, `${name}: hovering the residual chart shows the per-round read-out (${rows} rows)`);

    for (const k of Object.keys(NAMES)) {
      const r = res(k), fx = res("fixed");
      const pairs = r.map((v, i) => [v, fx[i]]).filter(([a, b]) => a != null && b != null);
      const vals = r.filter((v) => v != null);
      const bias = vals.reduce((a, b) => a + b, 0) / vals.length;
      const bt = card.locator(`[data-bias="${k}"]`);
      const btxt = (await bt.count()) === 1 ? await bt.innerText() : "";
      check(Math.abs(num(btxt) - bias) < 0.006 && (bias <= 0.005 || btxt.trim().startsWith("+")),
            `${name}: ${k} bias ${btxt || "none"} = ${bias.toFixed(3)} (signed)`);
      const beat = card.locator(`[data-beat="${k}"]`);
      const ttxt = (await beat.count()) === 1 ? (await beat.innerText()).trim() : null;
      if (k === "fixed") check(ttxt === null || ttxt === "—", `${name}: fixed tile has no beating-fixed count (${ttxt})`);
      else {
        const wins = pairs.filter(([a, b]) => Math.abs(a) < Math.abs(b)).length;
        check(ttxt === `${wins}/${pairs.length}`, `${name}: ${k} beats fixed 5 bps in ${wins}/${pairs.length} rounds (got ${ttxt})`);
      }
      const mae = card.locator(`.fee-mae[data-mae="${k}"]`);
      check(await mae.count() === 1 && Math.abs(num(await mae.innerText()) - d.summary.fee_strategies.mae_bps[k]) < 0.006, `${name}: ${k} MAE stays the headline`);
    }
    const tileText = await card.locator(".fee-tile").allInnerTexts();
    check(tileText.some((t) => /\bbias\b/.test(t)) && tileText.some((t) => /beating fixed 5 bps/.test(t)), `${name}: tiles label bias and rounds beating fixed 5 bps in English`);
    check(pageErrors.length === 0, `${name}: no page errors (${pageErrors.join("; ")})`);
    if (shots && name === "sample") await card.screenshot({ path: `${shots}/fee-card-1440.png` });
    await page.close();
  }

  for (const w of [375, 390, 1440]) {
    const { page, pageErrors } = await open("sample", w);
    const [sw, cw] = await page.evaluate(() => [document.documentElement.scrollWidth, document.documentElement.clientWidth]);
    check(sw <= cw, `${w} px: no page overflow (${sw} <= ${cw})`);
    const c = await page.evaluate(() => { const e = document.getElementById("fee-card"); return e ? [e.scrollWidth, e.clientWidth] : [1, 0]; });
    check(c[0] <= c[1], `${w} px: fee card does not scroll sideways (${c[0]} <= ${c[1]})`);
    const tiles = await page.evaluate(() => [...document.querySelectorAll("#fee-card .fee-tile")].every((t) => t.scrollWidth <= t.clientWidth + 1));
    check(tiles, `${w} px: strategy tiles fit their width`);
    check(pageErrors.length === 0, `${w} px: no page errors`);
    if (shots && w === 390) await page.locator("#fee-card").screenshot({ path: `${shots}/fee-card-390.png` });
    await page.close();
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "PASS");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e.message); console.log("FAIL"); process.exit(1); });
EOF
