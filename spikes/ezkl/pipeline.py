"""Run one EZKL pipeline step. Each step is a separate process so that
`/usr/bin/time -l` reports per-step peak memory.

Usage: uv run python pipeline.py <step> [--variant fixed|hashed] [--logits]
Steps: settings calibrate compile srs setup witness prove verify evm vka calldata
"""
import argparse
import asyncio
import inspect
import json
import os
import time

import ezkl

p = argparse.ArgumentParser()
p.add_argument("step")
p.add_argument("--variant", default="fixed", choices=["fixed", "hashed"])
p.add_argument("--logits", action="store_true")
a = p.parse_args()

model = "model_logits.onnx" if a.logits else "model.onnx"
d = f"out/{a.variant}{'_logits' if a.logits else ''}"
os.makedirs(d, exist_ok=True)
P = lambda n: os.path.join(d, n)  # noqa: E731
SRS = None  # ezkl caches SRS under ~/.ezkl/srs when None; we pin a local path below


def run(r):
    return asyncio.run(_await(r)) if inspect.isawaitable(r) else r


async def _await(r):
    return await r if inspect.isawaitable(r) else r


def srs_path():
    logrows = json.load(open(P("settings.json")))["run_args"]["logrows"]
    return os.path.abspath(f"out/kzg{logrows}.srs")


async def _call(fn, *args):
    return await _await(fn(*args))


async def _srs(sp):
    return await _await(ezkl.get_srs(P("settings.json"), srs_path=sp))


t0 = time.time()
s = a.step
if s == "settings":
    ra = ezkl.PyRunArgs()
    ra.input_visibility = "public"
    ra.output_visibility = "public"
    ra.param_visibility = a.variant
    print(run(ezkl.gen_settings(model, P("settings.json"), py_run_args=ra)))
elif s == "calibrate":
    print(run(ezkl.calibrate_settings("cal.json", model, P("settings.json"), "resources")))
elif s == "compile":
    print(run(ezkl.compile_circuit(model, P("model.compiled"), P("settings.json"))))
elif s == "srs":
    sp = srs_path()
    if not os.path.exists(sp):
        print(asyncio.run(_srs(sp)))
    print(sp)
elif s == "setup":
    print(run(ezkl.setup(P("model.compiled"), P("vk.key"), P("pk.key"), srs_path())))
elif s == "witness":
    w = run(ezkl.gen_witness("input.json", P("model.compiled"), P("witness.json"), P("vk.key"), srs_path()))
    json.dump(w, open(P("witness_ret.json"), "w"))
elif s == "prove":
    print(run(ezkl.prove(P("witness.json"), P("model.compiled"), P("pk.key"), P("proof.json"), srs_path())) is not None)
elif s == "verify":
    print("verify:", run(ezkl.verify(P("proof.json"), P("settings.json"), P("vk.key"), srs_path())))
elif s == "evm":
    reusable = os.environ.get("REUSABLE") == "1"
    sol = P("VerifierReusable.sol" if reusable else "Verifier.sol")
    print(asyncio.run(_call(ezkl.create_evm_verifier, P("vk.key"), P("settings.json"), sol, P("verifier_abi.json"), srs_path(), reusable)))
elif s == "vka":
    print(asyncio.run(_call(ezkl.create_evm_vka, P("vk.key"), P("settings.json"), P("vka.bytes"), srs_path())))
elif s == "calldata":
    addr_vk = os.environ.get("ADDR_VK")
    cd = run(ezkl.encode_evm_calldata(P("proof.json"), P("calldata.bin"), addr_vk))
    print("calldata bytes:", len(cd))
else:
    raise SystemExit(f"unknown step {s}")
print(f"[{s}] {time.time() - t0:.2f}s")
