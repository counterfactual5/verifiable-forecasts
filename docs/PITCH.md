# Pitch: Verifiable AI Forecasts, Held Accountable Onchain

ETH Shenzhen 2026 · Verifiable AI + Agent Infra · 3-minute pitch and slide outline.

Evidence grades follow `AGENTS.md`: **X** = measured in this repo (file cited), **C** = official
docs, **[待证据]** = not yet sourced and not used to justify any design decision.

## 3-minute script (English)

**0:00 Problem (30 s).** Every AI trading bot and forecasting agent shows you its best calls. You
can't check that a forecast was made *before* the outcome, by *the model claimed*, on *the inputs
claimed*, and there is no shared, tamper-proof scoreboard. So track records are marketing.

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

**问题（30 秒）**：AI 交易机器人和预测 agent 只展示自己猜对的那几次。没人能核实预测是事前做的、是它声称的模型做的、用的是它声称的输入，也没有公共、不可篡改的成绩单，所以“战绩”只是营销。

**方案（40 秒）**：我们在以太坊上开一个公开考场。考题是 Uniswap V3 ETH/USDC 池子下一小时的波动率落在 5 个区间中的哪一个。模型输入由合约从池子自己的预言机算出；agent 的预测必须附带 EZKL 生成的 zk 证明，证明是它登记的模型、用这组输入、算出了这组概率，合约验证通过才接受。一小时后任何人都能结算：合约用同一个池子算实际波动率，先用 Chainlink ETH/USD 交叉校验池子价格，再给每个预测打对数分，并以市场合约的身份写入该 agent 的 ERC-8004 信誉。

**为什么可信（30 秒）**：输入由合约算，不由预测者给；证明把模型、输入、输出绑在一起；答案来自池子的链上 TWAP；池子价格与 Chainlink 偏差超过 2% 就作废退款，不按可疑数据派彩。信誉由市场合约写，读取时只认市场合约地址，agent 无法自刷。

**演示（50 秒）**：主网 fork 上用真实池子、已部署的 ERC-8004 注册表和真实 Chainlink 喂价。三个 agent 证明并提交，篡改过的证明被拒；回放随后真实的一小时，结算，看板展示各 agent 的对数分与从 ERC-8004 读回的信誉。

**赛道与下一步（30 秒）**：Verifiable AI——链上验证的推理、合约自算的输入；Agent Infra——ERC-8004 身份加无法自报的信誉；Chainlink——喂价是结算护栏。局限：三个模型很小、用合成数据和占位区间训练；下一步按真实历史校准的区间重训，再开放给外部 agent 跑真实轮次。

## Slide outline (9 slides)

1. **Title.** "Verifiable AI Forecasts, Held Accountable Onchain." One line: zk-proven forecasts,
   onchain scores, ERC-8004 reputation. Team, track.
2. **Problem.** Forecast track records are self-reported and cherry-picked. Three questions nobody can
   answer today: made before the outcome? by this model? on these inputs?
3. **Why now.** ERC-8004 v2.0.0 Identity and Reputation registries are deployed on mainnet
   (`0x8004A169…a432`, `0x8004BAa1…9b63`; grade X, `spikes/facts/FACTS.md` §4) while the spec is still
   Draft. zk proofs of small-model inference fit an onchain verifier: EZKL proof ≈ 9 s / 1.23 GB, verifier
   19,656 B under EIP-170, verification ≈ 795k gas (grade X, `spikes/ezkl/README.md`). More agents are
   making onchain decisions [待证据].
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

## Numbers you can quote

| Claim | Value | Grade, source |
|---|---|---|
| Proof time per agent (demo laptop) | 3.7–9.1 s | X, `demo/fork_round.py` run output |
| EZKL prove / memory (spike) | ≈ 9 s / 1.23 GB | X, `spikes/ezkl/README.md` |
| Settle gas, 3 agents, Chainlink check + 3 ERC-8004 writes | 851,443 (sent with the gas estimate) | X, demo run (`docs/DEMO.md`) |
| Pool observation history (worst case) | ≈ 2.41 h, so a 1 h window is always readable | X, `spikes/facts/FACTS.md` §1 |
| Calibrated bounds | `[342, 620, 1124, 2052]` tick² over 2,010 hourly windows | X, `analysis/` |
