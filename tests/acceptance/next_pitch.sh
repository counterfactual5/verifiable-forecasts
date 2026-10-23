#!/usr/bin/env bash
# R7 acceptance: docs/PITCH.md answers the three judge questions (agent vs keeper, who consumes the
# forecast, how large models are verified), quotes the replay numbers exactly as the replay JSON has them
# (fixed 5 bps has the lowest fee MAE; Chronos-Bolt zero-shot scores below the uniform baseline) in both
# 3-minute scripts, drops the stale placeholder figures, stays speakable in 3 minutes, and docs/PLAN.md
# has phases 2 and 3 ticked.
set -uo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
python3 - <<'EOF'
import json, re, sys

fail = 0
def check(cond, msg):
    global fail
    print(("ok - " if cond else "not ok - ") + msg)
    if not cond:
        fail = 1

pitch = open("docs/PITCH.md", encoding="utf-8").read()
check(re.search(r"^## Tiered verification", pitch, re.M) is not None, "'## Tiered verification' heading kept (agents/MODEL_CARD.md cites it)")
norm = re.sub(r"<!--.*?-->", "", pitch, flags=re.S)
norm = re.sub(r"```.*?```", "", norm, flags=re.S).replace("\u2212", "-")
d = json.load(open("dashboard/sample-replay.json"))
fee = d["summary"]["fee_strategies"]
agents = d["summary"]["agents"]

def section(head):
    parts = norm.split(head, 1)
    return parts[1].split("\n## ", 1)[0] if len(parts) == 2 else ""

en = section("## 3-minute script (English)")
zh = section("## 3 分钟讲稿（中文）")
check(bool(en) and bool(zh), "both 3-minute scripts exist")

mae = {k: f"{v:.2f}" for k, v in fee["mae_bps"].items()}
fair = f"{fee['mean_bps']['fair']:.2f}"
uniform = f"{d['summary']['uniform_total_log_score']:.1f}"
chronos = f"{agents['agent-chronos-bolt']['total_log_score']:.1f}"
check(mae["fixed"] == "1.84" and mae["forecast"] == "2.31", f"replay JSON still has fixed {mae['fixed']} / forecast {mae['forecast']}")

def sentences(txt):
    return [s for s in re.split(r"(?<=[.!?。！？；;])(?!\d)\s*|\n\s*\n", txt) if s.strip()]

for name, txt in (("English script", en), ("Chinese script", zh)):
    sents = sentences(txt)
    check(mae["fixed"] in txt and mae["forecast"] in txt, f"{name} quotes fixed-5-bps MAE {mae['fixed']} and forecast MAE {mae['forecast']}")
    check(any(mae["fixed"] in s and re.search(r"lowest|lower|smallest|最低|最小|低于", s, re.I) for s in sents),
          f"{name} says in one sentence that fixed 5 bps ({mae['fixed']}) has the lowest error")
    check(any(chronos in s and uniform in s and re.search(r"below|under|worse|lower|低于|不如|差于", s, re.I) for s in sents),
          f"{name} says in one sentence that Chronos-Bolt {chronos} is below uniform {uniform}")
    praise = [
        r"forecast[^.\n]{0,60}(beat|outperform|lower|better|closer)[^.\n]{0,40}(fixed|5 bps)",
        r"forecast[^.\n]{0,40}\b(best|lowest|most accurate)\b",
        r"fixed[^.\n]{0,40}(worse|loses|underperform)[^.\n]{0,40}forecast",
        r"预测[^。\n]{0,30}(优于|好于|胜过|低于|更准)[^。\n]{0,20}固定",
        r"预测[^。\n]{0,20}(最低|最好|最优|最小|最准)",
        r"固定[^。\n]{0,30}(不如|差于|输给|高于)[^。\n]{0,20}预测",
    ]
    hits = [m.group(0) for p in praise for s in sents for m in [re.search(p, s, re.I)] if m]
    check(not hits, f"{name} does not claim the forecast fee beats fixed 5 bps {hits[:2]}")
    check(re.search(r"keeper", txt, re.I) is not None, f"{name} contrasts agents with keepers")
    check(any("settle" in s and "createRound" in s and re.search(r"permissionless|无许可", s, re.I) for s in sents),
          f"{name} says in one sentence that settle / createRound are permissionless")
    check(re.search(r"uncertaint|不确定", txt, re.I) is not None and re.search(r"accountab|担责", txt, re.I) is not None,
          f"{name} names judgment under uncertainty and accountability as what makes the forecaster an agent")
    check(any(re.search(r"consumer|消费方", s, re.I) and re.search(r"reputation|信誉", s, re.I) and re.search(r"pick|choose|select|挑", s, re.I) for s in sents),
          f"{name} says consumers pick forecasters by reputation")
    check(any("x402" in s and re.search(r"roadmap|路线图", s, re.I) for s in sents),
          f"{name} says x402 payment is roadmap")
    check(re.search(r"VolFeeConsumer|dynamic fee|动态手续费", txt) is not None, f"{name} tells the fee-consumer story")
    check(re.search(r"reproducib|可复现", txt) is not None, f"{name} names the reproducible tier")

check(len(en.split()) <= 480, f"English script is speakable in 3 minutes ({len(en.split())} words <= 480)")
zh_chars = len(re.sub(r"\s|[*`#>\-|]", "", zh))
check(zh_chars <= 950, f"Chinese script is speakable in 3 minutes ({zh_chars} chars <= 950)")

for k in ("fixed", "prev_hour", "forecast"):
    check(mae[k] in norm, f"fee MAE {k} {mae[k]} appears")
check(fair in norm, f"mean fair LVR fee {fair} bps appears")
check(re.search(r"\bopML\b", norm) is not None and re.search(r"challenge window|挑战窗口", norm) is not None, "opML Q&A explains the challenge window")
check(re.search(r"1-of-N", norm) is not None, "opML Q&A states the 1-of-N honesty assumption")
scale = [l for l in norm.splitlines() if re.search(r"10\^?5|1e5|10⁵", l) and re.search(r"10\^?6|1e6|10⁶", l)]
check(bool(scale), "zkML parameter scale gives the 1e5-1e6 on-chain range")
check(bool(scale) and all(re.search(r"\[待证据\]|grade\s*[A-DX]\b|证据\s*[A-DX]\b|\|\s*[A-DX][ ,|]|\(\s*[A-DX][,)]", l) for l in scale),
      "every 1e5-1e6 line carries an evidence grade or [待证据]")
check(re.search(r"^\|.*\|\s*$", "\n".join(l for l in norm.splitlines() if re.search(r"param|参数", l, re.I)), re.M) is not None,
      "zkML parameter scale is a table")
check(re.search(r"x402", norm) is not None, "agent economy at the consumer side mentions x402 as roadmap")
check("46.653" not in norm and not re.search(r"placeholder heuristic", norm, re.I), "stale commit-only placeholder figure is gone")
check(re.search(r"Reproducible[^\n]*\(implemented", norm) is not None, "tiered verification lists reproducible as implemented")

for a in ("agent-linear_abs", "agent-mlp32_abs", "agent-mlp16"):
    v = f"{agents[a]['total_log_score']:.1f}"
    check(v in norm, f"kept fact: {a} total {v} still quoted")
check(re.search(r"0 void|0 作废", norm) is not None and "24" in norm, "kept fact: 24 rounds, 0 voided still stated")
check(re.search(r"Synth", norm) is not None, "kept fact: the Synth comparison is still there")

plan = open("docs/PLAN.md", encoding="utf-8").read()
check("- [ ]" not in plan, "docs/PLAN.md has no unticked item (phases 2 and 3 done)")

print("PASS" if not fail else "FAIL")
sys.exit(fail)
EOF
