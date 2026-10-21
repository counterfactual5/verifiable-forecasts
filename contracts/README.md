# contracts/

Foundry project (solc 0.8.28). Settlement authority of the project; depends on nothing outside this directory.

| Path | What |
|---|---|
| `src/VolMarket.sol` | Parimutuel market on the realized volatility of a Uniswap V3 pool's TWAP tick; accepts AI forecasts only with an EZKL proof over features the contract derives from `observe()`; log-scores them at settlement |
| `src/lib/MarketMath.sol` | Shared pure math: `bucketOf`, `log1e18`, parimutuel `payout` |
| `src/verifier/` | EZKL-generated Halo2 verifiers, one per model (installed by `agents/vol_agents/build.py`); not hand-edited, excluded from `forge fmt`, compiled with the optimizer to fit EIP-170 |
| `src/interfaces/` | Minimal ERC20, Uniswap V3 `observe`, Halo2 verifier interfaces |
| `src/BaseFeeMarket.sol` | Legacy base-fee market from the previous direction; to be removed before submission |
| `test/fixtures/` | Shared vol fixture `vol_rv_cases.json` (also read by agents), real proof fixture, legacy base-fee cases |

```bash
forge build
forge test --match-path test/VolMarket.t.sol
```

The root `make check && make test` runs `forge fmt --check`, `forge build` and the full `forge test` with the
other subprojects. See `docs/ARCHITECTURE.md` for interfaces and encoding.
