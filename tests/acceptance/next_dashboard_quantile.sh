#!/usr/bin/env bash
# Quantile acceptance (vol-replay/v2): forecasts are 5 quantiles of ln RV scored by the pinball loss
# against the climatological baseline. With a v2 replay the dashboard
# - plots the cumulative pinball excess vs climatology (ln RV, labelled) from each round's `excess`;
# - replaces the winning-bucket card with realized ln RV vs the baseline median plus the 50% / 80%
#   interval coverage of the baseline and of every agent, read from the summary;
# - draws the nowcast glyph straight from the revealed quantiles (data-q10..q90 = exp(quantile),
#   faint 10–90 band, darker 25–75 band, median tick), labelled 80%, not 90%;
# - shows mean pinball loss / mean excess (not Σ ln p) in the agents table, per-round excess in the
#   rounds table, the v2 case target, and keeps the fee card with its short English labels;
# - has no page errors and no horizontal overflow at 390 px.
# The committed sample keeps rendering (a v1 replay too, while dashboard/sample-replay.json is still v1).
# DASHBOARD_HTML=<file> checks another index.html (fail-first against the previous version).
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/docs/.local/tmp/dashboard_quantile"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
cp dashboard/sample-replay.json "$tmp/dashboard/v1.json"
python3 - dashboard/sample-replay.json "$tmp/dashboard" <<'PY'
import copy, json, math, random, sys, time
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
LV = [0.1, 0.25, 0.5, 0.75, 0.9]
BQ = [4.69140625, 5.587158203125, 6.44091796875, 7.276611328125, 8.00244140625]
UNIT = 10**18 >> 12
def pin(y, q):
    return sum((t * (y - v) if y >= v else (1 - t) * (v - y)) for t, v in zip(LV, q)) / len(LV)
def grid(q):
    o = [round(v * 4096) for v in q]
    for k in range(1, len(o)):
        o[k] = max(o[k], o[k - 1] + 1)
    return o
if d.get("schema") != "vol-replay/v2":
    rnd = random.Random(11)
    d["schema"] = "vol-replay/v2"
    d["params"].update({"quantile_levels": LV, "output_scale_bits": 12})
    last = d["rounds"][-1]
    now = int(time.time()); start = now // 3600 * 3600
    pr = {"id": last["id"] + 1, "start": start, "end": start + 3600, "features_match_mainnet": True,
          "window_utc": [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start)),
                         time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start + 3600))],
          "agents": {n: {"entered": True} for n in last["agents"]}}
    d.update({"live": True, "generated_at": now - 60, "next_run_at": start + 3600 + 420, "pending_round": pr})
    for r in d["rounds"] + [pr]:
        o = r.get("outcome")
        voided = bool(o and o["voided"])
        y = math.log(max(1, (o or {}).get("realized_vol") or r.get("real_realized_vol") or 800))
        r["baseline_quantiles"] = BQ
        bl = pin(y, BQ)
        if o:
            r.update({"ln_rv": None if voided else y, "baseline_loss": None if voided else bl})
        mixes = []
        for n, ra in r["agents"].items():
            for k in ("probs", "probs_e18", "p_win", "log_score", "log_score_float"):
                ra.pop(k, None)
            if ra.get("entered") is False:
                ra.update({"quantiles": None, "outputs": None}); continue
            c = rnd.uniform(5.6, 7.2); w = rnd.uniform(0.7, 1.3)
            outs = grid([c + w * z for z in (-1.75, -0.86, 0, 0.83, 1.55)])
            q = [v / 4096 for v in outs]; mixes.append(q)
            ra.update({"quantiles": q, "quantiles_e18": [str(v * UNIT) for v in outs], "outputs": outs})
            if o and not voided:
                L = pin(y, q)
                ra.update({"pinball_loss": L, "excess": bl - L, "beat_baseline": bl > L,
                           "covered50": q[1] <= y <= q[3], "covered80": q[0] <= y <= q[4]})
            elif o:
                ra.update({"pinball_loss": None, "excess": None, "beat_baseline": False})
        if r.get("fee") and mixes:
            mq = [sum(m[k] for m in mixes) / len(mixes) for k in range(5)]
            for side in ("onchain", "mirror"):
                r["fee"][side].pop("mix_e18", None)
                r["fee"][side]["mix_quantiles_e18"] = [str(int(v * 1e18)) for v in mq]
    pr["agents"][list(pr["agents"])[-1]] = {"entered": False, "skip_reason": "API failed", "quantiles": None}
    s = d["summary"]; settled = [r for r in d["rounds"] if not r["outcome"]["voided"]]
    mean = lambda xs: sum(xs) / len(xs) if xs else None
    s["baseline_mean_pinball_loss"] = mean([r["baseline_loss"] for r in settled])
    s["baseline_coverage50"] = 0.4375; s["baseline_coverage80"] = 0.8125
    for i, (n, a) in enumerate(s["agents"].items()):
        rows = [r["agents"][n] for r in settled if r["agents"][n].get("pinball_loss") is not None]
        a.update({"rounds_scored": len(rows), "mean_pinball_loss": mean([x["pinball_loss"] for x in rows]),
                  "mean_excess": mean([x["excess"] for x in rows]), "total_excess": sum(x["excess"] for x in rows),
                  "coverage50": round(0.31 + 0.07 * i, 4), "coverage80": round(0.61 + 0.05 * i, 4)})
        a.pop("total_log_score", None); a.pop("mean_log_score", None)
if not d.get("pending_round"):
    last = d["rounds"][-1]
    now = int(time.time()); start = now // 3600 * 3600
    ags = {n: {"entered": True, "quantiles": a["quantiles"]} for n, a in last["agents"].items() if a.get("quantiles")}
    ags[list(last["agents"])[-1]] = {"entered": False, "skip_reason": "API failed", "quantiles": None}
    d.update({"live": True, "generated_at": now - 60, "next_run_at": start + 3600 + 420, "pending_round": {
        "id": last["id"] + 1, "start": start, "end": start + 3600, "features_match_mainnet": True, "agents": ags,
        "window_utc": [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start)),
                       time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start + 3600))]}})
json.dump(d, open(out + "/v2.json", "w"))
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp" >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$tmp" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const [base, tmp] = process.argv.slice(2);
const d = JSON.parse(require("fs").readFileSync(`${tmp}/dashboard/v2.json`, "utf8"));
let fail = 0;
const check = (cond, msg) => { console.log((cond ? "ok - " : "not ok - ") + msg); if (!cond) fail = 1; };
const near = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps * Math.max(1, Math.abs(b));

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errs = [];
  page.on("pageerror", (e) => errs.push(e.message));
  const go = async (view, data = "v2.json") => { await page.goto(`${base}/dashboard/?data=${data}#/${view}`); await page.waitForTimeout(700); };

  await go("agents");
  const ex = await page.evaluate(() => {
    const c = document.getElementById("excess-card");
    return c ? { title: c.querySelector("h2").textContent, text: c.textContent } : null;
  });
  check(ex && /pinball excess vs climatology \(ln RV\)/i.test(ex.title), "agents: cumulative excess chart titled 'pinball excess vs climatology (ln RV)'");
  check(ex && !/log score|nats/.test(ex.title), "agents: excess chart no longer in log-score / nats units");
  const ag = Object.keys(d.summary.agents);
  const tbl = await page.evaluate(() => [...document.querySelectorAll("table")].map((t) => t.textContent).find((x) => /平均分位数损失/.test(x)) ?? "");
  check(/平均分位数损失（越低越好）/.test(tbl) && /相对气候基线/.test(tbl) && !/Σ ln p/.test(tbl), "agents table: mean pinball loss and signed excess vs climatology columns, no Σ ln p");
  check(tbl.includes(d.summary.baseline_mean_pinball_loss.toFixed(3)) && /climatology baseline/.test(tbl), "agents table: climatology baseline row with its mean pinball loss");
  const a0 = d.summary.agents[ag[0]];
  check(tbl.includes(a0.mean_pinball_loss.toFixed(3)), `agents table: ${ag[0]} mean pinball loss ${a0.mean_pinball_loss.toFixed(3)} read from the summary`);

  await go("rounds");
  const oc = await page.evaluate(() => {
    const c = document.getElementById("outcome-card");
    return c ? { title: c.querySelector("h2").textContent, text: c.innerText } : null;
  });
  check(oc && /ln RV/.test(oc.title) && /climatology/i.test(oc.title), "rounds: outcome card plots realized ln RV vs climatology");
  check(oc && /50%/.test(oc.text) && /80%/.test(oc.text), "rounds: outcome card shows 50% / 80% interval coverage");
  check(oc && oc.text.includes(`${Math.round(d.summary.baseline_coverage50 * 100)}%`) && oc.text.includes(`${Math.round(d.summary.baseline_coverage80 * 100)}%`),
    "rounds: baseline coverage read from summary.baseline_coverage50/80");
  check(oc && ag.every((n) => oc.text.includes(`${Math.round(d.summary.agents[n].coverage50 * 100)}%`)), "rounds: every agent's 50% coverage shown");
  const winCard = await page.evaluate(() => [...document.querySelectorAll("h2")].some((h) => /Winning buckets/.test(h.textContent)));
  check(!winCard, "rounds: winning-bucket card replaced in v2");
  const r0 = d.rounds.find((r) => !r.outcome.voided);
  const rt = await page.evaluate(() => [...document.querySelectorAll("table.pin-first")].map((t) => t.innerText).join("\n"));
  const e0 = r0.agents[ag[0]].excess;
  check(rt.includes(`ln RV ${r0.ln_rv.toFixed(2)}`) && rt.includes(`${e0 > 0 ? "+" : ""}${e0.toFixed(3)}`), "rounds table: realized ln RV and per-agent excess of round 0");

  await go("live");
  const nc = await page.evaluate(() => [...document.querySelectorAll("#nowcast g[data-agent]")].map((g) => ({
    agent: g.dataset.agent, q: ["q10", "q25", "q50", "q75", "q90"].map((k) => Number(g.dataset[k])),
    bands: g.querySelectorAll("rect.nc-q90, rect.nc-q50").length, med: g.querySelectorAll("line.nc-med").length })));
  const pr = d.pending_round, entered = Object.entries(pr.agents).filter(([, a]) => a.entered);
  check(nc.length === entered.length, `live: one nowcast glyph per entered agent (${nc.length}/${entered.length})`);
  check(nc.length > 0 && nc.every((g) => { const q = pr.agents[g.agent].quantiles; return q && g.q.every((v, i) => near(v, Math.exp(q[i]))); }),
    "live: glyph data-q10..q90 = exp(revealed quantiles)");
  check(nc.every((g) => g.bands === 2 && g.med === 1), "live: glyph = faint 10–90 band, darker 25–75 band, median tick");
  const ncText = await page.evaluate(() => document.getElementById("nowcast")?.innerText ?? "");
  check(/80%/.test(ncText) && !/90% 区间|90% interval/.test(ncText), "live: intervals labelled 80% (10–90), not 90%");
  const pw2 = await page.evaluate(() => document.getElementById("pwin-card")?.querySelector("h2").textContent ?? "");
  check(/pinball excess vs climatology/i.test(pw2), "live: per-round chart shows pinball excess vs climatology");

  await go("overview");
  const cs = await page.evaluate(() => document.getElementById("case1")?.innerText ?? "");
  check(/分位数/.test(cs) && /pinball/.test(cs), "overview: case #1 target = ln RV quantiles scored by pinball loss");

  await go("fee");
  const fee = await page.evaluate(() => document.getElementById("fee-card")?.innerText ?? "");
  check(/hindsight fair fee/.test(fee) && /forecast/.test(fee) && /prev-hour RV/.test(fee), "fee: card kept with short English labels");

  await page.setViewportSize({ width: 390, height: 844 });
  for (const v of ["overview", "live", "rounds", "agents", "fee"]) {
    await go(v);
    const over = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
    check(!over, `390 px #/${v}: no horizontal overflow`);
  }
  await page.setViewportSize({ width: 1280, height: 900 });
  await go("agents", "v1.json");
  const v1 = await page.evaluate(() => ({ err: document.getElementById("error")?.textContent ?? null, h2: document.querySelectorAll("h2").length }));
  check(!v1.err && v1.h2 > 3, `committed sample (${JSON.parse(require("fs").readFileSync(`${tmp}/dashboard/v1.json`, "utf8")).schema}) renders`);
  check(errs.length === 0, `no page errors${errs.length ? ": " + errs.join(" | ") : ""}`);
  await go("agents");
  await page.screenshot({ path: `${tmp}/agents-v2.png`, fullPage: true });
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})();
EOF
status=$?
if [[ -n "${UI_CHECK:-}" ]]; then
  if bash "$UI_CHECK" run . --no-record >/dev/null 2>&1; then echo "ok - ui smoke passes"; else echo "not ok - ui smoke passes"; status=1; fi
else
  echo "SKIP - ui smoke (UI_CHECK unset)"
fi
exit $status
