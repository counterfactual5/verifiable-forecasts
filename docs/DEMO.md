# Demo: 24 real hours of VolMarket rounds on a mainnet fork

What the audience should see: six AI agents forecast, hour after hour, the volatility of the real
Uniswap V3 ETH/USDC 0.05% pool over 24 consecutive real hours. Each round, every agent commits a
hash first and reveals before the window opens; the three zk agents' forecasts are accepted only
with a valid EZKL proof; the other three (timesfm-3.0, timestral-209m, chronos-2) are reproducible:
public weights at a pinned revision registered by `modelHash`, and the replay re-derives every one
of their reveals from chain data with `python -m vol_agents.tsfm_recompute`, each bucket within
0.001. Each round settles from
the pool itself after a Chainlink cross-check, each agent's score accumulates in the deployed
ERC-8004 Reputation Registry (models without a verifier under their own `-commit` tag), and forecasters above the uniform
baseline share half of each round's fee. The dashboard then shows the 24-round track record.

Everything runs on one local Anvil fork. Nothing is broadcast to mainnet and no real funds move.

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
`observe()` on 307 grid points, the fee calibration, three EZKL proofs of ≈ 2 s per round and the
inference-service calls.

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
   terminal). Two bettors stake 1 WETH each (consensus bucket and
   runner-up). `sample(k)` runs at every 5-minute checkpoint, in the grid swap's block.
6. **Settle.** At the end of the hour: Chainlink cross-check, RV, winning bucket, log scores,
   ERC-8004 feedback (the script stops if any `ReputationWriteFailed` is emitted), bettor claims,
   `claimPredictorReward` for every forecaster above the baseline and `collectFee`.
7. **Tamper check** (round 0): each verifier must accept the honest proof and reject it with one
   output changed; its `verifyProof` gas is recorded.

The script prints one line per round and a summary table, and writes `demo/out/fork_replay.json`
(`schema: "vol-replay/v1"`; git-ignored). A committed copy of the run below is
`dashboard/sample-replay.json`.

## Expected output (24 h from 2026-10-21 06:00 UTC, fork block 26,238,538)

```text
[demo] agent-timesfm-3.0: model 3, reproducible, modelHash 0x68b3c2b8a273b629fc39f9889054babb218cabf58920daddf953f31c1a102a20, ERC-8004 agentId 54340
[demo] agent-timestral-209m: model 4, reproducible, modelHash 0xd5cca02d9f74a638830ddcadc293680e44ff865f161fe1dc430c83b05a5760ae, ERC-8004 agentId 54341
[demo] agent-chronos-2: model 5, reproducible, modelHash 0xf781b98b152b2b313399ed2a968f86f466f8c5134b64e0cced7ca86f02d2518b, ERC-8004 agentId 54342
...
[demo] round 0 2026-10-21 06:00:00Z: RV 538 (mainnet 538) bucket 2; feed age 539 s, dev 2.93 bps; linear_abs -1.498, mlp16 -1.388, mlp32_abs -1.480, timesfm-3.0 -1.452, timestral-209m -1.245, chronos-2 -1.284; fee bps fair 3.415 forecast 2.67 prev-hour 1.77
...
[demo] round 23 2026-10-22 05:00:00Z: RV 628 (mainnet 628) bucket 2; feed age 2375 s, dev 23.68 bps; linear_abs -1.484, mlp16 -1.522, mlp32_abs -1.455, timesfm-3.0 -1.590, timestral-209m -1.204, chronos-2 -1.284; fee bps fair 2.053 forecast 2.89 prev-hour 1.03
[demo] round 0: agent-timesfm-3.0 recompute exact (4 s)
[demo] round 0: agent-timestral-209m recompute exact (32 s)
[demo] round 0: agent-chronos-2 recompute exact (34 s)
...
[demo] round 23: agent-timesfm-3.0 recompute exact (3 s)
[demo] round 23: agent-timestral-209m recompute exact (30 s)
[demo] round 23: agent-chronos-2 recompute exact (31 s)

=== VolMarket replay on a mainnet fork: 24 h from 2026-10-21 06:00:00Z ===
fork block 26238538, market 0x024361c0eC3c1A9ED415E6ef3c859b48935DBe78, 32 Chainlink reports replayed, 2363 s wall time
rounds 24: settled 24, voided 0 {}; features match mainnet True, RV matches mainnet True; winning buckets [1, 4, 6, 9, 4]
agent                rounds  total ln p     mean  >base  reward WETH  ERC-8004 count
uniform baseline         24     -38.627   -1.609
agent-linear_abs         24     -35.506   -1.479     19     0.021930  24 (vol-300s-12)
agent-mlp16              24     -39.190   -1.633     16     0.021759  24 (vol-300s-12)
agent-mlp32_abs          24     -35.816   -1.492     18     0.023338  24 (vol-300s-12)
agent-timesfm-3.0        24     -37.553   -1.565     15     0.024543  24 (vol-300s-12-commit)
agent-timestral-209m     24     -34.761   -1.448     21     0.031373  24 (vol-300s-12-commit)
agent-chronos-2          24     -35.824   -1.493     14     0.027057  24 (vol-300s-12-commit)
agent-timesfm-3.0: recompute within tolerance in 24/24 rounds
agent-timestral-209m: recompute within tolerance in 24/24 rounds
agent-chronos-2: recompute within tolerance in 24/24 rounds
agent-linear_abs: honest proof verifies=True, tampered output verifies=False, verifyProof gas 848588
agent-mlp16: honest proof verifies=True, tampered output verifies=False, verifyProof gas 848516
agent-mlp32_abs: honest proof verifies=True, tampered output verifies=False, verifyProof gas 848504
fee strategies over 24 rounds (bps): mean fair 3.707, fixed 5.000, prev_hour 2.945, forecast 3.979; MAE vs fair fixed 1.837, prev_hour 2.809, forecast 2.065; mirror matches True, equal-weight rounds 3
left in market 0 wei; wrote demo/out/fork_replay.json
```

The JSON records per agent its onchain `tier` (`zk` / `reproducible` / `commit-only`) and
`model_hash`, and per round each agent's revealed `probs_e18` and, for the reproducible agents,
`reproduced` (exit code 0 of the recompute command), `recompute_verdict` (`exact` or `tolerant`)
and `recompute_max_abs_diff` (1e18 scale; all 72 were exact, difference 0).

**Voided rounds: 0 of 24.** The feed age at settle ranged 467–3455 s (limit 3900 s) and the
pool–feed deviation stayed ≤ 41.4 bps (limit 200 bps). A voided round would be listed under
`summary.void_reasons` and in its round's `outcome.void_reason` (Chainlink stale or invalid, price
deviation, tick out of range, feed call failed, or fewer than 90 % of checkpoints readable); its
stakes are refunded and nobody is scored.

What must hold on every run: features and RV match mainnet in every round, every honest proof
verifies and every tampered one does not, every reproducible recompute matches (`reproduced` true in
all rounds), no `ReputationWriteFailed`, each ERC-8004 `getSummary` count equals the number of
settled rounds, and the market keeps 0 wei. Scores are what they are: over these 24 hours
five of the six agents beat the uniform baseline in total and `mlp16` did not; the zero-shot
timestral-209m (a general time-series model, not trained on this pool) had the best total.

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
demo has not been run: cumulative and rolling log score per agent against the uniform baseline,
winning-bucket distribution, realized vol per round, cumulative fee share, ERC-8004 summaries and
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
| 0:00–0:20 | README headline | "AI forecasters can always show their best calls. We make every forecast provable and every score public." |
| 0:20–0:45 | Terminal: `bash demo/run.sh`, fork + deploy lines | "We fork Ethereum mainnet: the real Uniswap pool, the deployed ERC-8004 registries and the Chainlink ETH/USD feed. Six agents get ERC-8004 identities: three zk models and three reproducible time-series models registered by the hash of their public weights." |
| 0:45–1:15 | Round opened, features, commit lines, then reveal lines with "proof verified onchain" | "The contract computes the model inputs from the pool itself. Every agent first commits a sealed hash, then reveals before the hour starts. The zk agents prove their model with EZKL and the contract verifies the proof against its own inputs; the other three run public weights registered by hash, and anyone can re-run them from chain data: the replay does exactly that, and every bucket is within 0.001 in every round." |
| 1:15–1:30 | Tampered-proof lines | "Change a single output and the same proof is rejected." |
| 1:30–2:00 | Round lines scrolling, summary table | "We replay 24 real hours, five minutes at a time, with the real Chainlink reports. Each hour anyone can settle; settlement first checks the pool price against Chainlink." |
| 2:00–2:40 | Dashboard | "Over 24 rounds: each agent's cumulative log score against a uniform guess, the winning buckets, the fee share, the same scores read back from ERC-8004, written by the market contract, not by the agent, and Etherscan links to every replayed hour." |
| 2:40–3:00 | Known limitations in README | "Models are small and trained on four weeks of one pool; one day says little about skill, and the reproducible time-series agents are zero-shot, not trained on this pool; their recompute is a tolerance check on one machine and software stack." |
