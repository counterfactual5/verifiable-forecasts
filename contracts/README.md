# contracts/

Foundry project (solc 0.8.28). Settlement authority of the project; depends on nothing outside this directory.

| Path | What |
|---|---|
| `src/VolMarket.sol` | Parimutuel market on the realized volatility of a Uniswap V3 pool's TWAP tick; accepts AI forecasts only with an EZKL proof over features the contract derives from `observe()`; log-scores them at settlement |
| `src/lib/MarketMath.sol` | Shared pure math: `bucketOf`, `log1e18`, parimutuel `payout` |
| `src/verifier/` | EZKL-generated Halo2 verifiers, one per model (installed by `agents/vol_agents/build.py`); not hand-edited, excluded from `forge fmt`, compiled with the optimizer to fit EIP-170 |
| `src/interfaces/` | Minimal ERC20, Uniswap V3 `observe`, Halo2 verifier interfaces |
| `src/hooks/VolFeeHook.sol` | Uniswap v4 dynamic-fee hook charging the fee `VolFeeConsumer` recorded for the round covering the swap; fork simulation only, not deployed |
| `test/fixtures/` | Shared vol fixture `vol_rv_cases.json` (also read by agents and analysis), real proof fixture, v4 `PoolManager` creation code (`v4_pool_manager_v4.0.0.hex`, built from `lib/v4-core` with its own solc 0.8.26 profile because `PoolManager.sol` pins that compiler) |
| `lib/v4-core`, `lib/v4-periphery` | Vendored Uniswap v4: v4-core `v4.0.0` (`e50237c`, `src/` + `test/utils/CurrencySettler.sol`; core contracts BUSL-1.1, interfaces/libraries MIT, `src/test/` routers UNLICENSED, used only in tests) and v4-periphery `0c4e5bd` (`test/shared/HookMiner.sol` only, MIT) |

```bash
forge build
forge test --match-path test/VolMarket.t.sol
```

The root `make check && make test` runs `forge fmt --check`, `forge build` and the full `forge test` with the
other subprojects. See `docs/ARCHITECTURE.md` for interfaces and encoding.
