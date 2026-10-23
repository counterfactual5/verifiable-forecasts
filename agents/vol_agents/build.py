"""Idempotent EZKL build per model: settings -> calibrate -> compile -> setup -> evm verifier, then
copy the verifier into contracts/src/verifier/<Name>Verifier.sol (only the contract name and header
comment change). Artifacts live in out/<model>/ and are reused while model.onnx is unchanged.

EZKL's settings list range checks in hash-map order, so two calibrations of the same model can give
different circuits and verifiers. The calibrated settings are therefore pinned next to the model
(models/<model>/settings.json, valid while meta.json's onnx_sha256 matches) and later builds compile
from them; with fixed settings compile -> setup -> evm reproduces the committed verifier exactly.

The KZG SRS (logrows 15) must match SRS_SHA256: the verifier's soundness rests on it, so a file with
another digest is rejected wherever it comes from. A committed verifier that the build would change
is only overwritten with --force.

Usage: uv run python -m vol_agents.build [--srs PATH] [--force] [model ...]
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

from .ezkl_step import OUT, ROOT, SRS, paths

REPO = ROOT.parent
VERIFIER_DIR = REPO / "contracts" / "src" / "verifier"
SRS_ENV = "VOL_AGENTS_SRS"
# kzg15.srs as served by ezkl.get_srs (EZKL 23.0.5, logrows 15), 4,194,564 bytes; the committed
# verifiers were built from this file.
SRS_SHA256 = "90807800a1c3b248a452e1732c45ee5099f38b737356f5542c0584ec9c3ebb45"
BUILD_STEPS = ["settings", "calibrate", "compile", "setup", "evm"]
STEP_LIMIT_S = 15 * 60


def model_names():
    return sorted(p.parent.name for p in (ROOT / "models").glob("*/model.onnx"))


def verifier_name(model):
    return "".join(part.capitalize() for part in model.split("_")) + "Verifier"


def peak_mb(time_stderr):
    """Peak RSS from /usr/bin/time: BSD `-l` reports bytes, GNU `-v` kilobytes."""
    if m := re.search(r"(\d+)\s+maximum resident set size", time_stderr):
        return round(int(m.group(1)) / 2**20, 1)
    if m := re.search(r"Maximum resident set size \(kbytes\): (\d+)", time_stderr):
        return round(int(m.group(1)) / 2**10, 1)
    return None


def run_step(model, step, work=None):
    """Run one EZKL step under /usr/bin/time; returns {seconds, peak_mb}."""
    flag = "-l" if sys.platform == "darwin" else "-v"
    cmd = ["/usr/bin/time", flag, sys.executable, "-m", "vol_agents.ezkl_step", model, step]
    if work:
        cmd += ["--work", str(work)]
    t0 = time.time()
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=STEP_LIMIT_S)
    secs = time.time() - t0
    if r.returncode != 0:
        raise RuntimeError(f"ezkl {model}:{step} failed\n{r.stdout[-2000:]}\n{r.stderr[-4000:]}")
    rec = {"model": model, "step": step, "seconds": round(secs, 2),
           "peak_mb": peak_mb(r.stderr)}
    log = OUT / model / "timing.jsonl"
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open("a") as f:
        f.write(json.dumps(rec) + "\n")
    return rec


class SrsMismatch(RuntimeError):
    pass


class VerifierChanged(RuntimeError):
    pass


def check_srs(path):
    digest = _sha(path)
    if digest != SRS_SHA256:
        raise SrsMismatch(f"{path}: sha256 {digest}, expected {SRS_SHA256}")


def ensure_srs(source=None):
    """Put a digest-checked SRS at SRS: keep a valid one, else copy `source` (or $VOL_AGENTS_SRS),
    else download it with ezkl.get_srs."""
    if SRS.exists():
        check_srs(SRS)
        return
    OUT.mkdir(parents=True, exist_ok=True)
    source = source or os.environ.get(SRS_ENV)
    if source:
        check_srs(source)
        shutil.copyfile(source, SRS)
        return
    import ezkl

    from .ezkl_step import run

    settings = next(OUT.glob("*/settings.json"))
    run(ezkl.get_srs, str(settings), srs_path=str(SRS))
    try:
        check_srs(SRS)
    except SrsMismatch:
        SRS.unlink()
        raise


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(model, force=False, srs=None):
    p = paths(model)
    d = OUT / model
    d.mkdir(parents=True, exist_ok=True)
    stamp = d / "model.sha256"
    digest = _sha(p["onnx"])
    if not stamp.exists() or stamp.read_text().strip() != digest:
        for k in ("settings", "compiled", "vk", "pk", "sol", "abi"):
            p[k].unlink(missing_ok=True)
        stamp.write_text(digest + "\n")
    if not p["cal"].exists():
        raise SystemExit(f"{p['cal']} missing: run `uv run python -m vol_agents.train` first")
    outputs = {"settings": p["settings"], "calibrate": p["settings"], "compile": p["compiled"],
               "setup": p["pk"], "evm": p["sol"]}
    done = d / "steps_done.json"
    have = set(json.loads(done.read_text())) if done.exists() and p["settings"].exists() else set()
    pinned = p["onnx"].parent / "settings.json"
    meta = json.loads((p["onnx"].parent / "meta.json").read_text())
    pinned_ok = pinned.exists() and meta.get("onnx_sha256") == digest
    if pinned_ok and not p["settings"].exists():
        shutil.copyfile(pinned, p["settings"])
        have = {"settings", "calibrate"}
    for step in BUILD_STEPS:
        if step == "setup":
            ensure_srs(srs)
        if step in have and outputs[step].exists():
            continue
        print(run_step(model, step))
        have.add(step)
        done.write_text(json.dumps(sorted(have)))
    if not pinned_ok and meta.get("onnx_sha256") == digest:
        shutil.copyfile(p["settings"], pinned)
    return install_verifier(model, force)


def install_verifier(model, force=False):
    name = verifier_name(model)
    src = paths(model)["sol"].read_text()
    body = src.replace("contract Halo2Verifier {", f"contract {name} {{", 1)
    assert body != src, "unexpected EZKL verifier layout"
    body = body.replace(
        "// SPDX-License-Identifier: MIT\n",
        "// SPDX-License-Identifier: MIT\n"
        f"// Generated by EZKL (Halo2 verifier); source: agents/out/{model}/Verifier.sol "
        f"(agents/models/{model}/model.onnx). Only the contract name was changed.\n",
        1,
    )
    dest = VERIFIER_DIR / f"{name}.sol"
    if dest.exists() and dest.read_text() == body:
        return dest
    if dest.exists() and not force:
        raise VerifierChanged(
            f"{dest} differs from the freshly built verifier; rerun with --force to replace it")
    dest.write_text(body)
    return dest


def main():
    ap = argparse.ArgumentParser(prog="vol_agents.build")
    ap.add_argument("models", nargs="*")
    ap.add_argument("--srs", help=f"kzg15.srs to copy into out/ (default ${SRS_ENV}, or download)")
    ap.add_argument("--force", action="store_true", help="replace committed verifiers that differ")
    a = ap.parse_args()
    for m in a.models or model_names():
        print(m, "->", build(m, force=a.force, srs=a.srs))


if __name__ == "__main__":
    main()
