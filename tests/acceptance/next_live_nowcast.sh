#!/usr/bin/env bash
# Live nowcast acceptance: a live run also opens a round for the hour in progress (commit + reveal, no
# settlement) and writes it as pending_round; the dashboard shows it on the first screen, inside #hero:
# past realized vol next to each entered agent's median and 50% / 90% intervals read off its bucket
# probabilities, "待结算" with a ticking countdown to the hour's end, when it was updated, and per agent
# its provider, address, ERC-8004 agentId, tier and modelHash, plus the shared-operator disclaimer.
# A one-hot forecast fixes the interpolated quantiles, so the method is checked, not just drawn.
# Past rounds carry each agent's forecast median / intervals next to the realized line, on an axis
# labelled up to it, and the nowcast sits above the overview KPIs. With more than 8 past hours the
# wide chart drops the 90% whiskers and the narrow one stacks each hour's medians on the hour.
# Per-agent tooltips and the fee share legend rank high to low. Without pending_round the section is absent. No overflow at 390 px,
# no page errors.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

grep -q '"pending_round"' demo/fork_round.py && ok "fork_round writes pending_round" || bad "fork_round writes pending_round"
if [[ -f dashboard/live-replay.json ]] && python3 -c 'import json,sys; sys.exit(0 if "pending_round" in json.load(open("dashboard/live-replay.json")) else 1)'; then
  python3 - <<'EOF' && ok "live-replay.json pending_round: the hour after the replay, revealed, unsettled" || bad "live-replay.json pending_round: the hour after the replay, revealed, unsettled"
import json, sys
d = json.load(open("dashboard/live-replay.json"))
p = d["pending_round"]
entered = [a for a in p["agents"].values() if a.get("entered")]
sys.exit(0 if p["start"] == d["replay"]["end"] and p["end"] == p["start"] + 3600 and "outcome" not in p
         and p["features_match_mainnet"] and entered and all(len(a["probs"]) == 5 for a in entered)
         and d["rounds"][-1]["end"] == p["start"] else 1)
EOF
else
  echo "SKIP - dashboard/live-replay.json without pending_round (run LIVE=1 bash demo/live.sh)"
fi

tmp="$root/docs/.local/tmp/live_nowcast"
mkdir -p "$tmp"
python3 - dashboard/sample-replay.json "$tmp" <<'PY'
import json, sys, time
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
now = int(time.time())
last = d["rounds"][-1]
start = now // 3600 * 3600
agents = {}
for i, a in enumerate(d["agents"]):
    agents[a["agent"]] = {"entered": True, "probs": last["agents"][a["agent"]]["probs"]}
names = [a["agent"] for a in d["agents"]]
agents[names[0]]["probs"] = [0, 1, 0, 0, 0]
agents[names[-1]] = {"entered": False, "skip_reason": "API failed", "probs": None}
d["agents"][1].update({"provider": "self-hosted inference", "tier": "reproducible", "model_hash": "0x" + "ab" * 32})
d.update({"live": True, "generated_at": now - 60, "next_run_at": start + 3600 + 420,
          "pending_round": {"id": last["id"] + 1, "start": start, "end": start + 3600,
                            "window_utc": [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start)),
                                           time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start + 3600))],
                            "features_match_mainnet": True, "agents": agents}})
json.dump(d, open(out + "/pending.json", "w"))
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
res=$(NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); process.exit(1); }
const base = process.argv[2];
const check = (cond, msg) => console.log((cond ? "ok - " : "not ok - ") + msg);
const fs = require("fs");
(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const d = JSON.parse(fs.readFileSync("docs/.local/tmp/live_nowcast/pending.json", "utf8"));
  const b = d.params.bounds, entered = Object.entries(d.pending_round.agents).filter(([, a]) => a.entered).map(([n]) => n);
  for (const width of [1440, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(`${base}/dashboard/?data=../docs/.local/tmp/live_nowcast/pending.json`);
    await page.waitForSelector("#app svg", { timeout: 15000 });
    const read = () => page.evaluate(() => {
      const el = document.querySelector("#nowcast");
      if (!el) return null;
      const svg = el.querySelector("svg[role=img]");
      return { inHero: !!el.closest("#hero") && !el.closest("#app"), top: el.getBoundingClientRect().top + scrollY,
        text: el.textContent.replace(/\s+/g, " "), label: svg?.getAttribute("aria-label") ?? "",
        bands: [...el.querySelectorAll("svg g[data-agent]")].map((g) => ({ agent: g.dataset.agent, q: ["q05", "q25", "q50", "q75", "q95"].map((k) => Number(g.dataset[k])) })),
        cd: document.querySelector("#nowcast-cd")?.textContent ?? "",
        rows: [...el.querySelectorAll("tr[data-provider]")].map((tr) => ({ agent: tr.dataset.agent, provider: tr.dataset.provider, text: tr.textContent.replace(/\s+/g, " ") })),
        past: [...el.querySelectorAll("svg g.nc-past")].map((g) => ({ agent: g.dataset.forecaster, round: g.dataset.round, q50: Number(g.dataset.q50),
          fill: g.querySelector("circle")?.getAttribute("fill"), cx: g.querySelector("circle")?.getAttribute("cx"),
          bar: !!g.querySelector("rect"), whisker: !!g.querySelector("line") })),
        bandFill: Object.fromEntries([...el.querySelectorAll("svg g[data-agent]")].map((g) => [g.dataset.agent, g.querySelector("rect")?.getAttribute("fill")])),
        ticks: [...el.querySelectorAll("svg text.ax")].map((t) => Number(t.textContent)).filter((v) => Number.isFinite(v) && v > 0),
        summaryTop: (() => { const s = document.querySelector("#summary"); return s && s.offsetParent ? s.getBoundingClientRect().top + scrollY : null; })(),
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
    });
    const r = await read();
    check(r && r.inHero, `@${width}: #nowcast is in #hero, outside #app`);
    if (!r) { await page.close(); continue; }
    if (width === 1440) check(r.top < 900, `@${width}: #nowcast starts on the first screen (top ${Math.round(r.top)}px)`);
    check(/实时预测/.test(r.text) && /待结算/.test(r.text), `@${width}: titled 实时预测 and marked 待结算`);
    check(/运行于服务器，每小时自动更新/.test(r.text) && /上次更新/.test(r.text), `@${width}: last update and "运行于服务器，每小时自动更新"`);
    check(r.text.includes("演示中所有 agent 由同一台服务器代为提交；真实网络中各提供方用自己的私钥独立提交（无许可）。"), `@${width}: shared-operator disclaimer`);
    check(r.label.length > 20, `@${width}: chart is a named image`);
    check(JSON.stringify(r.bands.map((x) => x.agent).sort()) === JSON.stringify(entered.slice().sort()), `@${width}: one interval per entered agent (${r.bands.length}/${entered.length})`);
    check(r.bands.every((x) => x.q.every((v, i) => Number.isFinite(v) && v > 0 && (i === 0 || v >= x.q[i - 1]))), `@${width}: quantiles finite and ordered`);
    const one = r.bands.find((x) => x.agent === Object.keys(d.pending_round.agents)[0]);
    const near = (v, w) => Math.abs(v - w) / w < 1e-6;
    check(one && near(one.q[2], Math.sqrt(b[0] * b[1])) && near(one.q[1], b[0] * (b[1] / b[0]) ** 0.25) && near(one.q[4], b[0] * (b[1] / b[0]) ** 0.95),
      `@${width}: one-hot bucket #1 -> log-linear quantiles inside [${b[0]}, ${b[1]}] (${one && one.q.map((v) => v.toFixed(1))})`);
    const shown = d.rounds.slice(-24).filter((x) => (x.outcome?.realized_vol ?? x.real_realized_vol) != null);
    const want = shown.flatMap((x) => d.agents.filter((a) => x.agents[a.agent]?.probs && x.agents[a.agent].entered !== false).map((a) => `${x.id}/${a.agent}`));
    const got = r.past.map((m) => `${m.round}/${m.agent}`);
    check(want.length > 0 && JSON.stringify(got.slice().sort()) === JSON.stringify(want.slice().sort()),
      `@${width}: past rounds show one forecast marker per agent per settled round (${got.length}/${want.length})`);
    if (shown.length > 8) {
      const byRound = Object.values(r.past.reduce((o, m) => ((o[m.round] ??= new Set()).add(m.cx), o), {}));
      check(width < 600 ? byRound.every((x) => x.size === 1) && r.past.every((m) => !m.bar && !m.whisker)
        : r.past.every((m) => m.bar && !m.whisker),
        `@${width}: ${shown.length} past hours stay readable: ${width < 600 ? "medians stacked on the hour, no bars" : "50% bars, no 90% whiskers"}`);
    }
    check(r.past.every((m) => Number.isFinite(m.q50) && m.q50 > 0 && (!r.bandFill[m.agent] || m.fill === r.bandFill[m.agent])),
      `@${width}: past markers carry the agent's pending-bar colour and a finite median`);
    check(/预测中位数/.test(r.text) && /median/i.test(r.text) && /真实 RV/.test(r.text), `@${width}: legend explains forecast markers vs realized line`);
    const maxRv = Math.max(...shown.map((x) => x.outcome?.realized_vol ?? x.real_realized_vol));
    check(Math.max(...r.ticks) * 2 >= maxRv, `@${width}: y axis is labelled up to the realized line (top tick ${Math.max(...r.ticks)}, max RV ${maxRv})`);
    check(r.summaryTop != null && r.top < r.summaryTop, `@${width}: on the overview the nowcast sits above the KPI strip`);
    check(/\d+:\d\d/.test(r.cd), `@${width}: countdown shown (${r.cd})`);
    await page.waitForTimeout(1300);
    const cd2 = await page.evaluate(() => document.querySelector("#nowcast-cd")?.textContent ?? "");
    check(cd2 !== r.cd, `@${width}: countdown ticks (${r.cd} -> ${cd2})`);
    check(r.rows.length === d.agents.length, `@${width}: one provider row per agent (${r.rows.length}/${d.agents.length})`);
    const ok = d.agents.every((a) => {
      const row = r.rows.find((x) => x.agent === a.agent);
      const prov = a.provider === "self-hosted inference" ? "自部署推理服务"
        : a.provider === "self-built zk" || (!a.provider && (a.tier ?? "zk") === "zk") ? "自建 zk" : null;
      return row && (!prov || row.provider === prov) && row.text.includes(String(a.agent_id)) && row.text.includes(a.address.slice(0, 6))
        && (!a.model_hash || /^0x0*$/.test(a.model_hash) || row.text.includes(a.model_hash.slice(0, 6)));
    });
    check(ok, `@${width}: provider rows carry provider, address, agentId, modelHash`);
    check(r.overflow <= 0, `@${width}: no horizontal overflow (${r.overflow}px)`);
    check(errors.length === 0, `@${width}: no page errors ${JSON.stringify(errors)}`);
    await page.close();
  }
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await page.goto(`${base}/dashboard/?data=sample-replay.json`);
  await page.waitForSelector("#app svg", { timeout: 15000 });
  check(!(await page.$("#nowcast")), "no pending_round: no nowcast section");
  await page.goto(`${base}/dashboard/?data=sample-replay.json#/fee`);
  const chart = page.locator("section.card", { hasText: "Cumulative predictor fee share" }).locator(".chart svg");
  await chart.waitFor({ timeout: 15000 });
  await chart.scrollIntoViewIfNeeded();
  const box = await chart.boundingBox();
  await page.mouse.move(box.x + box.width * 0.98, box.y + box.height / 2);
  await page.waitForTimeout(200);
  const tipVals = await page.evaluate(() => [...document.querySelectorAll(".chart.hover .tip .r b")].map((b) => Number(b.textContent)));
  check(tipVals.length > 1 && tipVals.every((v, i) => i === 0 || v <= tipVals[i - 1]), `fee share tooltip sorted high to low (${tipVals})`);
  const legend = await page.locator("section.card", { hasText: "Cumulative predictor fee share" }).locator(".chart + .sub .nowrap").allTextContents();
  const finals = Object.fromEntries(d.agents.map((a) => [a.agent, d.rounds.reduce((s, x) => s + Number(x.agents[a.agent]?.predictor_reward_wei ?? 0), 0)]));
  const order = legend.map((t) => t.trim());
  check(order.length === d.agents.length && order.every((n, i) => i === 0 || finals[n] <= finals[order[i - 1]]), `fee share legend sorted by final value (${order})`);
  const cap = await page.locator("section.card", { hasText: "Cumulative predictor fee share" }).textContent();
  check(/不扣分/.test(cap) && /not the same as/i.test(cap), "fee share caption explains losses cost nothing, unlike the average score");
  await browser.close();
})().catch((e) => { console.log("not ok - " + e); process.exit(1); });
EOF
)
printf '%s\n' "$res"
grep -q '^not ok' <<<"$res" && fail=1
[[ -n "$res" ]] || fail=1
[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
