#!/usr/bin/env bash
# Agent table acceptance: #/agents shows one compact row per agent (Agent + tier badge + compact verification
# status, 平均分位数损失, signed excess vs climatology, 跑赢基线 x/N, 分到手续费) with no "Scored" column, a
# data-driven note "共 N 轮，全部 agent 每轮都参与" (or an "n/N 轮" badge next to an agent that missed rounds),
# the baseline row, and a collapsed-by-default detail row per agent (▸) holding the verification details and
# ERC-8004 agentId / getSummary ("条记录 × 平均分") / tags. Checked on v2 sample-replay (and live-replay when
# present), a variant with one agent missing a round, and the v1 fixture; no overflow at 375 / 390 / 1440.
# DASHBOARD_HTML overrides the page under test.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
tmp="$root/.local/tmp/agent_table"
rm -rf "$tmp" && mkdir -p "$tmp/dashboard"
cp "${DASHBOARD_HTML:-dashboard/index.html}" "$tmp/dashboard/index.html"
cp dashboard/sample-replay.json "$tmp/dashboard/v2.json"
cp tests/acceptance/fixtures/sample-replay-v1.json "$tmp/dashboard/v1.json"
[[ -f "${LIVE_REPLAY:-dashboard/live-replay.json}" ]] && cp "${LIVE_REPLAY:-dashboard/live-replay.json}" "$tmp/dashboard/live.json"
python3 - "$tmp/dashboard" <<'PY'
import json, sys
d = json.load(open(f"{sys.argv[1]}/v2.json"))
a = d["agents"][1]["agent"]
d["summary"]["agents"][a]["rounds_scored"] = d["summary"]["settled"] - 1
json.dump(d, open(f"{sys.argv[1]}/missed.json", "w"))
PY
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp" >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$tmp/dashboard" <<'EOF'
const fs = require("fs");
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const [base, dir] = process.argv.slice(2);
let fail = 0;
const check = (cond, msg) => { console.log((cond ? "ok - " : "not ok - ") + msg); if (!cond) fail = 1; };
const files = ["v2.json", "missed.json", "v1.json", ...(fs.existsSync(`${dir}/live.json`) ? ["live.json"] : [])];
const signed = (x) => (x >= 0 ? "+" : "−") + Math.abs(x).toFixed(3);

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const file of files) {
    const d = JSON.parse(fs.readFileSync(`${dir}/${file}`, "utf8"));
    const v2 = d.schema !== "vol-replay/v1", s = d.summary, N = s.settled;
    for (const width of file === "v2.json" ? [1440, 390, 375] : [1440, 375]) {
      const at = `${file}@${width}`;
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      const errors = [];
      page.on("pageerror", (e) => errors.push(String(e)));
      await page.goto(`${base}/dashboard/?data=${file}#/agents`);
      await page.waitForSelector("#app tr[data-agent]", { state: "attached", timeout: 15000 }).catch(() => {});
      await page.waitForTimeout(300);
      const t = await page.evaluate(() => {
        const tb = [...document.querySelectorAll("#app table")].find((x) => x.querySelector("tr[data-agent]"));
        if (!tb) return null;
        const txt = (e) => e ? e.textContent.replace(/\s+/g, " ").trim() : "";
        const card = tb.closest("section, .card");
        return { heads: [...tb.querySelector("tr").children].map(txt), note: txt(card.querySelector(".agent-rounds-note")),
          baseline: txt(tb.querySelector("tr.agent-baseline")),
          rows: [...tb.querySelectorAll("tr[data-agent]")].map((tr) => {
            const det = document.querySelector(`tr[data-detail-for="${tr.dataset.agent}"]`);
            const btn = tr.querySelector("button.agent-toggle");
            return { agent: tr.dataset.agent, cells: [...tr.cells].map(txt), text: txt(tr), badge: !!tr.querySelector(".badge.zk, .badge.commit, .badge"),
              missed: txt(tr.querySelector("[data-missed]")), btn: btn ? { exp: btn.getAttribute("aria-expanded"), ctl: btn.getAttribute("aria-controls"), label: btn.textContent.trim() } : null,
              det: det ? { id: det.id, shown: det.getClientRects().length > 0, text: txt(det), bg: getComputedStyle(det.cells[0]).backgroundColor,
                border: getComputedStyle(det.cells[0]).borderTopWidth } : null };
          }),
          overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth };
      });
      check(!!t, `${at}: agents table found`);
      if (!t) { await page.close(); continue; }
      check(!t.heads.some((h) => /scored/i.test(h)) && t.heads.length === 5, `${at}: 5 columns, no Scored (${t.heads.join(" | ")})`);
      check(!t.heads.some((h) => /^Verification$|reputation/i.test(h)), `${at}: no Verification / ERC-8004 reputation column`);
      check(v2 ? /平均分位数损失（越低越好）/.test(t.heads[1]) && /相对气候基线/.test(t.heads[2]) : /Σ ln p/.test(t.heads[1]) && /相对瞎猜基线/.test(t.heads[2]),
        `${at}: score + signed-excess headers in Chinese`);
      check(t.heads[3].includes(`跑赢基线 x/${N}`) && /分到手续费 \(WETH\)/.test(t.heads[4]), `${at}: 跑赢基线 x/${N} and 分到手续费 (WETH) headers`);
      const miss = d.agents.filter((a) => s.agents[a.agent].rounds_scored < N);
      check(t.note.includes(`共 ${N} 轮`) && (miss.length ? !/全部 agent 每轮都参与/.test(t.note) : /全部 agent 每轮都参与/.test(t.note)),
        `${at}: rounds note computed from data (${t.note})`);
      check(v2 ? /climatology baseline/.test(t.baseline) && t.baseline.includes(s.baseline_mean_pinball_loss.toFixed(3))
               : /uniform baseline/.test(t.baseline) && t.baseline.includes(s.uniform_total_log_score.toFixed(3)), `${at}: baseline row kept (${t.baseline})`);
      check(t.rows.length === d.agents.length, `${at}: one main row per agent (${t.rows.length}/${d.agents.length})`);
      const tc = Object.fromEntries((d.tamper_checks ?? []).map((x) => [x.agent, x]));
      for (const a of d.agents) {
        const r = t.rows.find((x) => x.agent === a.agent), m = s.agents[a.agent], rep = m.erc8004;
        if (!r) { check(false, `${at} ${a.agent}: row present`); continue; }
        const score = v2 ? m.mean_pinball_loss.toFixed(3) : m.total_log_score.toFixed(3);
        const ex = v2 ? signed(m.mean_excess) : signed(m.mean_log_score - d.params.baseline_log_score_float);
        check(r.cells.length === 5 && r.cells[1].includes(score) && r.cells[2] === ex && r.cells[3] === `${m.beat_baseline_rounds}/${m.rounds_scored}`,
          `${at} ${a.agent}: cells ${score} / ${ex} / ${m.beat_baseline_rounds}/${m.rounds_scored} (${r.cells.slice(1).join(" | ")})`);
        check(r.badge && /zk|可复现|仅提交/.test(r.cells[0]), `${at} ${a.agent}: tier badge and compact verification status in the main row`);
        check(m.rounds_scored < N ? r.missed === `${m.rounds_scored}/${N} 轮` : r.missed === "", `${at} ${a.agent}: missed-rounds badge "${r.missed}"`);
        check(!r.text.includes(`agentId`) && !/getSummary/.test(r.text), `${at} ${a.agent}: ERC-8004 details not in the main row`);
        check(!!r.btn && r.btn.exp === "false" && r.btn.label === "▸" && r.det && r.btn.ctl === r.det.id && !r.det.shown, `${at} ${a.agent}: ▸ toggle, detail collapsed by default`);
        if (!r.det) continue;
        const repVal = (Number(rep.summary_value) / 10 ** rep.summary_decimals).toFixed(3);
        check(r.det.text.includes(`agentId ${a.agent_id}`) && r.det.text.includes(`${rep.count} 条记录 × 平均分 ${repVal}`) && r.det.text.includes(`${rep.tag1} / ${rep.tag2}`),
          `${at} ${a.agent}: detail has agentId, getSummary as count 条记录 × 平均分, tags`);
        check(r.det.text.includes(a.address.slice(0, 6)) && (!a.model_hash || /^0x0*$/.test(a.model_hash) || r.det.text.includes(a.model_hash.slice(0, 6))), `${at} ${a.agent}: detail has address and modelHash`);
        if (tc[a.agent]) check(/tampered proof rejected/.test(r.det.text) && (!tc[a.agent].verify_proof_gas || r.det.text.includes(tc[a.agent].verify_proof_gas.toLocaleString())) && /prove/.test(r.det.text),
          `${at} ${a.agent}: detail has tamper rejection, prove time, verifyProof gas`);
        if (a.recompute_command) check(r.det.text.includes(a.recompute_command) && /详情复核命令/.test(r.det.text), `${at} ${a.agent}: detail has the recompute command`);
        if (a.license && !tc[a.agent]) check(r.det.text.includes("license"), `${at} ${a.agent}: detail has the license`);
        const dark = (c) => { const n = (c.match(/\d+/g) || []).map(Number); return n.length >= 3 && n[0] + n[1] + n[2] < 200 && (n[3] ?? 1) !== 0; };
        check(!dark(r.det.bg) && parseFloat(r.det.border) === 0, `${at} ${a.agent}: detail row is light, no hard outline (${r.det.bg}, ${r.det.border})`);
      }
      const first = t.rows[0];
      if (first?.btn) {
        await page.click(`tr[data-agent="${first.agent}"] button.agent-toggle`);
        await page.waitForTimeout(150);
        const open = await page.evaluate((id) => ({ shown: document.getElementById(id).getClientRects().length > 0,
          exp: document.querySelector(`[aria-controls="${id}"]`).getAttribute("aria-expanded"),
          overflow: document.documentElement.scrollWidth - document.documentElement.clientWidth }), first.btn.ctl);
        check(open.shown && open.exp === "true", `${at}: clicking ▸ expands the detail row`);
        check(open.overflow <= 0, `${at}: no page overflow when expanded (${open.overflow}px)`);
        await page.click(`tr[data-agent="${first.agent}"] button.agent-toggle`);
        await page.waitForTimeout(100);
        check(await page.evaluate((id) => document.getElementById(id).getClientRects().length === 0, first.btn.ctl), `${at}: clicking again collapses it`);
      }
      check(t.overflow <= 0, `${at}: no page overflow (${t.overflow}px)`);
      check(errors.length === 0, `${at}: no page errors (${errors.join("; ")})`);
      await page.close();
    }
  }
  await browser.close();
  console.log(fail ? "FAIL" : "DONE");
  process.exit(fail);
})();
EOF
