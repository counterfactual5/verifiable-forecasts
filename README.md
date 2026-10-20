# verifiable-forecasts

**An oracle-free, on-chain prediction market for Ethereum EIP-1559 base fees — with a verifiable AI
leaderboard.**

Each round asks: *where will the average base fee over the next K blocks land?* Participants bet on a
bucket. The contract samples the native EVM `BASEFEE` opcode (EIP-3198) once per block, settles the average
without an external oracle, and pays the winning bucket pro-rata. Forecasts are probability vectors recorded
before the window opens; the contract scores the probability assigned to the realized bucket with an integer
log score.

This is a **hackathon prototype** for ETH Shenzhen 2026. The default demo is local and uses Anvil; it does not
ask for real money or mainnet deployment.

## Why this is interesting

Most prediction markets need an oracle to decide the outcome. Base fees are already a protocol value exposed by
the EVM. This project turns that fact into a small, auditable market and uses the same settlement event as a
public benchmark for zero-shot time-series models.

## Repository map

```text
contracts/    Solidity market, `BASEFEE` sampling, settlement, log scoring, Foundry tests
analysis/     Python/uv data pipeline: RPC history -> window statistics -> data/params.json
agents/       Planned naive/EWMA/TimesFM forecast bots (boundary and interface documented)
dashboard/    Optional Streamlit viewer; static charts are the fallback
chainlink/    Planned Chainlink CRE workflow and local simulation

docs/SPEC.md              accepted scope and first-feature contract

docs/ARCHITECTURE.md     data-flow and dependency boundary
docs/plans/路线图.md      dated delivery roadmap
```

## Quickstart

### 1. Run the verification suite

Requirements: Foundry (`forge`, `anvil`), GNU Make (macOS `make` is fine), [uv](https://docs.astral.sh/uv/),
and Python >= 3.11.

One-time bootstrap (the only step that needs network access; installs the locked analysis dependencies):

```bash
make analysis-sync   # equivalent to: cd analysis && uv sync --locked
```

Then run the checks:

```bash
make check && make test
```

`make check` runs the Foundry suite (`forge fmt --check`, `forge build`, `forge test`) plus the analysis
`ruff check` and `pytest` suites. After the bootstrap, the Makefile exports `UV_LOCKED=1` and `UV_OFFLINE=1`,
so the analysis checks run offline against `uv.lock` and fail instead of silently downloading packages.

The contract suite is deterministic and offline: Foundry cheatcodes set the next block's base fee. It covers the full
round lifecycle, boundary buckets, coverage refunds, pro-rata claims, current-block `BASEFEE` reads, and
prediction log-score precision.

### 2. Calibrate from real base-fee history (optional, network required)

The checked-in code never requires downloaded market data. To create a local calibration, use the separate uv
project:

```bash
cd analysis
uv sync
uv run python src/fetch_fee_history.py \
  --rpc https://ethereum-rpc.publicnode.com \
  --from 26000000 --to 26200000
uv run python src/calibrate.py --history data/basefee_history.csv --out data/params.json
```

`data/` is git-ignored. The output `data/params.json` contains the `window_k` and `bounds_wei` values to pass
to `BaseFeeMarket.createRound` in a future round.

### 3. Run the local demo

The intended presentation sequence is:

1. Start Anvil.
2. Deploy `BaseFeeMarket` and the mock collateral token.
3. Create a round with calibrated (or demo) bounds.
4. Place bets and record three forecasts: naive, EWMA, and TimesFM.
5. Replay a base-fee path with `anvil_setNextBlockBaseFeePerGas`.
6. Call `sample()` during each block, then `settle()` and `claim()`.
7. Show the event log: native `BASEFEE` settlement, payouts, and the on-chain log-score leaderboard.

The replay driver and the three bots are the next implementation milestone; the contract is already tested as
the first vertical slice.

## Chainlink CRE sponsor track

The Chainlink integration lives under [`chainlink/`](chainlink/). The planned `workflow.ts` consumes the
parameter file and forecast output, and `simulate.sh` runs the same orchestration locally against Anvil.
The hackathon submission will explicitly label this as a **CRE CLI simulation**: the prediction market's
settlement does not trust Chainlink, while CRE demonstrates sponsor-compatible orchestration.

## What is deliberately out of scope

- LMSR market making; the prototype uses a transparent parimutuel pool.
- Blob fee markets (`BLOBBASEFEE`), FHE or commit-reveal sealed betting.
- ERC-8004 reputation, x402 payments, production authentication.
- Real funds, mainnet deployment, and a claim that a local demo is production-safe.
- A Streamlit dashboard before the contract + replay + forecast comparison path is complete.

See [`docs/SPEC.md`](docs/SPEC.md) for the accepted scope and [`docs/plans/路线图.md`](docs/plans/路线图.md)
for the delivery sequence.

## License

The prototype contract and project code are released under MIT, matching the Solidity source headers.
