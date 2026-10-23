#!/usr/bin/env bash
# An explicit ?data=<src> is the only data source: a missing file, invalid JSON or an unreachable URL shows the
# #error card naming the source (as text, never markup) instead of rendering another file; an existing ?data file
# and the no-param default chain still render. Last line: number of failing assertions (target 0).
set -uo pipefail
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root"
mkdir -p docs/.local/tmp
printf '{"schema": "vol-replay/v1", "rounds": [' > docs/.local/tmp/dp_bad.json
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
disown "$srv"
trap 'kill $srv 2>/dev/null; rm -f docs/.local/tmp/dp_bad.json' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log(99); process.exit(1); }
const base = process.argv[2];
let fail = 0;
const check = (cond, msg) => { console.log((cond ? "ok - " : "not ok - ") + msg); if (!cond) fail++; };

const state = (page) => page.evaluate(() => ({
  error: document.getElementById("error")?.textContent ?? null,
  errorChildren: document.getElementById("error")?.children.length ?? 0,
  svg: document.querySelectorAll("#app svg").length,
  source: document.getElementById("source")?.innerText.trim() ?? "",
  pwn: !!document.getElementById("pwn") || !!window.__pwned,
}));

const open = async (browser, query) => {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  let dialogs = 0;
  page.on("dialog", (d) => { dialogs++; d.dismiss().catch(() => {}); });
  await page.goto(`${base}/dashboard/${query}`);
  await page.waitForFunction(() => document.getElementById("error") || document.querySelector("#app svg"),
    null, { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(400);
  const s = await state(page);
  await page.close();
  return { ...s, dialogs };
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }

  let s = await open(browser, "?data=missing.json");
  check(s.error !== null && /missing\.json/.test(s.error), `missing file: #error names missing.json (${s.error})`);
  check(s.error !== null && /404/.test(s.error), `missing file: #error states HTTP 404 (${s.error})`);
  check(s.svg === 0, `missing file: no chart rendered from another source (${s.svg} svg)`);
  check(s.source === "", `missing file: footer names no fallback source (${s.source})`);

  s = await open(browser, "?data=../docs/.local/tmp/dp_bad.json");
  check(s.error !== null && /dp_bad\.json/.test(s.error), `invalid JSON: #error names dp_bad.json (${s.error})`);
  check(s.svg === 0 && s.source === "", `invalid JSON: nothing rendered from another source (${s.svg} svg, footer ${s.source})`);

  s = await open(browser, "?data=http://127.0.0.1:1/unreachable.json");
  check(s.error !== null && /unreachable\.json/.test(s.error), `network error: #error names unreachable.json (${s.error})`);
  check(s.svg === 0 && s.source === "", `network error: nothing rendered from another source (${s.svg} svg, footer ${s.source})`);

  s = await open(browser, "?data=" + encodeURIComponent('<img src=x id=pwn onerror="window.__pwned=1">'));
  check(s.error !== null && /<img/.test(s.error), `markup in ?data: #error shows it as text (${s.error})`);
  check(!s.pwn && s.errorChildren === 0 && s.dialogs === 0, "markup in ?data: nothing injected into the page");

  s = await open(browser, "?data=sample-replay.json");
  check(s.error === null && s.svg > 0, `existing ?data file renders (${s.svg} svg, error ${s.error})`);
  check(/sample-replay\.json/.test(s.source), `existing ?data file is the named source (${s.source})`);

  s = await open(browser, "");
  check(s.error === null && s.svg > 0 && s.source.startsWith("Data: "), `no param: default chain renders (${s.svg} svg, error ${s.error}, footer ${s.source})`);

  await browser.close();
  console.log(fail);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e); console.log(99); process.exit(1); });
EOF
