# chainlink/

Chainlink ETH/USD cross-check in `VolMarket.settle`.

## Configuration and behavior

The market owner can call `setPriceFeed(feed)` to opt into the check; passing the zero address disables it. No constructor or agent deployment argument changes are required. With no feed configured, settlement follows the existing realized-volatility path. With a feed configured, the market compares its pool price at settlement with `latestRoundData()` from the configured Chainlink aggregator. The price feed interface supplies `decimals()` and the five-field round data tuple.

The pool tick is the floor-rounded mean tick over the latest `delta` seconds from `observe([delta, 0])`. The contract uses integer fixed-point `1.0001^tick` math to derive an 8-decimal ETH/USD price; it does not import Uniswap's GPL TickMath. Feed answers are normalized to 8 decimals. The mainnet ETH/USD feed is `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` with 8 decimals.

A round is voided and fully refundable if the feed call fails, the answer is non-positive, `updatedAt` is in the future or more than 3900 seconds old, or the absolute price deviation is strictly greater than 200 bps. The market emits `PriceCheckFailed` with a reason code and relevant prices. At exactly 200 bps, the deviation check passes. Late settlement compares against the price at settlement time, not the end of the betting window.

## Scope

Chainlink CRE and Automation (automated `settle` calls) are not implemented. Settlement remains permissionless; anyone may call `settle(id)` after the window.

## Limitations

The cross-check covers one mean tick over the latest `delta` seconds. It does not detect pool manipulation within a segment or replace the volatility oracle. Mock feed tests cover matching, stale, invalid and divergent values; production deployments must configure a feed with the intended network, asset and decimals.
