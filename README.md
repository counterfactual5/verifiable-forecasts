# Verifiable AI Forecasts, Held Accountable Onchain

**AI agents forecast Uniswap V3 volatility, prove each forecast with a zk proof of model inference, and get
scored onchain by the contract itself — no trusted reporter, no cherry-picking.**

Hackathon prototype for ETH Shenzhen 2026. Everything runs on a local Anvil chain; no real funds, no
real-network deployment.

## Why

Anyone can claim their model "called it". Today there is no cheap way to check that a forecast was made
*before* the outcome, *by the model claimed*, *on the inputs claimed* — and no public record of how that model
did across rounds. This project turns a Uniswap V3 pool into a public exam:

- the **question** is defined by onchain data only (the pool's TWAP),
- the **inputs** to the model are computed by the contract from the pool, not supplied by the forecaster,
- the **inference** is proven with EZKL and verified onchain before the forecast is accepted,
- the **grade** is a log score computed onchain at settlement (and, planned, published to ERC-8004
  reputation so anyone can look up an agent's track record).

## How it works

The exam: realized volatility of the TWAP tick of the Uniswap V3 ETH/USDC 0.05% pool
(`0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`) over the next hour — 12 segments of Δ = 300 s, measured as
`RV = Σ (ā_k − ā_{k−1})²` over adjacent segment-mean ticks, in tick². Bettors stake on one of 5 buckets
(parimutuel); AI agents submit a probability for each bucket.

1. **observe → features.** `createRound(startTime, bounds)` calls the pool's `observe()` for the last 17
   segments and stores 16 features (differences of segment-mean ticks, clamped to ±64 and scaled by 128).
2. **EZKL proof.** Each agent reads `getFeatures(id)`, runs its small model (16 → … → 5, softmax) and
   proves the inference with EZKL (Halo2/KZG, logrows 15, ~9 s per proof).
3. **submitPrediction.** The agent submits `(modelId, proof, outputs[5])` before `startTime`. The contract
   rebuilds the public inputs from *its own stored features* plus the outputs, calls that model's
   EZKL-generated verifier, and records the normalized distribution only if the proof verifies. Only the
   model's registered operator may submit with it, so a copied proof is useless.
4. **settle.** After the window, `settle(id)` reads the 13 checkpoints via `observe()`. Anyone can call
   `sample(id, k)` during the window to store a checkpoint, which saves settlement if the pool's
   observation history rolls past the window. Missing points are tolerated up to one (normalized RV);
   below 90 % coverage the round is voided and all stakes refunded.
5. **log score.** Each forecast scores `max(ln p_win, −18)` (1e18-scaled); winners claim their pro-rata
   share of the pool minus fee.
6. **ERC-8004 reputation** *(planned)*. After settlement the market contract writes each agent's score as
   feedback on the ERC-8004 v2.0.0 Reputation Registry; readers filter by the market's address.

## Status

**Done**

- `contracts/src/VolMarket.sol`: rounds, betting, zk-verified predictions, `observe`-based settlement with
  `sample()` fallback, log scoring, claims. Shared math in `contracts/src/lib/MarketMath.sol`.
- `contracts/src/verifier/`: one EZKL-generated Halo2 verifier per model.
- `agents/`: three structurally different models (`linear_abs`, `mlp16`, `mlp32_abs`), EZKL build, and an
  end-to-end round on Anvil: prove → submit → settle → compare onchain scores.
- `make verify` covers the contracts, analysis and agents suites.

**Planned**

- Calibrate the bucket bounds from real Swap history (`analysis/`) and retrain the models on them.
- ERC-8004 identity + reputation (agents register, market writes the score after settlement; a failing
  feedback write must not block settlement or payouts).
- Chainlink ETH/USD cross-check at settlement, opt-in via `setPriceFeed` (see [`chainlink/`](chainlink/)).
- Mainnet-fork replay demo and a simple dashboard.
- Remove the legacy `BaseFeeMarket` and the base-fee analysis pipeline.

## Quickstart

Requirements: Foundry (`forge`, `anvil`, `cast`), GNU Make, [uv](https://docs.astral.sh/uv/), Python ≥ 3.12.

One-time setup (needs network; the Makefile then runs uv offline against the lock files):

```bash
make analysis-sync          # cd analysis && uv sync --locked
cd agents && uv sync && cd ..
```

Full verification (Foundry suite, analysis and agents ruff + pytest, including the Anvil end-to-end round):

```bash
make check && make test
```

> The first agents run builds the three EZKL circuits (proving keys ≈ 400 MB each, git-ignored under
> `agents/out/`) and, if no local SRS is found, **downloads the EZKL KZG SRS from the network**.

Run one round by hand and look at the result:

```bash
cd agents
uv run python -m vol_agents.round     # starts its own anvil: deploy, 3 agents prove + submit, settle
cat out/compare_round.json            # agents sorted by onchain log score
```

Other agent commands: `uv run python -m vol_agents.train` (retrain models, deterministic),
`uv run python -m vol_agents.build` (rebuild circuits and install verifiers into `contracts/src/verifier/`),
`uv run pytest -v`. The acceptance probe `bash tests/acceptance/next_agents.sh` checks models, the
end-to-end round and the comparison file.

## Repo layout

```text
contracts/            Foundry project
  src/VolMarket.sol     volatility market with zk-verified forecasts
  src/lib/MarketMath.sol  bucketing, log score, parimutuel payout
  src/verifier/         EZKL-generated verifiers (one per model + the spike model used in tests)
  src/BaseFeeMarket.sol legacy base-fee market, to be removed
  test/fixtures/        shared vol fixture, real proof fixture
agents/               models, EZKL build, forecasting agents, Anvil end-to-end round
analysis/             data pipeline (currently legacy base fee; Swap-based vol calibration planned)
spikes/facts/         verified facts: pool history depth, observe gas, ERC-8004, Chainlink
spikes/ezkl/          EZKL feasibility spike and measurements
chainlink/            Chainlink price-feed cross-check notes (planned)
docs/                 SPEC, architecture, implementation plan, roadmap
```

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for data flow and trust boundaries, and
[`docs/plans/实施计划.md`](docs/plans/实施计划.md) for the detailed design.

## Known limitations

- **Models are trained on synthetic data** in contract units, not on real pool history.
- **Bucket bounds are placeholders** `[8, 20, 45, 110]` tick². A rough estimate puts real hourly RV in the
  thousands of tick², so with real data nearly every round would land in the top bucket. Until bounds are
  calibrated and the models retrained, the demo uses these placeholders with a `MockPool`.
- **Fees cannot be withdrawn**: the protocol fee and rounding dust stay in the contract; there is no
  withdraw function.
- **The EZKL SRS is not checksum-verified**, and the build step silently overwrites committed verifier
  contracts when the generated output differs.
- **Features are snapshotted at `createRound`**, not at `startTime`; price action between the two is not
  in the model inputs.
- Bets and forecasts are public (no sealed bidding), so they can be copied by later bettors.
- At most 32 forecasts per round (bounds the scoring loop in `settle`).
- The legacy `BaseFeeMarket` and base-fee analysis pipeline are still in the tree and will be removed.

Out of scope: LMSR market making, blob-fee markets, FHE / commit-reveal betting, x402 payments, real funds,
ERC-8004 Validation Registry, Chainlink CRE / Automation.

## License

MIT, matching the Solidity source headers.
