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
(`models/eval.json`). Over four walk-forward test weeks (cuts 09-24 – 10-15, bounds recalibrated and
models retrained per fold, offline only) the mean is −1.345 / −1.383 / −1.398 against uniform −1.609
and the previous-hour transition matrix −1.395 (`models/walkforward.json`, `vol_agents.walkforward`).
Training details, baselines, limits and a judges' Q&A: [`MODEL_CARD.md`](MODEL_CARD.md).

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

The round writes `out/compare_round.json` (agents sorted by onchain score = −mean pinball loss of
`ln(max(RV, 1))`, 1e18-scaled; with the round's `ln_rv`, baseline quantiles and baseline loss).
Each EZKL step runs in its own process under `/usr/bin/time -l`; wall time and peak RSS are appended
to `out/<name>/timing.jsonl`.

## Time-series model agents (self-hosted inference)

`ApiAgent` calls a time-series model on the operator's self-hosted inference service and is
configured from the environment (see `.env.example`; never commit real values):

| variable | meaning |
|---|---|
| `VOL_TSFM_API_URL` | tsfm-forecast: the service's base URL (the agent POSTs `{url}/forecast`); generic schema: the POST endpoint. Unset: the agent uses a deterministic placeholder forecast (quantiles at 0.24×, 0.94×, 4.63× the trailing realized vol for levels 0.1/0.5/0.9, the training period's ratios of next-hour to trailing RV) and reports `forecast_source = "placeholder"` |
| `VOL_TSFM_API_KEY` | optional; sent as `Authorization: Bearer <key>` |
| `VOL_TSFM_API_KEY_HEADER` | optional; send the key raw under this header instead (e.g. `X-API-Key`) |
| `VOL_TSFM_API_SCHEMA` | `tsfm-forecast` (default) or `vol-forecast-request/v1` (the generic schema below) |
| `VOL_TSFM_MODEL` | model id of a single `ApiAgent` built from `ApiConfig.from_env()`, default `remote-model` |
| `VOL_TSFM_MODELS` | comma-separated models for `api_agent.tsfm_agents` (one independent agent each), default `timesfm-3.0,timestral-209m,chronos-2` |
| `VOL_TSFM_TIMEOUT_S` | request timeout, default 30 (120 recommended) |
| `VOL_HISTORY_CACHE` | absolute path of the swap cache written by `analysis/src/fetch_swaps.py --tail` (with its `.coverage.json`); unset: every agent sends the 16 onchain features |
| `VOL_HISTORY_CONTEXT` | long-context length in segment differences for commit-only models, default 512 (reproducible models always use 512: their `model_hash` fixes it) |

Error messages never contain the key or the response body. Tests use a local mock HTTP server only.

### tsfm-forecast format (default)

The context differences (ticks) go out as one long-table series (`unique_id` `round-<id>`, `ds`
every Δ seconds ending at `start − Δ`, `y`), with `h = nSegments + 1`, `freq` `5min`, `level`
`[98, 90, …, 10]` (the 21 native quantiles with the median) and the `raw` cleaning preset. The
answer's per-step `y_hat` and `intervals` become quantiles of each future difference; the last
`nSegments − 1` steps are the window's differences (rounds open one segment before their start).
The agent draws 4000 independent samples per step (fixed seed; linear between quantiles,
exponential tails), scales them by a per-model spread, sums the squares into realized vol per
path and takes the empirical quantiles (numpy linear) of `y = ln(max(RV_path, 1))` at the market's
levels `[0.1, 0.25, 0.5, 0.75, 0.9]`. Request and post-processing live in
`vol_agents/tsfm_forecast.py`; spreads were chosen on the validation period 2026-10-08 .. 10-15
only, under the earlier bucket log score (`MODEL_CARD.md` 6.2), and are kept for the quantile
output.

Context: `timestral-209m` and `chronos-2` send the long context of `history.round_context` (512
differences, ~42.7 h, from `VOL_HISTORY_CACHE`, falling back to the 16 features when the cache is
missing, stale or disagrees with them) with the long-context spread
`history.LONG_CONTEXT_SPREAD`; `timesfm-3.0` sends the 16 onchain features. The forecast
record carries `context_source` (`swaps` / `onchain`), `context_points` and `context_reason` next to
`quantiles` (ln units, as revealed), `outputs` and `api_quantiles` (before quantization).

Reveal: `outputs[k] = round(q_k · 4096)` (`OUTPUT_SCALE_BITS` = 12, the same grid as the zk
models), then lifted to strictly increasing by one step; the market stores
`outputs[k] · (1e18 >> 12)` and scores the mean pinball loss against `ln(max(RV, 1))`.

`tsfm_agents(config, keys)` builds one agent per model with its own name, key and address:

| agent | model | public weights | context | tier |
|---|---|---|---|---|
| `agent-timesfm-3.0` | `timesfm-3.0` | `google/timesfm-3.0-pytorch@43046b85ec22d584a13f8098c2ed39c889e129c2` (TimesFM non-commercial) | 16 onchain features | reproducible |
| `agent-timestral-209m` | `timestral-209m` | `mistralai/Timestral-209M@9874d252ab0aae16f7f7c999f98f98d6ad7d8365` (Mistral Modified MIT) | 512 | reproducible |
| `agent-chronos-2` | `chronos-2` | `amazon/chronos-2@29ec3766d36d6f73f0696f85560a422f50e8498c` (Apache-2.0) | 512 | reproducible |

The offline test-period numbers in `MODEL_CARD.md` 6.2 were measured under the earlier bucket log
score; pinball-loss numbers for the quantile output are not measured yet `[待证据]`.

**Reproducible tier.** The commitment binds the revealed integers. A recompute from the public
weights on CPU accepts the reveal when every quantile is within `RECOMPUTE_TOLERANCE_E18` = 1e15
(1e18 ln units, 4 steps of the 2^-12 grid) of what it computes: the verdict is `exact` (same
integers), `tolerant` or `fail`. Under the earlier bucket output the service and the local runner
gave the very same integers on 174/174 test and 24/24 replay rounds for all three models; the
quantile output has not been re-checked against the local runtimes yet `[待证据]`. The 512-point context is rebuilt from the pool's Swap logs over
JSON-RPC (`vol_agents/swap_logs.py`), equal to the cache series on every checked replay round.
When the rebuilt series misses, the recompute also tries the 16-feature context the agent falls
back to when its cache is stale; both are functions of chain data.

`ApiAgent.tier` and `ApiAgent.model_hash` tell the caller how to register: reproducible →
`registerModel(address(0), operator, model_hash)`, commit-only → `registerModel(address(0),
operator)`. `ApiAgent.kind` stays `commit-only` for all of them. The hash is keccak256 of the
canonical JSON in `tsfm_forecast.model_hash_preimage` (weights `repo@revision`, context, inference
and post-processing parameters, output levels, scale bits, grid and tolerance, sha256 of `tsfm_forecast.py`,
`tsfm_local.py` and, for 512-point models, `history.py`). Recompute without the inference service,
with `VOL_REPRO_PYTHON` naming a Python that has torch and the model's runtime (timesfm 3.0.2,
chronos-forecasting 2.x or timestral 1.0) and the snapshot in the Hugging Face cache; Swap logs
come from `--logs-rpc-url` (default `$MAINNET_RPC_URL`, else the public gateway), never from the
demo fork:

```bash
uv run python -m vol_agents.tsfm_recompute --model chronos-2 --rpc-url <RPC> \
  --market <MARKET> --round <ROUND> --model-id <MODEL_ID>
```

It exits 1 on a model hash mismatch, a missing reveal, quantile levels or scale bits that differ
from the model's, or a quantile beyond tolerance, and 2 when the
runner fails; there is no fallback forecast. `tests/test_api_agent.py` runs registration, reveal
and every verdict on anvil with a stand-in runner, so `uv run pytest` needs no `VOL_REPRO_PYTHON`.

### Generic format (`VOL_TSFM_API_SCHEMA=vol-forecast-request/v1`)

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

**Response**:

```json
{"quantiles": [{"level": 0.1, "value": 300.0}, {"level": 0.5, "value": 800.0}, {"level": 0.9, "value": 2200.0}]}
```

at least two quantiles of RV in tick², levels strictly increasing in (0, 1), values non-decreasing.
The `quantile_levels` in the request are a hint; any levels are accepted. The agent maps each value
to `ln(max(value, 1))` (ln is monotone, so quantiles map one to one), interpolates linearly in
(level, ln value) to the market's levels (levels outside the answer's range take the nearest
quantile) and quantizes as above. A `bucket_probs` answer is rejected with an error: the market
no longer scores bucket probabilities.

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
| `vol_agents/api_agent.py` | `ApiAgent` (one per model via `tsfm_agents`): inference request, RV quantiles → ln quantiles at the market levels, 2^-12 quantization |
| `vol_agents/tsfm_forecast.py` | `/forecast` request, sampled-path post-processing to ln RV quantiles, 2^-12 reveal grid and 1e15 tolerance, per-model spec and tier, `model_hash` |
| `vol_agents/tsfm_local.py` | public-weights CPU inference under `VOL_REPRO_PYTHON` (timesfm-3.0, chronos-2, timestral-209m) |
| `vol_agents/tsfm_recompute.py` | recompute a reproducible model agent's reveal without the inference service, within tolerance |
| `vol_agents/swap_logs.py` | the pool's Swap logs over JSON-RPC in the history cache format, for the recompute's 512-point context |
| `vol_agents/history.py` | long context for the model agents: 512 five-minute segment-mean differences from the analysis swap cache (`fetch_swaps.py --tail`), no reads at or after createRound, fallback to the 16 onchain features |
| `vol_agents/round.py` | deploy, open, commit, reveal, settle, compare |

## Boundary

- Reads `contracts/` artifacts only through Foundry (`forge create`) and the shared fixtures in
  `contracts/test/fixtures/`; never imports `analysis/` or `spikes/`.
- Models run in separate processes, so a heavy or crashed proof never takes the agent down.
