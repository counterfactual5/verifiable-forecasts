# Demo: one VolMarket round on a mainnet fork

What the audience should see in about three minutes: four AI agents forecast the next hour's
volatility of the real Uniswap V3 ETH/USDC 0.05% pool. Each commits a hash first and reveals before the
window opens; the three zk agents' forecasts are accepted only with a valid EZKL proof, the fourth is
commit-only (timing, not provenance). The market settles from the pool itself after a Chainlink
cross-check, each agent's score ends up in the deployed ERC-8004 Reputation Registry (commit-only
under its own tag), and forecasters above the uniform baseline share half of the fee.

Everything runs on a local Anvil fork. Nothing is broadcast to mainnet and no real funds move.

## Prerequisites

- Foundry (`anvil`, `cast`, `forge`), [uv](https://docs.astral.sh/uv/), Python ≥ 3.12, `python3`.
- `cd agents && uv sync` once. The EZKL circuits must be built (`uv run python -m vol_agents.build`,
  cached under `agents/out/`; the first build needs the KZG SRS, see `agents/README.md`).
- A mainnet RPC. Without configuration the public tenderly gateway is used (the same default as
  `analysis/src/fetch_swaps.py`). A private endpoint is faster: `cp .env.example .env` and set
  `MAINNET_RPC_URL`. Never commit `.env`.
- Optional: `VOL_TSFM_API_URL` / `VOL_TSFM_API_KEY` in `.env` for the commit-only agent's
  time-series model API (format in `agents/README.md`). Unset, it uses a deterministic placeholder
  forecast and is labeled `placeholder`.

## Run

```bash
make demo    # or: bash demo/run.sh
```

Takes about 2–4 minutes (forge build, three EZKL proofs of 2–9 s each, a few hundred fork RPC
reads). Steps, as printed with `[demo]`:

1. **Fork.** Picks the most recent Chainlink ETH/USD update that is at least 70 minutes old and forks
   mainnet at that block (override with `FORK_BLOCK`). The hour after it has already happened on
   mainnet, so it can be replayed.
2. **Deploy.** `VolMarket` (WETH stake, 1 % fee, 50 % of it to forecasters, Δ = 300 s, N = 12,
   commit lead 90 s, reveal lead 30 s) wired to the real pool, the deployed ERC-8004
   Identity/Reputation and the Chainlink feed; one EZKL verifier per zk model, and a commit-only model
   registered with `verifier = 0`. Each agent registers an ERC-8004 identity and links it to its model.
3. **Open.** `createRound` snapshots 16 features from the real pool's last 85 minutes. The script
   recomputes them from `observe()` at the same block and stops if they differ.
4. **Commit, then reveal.** Each zk agent reads the features and proves its model with EZKL; the
   commit-only agent asks its API (or the placeholder). All four commit a salted hash; the script
   jumps to the commit deadline and all four reveal. For zk agents the contract verifies the proof
   against its own stored features at reveal. The script then calls each verifier with the same proof
   and one output changed: it must be rejected.
5. **Bet.** Bettor 0 stakes 1 WETH on the agents' consensus bucket, bettor 1 on the runner-up.
6. **Window.** For each of the 12 checkpoints: `sample(k)`, then a trader swaps the forked pool to
   that segment's real TWAP tick, read from mainnet's own `observe()`.
7. **Settle.** Chainlink cross-check, RV, winning bucket, log scores, ERC-8004 feedback; bettor claims,
   `claimPredictorReward` for every forecaster above the baseline, and `collectFee` for the owner's
   part. `settle` is sent with `cast`'s gas estimate, the lowest limit it accepts: the market
   reverts instead of letting a starved registry call fail, so all four writes must land (the script
   stops if any `ReputationWriteFailed` is emitted). The script prints the summary and writes
   `demo/out/fork_round.json`.

## Expected output (one run, fork block 26,247,424)

```text
[demo] window: replaying the real pool's 5-minute TWAP path
[demo] agent-tsfm-api: committed (commit-only, forecast from placeholder)
[demo] agent-linear_abs: revealed, proof verified onchain
...
[demo] agent-tsfm-api: revealed, no proof (commit-only)
[demo] window: replaying the real pool's 5-minute TWAP path
[demo] segment  0: sell USDC    tick 198459 -> 198448 (real 198448)
...
[demo] segment 11: sell WETH    tick 198471 -> 198474 (real 198474)
[demo] settled=True voided=False RV=259 bucket=4

=== VolMarket round on a mainnet fork ===
realized vol 259 tick^2 (off-chain recompute 259, real mainnet hour 300), bounds [8, 20, 45, 110], winning bucket 4, voided False
Chainlink ETH/USD 2406.75 vs pool 2403.34: 14.18 bps (max 200), feed age 3752 s (max 3900)
settle gas 1096683 (estimated limit 1102040), events {'price_check_failed': 0, 'reputation_write_failed': 0, 'erc8004_feedback_logs': 4}
agent               type            agentId   p_win  logScore  reward WETH  ERC-8004 getSummary
agent-tsfm-api      commit-only       55250   0.972    -0.029     0.003194  count=1 value=-0.029 (vol-300s-12-commit)
agent-mlp32_abs     zk proof          55249   0.941    -0.061     0.003129  count=1 value=-0.061 (vol-300s-12)
agent-mlp16         zk proof          55248   0.497    -0.699     0.001840  count=1 value=-0.699 (vol-300s-12)
agent-linear_abs    zk proof          55247   0.496    -0.700     0.001837  count=1 value=-0.700 (vol-300s-12)
agent-tsfm-api: commit-only, forecast source placeholder
agent-linear_abs: honest proof verifies=True, tampered output verifies=False
agent-mlp16: honest proof verifies=True, tampered output verifies=False
agent-mlp32_abs: honest proof verifies=True, tampered output verifies=False
bettor 0x15d34AAf… bucket 4: payout 1.9800 WETH
bettor 0x9965507D… bucket 3: payout 0.0000 WETH
fee 0.0200 WETH: owner 0.0100, forecasters 0.0100 (5000 bps, above baseline -1.609), left in market 0 wei
```

Numbers change with the fork block. Things that must hold on every run: the off-chain recompute
equals the onchain RV, every honest proof verifies and every tampered one does not,
`reputation_write_failed` is 0, each `getSummary` value equals that agent's log score under its tier's
tag, and the forecasters' rewards add up to exactly their share of the fee. In this run the
commit-only placeholder scored best; it is a heuristic around the trailing realized vol, not a
trained model, and one round says nothing about skill.

## Dashboard

```bash
python3 -m http.server 8765 --bind 127.0.0.1    # from the repo root
open http://127.0.0.1:8765/dashboard/
```

The page reads `demo/out/fork_round.json`, or the committed `dashboard/sample-round.json` if the
demo has not been run. Screenshot: [`docs/img/dashboard.png`](img/dashboard.png).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Failed to estimate gas` / RPC timeouts | The fork pulls pool storage lazily; the public gateway can be slow. Re-run (Anvil caches fork reads on disk per block) or set a private `MAINNET_RPC_URL`. |
| `voided True`, `price_check_failed` 1 | Pool and feed disagree by more than 200 bps (a very volatile replayed hour) or the feed answer is over 3900 s old (a `FORK_BLOCK` that is not a feed-update block). Both are the cross-check working; pick another block to show a settled round. |
| `window: real hour unavailable, scripted swaps` | The replayed hour is outside the pool's mainnet observation history (an old `FORK_BLOCK`). The script falls back to small back-and-forth swaps. |
| `identity registration minted no token` | The registering account still has code; the script clears the EIP-7702 delegations of anvil's public test keys on the fork, check that this step ran. |

Offline fallback (no RPC at all): `cd agents && uv run python -m vol_agents.round` runs the same flow
on a plain Anvil chain with `MockPool` and the Lite ERC-8004 registries (no Chainlink check).

## Recording script (≈ 3 min, recorded by the user)

| Time | Screen | Voice-over |
|---|---|---|
| 0:00–0:20 | README headline | "AI forecasters can always show their best calls. We make every forecast provable and every score public." |
| 0:20–0:45 | Terminal: `bash demo/run.sh`, fork + deploy lines | "We fork Ethereum mainnet: the real Uniswap pool, the deployed ERC-8004 registries and the Chainlink ETH/USD feed. Three agents get ERC-8004 identities." |
| 0:45–1:15 | Round opened, features, commit lines, then reveal lines with "proof verified onchain" | "The contract computes the model inputs from the pool itself. Every agent first commits a sealed hash, then reveals before the hour starts. The zk agents prove their model with EZKL and the contract verifies the proof against its own inputs; the fourth agent is commit-only: it proves when it forecast, not which model did." |
| 1:15–1:30 | Tampered-proof lines | "Change a single output and the same proof is rejected." |
| 1:30–2:00 | Segment replay lines, settle line | "We replay the real hour that followed, five minutes at a time, then anyone can settle. Settlement first checks the pool price against Chainlink." |
| 2:00–2:40 | Dashboard | "Realized vol, the winning bucket, each agent's log score and model type, the same score read back from ERC-8004 reputation, written by the market contract, not by the agent, and half the fee shared among forecasters that beat a uniform guess." |
| 2:40–3:00 | Known limitations in README | "Models are trained on synthetic data with placeholder buckets; retraining on calibrated bounds is next." |
