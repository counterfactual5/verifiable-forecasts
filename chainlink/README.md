# chainlink/

Chainlink integration: an ETH/USD price-feed cross-check at settlement.

**Planned — not implemented yet.** Nothing in this directory or in `contracts/` reads a Chainlink feed today.
The design below follows `docs/plans/实施计划.md` (section 8) and the narrowed roadmap stage; it will be
updated once the code lands.

## What it will do

`VolMarket` settles from the Uniswap V3 pool's `observe()`. The cross-check compares the pool's price with
the Chainlink ETH/USD feed at settlement, so a round is not paid out on pool data that disagrees with an
independent price source.

- **Opt-in:** the owner calls `setPriceFeed(feed)`; the zero address turns the check off. The constructor
  does not change, and with no feed set, settlement, voiding and refunds behave exactly as today.
- **Feed:** mainnet ETH/USD `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` (8 decimals), read with
  `latestRoundData`; a `MockAggregator` is used in tests and the offline demo.
- **Pool price:** the TWAP tick over the last Δ before settlement (`observe([Δ, 0])`), converted to an
  8-decimal USD price with a self-written fixed-point `1.0001^tick` (Uniswap's GPL TickMath is not ported).
- **Thresholds** (from `docs/plans/实施计划.md`): deviation > **200 bps**, a feed update older than
  **3900 s**, or `answer ≤ 0` voids the round. Voiding reuses the existing full refund path and emits
  `PriceCheckFailed`.
- **Late settlement:** the comparison uses the price at settlement time, not at the end of the window.

## Limits

- It checks a single price point. Manipulation inside a segment, which moves the segment-mean ticks that
  realized volatility is built from, is not detected by this check.
- On real data the two prices differ by about 0.04 % (`spikes/facts/FACTS.md`), so the void branch is only
  exercised with the mock feed.

## Not in this phase

Chainlink CRE workflows and Automation (automatic `settle` calls) are out of scope for now. Settlement stays
permissionless: anyone can call `settle(id)` after the window.
