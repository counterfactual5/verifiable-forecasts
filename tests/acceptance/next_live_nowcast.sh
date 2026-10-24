#!/usr/bin/env bash
# Live nowcast acceptance: a live run also opens a round for the hour in progress (commit + reveal, no
# settlement) and writes it as pending_round; #/live shows it on the first screen, inside #hero:
# past realized vol next to each entered agent's median and 50% / 90% intervals read off its bucket
# probabilities, "待结算 · 分叉模拟" (commit times on the fork are simulated, not real-world ex-ante) with a ticking countdown to the hour's end, when it was updated, a compact row per
# agent (tier, median / interval), plus the shared-operator disclaimer. Each agent's provider, address,
# ERC-8004 agentId and modelHash live once, in the #/agents table.
# A one-hot forecast fixes the interpolated quantiles, so the method is checked, not just drawn.
# Past rounds draw the consensus fan, each agent's median line in its current-hour colour and the realized
# line on an axis labelled up to it (fan details: next_live_fan.sh); the current hour keeps one glyph per
# agent (faint 90% band, 50% band, median tick).
# The overview hides the nowcast and shows the compact case snapshot above its KPIs.
# Per-agent tooltips and the fee share legend rank high to low. Without pending_round the section is absent. No overflow at 390 px,
# no page errors. The browser clock is frozen inside the pending hour; after its end the countdown reads 已结束.
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
         and p["features_match_mainnet"] and entered
         and all(len(a["quantiles" if d["schema"] == "vol-replay/v2" else "probs"]) == 5 for a in entered)
         and (d["schema"] != "vol-replay/v2" or all(b > a for e in entered for a, b in zip(e["quantiles"], e["quantiles"][1:])))
         and d["rounds"][-1]["end"] == p["start"] else 1)
EOF
else
  echo "SKIP - dashboard/live-replay.json without pending_round (run LIVE=1 bash demo/live.sh)"
fi

tmp="$root/docs/.local/tmp/live_nowcast"
mkdir -p "$tmp"
rm -f "$tmp/pending.json"
# The pending window is fixed (the hour after the fixture's last round); the browser clock is frozen relative to it.
python3 - tests/acceptance/fixtures/sample-replay-v1.json "$tmp" <<'PY' || { bad "build the v1 pending_round fixture"; echo FAIL; exit 1; }
import json, sys, time
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
last = d["rounds"][-1]
start = last["end"]
agents = {}
for i, a in enumerate(d["agents"]):
    agents[a["agent"]] = {"entered": True, "probs": last["agents"][a["agent"]]["probs"]}
names = [a["agent"] for a in d["agents"]]
agents[names[0]]["probs"] = [0, 1, 0, 0, 0]
agents[names[-1]] = {"entered": False, "skip_reason": "API failed", "probs": None}
d["agents"][1].update({"provider": "self-hosted inference", "tier": "reproducible", "model_hash": "0x" + "ab" * 32})
d.update({"live": True, "generated_at": start + 540, "next_run_at": start + 3600 + 420,
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
  const pr = d.pending_round, inWindow = pr.start + 1200;
  for (const width of [1440, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    await page.clock.install({ time: inWindow * 1000 });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.goto(`${base}/dashboard/?data=../docs/.local/tmp/live_nowcast/pending.json#/live`);
    await page.waitForSelector("#nowcast svg", { timeout: 15000 });
    const read = () => page.evaluate(() => {
      // A forecast glyph: faint 90% band, 50% band inside it, horizontal median tick inside the 50% band.
      const glyph = (g) => {
        const box = (r) => r && { x: +r.getAttribute("x"), y: +r.getAttribute("y"), w: +r.getAttribute("width"), h: +r.getAttribute("height"),
          fill: r.getAttribute("fill"), op: +r.getAttribute("opacity") };
        const q90 = box(g.querySelector("rect.nc-q90")), q50 = box(g.querySelector("rect.nc-q50")), t = g.querySelector("line.nc-med");
        const tick = t && { x1: +t.getAttribute("x1"), x2: +t.getAttribute("x2"), y1: +t.getAttribute("y1"), y2: +t.getAttribute("y2"), stroke: t.getAttribute("stroke") };
        const ok = !!(q90 && q50 && tick && !g.querySelector("circle") && q90.fill === q50.fill && q50.fill === tick.stroke && q90.op < q50.op
          && q90.y <= q50.y + 0.11 && q90.y + q90.h >= q50.y + q50.h - 0.11 && tick.y1 === tick.y2 && tick.y1 >= q50.y - 0.11 && tick.y1 <= q50.y + q50.h + 0.11
          && tick.x2 - tick.x1 > q50.w && Math.abs((tick.x1 + tick.x2) / 2 - (q50.x + q50.w / 2)) < 0.11 && q90.x === q50.x && q90.w === q50.w);
        return { ok, fill: q50?.fill, cx: tick && (tick.x1 + tick.x2) / 2, w: q50?.w, op: q90 && q50 && [q90.op, q50.op] };
      };
      const el = document.querySelector("#nowcast");
      if (!el) return null;
      const svg = el.querySelector("svg[role=img]");
      return { inHero: !!el.closest("#hero") && !el.closest("#app"), top: el.getBoundingClientRect().top + scrollY,
        text: el.textContent.replace(/\s+/g, " "), label: svg?.getAttribute("aria-label") ?? "",
        bands: [...el.querySelectorAll("svg g[data-agent]")].map((g) => ({ agent: g.dataset.agent, q: ["q05", "q25", "q50", "q75", "q95"].map((k) => Number(g.dataset[k])) })),
        cd: document.querySelector("#nowcast-cd")?.textContent ?? "",
        compact: [...el.querySelectorAll("tr[data-agent]")].map((tr) => ({ agent: tr.dataset.agent, cells: tr.cells.length, text: tr.textContent.replace(/\s+/g, " ") })),
        lines: [...el.querySelectorAll("svg [data-agent-line]")].map((p) => ({ agent: p.dataset.agentLine, stroke: p.getAttribute("stroke"), pts: (p.getAttribute("d").match(/[ML]/g) || []).length })),
        fan: !!el.querySelector("svg [data-fan] .nc-band-wide") && !!el.querySelector("svg [data-fan] .nc-cmed"), dots: el.querySelectorAll("svg circle").length,
        now: [...el.querySelectorAll("svg g[data-agent]")].map((g) => ({ agent: g.dataset.agent, ...glyph(g) })),
        ticks: [...el.querySelectorAll("svg text.ax")].map((t) => Number(t.textContent)).filter((v) => Number.isFinite(v) && v > 0),
        overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
    });
    const r = await read();
    check(r && r.inHero, `@${width}: #nowcast is in #hero, outside #app`);
    if (!r) { await page.close(); continue; }
    if (width === 1440) check(r.top < 900, `@${width}: #nowcast starts on the first screen (top ${Math.round(r.top)}px)`);
    check(/实时预测/.test(r.text) && /待结算/.test(r.text), `@${width}: titled 实时预测 and marked 待结算`);
    check(/运行于服务器，每小时自动更新/.test(r.text) && /上次更新/.test(r.text), `@${width}: last update and "运行于服务器，每小时自动更新"`);
    check(/待结算 · 分叉模拟/.test(r.text) && /不证明现实中的事前性/.test(r.text) && !/已在链上提交/.test(r.text),
      `@${width}: pending hour marked 分叉模拟, says the fork commit does not prove real-world ex-ante`);
    check(r.text.includes("演示中所有 agent 由同一台服务器代为提交；真实网络中各提供方用自己的私钥独立提交（模型注册需 owner 批准）。"), `@${width}: shared-operator disclaimer`);
    check(r.label.length > 20, `@${width}: chart is a named image`);
    check(JSON.stringify(r.bands.map((x) => x.agent).sort()) === JSON.stringify(entered.slice().sort()), `@${width}: one interval per entered agent (${r.bands.length}/${entered.length})`);
    check(r.bands.every((x) => x.q.every((v, i) => Number.isFinite(v) && v > 0 && (i === 0 || v >= x.q[i - 1]))), `@${width}: quantiles finite and ordered`);
    const one = r.bands.find((x) => x.agent === Object.keys(d.pending_round.agents)[0]);
    const near = (v, w) => Math.abs(v - w) / w < 1e-6;
    check(one && near(one.q[2], Math.sqrt(b[0] * b[1])) && near(one.q[1], b[0] * (b[1] / b[0]) ** 0.25) && near(one.q[4], b[0] * (b[1] / b[0]) ** 0.95),
      `@${width}: one-hot bucket #1 -> log-linear quantiles inside [${b[0]}, ${b[1]}] (${one && one.q.map((v) => v.toFixed(1))})`);
    const shown = d.rounds.slice(-24).filter((x) => (x.outcome?.realized_vol ?? x.real_realized_vol) != null);
    const want = d.agents.filter((a) => shown.some((x) => x.agents[a.agent]?.probs && x.agents[a.agent].entered !== false)).map((a) => a.agent);
    check(r.fan && r.dots === shown.length && want.length > 0 && JSON.stringify(r.lines.map((l) => l.agent).sort()) === JSON.stringify(want.slice().sort()),
      `@${width}: past hours: consensus fan, ${shown.length} realized points, one median line per agent (${r.lines.length}/${want.length})`);
    const nowFill = Object.fromEntries(r.now.map((g) => [g.agent, g.fill]));
    check(r.now.length > 0 && r.now.every((g) => g.ok),
      `@${width}: current-hour forecasts: faint 90% band, 50% band, median tick (now ${r.now.filter((g) => g.ok).length}/${r.now.length})`);
    check(r.lines.every((l) => l.pts >= 2 && (!nowFill[l.agent] || l.stroke === nowFill[l.agent])),
      `@${width}: past median lines carry the agent's current-hour colour`);
    check(/预测中位数/.test(r.text) && /90% 区间/.test(r.text) && /50% 区间/.test(r.text) && /median/i.test(r.text) && /90% interval/.test(r.text)
      && /真实 RV/.test(r.text) && !/小点|dots/i.test(r.text), `@${width}: caption describes the one glyph (90% / 50% bands, median tick) vs the realized line`);
    const maxRv = Math.max(...shown.map((x) => x.outcome?.realized_vol ?? x.real_realized_vol));
    check(Math.max(...r.ticks) * 2 >= maxRv, `@${width}: y axis is labelled up to the realized line (top tick ${Math.max(...r.ticks)}, max RV ${maxRv})`);
    check(/\d+:\d\d/.test(r.cd), `@${width}: countdown shown (${r.cd})`);
    const left = (/^(\d+):(\d\d)$/.exec(r.cd) || []).slice(1).map(Number);
    const lag = pr.end - inWindow - (left[0] * 60 + left[1]);
    check(left.length === 2 && lag >= 0 && lag < 60, `@${width}: countdown counts to pending_round.end (${r.cd}, ${lag}s after the frozen clock)`);
    await page.waitForTimeout(1300);
    const cd2 = await page.evaluate(() => document.querySelector("#nowcast-cd")?.textContent ?? "");
    check(cd2 !== r.cd, `@${width}: countdown ticks (${r.cd} -> ${cd2})`);
    check(r.compact.length === d.agents.length && r.compact.every((x) => x.cells === 3 && /zk 证明|可复现|仅提交/.test(x.text)
      && (entered.includes(x.agent) ? /50% .*90% /.test(x.text) : /本轮未参赛/.test(x.text))),
      `@${width}: compact live table: one row per agent with tier and median / interval only (${r.compact.map((x) => x.cells)})`);
    await page.evaluate(() => { location.hash = "#/agents"; });
    await page.waitForTimeout(300);
    const rows = await page.evaluate(() => [...document.querySelectorAll("#app tr[data-provider]")].filter((tr) => tr.getClientRects().length)
      .map((tr) => ({ agent: tr.dataset.agent, provider: tr.dataset.provider,
        text: (tr.textContent + " " + (document.querySelector(`tr[data-detail-for="${tr.dataset.agent}"]`)?.textContent ?? "")).replace(/\s+/g, " ") })));
    check(rows.length === d.agents.length, `@${width}: #/agents: one provider row per agent (${rows.length}/${d.agents.length})`);
    const ok = d.agents.every((a) => {
      const row = rows.find((x) => x.agent === a.agent);
      const prov = a.provider === "self-hosted inference" ? "自部署推理服务"
        : a.provider === "self-built zk" || (!a.provider && (a.tier ?? "zk") === "zk") ? "自建 zk" : null;
      return row && (!prov || row.provider === prov) && row.text.includes(String(a.agent_id)) && row.text.includes(a.address.slice(0, 6))
        && (!a.model_hash || /^0x0*$/.test(a.model_hash) || row.text.includes(a.model_hash.slice(0, 6)));
    });
    check(ok, `@${width}: #/agents provider rows (with their detail row) carry provider, address, agentId, modelHash`);
    await page.evaluate(() => { location.hash = "#/overview"; });
    await page.waitForTimeout(300);
    const ov = await page.evaluate(() => {
      const top = (sel) => { const e = document.querySelector(sel); return e && e.getClientRects().length ? e.getBoundingClientRect().top + scrollY : null; };
      return { nc: !!document.querySelector("#nowcast")?.getClientRects().length, snap: top("#case-snap"), kpi: top("#summary") };
    });
    check(!ov.nc && ov.snap != null && ov.kpi != null && ov.snap < ov.kpi, `@${width}: overview hides the nowcast; the case snapshot sits above the KPI strip (${JSON.stringify(ov)})`);
    check(r.overflow <= 0, `@${width}: no horizontal overflow (${r.overflow}px)`);
    check(errors.length === 0, `@${width}: no page errors ${JSON.stringify(errors)}`);
    await page.close();
  }
  const late = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  await late.clock.install({ time: (pr.end + 60) * 1000 });
  await late.goto(`${base}/dashboard/?data=../docs/.local/tmp/live_nowcast/pending.json#/live`);
  await late.waitForSelector("#nowcast svg", { timeout: 15000 });
  const cdEnd = () => late.evaluate(() => document.querySelector("#nowcast-cd")?.textContent ?? "");
  const end1 = await cdEnd();
  await late.waitForTimeout(1300);
  const end2 = await cdEnd();
  check(end1 === "已结束，待下一次运行结算" && end2 === end1, `after pending_round.end: countdown replaced by 已结束 and stays (${end1} -> ${end2})`);
  await late.close();
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
  const fd = JSON.parse(fs.readFileSync("dashboard/sample-replay.json", "utf8"));
  const finals = Object.fromEntries(fd.agents.map((a) => [a.agent, fd.rounds.reduce((s, x) => s + Number(x.agents[a.agent]?.predictor_reward_wei ?? 0), 0)]));
  const order = legend.map((t) => t.trim());
  check(order.length === fd.agents.length && order.every((n, i) => i === 0 || finals[n] <= finals[order[i - 1]]), `fee share legend sorted by final value (${order})`);
  const cap = await page.locator("section.card", { hasText: "Cumulative predictor fee share" }).textContent();
  check(/按至今累计超额分，输的轮会扣掉累计。/.test(cap) && /losing rounds subtract from it/i.test(cap) && !/不扣分|losses cost nothing/.test(cap),
    "fee share caption explains the cumulative-excess rule: losing rounds subtract");
  check(/来自押注池：每轮抽 1%；回放中由 2 个脚本账户用分叉链测试资金下注/.test(cap), "fee share caption names the source: 1% of the betting pool, two scripted fork-funded bettors");
  check(/预测者分到的手续费/.test(cap), "fee share title unchanged");
  await browser.close();
})().catch((e) => { console.log("not ok - " + e); process.exit(1); });
EOF
)
printf '%s\n' "$res"
grep -q '^not ok' <<<"$res" && fail=1
[[ -n "$res" ]] || fail=1
[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
