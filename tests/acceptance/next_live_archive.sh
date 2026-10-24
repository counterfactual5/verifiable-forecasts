#!/usr/bin/env bash
# Live archive acceptance: every live run also keeps a copy of dashboard/live-replay.json under
# demo/out/live-archive/live-replay-YYYYMMDDTHHMMZ.json (UTC of generated_at), outside what the
# dashboard serves and what deploy/push.sh rsyncs; the oldest copies beyond the cap are removed.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
fail=0
ok() { echo "ok - $1"; }
bad() { echo "not ok - $1"; fail=1; }

grep -q -- "--exclude /demo/out/" deploy/push.sh && ok "push.sh leaves demo/out/ (the archive) on the server" \
  || bad "push.sh leaves demo/out/ (the archive) on the server"

res=$(cd "$root/agents" && PYTHONPATH="$root/agents:$root/demo" uv run --project "$root/agents" python - <<'EOF' 2>&1
import json, tempfile
from pathlib import Path
import fork_round as fr

check = lambda c, m: print(("ok - " if c else "not ok - ") + m)
check(fr.LIVE_ARCHIVE == fr.REPO / "demo" / "out" / "live-archive", "archive lives in demo/out/live-archive")
with tempfile.TemporaryDirectory() as d:
    d = Path(d)
    out, arc = d / "live-replay.json", d / "archive"
    out.write_text(json.dumps({"generated_at": 1792828980}) + "\n")
    dst = fr.archive_live(out, 1792828980, arc, keep=3)
    check(dst == arc / "live-replay-20261024T0803Z.json", f"copy named by generated_at in UTC ({dst.name})")
    check(dst.read_bytes() == out.read_bytes() and out.exists(), "copy is byte-identical; live-replay.json stays")
    for h in range(1, 5):
        fr.archive_live(out, 1792828980 + h * 3600, arc, keep=3)
    names = sorted(p.name for p in arc.iterdir())
    check(names == [f"live-replay-20261024T{h:02d}03Z.json" for h in (10, 11, 12)],
          f"only the newest 3 kept ({names})")
EOF
)
printf '%s\n' "$res"
grep -q '^not ok' <<<"$res" && fail=1
grep -q '^ok' <<<"$res" || fail=1
[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
