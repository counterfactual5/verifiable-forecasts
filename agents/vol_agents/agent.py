"""A forecasting agent: read the round's onchain features, run its model inside EZKL, check that the
witness public inputs equal the contract's encoding, prove, and submit the forecast with the proof.
"""

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import onnxruntime as ort

from . import contract_math as cm
from .build import run_step
from .chain import Anvil, as_int
from .ezkl_step import OUT, ROOT

SUBMIT_SIG = "submitPrediction(uint256,uint256,bytes,uint256[5])"


@dataclass
class Agent:
    name: str
    model: str
    key: str
    address: str
    model_id: int | None = None
    timings: dict = field(default_factory=dict)

    def onnx_probs(self, x):
        sess = ort.InferenceSession(str(ROOT / "models" / self.model / "model.onnx"))
        return sess.run(None, {"x": np.asarray([x], np.float32)})[0][0].tolist()

    def forecast(self, chain: Anvil, market: str, round_id: int):
        """Prove the model on round `round_id` and submit; returns the submitted outputs."""
        feats = [as_int(v) for v in chain.call(market, "getFeatures(uint256)(int256[16])", round_id)[0]]
        work = OUT / "rounds" / f"{market.lower()}-{round_id}" / self.name
        work.mkdir(parents=True, exist_ok=True)
        x = cm.model_input(feats)
        (work / "input.json").write_text(json.dumps({"input_data": [x]}))

        self.timings["witness"] = run_step(self.model, "witness", work)
        w = json.loads((work / "witness.json").read_text())
        got = [cm.le_hex_to_int(h) for h in w["inputs"][0]]
        want = [cm.encode(v) for v in feats]
        if got != want:
            raise RuntimeError(f"{self.name}: witness inputs differ from the contract encoding\n{got}\n{want}")

        self.timings["prove"] = run_step(self.model, "prove", work)
        proof = json.loads((work / "proof.json").read_text())
        inst = [cm.le_hex_to_int(h) for h in proof["instances"][0]]
        if inst[: cm.N_FEATURES] != want or len(inst) != cm.N_FEATURES + cm.BUCKETS:
            raise RuntimeError(f"{self.name}: proof instances do not match the round features")
        outputs = inst[cm.N_FEATURES :]
        if any(o >= cm.R // 2 for o in outputs) or sum(outputs) == 0:
            raise RuntimeError(f"{self.name}: outputs not acceptable onchain: {outputs}")

        t0 = time.time()
        chain.send(
            self.key, market, SUBMIT_SIG, round_id, self.model_id, proof["hex_proof"],
            "[" + ",".join(map(str, outputs)) + "]",
        )
        self.timings["submit_s"] = round(time.time() - t0, 2)
        return {"features": feats, "outputs": outputs, "onnx_probs": self.onnx_probs(x)}
