#!/usr/bin/env bash
# Dashboard acceptance (fee chart, tab bar, verification tiers):
# - fee chart: the hindsight fair fee is a solid reference line; the forecast fee is a dashed, thicker cobalt or
#   vermilion line; fixed 5 bps and prev-hour RV are thin muted grey baselines that differ from each other; legend,
#   hover tooltip and tile headers name the metrics in short English (hindsight fair fee / forecast / fixed 5 bps /
#   prev-hour RV, with reference / protocol output / baseline tags) while the Chinese 事后/参照/事前无法得到 and
#   forecast explanations live in the lead and caption; the caption says closer to the reference is better and that
#   the reference needs the hour to end, states the volume assumption, and each usable strategy shows its MAE
#   against the reference;
#   no view still uses the bare "fair LVR fee" / 公允费率 naming.
# - tab bar: the selected tab has no filled background, a 2px cobalt underline on the bar's bottom edge and cobalt
#   text; a hovered tab gets no filled background; keyboard focus shows a cobalt ring; no overflow at 375 / 390 px.
# - tiers card: five cells including opML marked 路线图 between 可复现 and TEE; every cell has a 押金 line; 可复现/仅提交 tagged
#   合约已实现，本演示未启用, opML/TEE 路线图, zk untagged; the shared-rule line is present; commit-only is not described as unable to prove provenance; the
#   implemented tiers keep their "N 个 agent" chips even at zero agents; no cell overflows at 375 / 390 px.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
res=$(NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$root/dashboard/sample-replay.json" <<'EOF' 2>&1
const fs = require("fs");
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("FAIL no playwright"); process.exit(1); }
const [base, jsonPath] = process.argv.slice(2);
const d = JSON.parse(fs.readFileSync(jsonPath, "utf8"));
const errs = [];
const check = (cond, msg) => { console.log(`${cond ? "ok" : "not ok"} - ${msg}`); if (!cond) errs.push(msg); };
const rgb = (s) => (String(s).match(/[\d.]+/g) || []).map(Number);
const transparent = (s) => s === "transparent" || (rgb(s).length === 4 && rgb(s)[3] === 0);
const ACCENT = "rgb(29, 63, 196)";
(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const width of [1280, 390, 375]) {
    const page = await browser.newPage({ viewport: { width, height: 900 }, reducedMotion: "reduce" });
    const pageErrors = [];
    page.on("pageerror", (e) => pageErrors.push(e.message));
    await page.goto(`${base}/dashboard/#/fee`);
    await page.waitForSelector("#fee-card", { timeout: 15000 });
    await page.waitForTimeout(300);
    const at = `@${width}`;

    const fee = await page.evaluate(() => {
      const card = document.querySelector("#fee-card");
      const chart = card.querySelector(".chart");
      const paths = [...chart.querySelectorAll("svg path")].map((p) => ({ stroke: p.getAttribute("stroke"),
        dash: p.getAttribute("stroke-dasharray") || "", width: parseFloat(p.getAttribute("stroke-width")) }));
      const legend = [...chart.nextElementSibling.querySelectorAll(".nowrap")].map((s) => {
        const l = s.querySelector("line");
        return { text: s.textContent.replace(/\s+/g, " ").trim(), stroke: l?.getAttribute("stroke"), dash: l?.getAttribute("stroke-dasharray") || "" };
      });
      const tiles = [...card.querySelectorAll("[data-mae]")].map((el) => ({ key: el.dataset.mae, value: parseFloat(el.textContent),
        text: el.closest(".fee-tile").textContent.replace(/\s+/g, " ") }));
      const heads = [...card.querySelectorAll(".fee-tile > .sub:first-child")].map((el) => el.textContent.replace(/\s+/g, " ").trim());
      const notes = [card.querySelector(".takeaway"), ...card.querySelectorAll(":scope > .sub:not(.chart + .sub)")].map((el) => el?.textContent ?? "").join(" ").replace(/\s+/g, " ");
      return { paths, legend, tiles, heads, notes, text: card.textContent.replace(/\s+/g, " "), all: document.getElementById("app").textContent.replace(/\s+/g, " ") };
    });
    const pathOf = (re) => { const l = fee.legend.find((x) => re.test(x.text)); return l && fee.paths.find((p) => p.stroke === l.stroke); };
    const ref = pathOf(/fair/i), fc = pathOf(/forecast/i), fixed = pathOf(/fixed/i), prev = pathOf(/prev/i);
    check(/事后/.test(fee.notes) && /参照/.test(fee.notes) && /事前无法得到/.test(fee.notes), `${at}: lead/caption explain the reference as 事后/参照/事前无法得到`);
    check(/forecast\s*=\s*按 ERC-8004 信誉加权各 agent 预测后由 VolFeeConsumer 算出/.test(fee.notes), `${at}: caption explains forecast in Chinese`);
    const NAMES = ["hindsight fair fee reference", "forecast protocol output", "fixed 5 bps baseline", "prev-hour RV baseline"];
    const CJK = /[\u3000-\u9fff\uff00-\uffef]/;
    check(fee.legend.length === 4 && NAMES.every((n) => fee.legend.some((x) => x.text === n)) && !fee.legend.some((x) => CJK.test(x.text)),
          `${at}: legend names are short English labels with role tags (${fee.legend.map((x) => x.text).join(" | ")})`);
    check(fee.heads.length === 4 && NAMES.every((n) => fee.heads.includes(n)), `${at}: fee tile headers are the same English labels (${fee.heads.join(" | ")})`);
    await page.locator("#fee-card .chart svg").scrollIntoViewIfNeeded();
    const box = await page.locator("#fee-card .chart svg").boundingBox();
    await page.mouse.move(box.x + box.width * 0.5, box.y + box.height * 0.5);
    await page.waitForTimeout(100);
    const tipNames = await page.$$eval("#fee-card .tip .r span", (els) => els.map((e) => e.textContent.trim()));
    check(tipNames.length === 4 && ["hindsight fair fee", "forecast", "fixed 5 bps", "prev-hour RV"].every((n) => tipNames.includes(n)),
          `${at}: hover tooltip uses the English metric names (${tipNames.join(" | ")})`);
    check(!!ref && !ref.dash, `${at}: reference drawn solid (${JSON.stringify(ref)})`);
    check(!!fc && !!fc.dash, `${at}: forecast fee drawn dashed (${JSON.stringify(fc)})`);
    check(!!fc && ["#d8431b", "#1d3fc4"].includes(fc.stroke.toLowerCase()), `${at}: forecast fee in vermilion or cobalt (${fc?.stroke})`);
    check(!!fc && fee.paths.every((p) => p === fc || p.width < fc.width), `${at}: forecast fee is the thickest line (${fee.paths.map((p) => p.width)})`);
    const grey = (hex) => { const n = parseInt(hex.slice(1), 16), c = [n >> 16, (n >> 8) & 255, n & 255]; return Math.max(...c) - Math.min(...c) <= 40 && Math.min(...c) >= 100; };
    for (const [k, p, re] of [["fixed", fixed, /fixed/i], ["prev-hour", prev, /prev/i]]) {
      const lt = fee.legend.find((x) => re.test(x.text))?.text ?? "";
      check(!!p && grey(p.stroke) && p.width <= 1.6, `${at}: ${k} baseline is a thin muted grey line (${JSON.stringify(p)})`);
      check(/ baseline$/.test(lt), `${at}: ${k} legend tagged baseline (${lt})`);
    }
    check(!!fixed && !!prev && (fixed.dash !== prev.dash || fixed.stroke !== prev.stroke), `${at}: the two baselines differ by dash or shade`);
    check(fee.text.includes("越贴近参照线越好") && fee.text.includes("参照线要等这一小时结束才算得出"), `${at}: caption says closer to the reference is better and needs the hour to end`);
    check(/成交量不受费率影响/.test(fee.text) && /LVR/.test(fee.text), `${at}: caption states the volume-unaffected / LP break-even assumption`);
    for (const k of ["forecast", "fixed", "prev_hour"]) {
      const t = fee.tiles.find((x) => x.key === k);
      const v = t ? t.value : NaN;
      check(!!t && /MAE vs reference/.test(t.text) && Math.abs(v - d.summary.fee_strategies.mae_bps[k]) < 0.006,
            `${at}: ${k} tile shows MAE vs reference = ${d.summary.fee_strategies.mae_bps[k].toFixed(2)} (${t?.text.trim()})`);
    }
    check(!/(?<!hindsight )fair LVR fee/i.test(fee.all) && !/公允费率|公平费率/.test(fee.all), `${at}: no view uses the bare fair LVR fee / 公允费率 naming`);
    check(!/出题|考题|考试/.test(fee.all), `${at}: no 出题/考题/考试 wording`);

    const tab = await page.evaluate(() => {
      const nav = document.getElementById("nav"), sel = nav.querySelector('.tab[aria-current="page"]');
      const cs = getComputedStyle(sel), nr = nav.getBoundingClientRect(), tr = sel.getBoundingClientRect();
      return { key: sel.dataset.tab, bg: cs.backgroundColor, img: cs.backgroundImage, shadow: cs.boxShadow, color: cs.color,
               bw: cs.borderBottomWidth, bs: cs.borderBottomStyle, bc: cs.borderBottomColor, gap: Math.abs(nr.bottom - parseFloat(getComputedStyle(nav).borderBottomWidth) - tr.bottom) };
    });
    check(tab.key === "fee", `${at}: consumer tab selected (${tab.key})`);
    check(transparent(tab.bg) && tab.img === "none" && (tab.shadow === "none" || !tab.shadow), `${at}: selected tab has no filled background (${tab.bg}, ${tab.shadow})`);
    check(tab.bw === "2px" && tab.bs === "solid" && tab.bc === ACCENT && tab.color === ACCENT, `${at}: selected tab has cobalt text and a 2px cobalt underline (${tab.bw} ${tab.bs} ${tab.bc}, ${tab.color})`);
    check(tab.gap <= 1, `${at}: underline sits on the tab bar bottom edge (gap ${tab.gap.toFixed(2)}px)`);
    const other = page.locator('#nav .tab[data-tab="agents"]');
    await other.hover();
    const hbg = await other.evaluate((el) => [getComputedStyle(el).backgroundColor, getComputedStyle(el).backgroundImage]);
    check(transparent(hbg[0]) && hbg[1] === "none", `${at}: hovered tab has no filled background (${hbg})`);
    let focused = null;
    for (let i = 0; i < 12 && !focused; i++) {
      await page.keyboard.press("Tab");
      focused = await page.evaluate(() => {
        const a = document.activeElement;
        if (!a?.classList.contains("tab")) return null;
        const cs = getComputedStyle(a);
        return { style: cs.outlineStyle, color: cs.outlineColor, width: cs.outlineWidth };
      });
    }
    check(!!focused && focused.style !== "none" && focused.color === ACCENT && parseFloat(focused.width) >= 2, `${at}: keyboard focus ring is cobalt (${JSON.stringify(focused)})`);

    await page.goto(`${base}/dashboard/#/agents`);
    await page.waitForSelector("#tiers", { timeout: 15000 });
    await page.waitForTimeout(300);
    const t = await page.evaluate(() => {
      const card = document.getElementById("tiers"), cr = card.getBoundingClientRect();
      const cells = [...card.querySelectorAll(".tier")].map((c) => ({ title: c.querySelector("h3")?.firstChild?.textContent.trim() ?? "",
        chip: c.querySelector("h3 .badge")?.textContent.trim() ?? "", text: c.textContent.replace(/\s+/g, " "),
        bond: [...c.querySelectorAll("*")].filter((e) => e.children.length === 0 || e.matches("p, div")).map((e) => e.textContent).find((x) => /押金/.test(x)) ?? "",
        right: c.getBoundingClientRect().right, left: c.getBoundingClientRect().left, sw: c.scrollWidth, cw: c.clientWidth }));
      return { cells, text: card.textContent.replace(/\s+/g, " "), cr: { left: cr.left, right: cr.right }, sw: card.scrollWidth, cw: card.clientWidth,
               doc: [document.documentElement.scrollWidth, document.documentElement.clientWidth] };
    });
    const idx = (re) => t.cells.findIndex((c) => re.test(c.title));
    check(t.cells.length === 5, `${at}: five tier cells (${t.cells.map((c) => c.title)})`);
    const op = t.cells[idx(/opML/)], tee = t.cells[idx(/TEE/)];
    check(!!op && /路线图/.test(op.chip), `${at}: opML cell present and marked 路线图 (${op?.chip})`);
    check(!!tee && /路线图/.test(tee.chip), `${at}: TEE cell marked 路线图 (${tee?.chip})`);
    check(idx(/可复现/) >= 0 && idx(/可复现/) < idx(/opML/) && idx(/opML/) < idx(/TEE/), `${at}: opML sits between 可复现 and TEE`);
    const bondTag = (re) => t.cells[idx(re)]?.bond ?? "";
    check(t.cells.length > 0 && t.cells.every((c) => /押金/.test(c.text) && c.bond), `${at}: every tier cell has a 押金 line (${t.cells.map((c) => c.bond.trim())})`);
    check([/可复现/, /仅提交/].every((re) => bondTag(re).includes("合约已实现，本演示未启用")) && [/opML/, /TEE/].every((re) => /路线图/.test(bondTag(re)))
          && !/未实现|路线图|已实现/.test(bondTag(/zk/)), `${at}: bond tags: 可复现/仅提交 合约已实现，本演示未启用; opML/TEE 路线图; zk untagged (${t.cells.map((c) => c.bond.trim())})`);
    check(bondTag(/可复现/).includes("乐观挑战已实现，裁决暂由仲裁方"), `${at}: reproducible bond names the implemented optimistic challenge`);
    const commit = t.cells[idx(/仅提交/)];
    check(!!commit && !/不证明是哪个模型|冒用|无法证明/.test(commit.text), `${at}: commit-only not described as unable to prove provenance (${commit?.text})`);
    check(t.text.includes("所有档共用：不公开的轮次按最低分记入信誉；三档分成相同，档位只标注出处，权重由消费方决定。（合约已实现，本演示未启用押金门槛；详见 docs/ARCHITECTURE.md 第 9 节）"),
          `${at}: shared-rule line present`);
    const tierOf = (a) => a.tier ?? (a.model_type === "zk" ? "zk" : "commit-only");
    for (const [k, re] of [["zk", /zk/], ["reproducible", /可复现/], ["commit-only", /仅提交/]]) {
      const n = d.agents.filter((a) => tierOf(a) === k).length, c = t.cells[idx(re)];
      check(!!c && c.chip === `${n} 个 agent`, `${at}: implemented ${k} tier keeps its agent-count chip "${c?.chip}" = ${n}`);
    }
    check(t.cells.every((c) => c.left >= t.cr.left - 0.5 && c.right <= t.cr.right + 0.5 && c.sw <= c.cw + 1) && t.sw <= t.cw + 1,
          `${at}: tier cells fit inside the card`);
    check(t.doc[0] <= t.doc[1], `${at}: no horizontal page overflow (${t.doc})`);
    check(pageErrors.length === 0, `${at}: no page errors (${pageErrors.join("; ")})`);
    await page.close();
  }
  await browser.close();
  console.log(errs.length ? "FAIL" : "DONE");
  process.exit(errs.length ? 1 : 0);
})().catch((e) => { console.log("FAIL " + e.message); process.exit(1); });
EOF
); nrc=$?
printf '%s\n' "$res" | grep -E '^(ok|not ok) - '
[[ $nrc -eq 0 ]] && ok "fee chart, tab bar and tiers card checks" || { bad "fee chart, tab bar and tiers card checks"; printf '%s\n' "$res" | grep -vE '^(ok|not ok) - ' | tail -5; }

if [[ -n "${UI_CHECK:-}" ]]; then
  bash "$UI_CHECK" run . --no-record >/dev/null 2>&1 && ok "ui smoke passes" || bad "ui smoke passes"
else
  echo "SKIP - ui smoke (UI_CHECK unset)"
fi

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
