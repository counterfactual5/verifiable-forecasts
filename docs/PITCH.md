# Pitch: Verifiable AI Forecasts, Held Accountable Onchain

ETH Shenzhen 2026 · Track: Verifiable AI / 可验证 AI · 3-minute pitch and slide outline.

> 可验证 AI 预测协议：模型先提交、再证明，链上按真实结果打分、按信誉加权；第一个消费者：AMM 动态手续费。  
> A protocol for verifiable AI forecasts — commit, prove, settle on-chain, weight by reputation.

Evidence grades follow `AGENTS.md`: **A** = primary source (regulator release, standard text,
peer-reviewed paper, a protocol's own docs about its own product), **B** = reputable press with
first-hand quotes, **C** = vendor blog or secondary write-up, **X** = measured by us (file or date
cited), **[待证据]** = not yet sourced and not used to justify any design decision.

## 3-minute script (English)

**0:00 Problem (25 s).** A protocol for verifiable AI forecasts — commit, prove, settle on-chain, weight by reputation. US regulators (SEC, CFTC, DOJ) have acted against firms that claimed
AI-driven forecasting or trading while using no such AI. From outside, nobody can check whether a
published track record was made before the outcome, by the model claimed, on the inputs claimed.
(Cases and sources: "Problem evidence" below.)

**0:25 What we built (35 s).** A public exam on Ethereum: how volatile will the Uniswap V3 ETH/USDC
pool be over the next hour, in five buckets. The contract computes the model inputs from the pool's
own oracle. Agents commit a hash of their forecast, then reveal it before the window opens. After
the hour, settlement measures realized volatility from the same pool, cross-checks the price against
Chainlink ETH/USD (more than 2 % apart voids and refunds the round), and the market contract writes
each log score into the agent's ERC-8004 reputation. Agents cannot write their own record.

**1:00 Agent, not keeper (25 s).** `settle` and `createRound` are keeper jobs: permissionless, any
script can call them. The forecaster is an agent in the ERC-8004 sense: it makes a judgment under
uncertainty, is accountable for it, and needs a reputation. The agent economy sits with consumers,
who pick forecasters by reputation. Paying them per request over x402 is roadmap.

**1:25 Who consumes it (35 s).** `VolFeeConsumer` mixes the revealed forecasts, weighted by ERC-8004
reputation, into an LVR-based dynamic fee for the pool. In the replay we measured mean absolute
error against the fair LVR fee, which averages 3.71 bps. Fixed 5 bps has the lowest error, 1.84 bps.
The forecast fee scores 2.06, ahead of the previous-hour realized-vol fee at 2.81 but not ahead of
the fixed tier. This is simulated; no real fee is charged.

**2:00 Three verification tiers (35 s).** zk: small models attach an EZKL proof that the registered
model computed these outputs from the contract's inputs. The reproducible tier is implemented: three
time-series models with open weights, timesfm-3.0, timestral-209m and chronos-2, their `modelHash`
stored at `registerModel`; anyone re-runs a forecast from chain data with
`python -m vol_agents.tsfm_recompute`, every bucket within 0.001, and it held in 24/24 rounds for
each. Commit-only: timing, not provenance. Reproducibility proves provenance, not accuracy;
zero-shot timestral-209m happened to score −34.8 in total, above the uniform baseline of −38.6.

**2:35 Demo and limits (25 s).** Mainnet fork, real pool, real Chainlink feed, 24 real hours: 24
rounds settled, 0 voided, features and volatility equal to the mainnet recompute. `linear_abs` −35.5
and `mlp32_abs` −35.8 beat uniform −38.6; `mlp16` −39.2 does not. One replayed day proves little
about skill. Next: live rounds with outside agents.

## 3 分钟讲稿（中文）

**问题（25 秒）**：可验证 AI 预测协议：模型先提交、再证明，链上按真实结果打分、按信誉加权；第一个消费者：AMM 动态手续费。美国 SEC、CFTC 和司法部已多次处理“宣称用 AI、实际没有”的案件。一份 AI 预测战绩是否事前做的、是否出自声称的模型和输入，外部无从核实。

**方案（35 秒）**：案例 #1 的预测目标：Uniswap V3 ETH/USDC 池子下一小时波动率落在 5 个区间的哪一个。输入由合约从池子预言机算出；agent 先只提交预测哈希（commit），窗口开始前再公开预测本身。一小时后用同一池子算实际波动率，用 Chainlink ETH/USD 交叉校验（偏差超过 2% 作废退款），再把对数分以市场合约身份写入 agent 的 ERC-8004 信誉，agent 无法自刷。

**agent 与 keeper（25 秒）**：`settle`、`createRound` 是 keeper 活，无许可，谁都能调。预测者才是 ERC-8004 意义上的 agent：在不确定性下做判断、要担责、需要信誉。agent 经济在消费方：消费方按信誉挑预测者；按次 x402 付费是路线图。

**谁在用（35 秒）**：`VolFeeConsumer` 把已公开的预测按 ERC-8004 信誉加权合成，按 LVR 设定池子的动态手续费。回放里对比各策略与公平 LVR 费率（均值 3.71 bps）的平均绝对误差：固定 5 bps 误差最低，为 1.84 bps。预报定费 2.06，好过上一小时波动定费 2.81，没赢过固定档；模拟，不真实收费。

**三档验证（35 秒）**：zk：小模型附 EZKL 证明，证明登记模型由合约输入得出这组输出。可复现（已实现）：三个开源权重时序模型登记 `modelHash`，任何人用 `vol_agents.tsfm_recompute` 从链上数据重算，每桶误差 ≤ 0.001，均 24/24 轮。仅提交：只证明时间。可复现证明出处不证明准确；零样本 timestral-209m 总分 −34.8，高于均匀基线 −38.6。

**演示与局限（25 秒）**：主网 fork、真实池子与 Chainlink 喂价，回放 24 个真实小时：24 轮全部结算、0 作废，特征与波动率都与主网重算一致。`linear_abs` −35.5、`mlp32_abs` −35.8 跑赢均匀基线 −38.6，`mlp16` −39.2 没有。一天说明不了能力；下一步开放外部 agent 跑真实轮次。

## Slide outline (9 slides)

1. **Title.** "Verifiable AI Forecasts, Held Accountable Onchain." One line: zk-proven forecasts,
   onchain scores, ERC-8004 reputation. Team, track.
2. **Problem.** "AI" track records can't be checked from outside. Three enforcement cases, one line
   each: SEC vs Delphia and Global Predictions ("expert AI-driven forecasts" that weren't, 2024, A);
   CFTC's Mirror Trading International case study (a "bot" with fake MetaTrader demo balances,
   ≈ $1.7 B in bitcoin, A); DOJ indictment of Nate's founder (claimed no human intervention, automation
   rate "effectively zero", allegation, 2025, A). Three questions nobody can answer today: made before
   the outcome? by this model? on these inputs?
3. **Why now.** ERC-8004's motivation: agent protocols like MCP and A2A "don't inherently cover agent
   discovery and trust"; it proposes pluggable trust models (client-feedback reputation, stake-secured
   re-execution, zkML, TEE oracles; grade A, EIP-8004). Its Identity and Reputation registries v2.0.0 are
   deployed on mainnet (`0x8004A169…a432`, `0x8004BAa1…9b63`; grade X, `spikes/facts/FACTS.md` §4) while
   the spec is still Draft. zk proofs of small-model inference fit an onchain verifier: verifier
   ≈ 21.8 KB under the 24,576 B EIP-170 limit, `verifyProof` ≈ 849k gas, proof under 1 GB of memory
   (grade X, `agents/MODEL_CARD.md` §1).
4. **Solution.** The exam loop diagram from the README: pool `observe()` → features → agent proves →
   `commitPrediction` → `revealPrediction` verifies → window → `settle` → log score → ERC-8004 →
   fee share for forecasters above baseline.
5. **Why it's trustworthy.** Four guarantees: contract-computed public inputs; proof binds model,
   inputs, outputs and only the registered operator can commit; forecasts stay sealed until the
   reveal phase, which ends before the window opens; settlement from the pool's TWAP with
   `sample()` fallback, voided under 90 % coverage; Chainlink cross-check (> 200 bps or > 3900 s stale
   voids). Plus: reputation written by the market and filtered by market address.
6. **Demo.** Mainnet fork, real pool, deployed ERC-8004, real feed, 24 consecutive real hours
   (2026-10-21 06:00 – 10-22 06:00 UTC, blocks 26,239,037–26,246,222), about 13 minutes with
   `HOURS=24 bash demo/run.sh` plus 26.5 minutes of CPU recompute. Screenshot `docs/img/dashboard.png` and the summary: 24 settled,
   0 voided, features and RV equal the mainnet recompute every round, tampered proofs rejected, each
   agent's ERC-8004 `getSummary` count = 24. Totals: `linear_abs` −35.506, `mlp32_abs` −35.816,
   uniform −38.627, `mlp16` −39.190; reproducible zero-shot timestral-209m −34.761, chronos-2
   −35.824, timesfm-3.0 −37.553, each recomputed from chain data within 0.001 per bucket in 24/24
   rounds (grade X, `docs/DEMO.md`, `dashboard/sample-replay.json`).
   Fee card: MAE against the fair LVR fee (mean 3.71 bps) is 1.84 bps for fixed 5 bps (lowest),
   2.81 for previous-hour realized vol, 2.06 for the forecast fee; rounds with no reputation yet fall
   back to equal weights (3 of 24) (grade X, `dashboard/sample-replay.json` `summary.fee_strategies`).
7. **Track fit.** Single track: 可验证 AI / Verifiable AI (verified inference on contract-derived
   inputs, onchain scoring, a reputation agents cannot self-report). Components used, no partnership
   implied: Uniswap V3 (outcome data), EZKL (proofs), Chainlink (feed as settlement guard), ERC-8004
   (identity and reputation).
8. **Limits, stated plainly.** Models trained on 4 weeks of one pool, bounds `[202, 474, 856, 1712]`
   tick² from the training period only; on the 7-day test period `linear_abs` −1.418 and `mlp16`
   −1.423 beat the previous-hour transition baseline (−1.452) by only ≈ 0.03, `mlp32_abs` (−1.469)
   does not; uniform is −1.609 (grade X, `agents/MODEL_CARD.md`). The test week drifted (9 % of hours
   in the lowest bucket). An offline 4-fold walk-forward gives means of `linear_abs` −1.345 vs the
   baseline's −1.395, with `mlp32_abs` −1.398 slightly behind it (grade X, `agents/MODEL_CARD.md`
   §6.1). A week of test data and a day of replay do not prove skill. Weights are
   public in the circuit, not hidden. The fork demo replays real hours by swaps. Features are
   snapshotted at `createRound`. Bets are public; forecasts are public after reveal, which ends before
   the window opens. No Automation / CRE, no paying users. Only small models fit the zk path; larger
   models join as reproducible (open weights, recomputable) or commit-only (timing, not provenance);
   a TEE tier is roadmap only. The consumer fee is simulated, and fixed 5 bps tracks the fair fee
   more closely than the forecast fee in the replay.
9. **Next.** Deploying rolling retrained models (new verifier + `modelId`); open model registration
   to outside agents; Chainlink Automation for `settle`; x402 per-request payment by consumers;
   ERC-8004 Validation Registry once the spec settles; a TEE tier and submission stake (roadmap, not
   implemented; see "Tiered verification" below).

## Tiered verification / 分级验证（zk、可复现、仅提交已实现，TEE 为路线图）

Accountability has four layers. Three of them do not need zk at all:

| Layer | Mechanism | Needs zk? |
|---|---|---|
| Committed before the outcome | hash committed before `startTime − commitLead`, revealed before `startTime − revealLead` | no |
| Objective settlement | contract reads `observe()`, cross-checked with Chainlink | no |
| Portable record | score written to ERC-8004 by the market contract | no |
| Provenance: this model really computed it | zk proof of inference, or public recompute of open weights (reproducible tier) | zk tier only |

So provenance can be offered in tiers, and readers choose which tier they trust:

- **zk (implemented, small models).** What runs today: EZKL proof on contract-derived inputs.
- **Reproducible** (implemented): open weights plus a pinned runner, registered with
  `registerModel(address(0), operator, modelHash)`, where `modelHash` hashes the weights, config and
  runner. The replay's `agent-timesfm-3.0`, `agent-timestral-209m` and `agent-chronos-2` register
  the hash of public weights at a pinned revision; anyone recomputes a reveal on CPU with
  `uv run python -m vol_agents.tsfm_recompute --model <MODEL> --rpc-url <RPC> --market <MARKET> --round <ID> --model-id <ID>`
  (in `agents/`), which exits 0 only if the hash matches and every bucket is within 0.001 (the reveal
  is rounded to that grid before the commitment). It held in 24/24 rounds for each, all 72 exact
  (X, `dashboard/sample-replay.json` `reproduced_rounds`). This proves provenance, not accuracy:
  zero-shot timestral-209m totals −34.8, timesfm-3.0 −37.6, against the uniform baseline −38.6
  (X, same file).
- **Commit-only (implemented).** Any model, registered with `verifier = address(0)` and no
  `modelHash`; proves timing, not provenance.
- **TEE remote attestation (not implemented).** For large models and LLMs; trusts the hardware vendor.

**Why not opML?** Optimistic ML accepts a result unless someone disputes it within a challenge
window, and resolving a dispute needs an onchain single-step VM that replays one disputed step of
the model. That adds a delay longer than our one-hour round and a large contract to audit, and its
security rests on a 1-of-N honesty assumption: at least one honest verifier must be watching and
willing to pay to challenge. For a public model the reproducible tier gives anyone the same check
offchain without the challenge machinery; it does not slash a wrong reveal automatically, the score
and reputation do the punishing.

**How large can a zk model be?**

| Model / range | Parameters | Grade, source |
|---|---|---|
| This project's largest zk model, `mlp32_abs` | 709 | X, `agents/MODEL_CARD.md` §4 (parameter table) |
| EZKL feasibility spike (small model, fixed params, Softmax): prove 8.9 s, 1.23 GB peak, verifier 19,656 B, 794,589 gas | small, logrows 15 | X, `spikes/ezkl/README.md` (Apple M5) |
| On-chain practical range for zkML (general estimate, not measured here) | ~1e5–1e6 parameters | [待证据] (no measured source in this repo) |
| timesfm-3.0 / timestral-209m / chronos-2 | far beyond our zk path; served in the reproducible tier | [待证据] (exact count not cited here) |

All agents, zk included, go through commit-reveal. The commitment is
`keccak256(abi.encode(roundId, modelId, outputs, salt, msg.sender))`, so a copied commitment cannot be
revealed by anyone else, and forecasts stay hidden until the reveal phase, which closes before the
window opens. A zk agent's proof is checked at reveal; a commit-only reveal only has to match its
hash. Only a model's registered operator may commit for it (`modelId → operator`), and a commitment
that is never revealed is neither scored nor paid.

The tier is recorded in ERC-8004 tag2: zk models write `vol-300s-12`, reproducible and commit-only
models `vol-300s-12-commit` (tag1 = `logScore` for both), so `getSummary` filters by the tier a reader
accepts; a reader tells reproducible from commit-only by the onchain `modelHash`. This follows ERC-8004's
own design: "Trust models are pluggable and tiered", listing client-feedback reputation,
stake-secured re-execution, zkML proofs and TEE oracles (grade A, EIP-8004).

问责分四层：事前提交（提交哈希 + 公开截止）、客观结算（`observe()` + Chainlink 交叉校验）、成绩可携带
（ERC-8004）都不依赖 zk；只有“出处：确实是该模型算的”需要 zk 证明或公开重算。出处分级：zk（已实现，小模型）；
可复现（已实现，开源权重 + 固定推理代码，`registerModel` 登记 `modelHash`，任何人用 `vol_agents.tsfm_recompute`
从链上数据重算，每桶误差 ≤ 0.001，回放三个模型均 24/24 轮；只证明出处不证明准确）；
仅提交（已实现，任意模型，`verifier = 0` 且无 `modelHash`，只证明时间不证明出处）；TEE 远程证明（大模型 / LLM，
需信任硬件厂商，未实现）。不做 opML：它需要挑战窗口和链上单步 VM，长于一小时一轮，且依赖 1-of-N 诚实假设
（至少一个诚实验证者在盯并愿意发起挑战）。本项目最大的 zk 模型 709 个参数；链上 zkML 实用规模的通行说法见上表，
标为待证据。所有 agent（含 zk）都先提交后公开：提交的哈希为
`keccak256(abi.encode(roundId, modelId, outputs, salt, msg.sender))`，绑定发送者，抄来的提交哈希无法被他人公开；
公开阶段在窗口开始前结束，zk 模型在公开时验证证明；未公开的预测不计分、不分钱。写入 ERC-8004 时 zk 用
tag2 `vol-300s-12`，可复现与仅提交用 `vol-300s-12-commit`、靠链上 `modelHash` 区分，读取方按自己接受的等级过滤。

## Economics without a token / 不发币的经济模型

Only the items marked implemented exist in `contracts/src/VolMarket.sol`. The business model is an
unvalidated hypothesis: nobody pays us today.

**Today (implemented).** Bettors stake the market's ERC-20 (WETH in the demo) on one of five buckets
before `startTime`; winners split the whole pool minus the protocol fee pro rata. `feeBps` is fixed at
deployment (< 1000, 1 % in the demo); `collectFee` is callable by anyone once per round and sends the
fee to `owner`; voided and no-winner rounds refund every stake and carry no fee. Every revealed
forecast gets a log score computed at settlement from the pool's own TWAP and written by the market
contract into its ERC-8004 reputation, so the score comes from onchain settlement, not
self-assessment. A fixed share of each round's fee, `predictorShareBps` (constructor parameter,
≤ 10000; 50 % in the demo), goes to forecasters whose log score is strictly above the uniform
baseline `ln 0.2`, split pro rata to their excess score; each claims with `claimPredictorReward`, and
the last claimer receives the rounding remainder so the pool is paid out exactly. If nobody beats the
baseline, the whole fee goes to the owner. The share is paid in the betting token from bettors' fees;
the contract mints nothing. It is small while betting volume is small.

**Later payers (hypothesis).** LP range management, Uniswap v4 dynamic-fee hooks, options market
makers, agent vaults. Payment by subscription as Synth does, or per request for an aggregated forecast
over x402 (roadmap). `VolFeeConsumer` is a simulated example of such a reader: it sets a dynamic
fee from reputation-weighted forecasts, and in the replay fixed 5 bps still tracked the fair LVR fee
more closely (MAE 1.84 vs 2.06 bps). That DeFi already pays for hourly bucketed probabilities is [待证据]. What is sourced: a
paid subscription for a similar product exists. Synth's API plans are $49 / $199 / $499 per month (A,
[Synth docs](https://docs.synthdata.co/getting-started/credits-and-pricing)), and community reporting
puts its Q1 2026 MRR at about $70k (C, [TAO Daily](https://taodaily.io/james-ross-gives-synths-q1-report-on-community-call/)).

**Cold start.** The team seeds the betting pool with its own stakes, runs the three agents itself,
and replays real mainnet prices on a fork.

**Anti-gaming.**

| Mechanism | Status |
|---|---|
| EZKL proof binds outputs to the registered model on contract-computed inputs | implemented |
| Forecasts committed as a sender-bound hash before `startTime − commitLead`, revealed before `startTime − revealLead`, one per predictor per round | implemented |
| Only the model's registered operator may commit (`modelId → operator`) | implemented |
| Fee share only for scores above the uniform baseline; unrevealed forecasts earn nothing | implemented |
| Submission stake and slashing; penalty for missed rounds, participation rate | roadmap |
| Reproducible and commit-only channels for agents without proofs (open-weight or API time-series models), separate ERC-8004 tag; reproducible reveals recomputable from `modelHash` | implemented |
| Diversity score in the style of Numerai MMC (A, [Numerai docs](https://docs.numer.ai/numerai-tournament/scoring/meta-model-contribution-mmc)) | roadmap |
| Weight cap per operator | roadmap |

**Governance.** No token governance. Today the deployer is a fixed `owner` that registers models
(`registerModel`), sets the Chainlink feed (`setPriceFeed`) and the ERC-8004 registries
(`setReputation`), and receives the fee minus the forecasters' share; `feeBps`, `predictorShareBps`,
the commit and reveal leads, pool, Δ and N are constructor parameters. `createRound`
is permissionless: anyone can open a round with any four ascending bounds. Governance would at most
cover allowed bound templates or relative-bound multiples and a fee cap. Opening rounds will not go to
a token vote: a rogue actor who became a top-5 UMA staker swung a disputed Polymarket resolution
through UMA's token vote (B, [CoinDesk 2025-03-26](https://www.coindesk.com/markets/2025/03/26/polymarket-suffers-uma-governance-attack-after-rouge-actor-becomes-top-5-token-staker)).
Polymarket itself runs without a platform token (A, [Polymarket help](https://help.polymarket.com/en/articles/13364250-does-polymarket-have-a-token)).

**Why no token.** In comparable protocols emissions subsidize supply while revenue stays far below
emissions (Bittensor subnets, B, [Crypto Briefing](https://cryptobriefing.com/bittensor-subnets-annualized-revenue/)).
Durable demand comes from outside payers with their own P&L: Numerai's fund, Synth's subscribers,
Polymarket's traders. A token appears only on the roadmap, as an optional tool for submission stake and
slashing, and only once outside payers exist.

已实现：下注者押注 ERC-20，赢家按比例分走扣除手续费后的整个彩池；`feeBps` 部署时固定（< 1000，演示为
1%），`collectFee` 任何人可调、每轮一次、转给 `owner`，作废或无人押中的轮次全额退款不收费。每个已公开的预测在
结算时由池子 TWAP 算出对数分，由市场合约写入 ERC-8004，分数来自链上结算而非自评。手续费中
`predictorShareBps`（构造参数，≤ 10000，演示为 50%）归得分严格高于均匀基线 `ln 0.2` 的预测者，按超出
基线的分数比例分配，各自用 `claimPredictorReward` 领取，最后一位领取者拿取整余数，总额精确守恒；没人
超过基线时整笔手续费归 owner。分成来自下注者的手续费，合约不增发任何代币，下注量小时分成也小。
防作弊已实现的是 EZKL 绑定模型输出、绑定发送者的提交哈希与公开截止、只许已登记 operator 提交、仅高于
基线才分钱、未公开不计分，以及可复现与仅提交通道（单独的 ERC-8004 tag）；当前 `owner` 负责登记模型、设喂价与
ERC-8004 注册表并收取扣除分成后的手续费，`createRound` 无许可。以下均为未验证的设想：未来付费方是
LP 区间管理、Uniswap v4 动态费率 hook、期权做市、Agent 金库，按订阅或 x402 按次付费（“DeFi 已在为小时级
分档概率付费”[待证据]；Synth 的付费订阅只说明存在类似需求）；冷启动靠团队自注彩池、自跑 3 个 agent、
主网 fork 真实行情；路线图上的防作弊是提交质押与罚没、缺席惩罚、MMC 式多样性
分、单 operator 权重上限；治理最多管分桶边界模板和手续费上限，开轮权不交给代币投票（UMA 治理操纵事件）。
不发币，因为同类协议增发补贴供给、收入远小于排放，可持续需求来自有盈亏的外部付费方；代币只作为路线图里
可选的质押罚没工具，前提是先有外部付费。

## Compared with Synth / 与 Synth 的区别

Synth is Bittensor subnet 50 (A, [synth-subnet](https://github.com/synthdataco/synth-subnet/)).

| | Synth (SN50) | This project |
|---|---|---|
| Scoring | validators score offchain with CRPS | settled onchain from Uniswap `observe()` TWAP, integer log score |
| Provenance | cannot prove which model produced a forecast | EZKL proof binds outputs to a registered model; weights are fixed in the circuit (`param_visibility = fixed`), not hidden |
| Incentive | subnet Alpha emissions | no token: betting pool and protocol fee; forecasters above baseline share part of the fee and earn ERC-8004 reputation usable across apps |
| Product | price-path distributions sold as an API | accountability layer for settlement and reputation; could give suppliers like Synth a verifiable track record |
| Paying users | yes | none yet |

Synth 由 validator 链下用 CRPS 打分，无法证明预测出自哪个模型，靠子网 Alpha 增发激励，卖价格路径分布
API；我们链上按 `observe()` TWAP 结算、整数对数分，EZKL 证明绑定已登记模型（权重固定在电路里，不是隐藏
模型），无代币，激励是彩池手续费（高于基线的预测者分一部分）与跨应用的 ERC-8004 信誉，定位是可问责的结算与信誉层，也可以反过来给
Synth 这类供给方做可验证战绩。坦白说：Synth 已有真实付费用户，我们没有。

## Problem evidence / 痛点证据

Only grade A/B items carry the pitch. aixbt's track record and "humans posing as AI" claims about
BasisOS are grade C only and are deliberately not used.
只有 A/B 级材料用于论点；aixbt 战绩、BasisOS“人工冒充”仅 C 级，刻意不用。

1. **SEC: Delphia and Global Predictions (2024-03-18, A).** First "AI washing" actions. Global
   Predictions advertised "[e]xpert AI-driven forecasts" and called itself the "first regulated AI
   financial advisor"; Delphia claimed AI and machine-learning capabilities it did not have. Settled,
   $400,000 total civil penalties ($225,000 + $175,000).
   SEC 首批 “AI washing” 处罚：Global Predictions 宣传“专家级 AI 驱动预测”，Delphia 宣称并不具备的
   AI/机器学习能力；和解，合计罚款 40 万美元。
   <https://www.sec.gov/newsroom/press-releases/2024-36>
2. **CFTC: AI trading-bot advisory, Mirror Trading International case study (2024-01-25, A).** The
   advisory warns that AI "can't predict the future". Its case study: MTI sold a "proprietary bot
   trading program", created fake customer accounts and balances with MetaTrader demo accounts, and took
   more than $1.7 billion in bitcoin from at least 23,000 people; very little was actually traded.
   CFTC 客户警示：AI 交易机器人不是印钞机。案例 MTI 自称用专有交易机器人，用 MetaTrader 模拟账户伪造
   客户账户与余额，骗取超过 17 亿美元比特币，实际几乎没有交易。
   <https://www.cftc.gov/LearnAndProtect/AdvisoriesAndArticles/AITradingBots.html>,
   <https://www.cftc.gov/PressRoom/PressReleases/8854-24>
3. **DOJ SDNY: Nate founder indicted (2025-04-09, A; allegations, not a conviction).** Pitched the app
   as "able to transact online without human intervention"; per the indictment the actual automation
   rate was "effectively zero percent" and purchases were completed by hundreds of contractors in a
   Philippine call center. Raised more than $40 million.
   人工冒充 AI：Nate 创始人被起诉，宣称“无需人工介入”，起诉书称实际自动化率“实际上为零”、由菲律宾
   呼叫中心数百名外包人员手工完成；融资超 4,000 万美元。目前为指控，未定罪。
   <https://www.justice.gov/usao-sdny/pr/tech-ceo-charged-artificial-intelligence-investment-fraud-scheme>
4. **Crypto-native, optional (2024-12-10, B).** Truth Terminal's creator Andy Ayrey told CoinDesk that
   he reviews the bot's tweets before they go live and that "wallet decisions are made by me having a
   discussion with it". Not fraud; it shows that "AI agent" output often has an unannounced human in
   the loop.
   加密圈补充：Truth Terminal 创作者承认发帖前人工审阅、钱包决策由他与模型“讨论”后做出。这不是欺诈，
   只说明“AI agent”的产出里常有未明示的人工环节。
   <https://www.coindesk.com/tech/2024/12/10/the-truth-terminal-ai-crypto-s-weird-future>

## Numbers you can quote

| Claim | Value | Grade, source |
|---|---|---|
| Proof time per model (laptop) | ≈ 2 s in the fork replay; 7.3–17.8 s / 0.87–0.99 GB under concurrent tests | X, `docs/DEMO.md`, `agents/MODEL_CARD.md` §1 |
| Verifier size / `verifyProof` gas | ≈ 21.8 KB (< 24,576 B) / ≈ 849k gas | X, `agents/MODEL_CARD.md` §1, `docs/DEMO.md` |
| Fork replay | 24 real hours, 24 settled, 0 voided, ≈ 13 min (+ 26.5 min CPU recompute) | X, `docs/DEMO.md` |
| Replay totals (24 rounds) | `timestral-209m` −34.8, `linear_abs` −35.5, `mlp32_abs` −35.8, `chronos-2` −35.8, `timesfm-3.0` −37.6, uniform −38.6, `mlp16` −39.2 | X, `dashboard/sample-replay.json` `summary.agents` |
| Consumer fee, MAE vs fair LVR fee (fair mean 3.71 bps) | fixed 5 bps 1.84 (lowest), previous-hour realized vol 2.81, forecast 2.06 bps | X, `dashboard/sample-replay.json` `summary.fee_strategies` |
| Reproducible timesfm-3.0 / timestral-209m / chronos-2 (zero-shot) | recompute within 0.001 per bucket in 24/24 rounds each (all 72 exact) | X, `dashboard/sample-replay.json` `summary.agents.*.reproduced_rounds` |
| Largest zk model | 709 parameters (`mlp32_abs`) | X, `agents/MODEL_CARD.md` §4 |
| Test-period mean log score | `linear_abs` −1.418, `mlp16` −1.423, transition baseline −1.452, `mlp32_abs` −1.469, uniform −1.609 | X, `agents/MODEL_CARD.md` §6 |
| 4-fold walk-forward mean log score | `linear_abs` −1.345, `mlp16` −1.383, transition baseline −1.395, `mlp32_abs` −1.398, uniform −1.609 | X, `agents/MODEL_CARD.md` §6.1 |
| Settle gas, 32 revealed forecasters bound to ERC-8004 (Lite registry) | 4,415,928 | X, `forge test --match-test test_SettleGasWith32BoundPredictors` |
| Pool observation history (worst case) | ≈ 2.41 h, so a 1 h window is always readable | X, `spikes/facts/FACTS.md` §1 |
| Bucket bounds | `[202, 474, 856, 1712]` tick², quintiles of the training period (2026-09-10 – 10-08 UTC) | X, `agents/MODEL_CARD.md` §3 |
| SEC "AI washing" penalties, Delphia + Global Predictions | $400,000 total (2024-03-18) | A, [SEC 2024-36](https://www.sec.gov/newsroom/press-releases/2024-36) |
| Mirror Trading International, "bot" with fake demo balances | > $1.7 B in bitcoin, ≥ 23,000 people | A, [CFTC advisory](https://www.cftc.gov/LearnAndProtect/AdvisoriesAndArticles/AITradingBots.html), [8854-24](https://www.cftc.gov/PressRoom/PressReleases/8854-24) (2024-01-25) |
| Nate, claimed AI checkout, automation rate "effectively zero" (allegation) | > $40 M raised | A, [DOJ SDNY](https://www.justice.gov/usao-sdny/pr/tech-ceo-charged-artificial-intelligence-investment-fraud-scheme) (2025-04-09) |
| Truth Terminal tweets reviewed by a human before posting | creator's own statement | B, [CoinDesk](https://www.coindesk.com/tech/2024/12/10/the-truth-terminal-ai-crypto-s-weird-future) (2024-12-10) |
| ERC-8004: agent protocols "don't inherently cover agent discovery and trust"; pluggable trust models (reputation, re-execution, zkML, TEE) | Motivation section | A, [EIP-8004](https://eips.ethereum.org/EIPS/eip-8004) |
