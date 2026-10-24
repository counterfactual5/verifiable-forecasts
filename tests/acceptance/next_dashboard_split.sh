#!/usr/bin/env bash
# Split acceptance: the default page (no ?data) reads two files. #/live reads live-replay.json (rolling LIVE_HOURS = 24,
# re-forked hourly) and is labelled 实时 · 每小时更新; 概览 / 单轮回放 / 预测者与信誉 / 消费方示例 / 链上记录 read the fixed
# 24 h replay sample-replay.json, so their numbers match the deck, and are labelled 固定回放 · 过去 24 小时主网（生成时间 …）.
# The live file served here is synthetic (20 rounds, a marker total) so each number shows which file it came from.
# The overview carries one "同一协议还能用在哪" card: lending, options / vol vaults, insurance / treasury and a
# Uniswap V4 dynamic-fee hook, each marked 尚未实现, plus the sentence that the contract only implements the
# Uniswap V3 observe() data source, said once. The deploy serves and ships the fixed file and its /vf/ fallback does not
# pin ?data to the live file. DASH_DIR overrides the dashboard directory so the checks can be run against an older index.html.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
dash="${DASH_DIR:-dashboard}"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

grep -qE '^LIVE_HOURS = 24$' demo/fork_round.py && ok "fork_round LIVE_HOURS = 24" || bad "fork_round LIVE_HOURS = 24"
grep -q 'default 24' demo/live.sh && ! grep -q 'default 12' demo/live.sh && ok "live.sh documents 24 hours" || bad "live.sh documents 24 hours"
grep -qE 'sample-replay' deploy/nginx-vf.conf && ! grep -q 'sample-replay' deploy/push.sh \
  && ok "nginx serves sample-replay.json and push.sh does not exclude it" || bad "nginx serves sample-replay.json and push.sh does not exclude it"
! grep -q 'data=live-replay' deploy/nginx-vf.conf && ok "/vf/ fallback does not pin ?data to the live file" || bad "/vf/ fallback does not pin ?data to the live file"

tmp="$root/docs/.local/tmp/dashboard_split"
mkdir -p "$tmp"
python3 - dashboard/sample-replay.json "$tmp" <<'PY'
import json, sys, time
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
now = int(time.time()); start = now // 3600 * 3600
d["rounds"] = d["rounds"][-20:]
d["replay"]["hours"] = 20
v2 = d.get("schema") == "vol-replay/v2"
for s in d["summary"]["agents"].values():
    s["mean_pinball_loss" if v2 else "total_log_score"] = 7.777 if v2 else -77.777
last = d["rounds"][-1]
d.update({"live": True, "generated_at": now - 60, "next_run_at": start + 3600 + 420,
          "pending_round": {"id": last["id"] + 1, "start": start, "end": start + 3600,
                            "window_utc": [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start)),
                                           time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start + 3600))],
                            "features_match_mainnet": True,
                            "agents": {a["agent"]: {"entered": True, **({"quantiles": last["agents"][a["agent"]]["quantiles"]} if v2
                                                                       else {"probs": last["agents"][a["agent"]]["probs"]})} for a in d["agents"]}}})
json.dump(d, open(out + "/live.json", "w"))
PY

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/$dash/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
res=$(NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$dash" "$tmp/live.json" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); process.exit(1); }
const fs = require("fs");
const [base, dash, livePath] = process.argv.slice(2);
const check = (cond, msg) => console.log((cond ? "ok - " : "not ok - ") + msg);
const fixed = JSON.parse(fs.readFileSync("dashboard/sample-replay.json", "utf8"));
const liveBody = fs.readFileSync(livePath, "utf8");
const FIXED_VIEWS = ["overview", "rounds", "agents", "fee", "chain"];
(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const width of [1440, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 900 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(e.message));
    await page.route("**/live-replay.json", (route) => route.fulfill({ status: 200, contentType: "application/json", body: liveBody }));
    await page.goto(`${base}/${dash}/`);
    await page.waitForSelector("#nav .tab", { timeout: 15000 });
    const header = () => page.evaluate(() => [...document.querySelectorAll("header *")].filter((el) => el.getClientRects().length
      && [...el.childNodes].some((c) => c.nodeType === 3 && c.textContent.trim())).map((el) => el.textContent).join(" ").replace(/\s+/g, " "));
    for (const view of FIXED_VIEWS) {
      await page.evaluate((h) => { location.hash = h; }, `#/${view}`);
      await page.waitForTimeout(200);
      const h = await header();
      check(/固定回放/.test(h) && /过去 24 小时主网/.test(h) && /生成时间/.test(h) && !/实时 · 每小时更新/.test(h),
        `@${width} ${view}: header labelled 固定回放 · 过去 24 小时主网（生成时间 …） (${h.slice(0, 160)})`);
    }
    await page.evaluate(() => { location.hash = "#/overview"; });
    await page.waitForTimeout(200);
    const ov = await page.evaluate(() => {
      const t = (el) => el ? el.textContent.replace(/\s+/g, " ").trim() : "";
      const card = document.querySelector("#usecases");
      const items = card ? [...card.querySelectorAll("li")].map(t) : [];
      return { kpi: t(document.querySelector("#summary")), items, card: t(card), visible: !!card?.getClientRects().length,
        body: document.body.innerText.replace(/\s+/g, " "), snap: t(document.querySelector("#case-snap")) };
    });
    const v2 = fixed.schema === "vol-replay/v2";
    const best = v2 ? fixed.summary.baseline_mean_pinball_loss.toFixed(3) : Math.max(...Object.values(fixed.summary.agents).map((a) => a.total_log_score)).toFixed(1);
    check(ov.kpi.includes(best) && !/-77\.8|−77\.8|7\.777/.test(ov.kpi), `@${width}: overview KPIs come from the fixed replay (${best})`);
    check(ov.visible && /同一协议还能用在哪/.test(ov.card), `@${width}: overview shows the 同一协议还能用在哪 card`);
    check(ov.items.length >= 3 && ov.items.length <= 4 && ov.items.every((x) => /尚未实现/.test(x)), `@${width}: 3-4 use cases, each marked 尚未实现 (${ov.items.length})`);
    check([/借贷/, /期权|波动率金库/, /保险|国库/, /V4/].every((re) => ov.items.some((x) => re.test(x))), `@${width}: lending, options / vaults, insurance / treasury, V4 hook listed`);
    check(/observe\(\)/.test(ov.card) && /只实现/.test(ov.card), `@${width}: card keeps that the contract only implements the V3 observe() source`);
    check((ov.body.match(/目前合约只实现/g) ?? []).length === 1, `@${width}: the only-implemented sentence appears once on the overview`);
    check(!/合作|赞助|sponsor|partner/i.test(ov.card) && !/出题|考题|考试/.test(ov.body), `@${width}: no partner claims, no exam wording`);
    await page.evaluate(() => { location.hash = "#/agents"; });
    await page.waitForTimeout(200);
    const ag = await page.evaluate(() => [...document.querySelectorAll("#app tr[data-agent]")].filter((tr) => tr.getClientRects().length).map((tr) => tr.textContent));
    const first = fixed.agents[0].agent;
    const tot = v2 ? fixed.summary.agents[first].mean_pinball_loss.toFixed(3) : fixed.summary.agents[first].total_log_score.toFixed(3);
    check(ag.some((x) => x.includes(tot)) && !ag.some((x) => x.includes("-77.777") || x.includes("7.777")),
      `@${width}: #/agents totals come from the fixed replay`);
    await page.evaluate(() => { location.hash = "#/live"; });
    await page.waitForTimeout(300);
    const lv = await page.evaluate(() => {
      const card = document.getElementById("pwin-card");
      const path = card?.querySelector("svg g.series > path");
      return { nowcast: !!document.querySelector("#nowcast svg")?.getClientRects().length,
        points: path ? (path.getAttribute("d").match(/[ML]/g) ?? []).length : 0,
        head: document.querySelector('.pagehead[data-v="live"]')?.textContent.replace(/\s+/g, " ") ?? "" };
    });
    const h = await header();
    check(/实时 · 每小时更新/.test(h) && !/固定回放/.test(h), `@${width} live: header labelled 实时 · 每小时更新 (${h.slice(0, 160)})`);
    check(lv.nowcast && lv.points === 20, `@${width} live: nowcast and p_win chart read the live file (${lv.points} rounds)`);
    const hours = JSON.parse(liveBody).replay.hours;
    check(new RegExp(`滚动窗口：最近 ${hours} 小时`).test(lv.head) && !/12 小时/.test(lv.head), `@${width} live: page head names the live file's rolling window (${hours} h)`);
    check(errors.length === 0, `@${width}: no page errors ${JSON.stringify(errors.slice(0, 3))}`);
    await page.close();
  }
  await browser.close();
})().catch((e) => { console.log("not ok - " + e); process.exit(1); });
EOF
)
printf '%s\n' "$res"
grep -q '^not ok' <<<"$res" && fail=1
[[ -n "$res" ]] || fail=1
[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
