# Pitch: 可验证预测协议 / Verifiable Forecast Protocol

ETH Shenzhen 2026 · 3-minute pitch and slide outline.

> 让 AI 预测事前锁定、事后验证、按结果记信誉。  
> Lock AI forecasts ex ante, verify them ex post, score reputation by outcome.

Evidence grades follow `AGENTS.md`: **A** = primary source (regulator release, standard text,
peer-reviewed paper, a protocol's own docs about its own product), **B** = reputable press with
first-hand quotes, **C** = vendor blog or secondary write-up, **X** = measured by us (file or date
cited), **[待证据]** = not yet sourced and not used to justify any design decision.

## 3-minute script (English)

**0:00 Problem (25 s).** Verifiable Forecast Protocol: lock AI forecasts ex ante, verify them ex post, score reputation by outcome. US regulators (SEC, CFTC, DOJ) have acted against firms that claimed
AI-driven forecasting or trading while using no such AI. From outside, nobody can check whether a
published track record was made before the outcome, by the model claimed, on the inputs claimed.

**0:25 What we built (35 s).** Case one on Ethereum: how volatile will the Uniswap V3 ETH/USDC pool
be over the next hour. The contract computes the model inputs from the pool's own oracle. Each agent
commits a hash of five quantiles of log realized volatility, then reveals them before the window
opens. After the hour, settlement measures realized volatility from the same pool, cross-checks the
price against Chainlink ETH/USD (more than 2 % apart voids and refunds the round), and scores every
forecast by pinball loss against a climatological baseline from training data. The market contract
writes the score into the agent's ERC-8004 reputation. Agents cannot write their own record. Five
volatility buckets remain only as betting pools.

**1:00 Agent, not keeper (25 s).** `settle` and `createRound` are keeper jobs: permissionless, any
script can call them. The forecaster is an agent in the ERC-8004 sense: it makes a judgment under
uncertainty, is accountable for it, and needs a reputation. The agent economy sits with consumers,
who pick forecasters by reputation. Per-request x402 payment is roadmap.

**1:25 Who consumes it (35 s).** `VolFeeConsumer` averages the revealed quantiles level by level,
weighted by ERC-8004 reputation, into an expected variance and an LVR-based dynamic fee. Mean absolute
error against the hindsight fair LVR fee (a reference known only after the hour, mean 4.06 bps):
forecast 2.16 bps, fixed 5 bps 2.36, previous-hour 3.52. At 2.16 the forecast fee has the lowest
error, though it runs low (mean 3.13 bps).
Twenty-four rounds, no significance test. Simulated on a fork; the v4 hook is unaudited and undeployed.

**2:00 Three verification tiers (35 s).** zk: small models attach an EZKL proof that the registered
model computed these quantiles from the contract's inputs. The reproducible tier is implemented: three
time-series models with open weights, timesfm-3.0, timestral-209m and chronos-2, their `modelHash`
registered; anyone re-runs a forecast from chain data with
`python -m vol_agents.tsfm_recompute`, every quantile within tolerance. Commit-only proves timing.
Reproducibility proves provenance, not accuracy.

**2:35 Demo and limits (25 s).** Every hour the server forks mainnet and replays the last 24 real
hours of pool and Chainlink data. The frozen run, 23–24 October, settled all 24 rounds, 0 voided.
4 of 6 agents (the three zk models and timestral-209m) have a lower mean pinball loss than the climatological baseline, timesfm-3.0 and chronos-2 do not; no significance test. Commits happen on the fork, so the live page is not yet a real-time ex-ante proof; next
are a persistent chain and outside agents.

## 3 分钟讲稿（中文）

**问题（25 秒）**：可验证预测协议：让 AI 预测事前锁定、事后验证、按结果记信誉。美国 SEC、CFTC、司法部已多次处理“宣称用 AI、实际没有”的案件。AI 预测战绩是否事前做出、是否出自声称的模型和输入，外部无从核实。

**方案（35 秒）**：案例 #1 的预测目标：Uniswap V3 ETH/USDC 池子下一小时的已实现波动率。输入由合约从池子预言机算出；agent 先只提交预测哈希，窗口开始前再公开 5 个分位数（对数波动率 10/25/50/75/90%）。一小时后用同一池子算实际波动率，用 Chainlink ETH/USD 交叉校验（偏差超过 2% 作废退款），按 pinball 损失与训练期气候基线比较打分，由市场合约写入 ERC-8004 信誉，agent 无法自刷。5 个波动区间只留作下注彩池。

**agent 与 keeper（25 秒）**：`settle`、`createRound` 是 keeper 活，无许可，谁都能调。预测者才是 ERC-8004 意义上的 agent：在不确定性下做判断、要担责、需要信誉。消费方按信誉挑预测者；按次 x402 付费是路线图。

**谁在用（35 秒）**：`VolFeeConsumer` 把已公开的分位数按 ERC-8004 信誉加权、逐分位平均，得到期望方差，按 LVR 定动态手续费。与事后公平费率（参照，均值 4.06）的平均绝对误差：预测定费 2.16，固定 5 bps 2.36，上一小时 3.52。预测定费误差最低（2.16），但费率偏低（均值 3.13）。24 轮，未做显著性检验。分叉上模拟，v4 hook 未部署、未审计。

**三档验证（35 秒）**：zk：小模型附 EZKL 证明，证明登记模型由合约输入得出这组分位数。可复现（已实现）：三个开源权重时序模型登记 `modelHash`，任何人可从链上数据重算，每个分位在容差内。仅提交只证明时间。可复现证明出处，不证明准确。

**演示与局限（25 秒）**：服务器每小时 fork 主网，回放最近 24 个真实小时的池子与 Chainlink 喂价。冻结运行（10 月 23–24 日）24 轮全部结算，0 作废。6 个 agent 中 4 个（三个 zk 模型和 timestral-209m）的平均 pinball 损失低于气候基线，timesfm-3.0 和 chronos-2 没有，未做显著性检验。提交在分叉上，实时页还不是事前证明；下一步上持久链、开放外部 agent。

## Slide outline (9 slides)

1. **Title.** "可验证预测协议 / Verifiable Forecast Protocol." One line: lock AI forecasts ex ante,
   verify them ex post, score reputation by outcome. Team.
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
   13,440 B under the 24,576 B EIP-170 limit, `verifyProof` ≈ 551k–553k gas, proof ≈ 4–7 s and under
   0.5 GB of memory (grade X, `agents/MODEL_CARD.md` §1).
4. **Solution.** The loop diagram from the README: pool `observe()` → features → agent forecasts
   5 quantiles of ln RV (zk agents prove) → `commitPrediction` → `revealPrediction` verifies → window →
   `settle` → pinball loss vs climatological baseline → ERC-8004 → fee share for forecasters above
   the baseline. The 5 buckets are betting pools only.
5. **Why it's trustworthy.** Four guarantees: contract-computed public inputs; proof binds model,
   inputs, outputs and only the registered operator can commit; forecasts stay sealed until the
   reveal phase, which ends before the window opens; settlement from the pool's TWAP with
   `sample()` fallback, voided under 90 % coverage; Chainlink cross-check (> 200 bps or > 3900 s stale
   voids). Plus: reputation written by the market and filtered by market address.
6. **Demo.** Hourly mainnet fork on the demo server, real pool, deployed ERC-8004, real feed, the
   last 24 real hours. window 2026-10-23 06:00 – 10-24 06:00 UTC, 24 settled / 0 voided, features and RV vs mainnet recompute,
   tampered proofs rejected, ERC-8004 `getSummary` counts, each agent's mean pinball loss against its
   round-matched climatological baseline, recompute verdicts (grade X, `dashboard/sample-replay.json`).
   Fee card: MAE against the hindsight fair LVR fee (reference, computable only after the hour,
   assumes volume is unaffected by the fee, mean 4.06 bps): 2.16 / 2.36 / 3.52 bps for forecast / fixed 5 bps / previous-hour
   (grade X, `summary.fee_strategies`). 24 rounds, no significance test. Commits are simulated on the
   fork, not a real-time ex-ante proof.
7. **Why "verifiable AI".** Verified inference on contract-derived inputs, onchain scoring, a
   reputation agents cannot self-report. Components used, no partnership
   implied: Uniswap V3 (outcome data), EZKL (proofs), Chainlink (feed as settlement guard), ERC-8004
   (identity and reputation).
8. **Limits, stated plainly.** zk models trained on 4 weeks of one pool; baseline quantiles and
   betting bounds from the training period only. On the 7-day test period the mean pinball loss is
   `mlp32_abs` 0.2856, `linear_abs` 0.2874, `mlp16` 0.2912, against the climatological baseline 0.3325
   and previous-hour y + residual 0.3254 (grade X, `agents/MODEL_CARD.md` §6); the 4-fold walk-forward
   keeps all three below the climatological baseline (§6.1). A week of test data and a day of live runs
   do not prove skill. Weights are public in the circuit, not hidden. The live page replays real hours
   on a fresh fork each hour: commits are simulated, not a real-time ex-ante proof. Features are
   snapshotted at `createRound`. Bets are public; forecasts are public after reveal, which ends before
   the window opens. No Automation / CRE, no paying users. Only small models fit the zk path; larger
   models join as reproducible (open weights, recomputable) or commit-only (timing, not provenance);
   a TEE tier is roadmap only. The consumer fee and the v4 hook are simulated on the fork only, not
   deployed or audited.
9. **Next.** A persistent chain so commits are real-time ex-ante proofs; deploying rolling retrained models (new verifier + `modelId`); open model registration
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
  (in `agents/`), which exits 0 only if the hash matches and every quantile is within 1e15 on the
  1e18 scale (the reveal is quantized to the 2^-12 grid before the commitment). Per-round verdicts
  are in `dashboard/sample-replay.json` (`reproduced_rounds`). This proves provenance, not accuracy.
- **Commit-only (implemented).** Any model, registered with `verifier = address(0)` and no
  `modelHash`; proves timing, not provenance.
- **TEE remote attestation (not implemented).** For large models and LLMs; trusts the hardware vendor.

**Why not opML?** Optimistic ML accepts a result unless someone disputes it within a challenge
window, and resolving a dispute needs an onchain single-step VM that replays one disputed step of
the model. That adds a delay longer than our one-hour round and a large contract to audit, and its
security rests on a 1-of-N honesty assumption: at least one honest verifier must be watching and
willing to pay to challenge. So opML is not our per-round settlement path. For a public model the
reproducible tier gives anyone the same check offchain today; it does not slash a wrong reveal
automatically, the score and reputation do the punishing. We plan opML-style challenges as the
dispute layer of the reproducible tier, against a per-tier bond and off the settlement path (design
only, not implemented: `docs/ARCHITECTURE.md` "验证档位与押金").

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
models `vol-300s-12-commit` (tag1 = `pinball` for both, value = −mean pinball loss), so `getSummary` filters by the tier a reader
accepts; a reader tells reproducible from commit-only by the onchain `modelHash`. This follows ERC-8004's
own design: "Trust models are pluggable and tiered", listing client-feedback reputation,
stake-secured re-execution, zkML proofs and TEE oracles (grade A, EIP-8004).

问责分四层：事前提交（提交哈希 + 公开截止）、客观结算（`observe()` + Chainlink 交叉校验）、成绩可携带
（ERC-8004）都不依赖 zk；只有“出处：确实是该模型算的”需要 zk 证明或公开重算。出处分级：zk（已实现，小模型）；
可复现（已实现，开源权重 + 固定推理代码，`registerModel` 登记 `modelHash`，任何人用 `vol_agents.tsfm_recompute`
从链上数据重算，每个分位误差 ≤ 1e15（1e18 刻度）；只证明出处不证明准确）；
仅提交（已实现，任意模型，`verifier = 0` 且无 `modelHash`，只证明时间不证明出处）；TEE 远程证明（大模型 / LLM，
需信任硬件厂商，未实现）。每轮结算不做 opML：它需要挑战窗口和链上单步 VM，长于一小时一轮，且依赖 1-of-N 诚实假设
（至少一个诚实验证者在盯并愿意发起挑战）；计划作为可复现档的争议层（按档位押金 + 挑战，不阻塞结算，未实现）。本项目最大的 zk 模型 709 个参数；链上 zkML 实用规模的通行说法见上表，
标为待证据。所有 agent（含 zk）都先提交后公开：提交的哈希为
`keccak256(abi.encode(roundId, modelId, outputs, salt, msg.sender))`，绑定发送者，抄来的提交哈希无法被他人公开；
公开阶段在窗口开始前结束，zk 模型在公开时验证证明；未公开的预测不计分、不分钱。写入 ERC-8004 时 zk 用
tag2 `vol-300s-12`，可复现与仅提交用 `vol-300s-12-commit`、靠链上 `modelHash` 区分，读取方按自己接受的等级过滤。

## Economics without a token / 不发币的经济模型

Only the items marked implemented exist in `contracts/src/VolMarket.sol`. The business model is an
unvalidated hypothesis: nobody pays us today.

**Today (implemented).** Bettors stake the market's ERC-20 (WETH in the demo) on one of five
volatility buckets (parimutuel pools, used only for betting) before `startTime`; winners split the whole pool minus the protocol fee pro rata. `feeBps` is fixed at
deployment (< 1000, 1 % in the demo); `collectFee` is callable by anyone once per round and sends the
fee to `owner`; voided and no-winner rounds refund every stake and carry no fee. Every revealed
forecast gets a pinball loss on its 5 quantiles of ln RV, computed at settlement from the pool's own
TWAP; −loss is written by the market
contract into its ERC-8004 reputation, so the score comes from onchain settlement, not
self-assessment. A fixed share of each round's fee, `predictorShareBps` (constructor parameter,
≤ 10000; 50 % in the demo), goes to the round's forecasters pro rata to their model's positive cumulative
excess Σ (baseline loss − agent loss) over all rounds so far, so losing rounds subtract (an unrevealed commit counts at the worst loss); each claims with `claimPredictorReward`, and
the last claimer receives the rounding remainder so the pool is paid out exactly. If nobody beats the
baseline cumulatively, the whole fee goes to the owner. The share is paid in the betting token from bettors' fees;
the contract mints nothing. It is small while betting volume is small.

**Later payers (hypothesis).** LP range management, Uniswap v4 dynamic-fee hooks, options market
makers, agent vaults. Payment by subscription as Synth does, or per request for an aggregated forecast
over x402 (roadmap). `VolFeeConsumer` is a simulated example of such a reader: it sets a dynamic
fee from reputation-weighted quantile forecasts (MAE against the hindsight fair LVR fee, a reference:
2.16 bps vs 2.36 for fixed 5 bps and 3.52 for the previous-hour fee; 24 rounds, no significance test). That DeFi already pays for hourly volatility forecasts is [待证据]. What is sourced: a
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
| Fee share only for pinball loss below the climatological baseline; unrevealed forecasts earn nothing | implemented |
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
结算时由池子 TWAP 算出 5 个分位数的 pinball 损失，由市场合约把 −损失写入 ERC-8004，分数来自链上结算而非自评。手续费中
`predictorShareBps`（构造参数，≤ 10000，演示为 50%）归 pinball 损失严格低于本轮气候基线的预测者，按超出
（基线损失 − 自身损失）比例分配，各自用 `claimPredictorReward` 领取，最后一位领取者拿取整余数，总额精确守恒；没人
超过基线时整笔手续费归 owner。分成来自下注者的手续费，合约不增发任何代币，下注量小时分成也小。
防作弊已实现的是 EZKL 绑定模型输出、绑定发送者的提交哈希与公开截止、只许已登记 operator 提交、仅高于
基线才分钱、未公开不计分，以及可复现与仅提交通道（单独的 ERC-8004 tag）；当前 `owner` 负责登记模型、设喂价与
ERC-8004 注册表并收取扣除分成后的手续费，`createRound` 无许可。以下均为未验证的设想：未来付费方是
LP 区间管理、Uniswap v4 动态费率 hook、期权做市、Agent 金库，按订阅或 x402 按次付费（“DeFi 已在为小时级
波动率预测付费”[待证据]；Synth 的付费订阅只说明存在类似需求）；冷启动靠团队自注彩池、自跑 3 个 agent、
主网 fork 真实行情；路线图上的防作弊是提交质押与罚没、缺席惩罚、MMC 式多样性
分、单 operator 权重上限；治理最多管分桶边界模板和手续费上限，开轮权不交给代币投票（UMA 治理操纵事件）。
不发币，因为同类协议增发补贴供给、收入远小于排放，可持续需求来自有盈亏的外部付费方；代币只作为路线图里
可选的质押罚没工具，前提是先有外部付费。

## Compared with Synth / 与 Synth 的区别

Synth is Bittensor subnet 50 (A, [synth-subnet](https://github.com/synthdataco/synth-subnet/)).

| | Synth (SN50) | This project |
|---|---|---|
| Scoring | validators score offchain with CRPS | settled onchain from Uniswap `observe()` TWAP, integer pinball loss on 5 quantiles vs a climatological baseline |
| Provenance | cannot prove which model produced a forecast | EZKL proof binds outputs to a registered model; weights are fixed in the circuit (`param_visibility = fixed`), not hidden |
| Incentive | subnet Alpha emissions | no token: betting pool and protocol fee; forecasters above baseline share part of the fee and earn ERC-8004 reputation usable across apps |
| Product | price-path distributions sold as an API | accountability layer for settlement and reputation; could give suppliers like Synth a verifiable track record |
| Paying users | yes | none yet |

Synth 由 validator 链下用 CRPS 打分，无法证明预测出自哪个模型，靠子网 Alpha 增发激励，卖价格路径分布
API；我们链上按 `observe()` TWAP 结算、整数 pinball 损失（5 个分位数，对比气候基线），EZKL 证明绑定已登记模型（权重固定在电路里，不是隐藏
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
| Proof time per model (laptop) | ≈ 4–7 s, 0.38–0.41 GB peak (4 proofs in parallel) | X, `agents/MODEL_CARD.md` §1 |
| Verifier size / `verifyProof` gas | 13,440 B (< 24,576 B) / 550,870–552,682 gas over 6 real proofs | X, `agents/MODEL_CARD.md` §1 |
| 24-hour live run | 24 settled / 0 voided (2026-10-23 06:00 – 10-24 06:00 UTC), 411 s wall time | X, `dashboard/sample-replay.json` |
| 24-hour live run, mean pinball loss per agent vs round-matched climatological baseline (no significance test) | baseline 0.289; `linear_abs` 0.270, `mlp16` 0.264, `mlp32_abs` 0.263, timesfm-3.0 0.304, timestral-209m 0.261, chronos-2 0.311; 4 of 6 below baseline | X, `dashboard/sample-replay.json` `summary.agents` |
| Consumer fee, MAE vs hindsight fair LVR fee (reference) | 2.16 / 2.36 / 3.52 bps forecast / fixed 5 bps / previous-hour (reference mean 4.06 bps; 2 of 24 rounds on the equal-weight fallback) | X, `dashboard/sample-replay.json` `summary.fee_strategies` |
| Reproducible timesfm-3.0 / timestral-209m / chronos-2 (zero-shot) | recompute within 1e15 per quantile: 72 of 72 forecasts (70 exact, max diff 2.44e14) | X, `dashboard/sample-replay.json` `summary.agents.*.reproduced_rounds` |
| Largest zk model | 709 parameters (`mlp32_abs`) | X, `agents/MODEL_CARD.md` §4 |
| Test-period mean pinball loss (lower is better) | `mlp32_abs` 0.2856, `linear_abs` 0.2874, `mlp16` 0.2912, previous-hour y + residual 0.3254, climatological baseline 0.3325 | X, `agents/MODEL_CARD.md` §6 |
| 4-fold walk-forward | all three zk models below the climatological baseline in every fold | X, `agents/MODEL_CARD.md` §6.1 |
| Settle gas, 32 revealed forecasters bound to ERC-8004 (Lite registry) | 4,415,928 | X, `forge test --match-test test_SettleGasWith32BoundPredictors` |
| Pool observation history (worst case) | ≈ 2.41 h, so a 1 h window is always readable | X, `spikes/facts/FACTS.md` §1 |
| Betting bucket bounds | `[202, 474, 856, 1712]` tick², quintiles of the training period (2026-09-10 – 10-08 UTC) | X, `agents/MODEL_CARD.md` §3 |
| SEC "AI washing" penalties, Delphia + Global Predictions | $400,000 total (2024-03-18) | A, [SEC 2024-36](https://www.sec.gov/newsroom/press-releases/2024-36) |
| Mirror Trading International, "bot" with fake demo balances | > $1.7 B in bitcoin, ≥ 23,000 people | A, [CFTC advisory](https://www.cftc.gov/LearnAndProtect/AdvisoriesAndArticles/AITradingBots.html), [8854-24](https://www.cftc.gov/PressRoom/PressReleases/8854-24) (2024-01-25) |
| Nate, claimed AI checkout, automation rate "effectively zero" (allegation) | > $40 M raised | A, [DOJ SDNY](https://www.justice.gov/usao-sdny/pr/tech-ceo-charged-artificial-intelligence-investment-fraud-scheme) (2025-04-09) |
| Truth Terminal tweets reviewed by a human before posting | creator's own statement | B, [CoinDesk](https://www.coindesk.com/tech/2024/12/10/the-truth-terminal-ai-crypto-s-weird-future) (2024-12-10) |
| ERC-8004: agent protocols "don't inherently cover agent discovery and trust"; pluggable trust models (reputation, re-execution, zkML, TEE) | Motivation section | A, [EIP-8004](https://eips.ethereum.org/EIPS/eip-8004) |
