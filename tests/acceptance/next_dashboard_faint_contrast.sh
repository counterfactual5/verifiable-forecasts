#!/usr/bin/env bash
# The --faint text color (10-12px labels, axis text, footer) reaches WCAG AA 4.5:1 on every background it sits on
# (--bg, --panel, --panel-2) and stays lighter than --muted so the text hierarchy holds.
# Last line: number of failing checks (target 0).
set -uo pipefail
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$root"
python3 - <<'EOF'
import re, sys

s = open("dashboard/index.html").read()
root = re.search(r":root\s*\{(.*?)\}", s, re.S).group(1)
v = dict(re.findall(r"--([\w-]+):\s*(#[0-9a-fA-F]{6})", root))


def lum(h):
    c = [int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    c = [x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def ratio(a, b):
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


fail = 0
for bg in ("bg", "panel", "panel-2"):
    r = ratio(v["faint"], v[bg])
    ok = r >= 4.5
    fail += not ok
    print(f"{'ok' if ok else 'not ok'} - --faint {v['faint']} on --{bg} {v[bg]}: {r:.2f}:1 (AA 4.5)")
ok = lum(v["faint"]) > lum(v["muted"])
fail += not ok
print(f"{'ok' if ok else 'not ok'} - --faint {v['faint']} stays lighter than --muted {v['muted']}")
print(fail)
sys.exit(1 if fail else 0)
EOF
