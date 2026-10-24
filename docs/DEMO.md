# Demo: 24 real hours of VolMarket rounds on a mainnet fork

可验证预测协议 / Verifiable Forecast Protocol: lock AI forecasts ex ante, verify them ex post, score
reputation by outcome.

What the audience should see: six AI agents forecast, hour after hour, the volatility of the real
Uniswap V3 ETH/USDC 0.05% pool over 24 consecutive real hours, each as 5 quantiles (10/25/50/75/90 %)
of ln RV. Each round, every agent commits a hash first and reveals before the window opens; the three zk agents' forecasts are accepted only
with a valid EZKL proof; the other three (timesfm-3.0, timestral-209m, chronos-2) are reproducible:
public weights at a pinned revision registered by `modelHash`, and the replay re-derives every one
of their reveals from chain data with `python -m vol_agents.tsfm_recompute`, each quantile within
1e15 on the 1e18 scale. Each round settles from
the pool itself after a Chainlink cross-check, each agent's score accumulates in the deployed
ERC-8004 Reputation Registry as −mean pinball loss (tag1 `pinball`; models without a verifier under
their own `-commit` tag), and forecasters share half of each round's fee pro rata to their positive
cumulative excess over the climatological baseline (training-period quantiles), Σ baseline loss − own loss.
Bettors stake on 5 volatility buckets; the buckets are betting pools only, not used for scoring. The dashboard then shows the 24-round track record.

Everything runs on one local Anvil fork. Nothing is broadcast to mainnet and no real funds move.
The live page (`demo/live.sh`, hourly on the demo server) does the same on a fresh fork each hour:
its commits are simulated on the fork, so it is not a real-time ex-ante proof; a persistent chain is
the next step.

## Prerequisites

- Foundry (`anvil`, `cast`, `forge`), [uv](https://docs.astral.sh/uv/), Python ≥ 3.12, `python3`.
- `cd agents && uv sync` once. The EZKL circuits must be built (`uv run python -m vol_agents.build`,
  cached under `agents/out/`; the first build needs the KZG SRS, see `agents/README.md`).
- An archive mainnet RPC (the replay reads historical `observe()` and logs). Without configuration
  the public tenderly gateway is used (the same default as `analysis/src/fetch_swaps.py`). A private
  endpoint is faster: `cp .env.example .env` and set `MAINNET_RPC_URL`. Never commit `.env`.
- `VOL_TSFM_API_URL` / `VOL_TSFM_API_KEY` (`.env`): the self-hosted inference service the three
  time-series model agents call. An agent whose call fails sits that round out; there is no
  fallback forecast.
- For the recompute: `VOL_REPRO_PYTHON`, a Python interpreter with torch and the models' runtimes
  (timesfm 3.0.2, chronos-forecasting 2.x, timestral 1.0) and the pinned weights in the Hugging Face cache;
  `VOL_REPRO_PYTHON_<MODEL>` (for example `VOL_REPRO_PYTHON_TIMESTRAL_209M`) overrides it for one
  model (see `agents/README.md`). Without `VOL_REPRO_PYTHON` the replay skips the recompute.
- timestral-209m and chronos-2 read 512 five-minute points before each round, rebuilt from the
  pool's Swap logs: `VOL_HISTORY_CACHE=<csv from analysis/src/fetch_swaps.py>` and
  `VOL_HISTORY_CONTEXT=512`.

## Run

```bash
make demo                    # or: bash demo/run.sh            (24 hours, ≈ 13 min, ≈ 40 min with the recompute)
HOURS=2 bash demo/run.sh     # quick check, ≈ 2 min
REPLAY_START=2026-10-16T00:00:00Z HOURS=6 bash demo/run.sh
```

`HOURS` (default 24) and `REPLAY_START` (a full UTC hour, unix seconds or ISO-8601; default
2026-10-21 06:00 UTC, inside the models' test period 10-15 – 10-22, after their training and
validation data) are read from the environment or `.env`. The window must be within the pool's
mainnet history and already over. Measured in the committed run: 24 h in 2363 s wall time, of which
1590 s was the CPU recompute after the last round (timesfm-3.0 3–6 s per round, timestral-209m and
chronos-2 30–37 s each, since they rebuild 512 points from Swap logs); the rest is reading mainnet
`observe()` on 307 grid points, the fee calibration, three EZKL proofs per round and the
inference-service calls. (These timings are from the earlier 5-bucket run. The frozen quantile live run took 411 s: the
server caches zk proofs and does not recompute; the 72 recomputes were run afterwards.)

Steps, as printed with `[demo]`:

1. **Read mainnet.** For every 5-minute grid time from 85 minutes before the first round to the end
   of the last, the real pool's floor mean tick over the next 5 minutes (archive `observe()` calls),
   plus every real Chainlink ETH/USD transmission in the range.
2. **Fork and deploy, once.** Fork mainnet 10 minutes before the replay grid starts. Deploy
   `VolMarket` (WETH stake, 1 % fee, 50 % of it to forecasters, Δ = 300 s, N = 12, commit lead 90 s,
   reveal lead 30 s) wired to the real pool, the deployed ERC-8004 Identity/Reputation and the
   Chainlink feed; one EZKL verifier per zk model and the reproducible model with `verifier = 0` and
   its `modelHash` (checked against the local snapshot before any round). Each agent registers one
   ERC-8004 identity for the whole replay; the reproducible agent's is an inline agent card.
3. **Replay the pool.** At each grid time t, in a block stamped exactly t, a trader swaps the forked
   pool to mainnet's real mean tick of [t, t + 300 s) and holds it there. Every segment mean the
   contract reads therefore equals mainnet's. The script stops if a swap misses its target tick, and
   records per round whether the features and realized vol equal the mainnet recompute
   (`features_match_mainnet`, `rv_matches_mainnet`, both summarized at the end).
4. **Replay Chainlink.** Each real `transmit` is re-sent by its original transmitter (impersonated)
   at its original timestamp, so the feed's answer and age at every settle are mainnet's.
5. **Every hour, one round.** `createRound` 5 minutes before the hour (in the same block as that
   grid swap); each zk agent proves its model on the onchain features, the reproducible agents ask
   the inference service for their forecast; all commit, then reveal after commits close, and the
   contract verifies each proof against its own stored features. After the last round the replay
   runs `python -m vol_agents.tsfm_recompute` against the fork for every reproducible reveal
   (`reproduced` and `recompute_verdict` in the JSON, `exact` / `tolerant` / `fail` in the
   terminal). Two bettors stake 1 WETH each (the bucket of the agents' mean
   median, and the bucket of a mean quartile). `sample(k)` runs at every 5-minute checkpoint, in the grid swap's block.
6. **Settle.** At the end of the hour: Chainlink cross-check, RV, y = ln(max(RV, 1)), winning
   betting bucket, pinball loss per forecast and for the baseline quantiles,
   ERC-8004 feedback (the script stops if any `ReputationWriteFailed` is emitted), bettor claims,
   `claimPredictorReward` for every forecaster above the baseline and `collectFee`.
7. **Tamper check** (round 0): each verifier must accept the honest proof and reject it with one
   output changed; its `verifyProof` gas is recorded.

The script prints one line per round and a summary table, and writes `demo/out/fork_replay.json`
(`schema: "vol-replay/v2"`; git-ignored). The committed `dashboard/sample-replay.json` is the frozen
first successful 24-hour quantile live run from the demo server.

## Expected output (frozen 24-hour quantile live run)

Frozen run: 2026-10-23 06:00 – 10-24 06:00 UTC, 24 of 24 rounds settled, every agent scored in all
24, climatological baseline mean pinball loss 0.289. Mean pinball loss per agent: `linear_abs` 0.270,
`mlp16` 0.264, `mlp32_abs` 0.263, timesfm-3.0 0.304, timestral-209m 0.261, chronos-2 0.311; four of
six below the baseline, timesfm-3.0 and chronos-2 above it. Recompute: 72 of 72 within tolerance
(70 `exact`, 2 `tolerant`). Tampered proofs: 3 of 3 rejected, `verifyProof` ≈ 552k gas. Fee MAE vs
the reference (mean 4.06 bps): forecast 2.16, fixed 5 bps 2.36, previous-hour 3.52.

The summary table of the frozen run: per agent rounds scored, mean pinball loss, the
round-matched climatological baseline loss, excess, 50 % / 80 % coverage, rounds beating the
baseline, fee share and ERC-8004 count; recompute verdicts; tamper check and `verifyProof` gas; fee
strategies (mean and MAE vs the hindsight fair LVR fee, a reference, not a strategy).

The JSON records per agent its onchain `tier` (`zk` / `reproducible` / `commit-only`) and
`model_hash`, and per round each agent's revealed quantiles and, for the reproducible agents,
`reproduced`, `recompute_verdict` (`exact` or `tolerant`) and `recompute_max_abs_diff` (1e18 scale).

**Voided rounds: 0.** A voided round would be listed under
`summary.void_reasons` and in its round's `outcome.void_reason` (Chainlink stale or invalid, price
deviation, tick out of range, feed call failed, or fewer than 90 % of checkpoints readable); its
stakes are refunded and nobody is scored.

What must hold on every run: features and RV match mainnet in every round, every honest proof
verifies and every tampered one does not, every reproducible recompute matches (`reproduced` true in
all rounds), no `ReputationWriteFailed`, each ERC-8004 `getSummary` count equals the number of
settled rounds, and the market keeps 0 wei from settled rounds (a live run's file shows 2 WETH: the
two stakes in the hour still in progress, which that run opens but cannot settle). Scores are what
they are: 24 rounds is a
small sample, no significance test was run, and the tiers are not compared with each other.

## Checking a round on Etherscan

The market lives only on the fork, but every input it used is on mainnet. Per round the JSON (and
the dashboard's rounds table) has `mainnet.block_from` / `block_to` (the first and last mainnet block
of the hour), the pool's swap count in that range and its last swap transaction, and the replay lists
each Chainlink transmission it re-sent. For round 0 (2026-10-21 06:00–07:00 UTC):

- Blocks [26,239,037](https://etherscan.io/block/26239037) – [26,239,336](https://etherscan.io/block/26239336);
  143 swaps on the [pool](https://etherscan.io/address/0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640#events),
  the last one [0x7379…b250](https://etherscan.io/tx/0x73791ccfef13b5736d18b274938bfece10b918727265f59f52a688ca4da2b250).
- Chainlink report replayed before it settled:
  [0xda74…670d](https://etherscan.io/tx/0xda744edefa307f282a3674bfef1025ea03dcff56c0da4fa50ccb940bb0e0670d)
  (ETH/USD 2438.94, updated 06:51:11 UTC).
- The realized vol itself can be recomputed from mainnet alone with the pool's `observe()` at
  `block_to + 1` (12 segment means, `analysis/` does the same over the whole history).

## Dashboard

```bash
python3 -m http.server 8765 --bind 127.0.0.1    # from the repo root
open http://127.0.0.1:8765/dashboard/
```

The page reads `demo/out/fork_replay.json`, or the committed `dashboard/sample-replay.json` if the
demo has not been run: each agent's quantile fan and pinball loss against the climatological
baseline, betting-bucket distribution, realized vol per round, cumulative fee share, ERC-8004 summaries and
the per-round table with Etherscan links. The earlier single-round view still works with
`?data=sample-round.json`. Screenshot: [`docs/img/dashboard.png`](img/dashboard.png).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Failed to estimate gas` / RPC timeouts | The fork pulls pool storage lazily; the public gateway can be slow. Re-run (Anvil caches fork reads on disk per block) or set a private `MAINNET_RPC_URL`. |
| A round line shows `VOID (...)` | The Chainlink cross-check failed for that hour: pool and feed more than 200 bps apart, or no feed update for over 3900 s on mainnet. That is the check working; the round refunds and the replay continues. The count and reasons are in `summary.void_reasons`. |
| `pool at tick X, replay target Y` | A grid swap did not land the pool on mainnet's tick (e.g. a move larger than the trader's fork-local inventory). The replay stops rather than score a wrong hour; report the time printed with it. |
| `Chainlink report ... did not replay` | The transmitter's resent transaction reverted on the fork (e.g. a feed config change inside the range). Later settles then see an older answer; pick another `REPLAY_START`. |
| `identity registration minted no token` | The registering account still has code; the script clears the EIP-7702 delegations of anvil's public test keys on the fork, check that this step ran. |

Offline fallback (no RPC at all): `cd agents && uv run python -m vol_agents.round` runs the same flow
on a plain Anvil chain with `MockPool` and the Lite ERC-8004 registries (no Chainlink check).

## Recording script (≈ 3 min, recorded by the user)

| Time | Screen | Voice-over |
|---|---|---|
| 0:00–0:20 | README headline | "AI forecasters can always show their best calls. Verifiable Forecast Protocol locks every forecast before the outcome, verifies it after, and scores reputation by outcome." |
| 0:20–0:45 | Terminal: `bash demo/run.sh`, fork + deploy lines | "We fork Ethereum mainnet: the real Uniswap pool, the deployed ERC-8004 registries and the Chainlink ETH/USD feed. Six agents get ERC-8004 identities: three zk models and three reproducible time-series models registered by the hash of their public weights." |
| 0:45–1:15 | Round opened, features, commit lines, then reveal lines with "proof verified onchain" | "The contract computes the model inputs from the pool itself. Every agent first commits a sealed hash of five quantiles of log volatility, then reveals before the hour starts. The zk agents prove their model with EZKL and the contract verifies the proof against its own inputs; the other three run public weights registered by hash, and anyone can re-run them from chain data, every quantile within tolerance." |
| 1:15–1:30 | Tampered-proof lines | "Change a single output and the same proof is rejected." |
| 1:30–2:00 | Round lines scrolling, summary table | "We replay 24 real hours, five minutes at a time, with the real Chainlink reports. Each hour anyone can settle; settlement first checks the pool price against Chainlink." |
| 2:00–2:40 | Dashboard | "Over 24 rounds: each agent's pinball loss against a climatological baseline from training data, the fee share, the same scores read back from ERC-8004, written by the market contract, not by the agent, and Etherscan links to every replayed hour." |
| 2:40–3:00 | Known limitations in README | "Commits happen on a fork, so this is not yet a real-time ex-ante proof; models are small and trained on four weeks of one pool; one day says little about skill, and the reproducible time-series agents are zero-shot, not trained on this pool; their recompute is a tolerance check on one machine and software stack." |
