# agents/

Forecasters that enter VolMarket. Each agent runs a small model on the round's onchain features
(`getFeatures`), proves the inference with EZKL, and submits the 5-bucket forecast together with the
proof (`submitPrediction`). The contract verifies the proof against the features it derived itself
and scores every forecast with the log score at settlement.

## Models

Three structurally different models, trained with numpy on synthetic tick paths in the contract's
units (17 history segments give the 16 features, the 12 window segments that follow give the
realized-vol bucket under bounds `[8, 20, 45, 110]`):

| model | structure | params |
|---|---|---|
| `linear_abs` | `softmax(clip(W·abs(x) + b))` | 85 |
| `mlp16` | `16 → 16 ReLU → 5`, signed features | 357 |
| `mlp32_abs` | `abs(x) → 32 ReLU → 5` | 709 |

Every model ends in `Clip(±3) → Softmax`, so the circuit's exp lookup is bounded for any input and all
three circuits stay at logrows 15. EZKL settings pin `input_scale = 12` (the contract's feature scale
4096), public inputs/outputs and fixed params. `models/<name>/` holds `model.onnx`, `meta.json`,
`cal.json` and the pinned calibrated `settings.json`.

## Usage

```bash
uv sync
uv run python -m vol_agents.train     # retrain -> models/<name>/ (deterministic)
uv run python -m vol_agents.build     # EZKL build (cached in out/<name>/), verifiers -> contracts/src/verifier/
uv run python -m vol_agents.round     # anvil round: deploy, 3 agents prove + submit, settle, compare
uv run pytest -v                      # unit + EZKL export + end-to-end round on anvil
```

The round writes `out/compare_round.json` (agents sorted by onchain log score, 1e18-scaled ln p_win).
Each EZKL step runs in its own process under `/usr/bin/time -l`; wall time and peak RSS are appended
to `out/<name>/timing.jsonl`.

## Layout

| module | role |
|---|---|
| `vol_agents/contract_math.py` | off-chain mirror of the contract's features, field encoding and RV |
| `vol_agents/train.py` | synthetic data, numpy training, ONNX export |
| `vol_agents/ezkl_step.py` | one EZKL step per process |
| `vol_agents/build.py` | idempotent per-model build and verifier install |
| `vol_agents/chain.py` | anvil / forge / cast subprocess wrappers |
| `vol_agents/agent.py` | read features → witness → check public inputs → prove → submit |
| `vol_agents/round.py` | deploy, open, submit, settle, compare |

## Boundary

- Reads `contracts/` artifacts only through Foundry (`forge create`) and the shared fixtures in
  `contracts/test/fixtures/`; never imports `analysis/` or `spikes/`.
- Models run in separate processes, so a heavy or crashed proof never takes the agent down.
