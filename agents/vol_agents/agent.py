"""Forecasting agents enter a VolMarket round in two steps: commit a hash of the forecast while
commits are open, then reveal it once they close. `Agent` runs its model inside EZKL, checks that
the witness public inputs equal the contract's encoding and proves; its reveal carries the proof.
Commit-only agents (`api_agent.ApiAgent`) share the commit/reveal steps and reveal without a proof.
"""

import hashlib
import json
import secrets
import shutil
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import onnxruntime as ort

from . import contract_math as cm
from .build import run_step
from .chain import Anvil, as_int, keccak
from .ezkl_step import OUT, ROOT

COMMIT_SIG = "commitPrediction(uint256,uint256,bytes32)"
REVEAL_SIG = "revealPrediction(uint256,bytes,uint256[5],bytes32)"


@dataclass
class Forecaster:
    name: str
    key: str
    address: str
    model_id: int | None = None
    timings: dict = field(default_factory=dict)
    # (market, round) -> {"outputs", "proof", "salt"}, kept until the reveal
    pending: dict = field(default_factory=dict)

    kind = "zk"

    def prepare(self, chain: Anvil, market: str, round_id: int) -> dict:
        """Compute the forecast; returns at least {"outputs": [5 ints], "proof": hex}."""
        raise NotImplementedError

    def commit(self, chain: Anvil, market: str, round_id: int, forecast: dict | None = None):
        """Commit `forecast` (or a fresh `prepare`); returns the forecast."""
        forecast = forecast or self.prepare(chain, market, round_id)
        salt = secrets.token_bytes(32)
        digest = keccak(cm.commitment_preimage(
            round_id, self.model_id, forecast["outputs"], salt, self.address))
        t0 = time.time()
        chain.send(self.key, market, COMMIT_SIG, round_id, self.model_id, digest)
        self.timings["commit_s"] = round(time.time() - t0, 2)
        self.pending[(market.lower(), round_id)] = {**forecast, "salt": salt}
        return forecast

    def reveal(self, chain: Anvil, market: str, round_id: int):
        p = self.pending[(market.lower(), round_id)]
        t0 = time.time()
        receipt = chain.send(
            self.key, market, REVEAL_SIG, round_id, p["proof"],
            "[" + ",".join(map(str, p["outputs"])) + "]", "0x" + p["salt"].hex(),
        )
        self.timings["reveal_s"] = round(time.time() - t0, 2)
        return receipt


@dataclass
class Agent(Forecaster):
    model: str = ""
    # Proofs bind only the public inputs (round features) and outputs, so with a cache directory a
    # model proves each distinct feature vector once and every later fork of that hour reuses it.
    proof_cache: Path | None = None

    def onnx_probs(self, x):
        sess = ort.InferenceSession(str(ROOT / "models" / self.model / "model.onnx"))
        return sess.run(None, {"x": np.asarray([x], np.float32)})[0][0].tolist()

    def cache_dir(self, feats):
        onnx = (ROOT / "models" / self.model / "model.onnx").read_bytes()
        key = hashlib.sha256(onnx + json.dumps(feats).encode()).hexdigest()[:32]
        return self.proof_cache / self.model / key

    def prepare(self, chain: Anvil, market: str, round_id: int) -> dict:
        """Prove the model on round `round_id`'s onchain features (or reuse the cached proof)."""
        raw = chain.call(market, "getFeatures(uint256)(int256[16])", round_id)
        feats = [as_int(v) for v in raw[0]]
        work = OUT / "rounds" / f"{market.lower()}-{round_id}" / self.name
        work.mkdir(parents=True, exist_ok=True)
        x = cm.model_input(feats)
        want = [cm.encode(v) for v in feats]
        cached = self.cache_dir(feats) if self.proof_cache else None
        if cached and (cached / "proof.json").exists():
            shutil.copyfile(cached / "proof.json", work / "proof.json")
            self.timings["witness"] = None
            self.timings["prove"] = {**json.loads((cached / "timing.json").read_text()),
                                     "cached": True}
        else:
            (work / "input.json").write_text(json.dumps({"input_data": [x]}))
            self.timings["witness"] = run_step(self.model, "witness", work)
            w = json.loads((work / "witness.json").read_text())
            got = [cm.le_hex_to_int(h) for h in w["inputs"][0]]
            if got != want:
                raise RuntimeError(
                    f"{self.name}: witness inputs differ from the contract encoding\n{got}\n{want}"
                )
            self.timings["prove"] = run_step(self.model, "prove", work)
        proof = json.loads((work / "proof.json").read_text())
        inst = [cm.le_hex_to_int(h) for h in proof["instances"][0]]
        if inst[: cm.N_FEATURES] != want or len(inst) != cm.N_FEATURES + cm.BUCKETS:
            raise RuntimeError(f"{self.name}: proof instances do not match the round features")
        outputs = inst[cm.N_FEATURES :]
        if any(o > cm.MAX_OUTPUT for o in outputs) or sum(outputs) == 0:
            raise RuntimeError(f"{self.name}: outputs not acceptable onchain: {outputs}")
        if cached and not self.timings["prove"].get("cached"):
            cached.mkdir(parents=True, exist_ok=True)
            (cached / "timing.json").write_text(json.dumps(self.timings["prove"]))
            tmp = cached / "proof.json.tmp"
            shutil.copyfile(work / "proof.json", tmp)
            tmp.replace(cached / "proof.json")
        return {"features": feats, "outputs": outputs, "proof": proof["hex_proof"],
                "onnx_probs": self.onnx_probs(x)}
