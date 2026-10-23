"""Local CPU inference with the public weights of a self-hosted model, for recomputing a reveal.
Run as a script by the interpreter in VOL_REPRO_PYTHON (torch, timesfm 3.0.2, chronos-forecasting
2.x, timestral 1.0), not by the agents environment; weights are read offline from the Hugging
Face cache.

Protocol: one JSON request on stdin ({"model": id, "weights": "repo@rev", "context": [ticks],
"h": steps}), one JSON line
on stdout ({"levels": [...], "steps": [h][levels]}). Errors exit non-zero with stderr.
"""

import contextlib
import json
import os
import sys
from pathlib import Path

CHRONOS2_LEVELS = [0.01, 0.05] + [round(0.1 + 0.05 * i, 2) for i in range(17)] + [0.95, 0.99]
DECILES = [round(0.1 * i, 1) for i in range(1, 10)]


def snapshot(weights: str) -> Path:
    repo, rev = weights.split("@")
    hub = (Path(os.environ["HF_HUB_CACHE"]) if os.environ.get("HF_HUB_CACHE")
           else Path(os.environ.get("HF_HOME", Path.home() / ".cache" / "huggingface")) / "hub")
    d = hub / f"models--{repo.replace('/', '--')}" / "snapshots" / rev
    if not d.is_dir():
        raise FileNotFoundError(f"{d} missing: download {weights} first")
    return d


def predict(model: str, weights: str, ctx: list[float], h: int) -> dict:
    os.environ["HF_HUB_OFFLINE"] = "1"
    import numpy as np
    import torch

    torch.use_deterministic_algorithms(True)
    if model == "timesfm-3.0":
        from timesfm3 import ModelConfig, TimesFM3Evaluator

        ev = TimesFM3Evaluator(ModelConfig(checkpoint_path=str(snapshot(weights)),
                                           per_core_batch_size=32, device="cpu"))
        out = list(ev.predict_batch([np.asarray(ctx, np.float32)], horizon=h,
                                    return_quantiles=True, use_symmetric_averaging=False))[0]
        return {"levels": DECILES, "steps": np.asarray(out.quantiles, float).tolist()}
    if model == "chronos-2":
        from chronos import BaseChronosPipeline

        pipe = BaseChronosPipeline.from_pretrained(str(snapshot(weights)), device_map="cpu",
                                                   torch_dtype=torch.float32)
        with torch.no_grad():
            q, _ = pipe.predict_quantiles([torch.tensor(ctx, dtype=torch.float32)],
                                          prediction_length=h, quantile_levels=CHRONOS2_LEVELS)
        q = q[0] if isinstance(q, list) else q
        return {"levels": CHRONOS2_LEVELS, "steps": q.reshape(h, len(CHRONOS2_LEVELS)).tolist()}
    if model == "timestral-209m":
        from timestral import TimestralForecaster

        fc = TimestralForecaster.from_pretrained(str(snapshot(weights)), device="cpu")
        # the inference service averages with the mirrored forecast; without it reveals differ
        out = fc.forecast(np.asarray(ctx, np.float32), h, symmetric_averaging=True)
        return {"levels": list(fc.quantile_levels), "steps": out.quantiles[0, 0].tolist()}
    raise ValueError(f"no local runtime for {model}")


def main():
    try:
        req = json.loads(sys.stdin.read())
        with contextlib.redirect_stdout(sys.stderr):
            out = predict(req["model"], req["weights"], [float(v) for v in req["context"]],
                          int(req["h"]))
    except Exception as e:
        print(f"tsfm_local: {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(out))


if __name__ == "__main__":
    main()
