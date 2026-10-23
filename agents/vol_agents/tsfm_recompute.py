"""Recompute a reproducible inference agent's reveal from onchain data and the public weights, on CPU,
without the API.

Online:  uv run python -m vol_agents.tsfm_recompute --model timesfm-3.0 --rpc-url URL
           --market ADDR --round N --model-id M
  checks the onchain modelHash(M) against tsfm_forecast.model_hash(model), runs the public
  weights (tsfm_local.py under VOL_REPRO_PYTHON) on the round's onchain features, applies the
  same post-processing and compares the 5 outputs with the reveal of modelOperator(M). Prints a
  JSON summary; exit 0 only when every bucket matches.
Offline: uv run python -m vol_agents.tsfm_recompute --model timesfm-3.0
           --features=f1,...,f16 --bounds=b1,...,b4   prints the 1e18 vector.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

from . import contract_math as cm
from . import tsfm_forecast as sf
from .api_agent import ROUND_SIG, quantize
from .chain import Rpc, as_int

LOCAL_RUNNER = Path(__file__).resolve().parent / "tsfm_local.py"
PREDICTION_SIG = "getPrediction(uint256,address)(bool,uint256,uint256[5],int256)"
EXIT_MISMATCH, EXIT_ERROR = 1, 2


def local_step_quantiles(model: str, features, n_segments: int, python=None) -> dict:
    python = python or os.environ.get("VOL_REPRO_PYTHON")
    if not python:
        raise RuntimeError("VOL_REPRO_PYTHON is unset: it must name an interpreter with torch "
                           "and the model's runtime")
    req = {"model": model, "weights": sf.spec(model).weights, "context": sf.context(features),
           "h": sf.horizon(n_segments)}
    r = subprocess.run([python, str(LOCAL_RUNNER)], input=json.dumps(req), capture_output=True,
                       text=True, timeout=600)
    if r.returncode != 0:
        raise RuntimeError(f"tsfm_local failed (exit {r.returncode}): {r.stderr[-2000:]}")
    return json.loads(r.stdout.strip().splitlines()[-1])


def recompute_outputs(model: str, features, bounds, n_segments=cm.N_SEGMENTS, python=None):
    q = local_step_quantiles(model, features, n_segments, python)
    return quantize(sf.probs(q["levels"], q["steps"], bounds, n_segments, model))


def recompute_online(model, rpc_url, market, round_id, model_id) -> int:
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
    bounds = [as_int(b) for b in chain.call(market, ROUND_SIG, round_id)[7]]
    n = as_int(chain.call(market, "nSegments()(uint8)")[0])
    recomputed = recompute_outputs(model, feats, bounds, n)
    differ = [i for i, (a, b) in enumerate(zip(revealed, recomputed, strict=True)) if a != b]
    print(json.dumps({"model": model, "weights": sf.spec(model).weights, "market": market,
                      "round": round_id, "modelId": model_id, "modelHash": onchain,
                      "revealed": revealed, "recomputed": recomputed,
                      "mismatchedBuckets": differ, "match": not differ}))
    return 0 if not differ else EXIT_MISMATCH


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="python -m vol_agents.tsfm_recompute", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--model", required=True)
    p.add_argument("--rpc-url")
    p.add_argument("--market")
    p.add_argument("--round", type=int)
    p.add_argument("--model-id", type=int)
    p.add_argument("--features", type=lambda s: [int(v) for v in s.split(",") if v.strip()])
    p.add_argument("--bounds", type=lambda s: [int(v) for v in s.split(",") if v.strip()])
    a = p.parse_args(argv)
    try:
        if a.rpc_url:
            if a.market is None or a.round is None or a.model_id is None:
                p.error("online mode needs --market, --round and --model-id")
            return recompute_online(a.model, a.rpc_url, a.market, a.round, a.model_id)
        if a.features is None or a.bounds is None:
            p.error("offline mode needs --features and --bounds")
        print(json.dumps(recompute_outputs(a.model, a.features, a.bounds)))
        return 0
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as e:
        print(f"tsfm_recompute: {e}", file=sys.stderr)
        return EXIT_ERROR


if __name__ == "__main__":
    sys.exit(main())
