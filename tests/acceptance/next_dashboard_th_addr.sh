#!/usr/bin/env bash
# R2 acceptance: at 1280, on sample-replay.json#/agents and on sample-round.json, every table header holds at
# least one address link whose computed text-transform is not uppercase and whose innerText starts with a
# lowercase 0x, while the header's own "ERC-8004" text and its sibling headers stay uppercase.
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

const inspect = (page) => page.evaluate(() => {
  const ths = [...document.querySelectorAll("#app th")].filter((th) => th.querySelector("a.mono"));
  return ths.map((th) => {
    const a = th.querySelector("a.mono");
    const sib = [...th.parentElement.children].find((c) => c !== th && c.tagName === "TH" && /[a-z]/i.test(c.textContent));
    return { linkTransform: getComputedStyle(a).textTransform, linkText: a.innerText.trim(),
      hasErc: /ERC-8004/.test(th.textContent), thTransform: getComputedStyle(th).textTransform,
      sibTransform: sib ? getComputedStyle(sib).textTransform : null };
  });
});

(async () => {
  let browser;
  try { browser = await pw.chromium.launch(); } catch (_) { browser = await pw.chromium.launch({ channel: "chrome" }); }
  for (const view of ["sample-replay.json#/agents", "sample-round.json"]) {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    const errors = [];
    page.on("pageerror", (e) => errors.push(String(e)));
    await page.goto(`${base}/dashboard/?data=${view}`);
    await page.waitForSelector("#app th a.mono", { state: "attached", timeout: 15000 }).catch(() => {});
    await page.waitForTimeout(300);
    const heads = await inspect(page);
    check(heads.length >= 1, `${view}: at least one table header holds an address link (${heads.length})`);
    for (const [i, h] of heads.entries()) {
      check(h.linkTransform !== "uppercase", `${view} th#${i}: address link is not uppercased (text-transform: ${h.linkTransform})`);
      check(/^0x/.test(h.linkText), `${view} th#${i}: address innerText starts with lowercase 0x (${h.linkText})`);
      if (h.hasErc) check(h.thTransform === "uppercase", `${view} th#${i}: the ERC-8004 header text stays uppercase (${h.thTransform})`);
      check(h.sibTransform === "uppercase", `${view} th#${i}: sibling headers stay uppercase (${h.sibTransform})`);
    }
    check(errors.length === 0, `${view}: no page errors (${errors.join("; ")})`);
    await page.close();
  }
  await browser.close();
  console.log(fail ? "FAIL" : "PASS");
  process.exit(fail);
})().catch((e) => { console.log("not ok - " + e); console.log("FAIL"); process.exit(1); });
EOF
