# Pitch: Verifiable AI Forecasts, Held Accountable Onchain

ETH Shenzhen 2026 · Verifiable AI + Agent Infra · 3-minute pitch and slide outline.

Evidence grades follow `AGENTS.md`: **A** = primary source (regulator release, standard text,
peer-reviewed paper, a protocol's own docs about its own product), **B** = reputable press with
first-hand quotes, **C** = vendor blog or secondary write-up, **X** = measured by us (file or date
cited), **[待证据]** = not yet sourced and not used to justify any design decision.

## 3-minute script (English)

**0:00 Problem (30 s).** US regulators (SEC, CFTC, DOJ) have repeatedly acted against firms that
claimed AI-driven forecasting or trading while using no such AI, or quietly relying on humans,
sometimes backed by fabricated account balances. Outsiders today have essentially no way to check
whether an agent's published track record was produced by the model it claims, or cherry-picked:
made *before* the outcome, by *the model claimed*, on *the inputs claimed*, on a shared,
tamper-proof scoreboard. (Cases and sources: "Problem evidence" below.)

**0:30 What we built (40 s).** A public exam on Ethereum. The question: how volatile will the Uniswap
V3 ETH/USDC pool be over the next hour, in five buckets. The contract computes the model's inputs
from the pool's own oracle. An agent's forecast is accepted only with a zk proof, made with EZKL,
that its registered model produced exactly these probabilities from exactly these inputs. After the
hour, anyone can settle: the contract measures the realized volatility from the same pool, checks the
pool price against Chainlink ETH/USD, gives each forecast a log score, and writes that score into the
agent's ERC-8004 reputation as the market contract.

**1:10 Why trust it (30 s).** Four things nobody can fake: inputs come from the contract, not the
forecaster; the proof binds model, inputs and outputs; the answer comes from the pool's onchain
TWAP; and if the pool disagrees with Chainlink by more than 2 %, the round is voided and refunded
instead of paying out on manipulated data. Reputation is written by the market, and readers filter
by the market's address, so agents cannot pad their own record.

**1:40 Demo (50 s).** On a mainnet fork: real pool, deployed ERC-8004 registries, real Chainlink feed.
Three agents prove and submit; a tampered proof is rejected. We replay the real hour that followed,
settle, and the dashboard shows each agent's log score, read back from ERC-8004.

**2:30 Track fit and next (30 s).** Verifiable AI: onchain-verified inference on contract-derived
inputs. Agent Infra: ERC-8004 identity plus a reputation signal nobody can self-report. Chainlink:
the feed is the settlement guard. Honest limits: our three models are small and trained on synthetic
data with placeholder buckets; next is retraining on the calibrated real-history bounds, then live
rounds with outside agents.

## 3 分钟讲稿（中文）

**问题（30 秒）**：美国 SEC、CFTC 和司法部已多次处理“宣称用 AI 预测或交易、实际没有，或由人工冒充”的案件，相关战绩甚至用伪造的账户与余额撑场。对外部人来说，一个 AI agent 公布的预测战绩是否真由它声称的模型算出、是否经过挑选，今天基本无从核实：预测是不是事前做的、是不是它声称的模型、用的是不是它声称的输入，也没有公共、不可篡改的成绩单。（案例与出处见下文“痛点证据”。）

**方案（40 秒）**：我们在以太坊上开一个公开考场。考题是 Uniswap V3 ETH/USDC 池子下一小时的波动率落在 5 个区间中的哪一个。模型输入由合约从池子自己的预言机算出；agent 的预测必须附带 EZKL 生成的 zk 证明，证明是它登记的模型、用这组输入、算出了这组概率，合约验证通过才接受。一小时后任何人都能结算：合约用同一个池子算实际波动率，先用 Chainlink ETH/USD 交叉校验池子价格，再给每个预测打对数分，并以市场合约的身份写入该 agent 的 ERC-8004 信誉。

**为什么可信（30 秒）**：输入由合约算，不由预测者给；证明把模型、输入、输出绑在一起；答案来自池子的链上 TWAP；池子价格与 Chainlink 偏差超过 2% 就作废退款，不按可疑数据派彩。信誉由市场合约写，读取时只认市场合约地址，agent 无法自刷。

**演示（50 秒）**：主网 fork 上用真实池子、已部署的 ERC-8004 注册表和真实 Chainlink 喂价。三个 agent 证明并提交，篡改过的证明被拒；回放随后真实的一小时，结算，看板展示各 agent 的对数分与从 ERC-8004 读回的信誉。

**赛道与下一步（30 秒）**：Verifiable AI——链上验证的推理、合约自算的输入；Agent Infra——ERC-8004 身份加无法自报的信誉；Chainlink——喂价是结算护栏。局限：三个模型很小、用合成数据和占位区间训练；下一步按真实历史校准的区间重训，再开放给外部 agent 跑真实轮次。

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
   the spec is still Draft. zk proofs of small-model inference fit an onchain verifier: EZKL proof ≈ 9 s /
   1.23 GB, verifier 19,656 B under EIP-170, verification ≈ 795k gas (grade X, `spikes/ezkl/README.md`).
4. **Solution.** The exam loop diagram from the README: pool `observe()` → features → agent proves →
   `submitPrediction` verifies → window → `settle` → log score → ERC-8004.
5. **Why it's trustworthy.** Four guarantees: contract-computed public inputs; proof binds model,
   inputs, outputs and only the registered operator can submit; settlement from the pool's TWAP with
   `sample()` fallback, voided under 90 % coverage; Chainlink cross-check (> 200 bps or > 3900 s stale
   voids). Plus: reputation written by the market and filtered by market address.
6. **Demo.** Mainnet fork, real pool, deployed ERC-8004, real feed. Screenshot `docs/img/dashboard.png`
   and the terminal summary: RV 305 tick² onchain = 305 off-chain, Chainlink deviation 34.6 bps,
   three scores mirrored in `getSummary`, tampered proofs rejected (grade X, `docs/DEMO.md`).
7. **Track fit.** Verifiable AI (verified inference on contract-derived inputs), Agent Infra (ERC-8004
   identity + a reputation signal agents cannot self-report), Chainlink (feed as settlement guard).
8. **Limits, stated plainly.** Synthetic training data and placeholder buckets `[8, 20, 45, 110]` tick²
   (real hourly RV calibrates to `[342, 620, 1124, 2052]`; grade X, `analysis/`), so today nearly every
   real round lands in the top bucket. The fork demo replays the real hour by swaps. Features are
   snapshotted at `createRound`. Bets and forecasts are public. No Automation / CRE.
9. **Next.** Retrain on calibrated bounds and real history, rebuild verifiers; open model registration
   to outside agents; sealed forecasts; Chainlink Automation for `settle`; ERC-8004 Validation
   Registry once the spec settles.

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
| Proof time per agent (demo laptop) | 3.7–9.1 s | X, `demo/fork_round.py` run output |
| EZKL prove / memory (spike) | ≈ 9 s / 1.23 GB | X, `spikes/ezkl/README.md` |
| Settle gas, 3 agents, Chainlink check + 3 ERC-8004 writes | 851,443 (sent with the gas estimate) | X, demo run (`docs/DEMO.md`) |
| Pool observation history (worst case) | ≈ 2.41 h, so a 1 h window is always readable | X, `spikes/facts/FACTS.md` §1 |
| Calibrated bounds | `[342, 620, 1124, 2052]` tick² over 2,010 hourly windows | X, `analysis/` |
| SEC "AI washing" penalties, Delphia + Global Predictions | $400,000 total (2024-03-18) | A, [SEC 2024-36](https://www.sec.gov/newsroom/press-releases/2024-36) |
| Mirror Trading International, "bot" with fake demo balances | > $1.7 B in bitcoin, ≥ 23,000 people | A, [CFTC advisory](https://www.cftc.gov/LearnAndProtect/AdvisoriesAndArticles/AITradingBots.html), [8854-24](https://www.cftc.gov/PressRoom/PressReleases/8854-24) (2024-01-25) |
| Nate, claimed AI checkout, automation rate "effectively zero" (allegation) | > $40 M raised | A, [DOJ SDNY](https://www.justice.gov/usao-sdny/pr/tech-ceo-charged-artificial-intelligence-investment-fraud-scheme) (2025-04-09) |
| Truth Terminal tweets reviewed by a human before posting | creator's own statement | B, [CoinDesk](https://www.coindesk.com/tech/2024/12/10/the-truth-terminal-ai-crypto-s-weird-future) (2024-12-10) |
| ERC-8004: agent protocols "don't inherently cover agent discovery and trust"; pluggable trust models (reputation, re-execution, zkML, TEE) | Motivation section | A, [EIP-8004](https://eips.ethereum.org/EIPS/eip-8004) |
