#!/usr/bin/env bash
# A cross-origin ?data= (CORS-enabled attacker JSON whose agent name carries markup) must not reach the page:
# no payload executes and no element is injected on any view; the page either refuses it with #error naming the URL
# or renders the data inertly. Last line: executed payloads + injected elements + blank views (target 0).
set -uo pipefail
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root"
tmp=$(mktemp -d)
python3 - "$tmp/evil.json" <<'EOF'
import json, sys
s = open("dashboard/sample-replay.json").read()
payload = json.dumps('<img class=pwn src=x onerror="window.__pwned=(window.__pwned||0)+1">')[1:-1]
open(sys.argv[1], "w").write(s.replace('"agent-linear_abs"', '"' + payload + '"'))
EOF
free() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }
port=$(free)
port2=$(free)
python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1 &
srv=$!
disown "$srv"
python3 - "$port2" "$tmp" >/dev/null 2>&1 <<'EOF' &
import functools, http.server, sys
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), functools.partial(H, directory=sys.argv[2])).serve_forever()
EOF
srv2=$!
disown "$srv2"
trap 'kill $srv $srv2 2>/dev/null; rm -rf "$tmp"' EXIT
for _ in $(seq 50); do curl -sf "http://127.0.0.1:$port/dashboard/" >/dev/null && curl -sf "http://127.0.0.1:$port2/evil.json" >/dev/null && break; sleep 0.1; done

groot=$(npm root -g 2>/dev/null)
NODE_PATH="$groot:$groot/@playwright/cli/node_modules" node - "http://127.0.0.1:$port" "http://127.0.0.1:$port2/evil.json" <<'EOF'
let pw;
for (const m of ["playwright", "playwright-core"]) { try { pw = require(m); break; } catch (_) {} }
if (!pw) { console.log("not ok - playwright not found"); console.log(99); process.exit(1); }
const [base, evil] = process.argv.slice(2);
let total = 0;

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const view of ["", "#/agents", "#/rounds", "#/live"]) {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.goto(`${base}/dashboard/?data=${encodeURIComponent(evil)}${view}`);
    await page.waitForFunction(() => document.getElementById("error") || document.querySelector("#app svg"),
      null, { timeout: 15000 }).catch(() => {});
    await page.waitForTimeout(600);
    const s = await page.evaluate(() => ({
      pwned: window.__pwned || 0,
      injected: document.querySelectorAll("img.pwn").length,
      error: document.getElementById("error")?.textContent ?? null,
      svg: document.querySelectorAll("#app svg").length,
    }));
    const named = s.error !== null ? s.error.includes("evil.json") : s.svg > 0;
    console.log(`${s.pwned + s.injected === 0 ? "ok" : "not ok"} - ${view || "#/"}: executed ${s.pwned}, injected ${s.injected}`);
    console.log(`${named ? "ok" : "not ok"} - ${view || "#/"}: refused with #error naming the URL, or rendered inertly (error ${s.error}, ${s.svg} svg)`);
    total += s.pwned + s.injected + (named ? 0 : 1);
    await page.close();
  }
  await browser.close();
  console.log(total);
  process.exit(total ? 1 : 0);
})().catch((e) => { console.log("not ok - " + e); console.log(99); process.exit(1); });
EOF
