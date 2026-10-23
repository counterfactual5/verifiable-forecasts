#!/usr/bin/env bash
# R1 acceptance: on sample-replay.json#/rounds the round player's stage 4 (被使用) shows reputation weights as
# per-agent percentages: on round 3 no digit run of 10+, each agent with a non-zero weight named with a % value,
# zero-weight agents left out, the percentages summing to 100 +- 1; equal-weight fallback rounds keep their sentence.
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
const replay = require(require("path").join(process.cwd(), "dashboard/sample-replay.json"));
const short = (a) => a.replace(/^agent-/, "");
const label = (r) => `#${r.h ?? r.id} `;

const target = 3;
const weights = replay.rounds[target].fee.mirror.weights.map(BigInt);
const named = replay.agents.map((a, i) => ({ name: short(a.agent), w: weights[i] }));
const nonzero = named.filter((a) => a.w > 0n), zero = named.filter((a) => a.w === 0n);
const fallbackIdx = replay.rounds.findIndex((r) => r.fee?.mirror?.equal_weight_fallback);

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(`${base}/dashboard/?data=sample-replay.json#/rounds`);
  await page.waitForSelector(".player #pl-body .pl-stage", { state: "attached", timeout: 15000 });
  const next = page.locator('.player [data-rc="next"]');
  const goTo = async (i) => {
    for (let n = 0; n < replay.rounds.length + 1; n++) {
      const t = (await page.locator("#pl-round").textContent()) ?? "";
      if (t.startsWith(label(replay.rounds[i]))) return true;
      await next.click();
      await page.waitForTimeout(60);
    }
    return false;
  };
  const stage4 = () => page.locator('.player .pl-stage[data-stage="4"]').innerText();

  check(nonzero.length === 5 && zero.length === 1, `fixture: round ${target} has 5 non-zero weights and 1 zero (${nonzero.length}/${zero.length})`);
  check(await goTo(target), `the player reaches round ${target} (${label(replay.rounds[target]).trim()})`);
  const text = await stage4();
  check(!/\d{10,}/.test(text), `stage 4 has no digit run of 10+ (${(text.match(/\d{10,}/) ?? [""])[0]})`);
  const pcts = [];
  for (const a of nonzero) {
    const m = text.match(new RegExp(`${a.name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*([0-9]+(?:\\.[0-9]+)?)\\s*%`));
    check(!!m, `stage 4 names ${a.name} with a % value`);
    if (m) pcts.push(Number(m[1]));
  }
  for (const a of zero) check(!text.includes(a.name), `zero-weight ${a.name} is left out of stage 4`);
  const sum = pcts.reduce((x, y) => x + y, 0);
  check(pcts.length === nonzero.length && Math.abs(sum - 100) <= 1, `percentages sum to 100 +- 1 (${sum.toFixed(1)})`);

  check(fallbackIdx >= 0, `fixture: a fallback round exists (${fallbackIdx})`);
  if (fallbackIdx >= 0) {
    check(await goTo(fallbackIdx), `the player reaches fallback round ${fallbackIdx}`);
    check((await stage4()).includes("声誉权重尚未形成 → 等权混合"), "the fallback round keeps 声誉权重尚未形成 → 等权混合");
  }
  check(errors.length === 0, `no page errors (${errors.join("; ")})`);
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
