"""One EZKL step for one model, in its own process so `/usr/bin/time -l` reports its peak memory.

Usage: uv run python -m vol_agents.ezkl_step <model> <step> [--work DIR]
Build steps (artifacts in out/<model>/): settings calibrate compile setup evm
Proof steps (per-round files in --work): witness prove verify

Every circuit pins input_scale = 12 (the contract's feature scale 4096), public inputs and outputs,
and fixed params, so the proof's public inputs are exactly the contract-encoded round features.
"""

import argparse
import asyncio
import inspect
import json
import time
from pathlib import Path

import ezkl

from .contract_math import OUTPUT_SCALE_BITS

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "out"
SRS = OUT / "kzg15.srs"
INPUT_SCALE = 12
MAX_LOGROWS = 15


def run(fn, *args, **kwargs):
    """Call an ezkl binding inside an event loop.

    Some bindings return awaitables, some need a running loop.
    """

    async def call():
        r = fn(*args, **kwargs)
        return await r if inspect.isawaitable(r) else r

    return asyncio.run(call())


def paths(model):
    d = OUT / model
    return {
        "onnx": ROOT / "models" / model / "model.onnx",
        "cal": ROOT / "models" / model / "cal.json",
        "settings": d / "settings.json",
        "compiled": d / "model.compiled",
        "vk": d / "vk.key",
        "pk": d / "pk.key",
        "sol": d / "Verifier.sol",
        "abi": d / "verifier_abi.json",
    }


def step(model, name, work=None):
    p = {k: str(v) for k, v in paths(model).items()}
    srs = str(SRS)
    if name == "settings":
        ra = ezkl.PyRunArgs()
        ra.input_visibility = "public"
        ra.output_visibility = "public"
        ra.param_visibility = "fixed"
        ra.input_scale = INPUT_SCALE
        ra.param_scale = INPUT_SCALE
        ra.logrows = MAX_LOGROWS
        assert run(ezkl.gen_settings, p["onnx"], p["settings"], py_run_args=ra)
    elif name == "calibrate":
        assert run(
            ezkl.calibrate_settings, p["cal"], p["onnx"], p["settings"], "resources",
            scales=[INPUT_SCALE], max_logrows=MAX_LOGROWS,
        )
        s = json.loads(Path(p["settings"]).read_text())
        ra = s["run_args"]
        if ra["input_scale"] != INPUT_SCALE or ra["logrows"] > MAX_LOGROWS:
            raise SystemExit(f"calibration moved input_scale/logrows: {ra}")
        # VolMarket reads outputs at 2^outputScaleBits; another output scale would misprice them
        if s["model_output_scales"] != [OUTPUT_SCALE_BITS]:
            raise SystemExit(f"output scales {s['model_output_scales']} != [{OUTPUT_SCALE_BITS}]")
    elif name == "compile":
        assert run(ezkl.compile_circuit, p["onnx"], p["compiled"], p["settings"])
    elif name == "setup":
        assert run(ezkl.setup, p["compiled"], p["vk"], p["pk"], srs)
    elif name == "evm":
        assert run(ezkl.create_evm_verifier, p["vk"], p["settings"], p["sol"], p["abi"], srs)
    elif name in ("witness", "prove", "verify"):
        w = Path(work)
        if name == "witness":
            run(ezkl.gen_witness, str(w / "input.json"), p["compiled"], str(w / "witness.json"),
                p["vk"], srs)
        elif name == "prove":
            run(
                ezkl.prove,
                str(w / "witness.json"),
                p["compiled"],
                p["pk"],
                str(w / "proof.json"),
                srs,
            )
        elif not run(ezkl.verify, str(w / "proof.json"), p["settings"], p["vk"], srs):
            raise SystemExit("verify failed")
    else:
        raise SystemExit(f"unknown step {name}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("step")
    ap.add_argument("--work")
    a = ap.parse_args()
    t0 = time.time()
    step(a.model, a.step, a.work)
    print(f"[{a.model}:{a.step}] {time.time() - t0:.2f}s")


if __name__ == "__main__":
    main()
