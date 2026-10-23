"""Recompute a reproducible agent's reveal from onchain data and the pinned model.

Online:  uv run python -m vol_agents.recompute --rpc-url URL --market ADDR --round N --model-id M
  checks the onchain modelHash(M) against the local snapshot and runner, re-runs the runner on the
  round's onchain features and bounds, and compares the 5 quantized outputs with the reveal of
  modelOperator(M). Prints a JSON summary; exit 0 only when every bucket matches.
Offline: uv run python -m vol_agents.recompute --features=f1,...,f16 --bounds=b1,...,b4
         (or --input FILE with {"features": [...], "bounds": [...]}) prints the 1e18 vector.
Negative values need the --features=... form. A runner failure exits non-zero, never a fallback.
"""

import argparse
import json
import sys

from . import repro_agent as ra
from .chain import Rpc, as_int

PREDICTION_SIG = "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)"
EXIT_MISMATCH = 1
EXIT_ERROR = 2


def _ints(text: str) -> list[int]:
    return [int(v) for v in text.split(",") if v.strip()]


def recompute_online(rpc_url: str, market: str, round_id: int, model_id: int) -> int:
    chain = Rpc(rpc_url)
    onchain_hash = chain.call(market, "modelHash(uint256)(bytes32)", model_id)[0]
    local_hash = ra.local_model_hash()
    if onchain_hash.lower() != local_hash.lower():
        print(f"model hash mismatch: onchain {onchain_hash}, local {local_hash}", file=sys.stderr)
        return EXIT_MISMATCH
    operator = chain.call(market, "modelOperator(uint256)(address)", model_id)[0]
    rec = chain.call(market, PREDICTION_SIG, round_id, operator)
    if rec[0] not in (True, "true") or as_int(rec[1]) != model_id:
        print(f"no revealed prediction of model {model_id} by {operator} in round {round_id}",
              file=sys.stderr)
        return EXIT_MISMATCH
    revealed = [as_int(v) for v in rec[2]]
    feats, bounds = ra.round_inputs(chain, market, round_id)
    recomputed = ra.forecast(feats, bounds)["outputs"]
    differ = [i for i, (a, b) in enumerate(zip(revealed, recomputed, strict=True)) if a != b]
    tier = as_int(chain.call(market, "verificationTier(uint256)(uint8)", model_id)[0])
    print(json.dumps({
        "market": market, "round": round_id, "modelId": model_id, "operator": operator,
        "modelHash": onchain_hash, "verificationTier": tier, "features": feats,
        "bounds": bounds, "revealed": revealed, "recomputed": recomputed,
        "mismatchedBuckets": differ, "match": not differ,
    }))
    return 0 if not differ else EXIT_MISMATCH


def recompute_offline(features, bounds) -> int:
    print(json.dumps(ra.forecast(features, bounds)["outputs"]))
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="python -m vol_agents.recompute", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--rpc-url")
    p.add_argument("--market")
    p.add_argument("--round", type=int)
    p.add_argument("--model-id", type=int)
    p.add_argument("--features", type=_ints)
    p.add_argument("--bounds", type=_ints)
    p.add_argument("--input", help='JSON file {"features": [...], "bounds": [...]}')
    a = p.parse_args(argv)
    try:
        if a.rpc_url:
            if a.market is None or a.round is None or a.model_id is None:
                p.error("online mode needs --market, --round and --model-id")
            return recompute_online(a.rpc_url, a.market, a.round, a.model_id)
        if a.input:
            with open(a.input) as f:
                data = json.load(f)
            return recompute_offline(data["features"], data["bounds"])
        if a.features is None or a.bounds is None:
            p.error("give --rpc-url ... (online) or --features and --bounds / --input (offline)")
        return recompute_offline(a.features, a.bounds)
    except (RuntimeError, ValueError, OSError, KeyError) as e:
        print(f"recompute failed: {e}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
