#!/usr/bin/env bash
# Protocol-first acceptance: the header names the protocol, Uniswap appears on the overview only inside the
# labelled case #1 card (target, settlement data source, Chainlink void rule, example agents), the overview
# carries a compact case snapshot instead of the full nowcast chart, and no chart, KPI strip or agent table is
# rendered on two views. The exam wording (出题 / 考题 / 考试) never appears. Six tabs keep keys 1-6. The #/agents
# cumulative-score chart draws every agent line alike and its caption gives per-tier counts without singling out an agent.
# DASH_DIR overrides the dashboard directory (served next to dashboard/ data) so the checks can be run
# against an older index.html to prove they fail.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
dash="${DASH_DIR:-dashboard}"
tmp="$root/docs/.local/tmp/dashboard_protocol"
mkdir -p "$tmp"
python3 - dashboard/sample-replay.json "$tmp" <<'PY'
import json, sys, time
src, out = sys.argv[1], sys.argv[2]
d = json.load(open(src))
now = int(time.time()); start = now // 3600 * 3600; last = d["rounds"][-1]
d.update({"live": True, "generated_at": now - 60, "next_run_at": start + 3600 + 420,
          "pending_round": {"id": last["id"] + 1, "start": start, "end": start + 3600,
                            "window_utc": [time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start)),
                                           time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start + 3600))],
                            "features_match_mainnet": True,
                            "agents": {a["agent"]: {"entered": True, "quantiles": last["agents"][a["agent"]]["quantiles"],
                                                    "quantiles_e18": last["agents"][a["agent"]]["quantiles_e18"]} for a in d["agents"]}}})
json.dump(d, open(out + "/pending.json", "w"))
PY
[[ $? -eq 0 ]] || { echo "not ok - pending.json fixture written"; echo FAIL; exit 1; }

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/$dash/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
res=$(NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$dash" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); process.exit(1); }
const [base, dash] = process.argv.slice(2);
const check = (cond, msg) => console.log((cond ? "ok - " : "not ok - ") + msg);
const VIEWS = ["overview", "live", "rounds", "agents", "fee", "chain"];
(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const data of ["/docs/.local/tmp/dashboard_protocol/pending.json", "/dashboard/sample-replay.json"]) {
    const tag = data.includes("pending") ? "pending" : "sample";
    for (const width of [1440, 390]) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message));
      page.on("console", (m) => m.type() === "error" && errors.push(m.text()));
      await page.goto(`${base}/${dash}/?data=${data}`);
      await page.waitForSelector("#nav .tab", { timeout: 15000 });
      const seen = {};
      for (const [i, view] of VIEWS.entries()) {
        await page.keyboard.press(String(i + 1));
        await page.waitForTimeout(150);
        const r = await page.evaluate(() => {
          const vis = (el) => el.getClientRects().length > 0 && el.getBoundingClientRect().width > 0;
          const t = (el) => el.textContent.replace(/\s+/g, " ").trim();
          const items = [...document.querySelectorAll("svg[role=img], canvas")].filter(vis)
            .map((el) => `${el.tagName}:${(el.getAttribute("aria-label") ?? "").replace(/[\d.,:#–-]+/g, "#").slice(0, 60)}`);
          if ([...document.querySelectorAll("#summary")].some(vis)) items.push("KPI strip");
          [...document.querySelectorAll("table")].filter(vis).forEach((tb) => {
            if ([...tb.querySelectorAll("tr[data-agent]")].length) items.push(`agent table:${t(tb.querySelector("tr"))}`);
          });
          const ncChart = document.querySelector("#nowcast svg[role=img]");
          return { view: document.body.dataset.view, items, nowcastShown: !!ncChart && vis(ncChart), text: t(document.body),
            overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth,
            uniswapOutsideCase: document.body.dataset.view === "overview"
              && [...document.querySelectorAll("#hero, header")].some((el) => [...el.querySelectorAll("*")].some((n) => vis(n) && !n.closest("#case1")
                && [...n.childNodes].some((c) => c.nodeType === 3 && /uniswap/i.test(c.textContent)))) };
        });
        check(r.view === view, `${tag}@${width}: key ${i + 1} opens ${view}`);
        for (const it of r.items) (seen[it] ??= []).push(view);
        check(!/出题|考题|考试/.test(r.text), `${tag}@${width} ${view}: no exam wording`);
        check(r.overflow <= 0, `${tag}@${width} ${view}: no horizontal overflow (${r.overflow}px)`);
        if (view === "overview") {
          check(!r.nowcastShown, `${tag}@${width}: the full nowcast chart is not on the overview`);
          check(!r.uniswapOutsideCase, `${tag}@${width}: on the overview Uniswap is named only inside the case #1 card`);
        }
        if (view === "live" && tag === "pending") check(r.nowcastShown, `${tag}@${width}: the nowcast chart is on #/live`);
      }
      const dup = Object.entries(seen).filter(([, v]) => v.length > 1);
      check(dup.length === 0, `${tag}@${width}: no chart, KPI strip or agent table on two views ${JSON.stringify(dup.slice(0, 3))}`);
      await page.keyboard.press("1");
      await page.waitForTimeout(150);
      const o = await page.evaluate(() => {
        const t = (el) => el ? el.textContent.replace(/\s+/g, " ").trim() : "";
        const c = document.querySelector("#case1"), s = document.querySelector("#case-snap"), k = document.querySelector("#summary");
        return { h1: t(document.querySelector("h1")), claim: t(document.querySelector(".claim")), tabs: [...document.querySelectorAll("#nav .tab")].length,
          caseText: t(c), snap: t(s), snapLink: s?.querySelector("a.goto")?.getAttribute("href") ?? null,
          snapTop: s ? s.getBoundingClientRect().top + scrollY : null, kpiTop: k && k.offsetParent ? k.getBoundingClientRect().top + scrollY : null,
          cd: s?.querySelector(".cd")?.textContent ?? "" };
      });
      check(/协议/.test(o.h1) && /协议/.test(o.claim) && !/uniswap/i.test(o.h1), `${tag}@${width}: header and claim name the protocol (${o.h1})`);
      check(o.tabs === 6, `${tag}@${width}: six tabs (${o.tabs})`);
      check(/案例 #1/.test(o.caseText) && /预测目标/.test(o.caseText) && /observe\(\)/.test(o.caseText) && /Chainlink/.test(o.caseText)
        && /2%/.test(o.caseText) && /作废退款/.test(o.caseText) && /6 个示例 agent/.test(o.caseText), `${tag}@${width}: case #1 card lists target, observe(), Chainlink 2% void rule, 6 example agents`);
      check(o.snapTop != null && o.kpiTop != null && o.snapTop < o.kpiTop && (width > 600 ? o.snapTop < 900 : true), `${tag}@${width}: case snapshot sits above the KPI strip on the first screen`);
      if (tag === "pending") check(/待结算/.test(o.snap) && /6\/6/.test(o.snap) && /中位数/.test(o.snap) && /\d+:\d\d/.test(o.cd) && o.snapLink === "#/live",
        `${tag}@${width}: snapshot shows the hour, countdown, 6/6 submitted, consensus median and links to #/live (${o.snap.slice(0, 120)})`);
      else check(/最近一轮/.test(o.snap) && o.snapLink === "#/rounds", `${tag}@${width}: without a pending round the snapshot shows the last round and links to #/rounds`);
      await page.keyboard.press("4");
      await page.waitForTimeout(150);
      const x = await page.evaluate(async (url) => {
        const d = await (await fetch(url)).json(), s = d.summary;
        const tierOf = (a) => a.tier ?? (a.model_type === "zk" ? "zk" : "commit-only");
        const want = [["zk", "zk 档"], ["reproducible", "可复现档"], ["commit-only", "仅提交档"]].map(([k, zh]) => {
          const pool = d.agents.filter((a) => tierOf(a) === k);
          return pool.length ? `${zh} ${pool.filter((a) => s.agents[a.agent].total_excess > 0).length}/${pool.length} 累计跑赢气候基线` : null;
        }).filter(Boolean);
        const c = document.querySelector("#excess-card"), tk = c?.querySelector(".takeaway")?.cloneNode(true);
        tk?.querySelectorAll(".badge").forEach((b) => b.remove());
        const paths = [...(c?.querySelectorAll("svg .series path") ?? [])];
        return { cap: tk ? tk.textContent.replace(/\s+/g, " ").trim() : "", want, names: d.agents.map((a) => a.agent),
          n: paths.length, widths: [...new Set(paths.map((p) => p.getAttribute("stroke-width")))],
          fills: paths.filter((p) => p.getAttribute("fill") !== "none").length, faded: paths.filter((p) => p.hasAttribute("opacity")).length };
      }, data);
      check(x.n > 0 && x.widths.length === 1 && x.fills === 0 && x.faded === 0,
        `${tag}@${width}: cumulative-score chart draws every agent line alike (widths ${x.widths}, fills ${x.fills}, faded ${x.faded})`);
      check(!/粗线|最佳|best/i.test(x.cap) && !x.names.some((nm) => x.cap.includes(nm)) && x.want.every((w) => x.cap.includes(w)),
        `${tag}@${width}: cumulative-score caption gives per-tier counts ${x.want.join(" · ")} and singles out no agent (${x.cap})`);
      check(errors.length === 0, `${tag}@${width}: no console or page errors ${JSON.stringify(errors.slice(0, 3))}`);
      await page.close();
    }
  }
  await browser.close();
})().catch((e) => { console.log("not ok - " + e); process.exit(1); });
EOF
)
printf '%s\n' "$res"
fail=0
grep -q '^not ok' <<<"$res" && fail=1
[[ -n "$res" ]] || fail=1
[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
