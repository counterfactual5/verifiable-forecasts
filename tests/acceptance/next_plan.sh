#!/usr/bin/env bash
# R1 acceptance: docs/plans/实施计划.md holds 分工 / 三天排期 / 先砍 (ordered), the chosen Δ, N
# and the ERC-8004 integration choice; contracts/ and analysis/ untouched by the R1 milestone commit.
set -uo pipefail
cd "$(dirname "$0")/../.."
doc=docs/plans/实施计划.md
fail=0
check() { if eval "$2"; then echo "ok - $1"; else echo "not ok - $1"; fail=1; fi; }

check "doc exists" "[[ -f $doc ]]"
[[ -f $doc ]] || { echo "FAIL"; exit 1; }

section() { awk -v h="$1" '/^#+ /{insec = index($0, h) > 0; next} insec' "$doc"; }

check "分工 section" "grep -qE '^#+ .*分工' $doc"
check "排期 section covers three days" "grep -qE '^#+ .*排期' $doc && [[ \$(section 排期 | grep -oE '10/2[123]' | sort -u | wc -l) -ge 3 ]]"
check "先砍 section is an ordered list" "grep -qE '^#+ .*先砍' $doc && [[ \$(section 先砍 | grep -cE '^[0-9]+\\. ') -ge 2 ]]"
check "Δ = 300 s chosen" "grep -qE '(Δ|delta|Delta)[^0-9]{0,6}300' $doc"
check "N = 12 chosen" "grep -qE 'N[[:space:]]*=[[:space:]]*12' $doc"
check "Δ/N grounded in pool lookback facts" "grep -q 'FACTS.md' $doc && grep -qE '2\\.4h|2\\.41|回溯' $doc"
check "ERC-8004 integration decided" "grep -qE '^#+ .*ERC-8004' $doc && section ERC-8004 | grep -qE '已部署|参考实现'"
check "R1 milestone left contracts/ and analysis/ untouched" "git diff --quiet c860c40 581bd2d -- contracts analysis"

[[ $fail -eq 0 ]] && echo PASS || { echo FAIL; exit 1; }
