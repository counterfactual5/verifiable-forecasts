"""Recompute a reproducible agent's reveal from chain data and the public weights, on CPU, without
the inference service.

Online:  uv run python -m vol_agents.tsfm_recompute --model chronos-2 --rpc-url URL
           --market ADDR --round N --model-id M [--logs-rpc-url MAINNET_URL]
  checks the onchain modelHash(M) against tsfm_forecast.model_hash(model), rebuilds the model's
  context from chain data (the round's 16 features; for a long-context model the 512-point series
  from the pool's Swap logs, read from --logs-rpc-url, default $MAINNET_RPC_URL or the public
  gateway), runs the public weights (tsfm_local.py under VOL_REPRO_PYTHON), applies the same
  post-processing and quantization and compares the K quantiles (1e18 ln units) with the reveal
  of modelOperator(M). Prints a JSON summary with the largest per-quantile difference and a
  verdict: "exact" (same integers), "tolerant" (every quantile within
  tsfm_forecast.RECOMPUTE_TOLERANCE_E18) or "fail"; exit 0 unless "fail".
Offline: uv run python -m vol_agents.tsfm_recompute --model timesfm-3.0 --features=f1,...,f16
  prints the reveal outputs (2^-12 grid) of the 16-feature context.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from . import contract_math as cm
from . import history
from . import tsfm_forecast as sf
from .api_agent import ROUND_SIG
from .chain import Rpc, as_int
from .swap_logs import SwapLogs, round_context_from_chain

LOCAL_RUNNER = Path(__file__).resolve().parent / "tsfm_local.py"
PREDICTION_SIG = "getPrediction(uint256,address)(bool,uint256,int256[],int256)"
EXIT_MISMATCH, EXIT_ERROR = 1, 2
DEFAULT_LOGS_RPC = "https://mainnet.gateway.tenderly.co"


def local_step_quantiles(model: str, diffs, n_segments: int, python=None) -> dict:
    python = python or os.environ.get("VOL_REPRO_PYTHON")
    if not python:
        raise RuntimeError("VOL_REPRO_PYTHON is unset: it must name an interpreter with torch "
                           "and the model's runtime")
    req = {"model": model, "weights": sf.spec(model).weights, "context": list(diffs),
           "h": sf.horizon(n_segments)}
    r = subprocess.run([python, str(LOCAL_RUNNER)], input=json.dumps(req), capture_output=True,
                       text=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError(f"tsfm_local failed (exit {r.returncode}): {r.stderr[-2000:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def recompute_outputs(model: str, ctx: history.Context, n_segments=cm.N_SEGMENTS,
                      python=None) -> list[int]:
    """The reveal outputs (2^-12 grid) the public weights give for ctx."""
    q = local_step_quantiles(model, ctx.diffs, n_segments, python)
    return sf.quantize_reveal(sf.ln_quantiles(q["levels"], q["steps"], n_segments, model,
                                              ctx.source))


def candidate_contexts(model: str, features, start: int, delta: int, logs: SwapLogs | None,
                       pool: str | None) -> list[history.Context]:
    """What the agent may have sent, in order: for a long-context model the series rebuilt from
    the pool's Swap logs, then the 16 onchain differences it falls back to when its own cache
    could not provide that series; otherwise only the 16. Both are functions of chain data."""
    onchain = history.Context(sf.context(features), sf.ONCHAIN)
    if not sf.spec(model).long_context:
        return [onchain]
    rebuilt = round_context_from_chain(logs, pool, features, start, delta)
    return [rebuilt, onchain] if rebuilt.source == sf.SWAPS else [onchain]


def verify(model, revealed_e18, contexts, n_segments, python=None) -> dict:
    """The first context whose recompute matches the reveal (quantiles in 1e18 ln units, as
    getPrediction returns them) within tolerance, else the closest."""
    tried = []
    for ctx in contexts:
        out = cm.outputs_to_e18(recompute_outputs(model, ctx, n_segments, python))
        diff, verdict = sf.compare_reveal(revealed_e18, out)
        tried.append({"contextSource": ctx.source, "contextPoints": len(ctx.diffs),
                      "recomputed": out, "maxAbsDiff": diff, "verdict": verdict})
        if verdict != sf.FAIL:
            break
    best = min(tried, key=lambda t: t["maxAbsDiff"])
    return {**best, "tried": [{k: t[k] for k in ("contextSource", "maxAbsDiff", "verdict")}
                              for t in tried]}


def recompute_online(model, rpc_url, market, round_id, model_id, logs_rpc_url=None) -> int:
    chain = Rpc(rpc_url)
    onchain = chain.call(market, "modelHash(uint256)(bytes32)", model_id)[0]
    local = sf.model_hash(model)
    if onchain.lower() != local.lower():
        print(f"model hash mismatch: onchain {onchain}, local {local}", file=sys.stderr)
        return EXIT_MISMATCH
    operator = chain.call(market, "modelOperator(uint256)(address)", model_id)[0]
    rec = chain.call(market, PREDICTION_SIG, round_id, operator)
    if rec[0] not in (True, "true") or as_int(rec[1]) != model_id:
        print(f"no revealed prediction of model {model_id} in round {round_id}", file=sys.stderr)
        return EXIT_MISMATCH
    revealed = [as_int(v) for v in rec[2]]
    feats = [as_int(v) for v in chain.call(market, "getFeatures(uint256)(int256[16])",
                                           round_id)[0]]
    levels = [as_int(v) for v in chain.call(market, "quantileLevels()(uint256[])")[0]]
    bits = as_int(chain.call(market, "outputScaleBits()(uint8)")[0])
    if levels != list(cm.QUANTILE_LEVELS_E18) or bits != cm.OUTPUT_SCALE_BITS:
        print(f"market quantile levels {levels} / scale bits {bits} differ from the model's",
              file=sys.stderr)
        return EXIT_MISMATCH
    r = chain.call(market, ROUND_SIG, round_id)
    start = as_int(r[0])
    n = as_int(chain.call(market, "nSegments()(uint8)")[0])
    delta = as_int(chain.call(market, "delta()(uint32)")[0])
    pool = chain.call(market, "pool()(address)")[0]
    logs = SwapLogs(logs_rpc_url or os.environ.get("MAINNET_RPC_URL") or DEFAULT_LOGS_RPC)
    result = verify(model, revealed, candidate_contexts(model, feats, start, delta, logs, pool), n)
    print(json.dumps({"model": model, "weights": sf.spec(model).weights, "market": market,
                      "round": round_id, "modelId": model_id, "modelHash": onchain,
                      "revealed": revealed, "tolerance": sf.RECOMPUTE_TOLERANCE_E18, **result}))
    return 0 if result["verdict"] != sf.FAIL else EXIT_MISMATCH


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="python -m vol_agents.tsfm_recompute", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", required=True)
    p.add_argument("--rpc-url")
    p.add_argument("--logs-rpc-url")
    p.add_argument("--market")
    p.add_argument("--round", type=int)
    p.add_argument("--model-id", type=int)
    p.add_argument("--features", type=lambda s: [int(v) for v in s.split(",") if v.strip()])
    a = p.parse_args(argv)
    try:
        if a.rpc_url:
            if a.market is None or a.round is None or a.model_id is None:
                p.error("online mode needs --market, --round and --model-id")
            return recompute_online(a.model, a.rpc_url, a.market, a.round, a.model_id,
                                    a.logs_rpc_url)
        if a.features is None:
            p.error("offline mode needs --features")
        ctx = history.Context(sf.context(a.features), sf.ONCHAIN)
        print(json.dumps(recompute_outputs(a.model, ctx)))
        return 0
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        print(f"tsfm_recompute: {e}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
