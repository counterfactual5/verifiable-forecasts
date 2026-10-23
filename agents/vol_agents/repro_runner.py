"""Pinned Chronos-Bolt inference for the reproducible agent, run as a script by the interpreter in
VOL_REPRO_PYTHON (chronos-forecasting and torch), not by the agents environment.

Protocol: one JSON request on stdin ({"features": [16 contract features], ...}), one JSON line on
stdout ({"levels": [...], "values": [...]}, quantiles of the next hour's realized vol in tick^2).
Any error exits non-zero with a message on stderr.

The model input is the series of squared segment-mean tick differences d_j^2 (d_j = f_j // 128,
the contract's feature scale); realized vol is the sum of the next nSegments - 1 of them. The
bytes of this file are part of the registered model hash, so changing it changes the model.
"""

import contextlib
import json
import os
import sys
from pathlib import Path

MODEL_REPO = "amazon/chronos-bolt-tiny"
MODEL_REVISION = "a0e552de83495b5c28c14c71c374f3e33280b340"
QUANTILE_LEVELS = (0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9)
PREDICTION_LENGTH = 11  # nSegments - 1 differences make up one window's realized vol
N_FEATURES = 16
# contract features are clamped tick differences times 128 (contract_math.MULT)
FEATURE_MULT = 128


def hub_cache() -> Path:
    if os.environ.get("HF_HUB_CACHE"):
        return Path(os.environ["HF_HUB_CACHE"])
    if os.environ.get("HF_HOME"):
        return Path(os.environ["HF_HOME"]) / "hub"
    return Path.home() / ".cache" / "huggingface" / "hub"


def snapshot_dir() -> Path:
    return (hub_cache() / f"models--{MODEL_REPO.replace('/', '--')}" / "snapshots"
            / MODEL_REVISION)


def artifact_paths() -> tuple[Path, Path]:
    """(weights, config.json) of the pinned snapshot; raises if it was not downloaded."""
    d = snapshot_dir()
    weights, config = d / "model.safetensors", d / "config.json"
    for p in (weights, config):
        if not p.is_file():
            raise FileNotFoundError(f"{p} missing: download {MODEL_REPO}@{MODEL_REVISION} first")
    return weights, config


def series_from_features(features) -> list[int]:
    if len(features) != N_FEATURES:
        raise ValueError(f"need {N_FEATURES} features, got {len(features)}")
    return [(int(f) // FEATURE_MULT) ** 2 for f in features]


def predict(features) -> dict:
    os.environ["HF_HUB_OFFLINE"] = "1"
    import torch
    from chronos import BaseChronosPipeline

    torch.set_num_threads(1)
    torch.use_deterministic_algorithms(True)
    artifact_paths()
    pipe = BaseChronosPipeline.from_pretrained(
        str(snapshot_dir()), device_map="cpu", torch_dtype=torch.float32)
    context = torch.tensor([series_from_features(features)], dtype=torch.float32)
    with torch.no_grad():
        q, _ = pipe.predict_quantiles(context, prediction_length=PREDICTION_LENGTH,
                                      quantile_levels=list(QUANTILE_LEVELS))
    steps = q[0].tolist()  # [PREDICTION_LENGTH][len(QUANTILE_LEVELS)]
    # Summing per-step quantiles is only an approximation of the quantiles of the sum: quantiles
    # are not additive. A squared difference is never negative, so each step is clamped first.
    values = [sum(max(step[i], 0.0) for step in steps) for i in range(len(QUANTILE_LEVELS))]
    # bucket probabilities need non-decreasing quantiles; crossing ones are rearranged upward
    for i in range(1, len(values)):
        values[i] = max(values[i], values[i - 1])
    return {"levels": list(QUANTILE_LEVELS), "values": values}


def check_request(req: dict):
    if req.get("prediction_length", PREDICTION_LENGTH) != PREDICTION_LENGTH:
        raise ValueError(f"runner predicts {PREDICTION_LENGTH} steps")
    if list(req.get("quantile_levels", QUANTILE_LEVELS)) != list(QUANTILE_LEVELS):
        raise ValueError(f"runner answers quantile levels {list(QUANTILE_LEVELS)}")


def main():
    try:
        req = json.loads(sys.stdin.read())
        check_request(req)
        # stdout carries only the answer line; library chatter goes to stderr
        with contextlib.redirect_stdout(sys.stderr):
            out = predict(req["features"])
    except Exception as e:
        print(f"repro_runner: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
