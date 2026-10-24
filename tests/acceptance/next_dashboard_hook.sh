#!/usr/bin/env bash
# V4 hook acceptance: with a replay whose round carries the optional "hook" record (demo V4_HOOK=1), the round player's
# stage 4 (被使用) shows what the VolFeeHook pool actually charged (V4 hook 实际收取 <effective bps>, the hook's quote and
# whether it came from the round's recorded fee); a round without "hook" shows no such line. DASH_DIR overrides the
# dashboard directory so the checks can be run against an older index.html.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
dash="${DASH_DIR:-dashboard}"
tmp="$root/docs/.local/tmp/dashboard_hook"
mkdir -p "$tmp"
python3 - dashboard/sample-replay.json "$tmp/replay.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["contracts"]["v4_hook"] = {"hook": "0x" + "ab" * 18 + "1080"}
d["rounds"][0]["hook"] = {"hook_fee_pips": 298, "recorded": True, "round_id": 0, "effective_fee_pips": 298.0,
                          "lp_fee_usdc": 2.98, "swap_usdc": 10000.0, "swap_gas": 225346}
for r in d["rounds"][1:]:
    r.pop("hook", None)
json.dump(d, open(sys.argv[2], "w"))
PY
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/$dash/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "$dash" "$tmp/replay.json" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log("FAIL"); process.exit(1); }
const path = require("path");
const [base, dash, file] = process.argv.slice(2);
const replay = require(file);
const data = path.relative(path.join(process.cwd(), dash), file);
let fail = 0;
const check = (cond, msg) => { console.log((cond ? "ok - " : "not ok - ") + msg); if (!cond) fail = 1; };
const label = (r) => `#${r.h ?? r.id} `;

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errors = [];
  page.on("pageerror", (e) => errors.push(String(e)));
  await page.goto(`${base}/${dash}/?data=${data}#/rounds`);
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
  const stage4 = async () => (await page.locator('.player .pl-stage[data-stage="4"]').textContent()) ?? "";

  check(await goTo(0), "the player reaches round 0");
  const hooked = (await stage4()).replace(/\s+/g, " ");
  check(/V4 hook 实际收取 2\.98 bps/.test(hooked), "stage 4 shows V4 hook 实际收取 2.98 bps");
  check(/hook 报价 2\.98 bps/.test(hooked) && /取自本轮记录的推荐费率/.test(hooked), "stage 4 shows the hook quote and its recorded source");
  check(await goTo(1), "the player reaches round 1");
  check(!/V4 hook 实际收取/.test(await stage4()), "a round without hook data shows no hook line");
  check(errors.length === 0, `no page errors (${errors.join("; ")})`);
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
