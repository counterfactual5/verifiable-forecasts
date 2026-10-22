# agents/

Forecasters that enter VolMarket. Every agent works in two phases:

1. **commit** before `startTime − commitLead`: `commitPrediction(id, modelId, commitment)` with
   `commitment = keccak256(abi.encode(id, modelId, outputs[5], salt, sender))`. The hash is computed
   locally (`cast keccak`), so the forecast never leaves the machine before it is committed; the salt
   is random per round.
2. **reveal** between `startTime − commitLead` and `startTime − revealLead`:
   `revealPrediction(id, proof, outputs[5], salt)`.

The zk agents (`agent.py`) run a small model on the round's onchain features (`getFeatures`) and
prove the inference with EZKL; the contract verifies the proof at reveal against the features it
derived itself. The commit-only agent (`api_agent.py`) asks a time-series model API and reveals with
an empty proof; its model is registered with `verifier = address(0)`, so it proves timing, not
provenance, and its ERC-8004 score carries tag2 `vol-<Δ>s-<N>-commit`. An unrevealed forecast is
neither scored nor paid. Forecasts that score above the uniform baseline `ln 0.2` share
`predictorShareBps` of the round's fee (`claimPredictorReward`).

## Models

Three structurally different models, trained with numpy on real ETH/USDC 0.05% pool history
(42 days of Swap logs, rebuilt into a 60 s tick-cumulative grid by `analysis/`). Every sample is a
round in the contract's units: the 16 features `createRound` would compute at time T, and the
realized-vol bucket of the hour that starts one segment later, under bounds `[202, 474, 856, 1712]`
tick² (`contract_math.BOUNDS`, the p20/p40/p60/p80 of the training period's hourly RV). The split is
chronological: train 2026-09-10 – 10-08, validation 10-08 – 10-15, test 10-15 – 10-22; the bounds
and the weights see only the training period.

| model | structure | params |
|---|---|---|
| `linear_abs` | `softmax(clip(W·abs(x) + b))` | 85 |
| `mlp16` | `16 → 16 ReLU → 5`, signed features | 357 |
| `mlp32_abs` | `abs(x) → 32 ReLU → 5` | 709 |

Every model ends in `Clip(±3) → Softmax`, so the circuit's exp lookup is bounded for any input and all
three circuits stay at logrows 15. EZKL settings pin `input_scale = 12` (the contract's feature scale
4096), public inputs/outputs and fixed params. `models/<name>/` holds `model.onnx`, `meta.json`,
`cal.json` and the pinned calibrated `settings.json`.

Test-period mean log score (higher is better): `linear_abs` −1.418, `mlp16` −1.423, `mlp32_abs`
−1.469, against uniform −1.609 and the training-period bucket frequencies −1.606
(`models/eval.json`). Training details, baselines, limits and a judges' Q&A:
[`MODEL_CARD.md`](MODEL_CARD.md).

## Usage

```bash
uv sync
# retrain -> models/<name>/, models/eval.json, tests/fixtures/real_holdout.json (deterministic);
# needs analysis/data/tick_cumulative_grid.csv and analysis/data/train/vol_params.json:
#   cd ../analysis && uv run python src/vol_calibrate.py --swaps data/swaps_6w.csv \
#     --until 1791417600 --out data/train/vol_params.json
#   cd ../analysis && uv run python src/vol_calibrate.py --swaps data/swaps_6w.csv \
#     --export-grid data/tick_cumulative_grid.csv
uv run python -m vol_agents.train
uv run python -m vol_agents.build     # EZKL build (cached in out/<name>/), verifiers -> contracts/src/verifier/
                                      #   [--srs PATH] [--force], see "EZKL SRS" below
uv run python -m vol_agents.round     # anvil round: deploy, 3 agents prove, commit, reveal, settle
uv run pytest -v                      # unit + EZKL export + end-to-end round on anvil
```

### EZKL SRS

`setup` and `evm` need the KZG SRS for logrows 15 at `out/kzg15.srs` (git-ignored, 4,194,564
bytes). The build accepts it only if its sha256 equals `SRS_SHA256` in `vol_agents/build.py`
(`90807800a1c3b248a452e1732c45ee5099f38b737356f5542c0584ec9c3ebb45`) and stops otherwise. Sources,
in order:

1. an existing `out/kzg15.srs` (checked on every build);
2. `--srs PATH` or `VOL_AGENTS_SRS=PATH`, copied into `out/` after the check (e.g. the file
   `spikes/ezkl/run.sh` leaves at `spikes/ezkl/out/kzg15.srs`);
3. otherwise `ezkl.get_srs` downloads it (network), and a download with another digest is deleted.

### Committed verifiers

`build` copies each verifier into `contracts/src/verifier/<Name>Verifier.sol`. If that file exists
and the fresh build differs from it, the build stops instead of overwriting it; pass `--force` only
when replacing the onchain verifier is intended (retrained model or new settings).

The round writes `out/compare_round.json` (agents sorted by onchain log score, 1e18-scaled ln p_win).
Each EZKL step runs in its own process under `/usr/bin/time -l`; wall time and peak RSS are appended
to `out/<name>/timing.jsonl`.

## Commit-only API agent

`ApiAgent` is configured from the environment (see `.env.example`; never commit real values):

| variable | meaning |
|---|---|
| `VOL_TSFM_API_URL` | POST endpoint. Unset: the agent uses a deterministic placeholder forecast (quantiles at 0.24×, 0.94×, 4.63× the trailing realized vol for levels 0.1/0.5/0.9, the training period's ratios of next-hour to trailing RV) and reports `forecast_source = "placeholder"` |
| `VOL_TSFM_API_KEY` | optional; sent as `Authorization: Bearer <key>` |
| `VOL_TSFM_API_KEY_HEADER` | optional; send the key raw under this header instead (e.g. `X-API-Key`) |
| `VOL_TSFM_TIMEOUT_S` | request timeout, default 30 |

Error messages never contain the key or the response body. Tests use a local mock HTTP server only.

**Request** (`Content-Type: application/json`), built from the contract's own features:

```json
{
  "schema": "vol-forecast-request/v1",
  "target": "realized_vol_tick2",
  "round": {"market": "0x…", "id": 0, "start": 1792663437, "delta_s": 300, "n_segments": 12},
  "bounds_tick2": [202, 474, 856, 1712],
  "history": {
    "step_s": 300,
    "segment_mean_tick_diffs": [-12, -4, 0, 4, 17, 2, 9, -14, 13, 10, -6, 5, 4, -15, -7, -8],
    "relative_segment_mean_ticks": [0, -12, -16, -16, -12, 5, 7, 16, 2, 15, 25, 19, 24, 28, 13, 6, -2],
    "clamp_ticks": 64
  },
  "quantile_levels": [0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95]
}
```

`segment_mean_tick_diffs` are the 16 contract features divided by 128 (differences of adjacent
Δ-second mean ticks, clamped to ±64); `relative_segment_mean_ticks` is their running sum from 0, i.e.
the last 17 segment-mean ticks relative to the oldest. The target is the next window's realized vol
`RV = Σ (ā_k − ā_{k−1})²` over `n_segments` segment-mean ticks, in tick², bucketed half-open by
`bounds_tick2` (bucket 0: `RV < b0`, bucket 4: `RV ≥ b3`).

**Response**, either form:

```json
{"bucket_probs": [0.05, 0.15, 0.3, 0.3, 0.2]}
```

five non-negative numbers with a positive sum (normalized by the agent), or

```json
{"quantiles": [{"level": 0.1, "value": 300.0}, {"level": 0.5, "value": 800.0}, {"level": 0.9, "value": 2200.0}]}
```

at least two quantiles of RV in tick², levels strictly increasing in (0, 1), values non-decreasing.
The `quantile_levels` in the request are a hint; any levels are accepted. The agent builds a CDF:
linear from (0, 0) to the lowest quantile, linear between quantiles, and an exponential upper tail
fitted through the top two; bucket probabilities are the CDF differences at the bounds. Probabilities
are then floored at 1e-6 (a zero bucket would score the −18 floor if it wins) and quantized to
1e18-scaled integers that sum exactly to 1e18 (largest remainder), which are the revealed outputs.

## Layout

| module | role |
|---|---|
| `vol_agents/contract_math.py` | off-chain mirror of the contract's features, field encoding and RV |
| `vol_agents/dataset.py` | real samples from the tick-cumulative grid (contract features and RV), chronological split |
| `vol_agents/train.py` | numpy training, baselines, ONNX export, `models/eval.json` |
| `vol_agents/ezkl_step.py` | one EZKL step per process |
| `vol_agents/build.py` | idempotent per-model build and verifier install |
| `vol_agents/chain.py` | anvil / forge / cast subprocess wrappers |
| `vol_agents/agent.py` | `Forecaster` (commit / reveal); zk `Agent`: read features → witness → check public inputs → prove |
| `vol_agents/api_agent.py` | commit-only `ApiAgent`: API request, quantile → bucket conversion, 1e18 quantization |
| `vol_agents/round.py` | deploy, open, commit, reveal, settle, compare |

## Boundary

- Reads `contracts/` artifacts only through Foundry (`forge create`) and the shared fixtures in
  `contracts/test/fixtures/`; never imports `analysis/` or `spikes/`.
- Models run in separate processes, so a heavy or crashed proof never takes the agent down.
