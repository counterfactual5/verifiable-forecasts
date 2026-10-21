# 架构说明：可验证 AI 预测的链上问责

本文与根目录 `README.md` 配套：README 面向评审快速上手，本文记录已实现的组件边界、数据流、合约接口与信任边界。设计依据见 `docs/plans/实施计划.md` 第 4–8 节；标「计划中」的部分尚未实现，按当前收窄后的设计简述，实现后再更新对应小节。

## 1. 一句话

合约从 Uniswap V3 池子的 `observe()` 自己算出考题输入和结算答案；AI agent 的预测只有附带 EZKL 推理证明、且证明的公开输入与合约自算的特征一致时才被接受；结算时合约按对数评分给每个预测打分。

## 2. 数据流（已实现部分）

```text
Uniswap V3 ETH/USDC 0.05% 池（演示与测试中为 MockPool）
        │ observe(secondsAgos) → tickCumulative[]
        ▼
VolMarket.createRound(startTime, bounds)
        │ 取 18 个点 [17Δ … 0] → 17 个段均值 → 16 个相邻差 f_j
        │ 存 x_int_j = clamp(f_j, −64, 64) × 128
        ▼
agents/（每个 agent 一个模型、一个 operator 账户）
        │ getFeatures(id) → 本地核对与 contract_math 镜像一致
        │ EZKL witness → prove（子进程）
        ▼
VolMarket.submitPrediction(id, modelId, proof, outputs[5])     ← startTime 之前
        │ 校验 operator、输出范围；instances = [16 个存储特征, 5 个输出]
        │ 低层 call 该模型的 EZKL 验证合约 verifyProof(proof, instances)
        │ 通过 → 归一化为 probs（和恰为 1e18）并记录
        ▼
窗口内：任何人 sample(id, k) 把 tickCumulative(t_k) 存入检查点（可选兜底）
        ▼
VolMarket.settle(id)                                          ← t_N 之后
        │ 已存检查点 + 其余点批量 observe（失败则逐点 try/catch）
        │ RV（tick²）→ MarketMath.bucketOf → 获胜桶
        │ 覆盖率 < 90% → voided（全额退款）
        │ 每个预测：logScore = max(ln p_win, −18e18)
        ▼
claim(id)：赢家按比例分池（扣 fee）；作废或获胜桶无人下注时全额退款
        ▼
agents 读 getPrediction → out/compare_round.json（按链上分数排序）
```

## 3. 合约

### `VolMarket.sol`

构造参数：`(token, feeBps, pool, delta, nSegments)`；`feeBps < 1000`，`nSegments ≥ 2`，`17 × delta` 须放得进 `uint32`。owner 为部署者。

| 接口 | 谁调用 | 作用 |
|---|---|---|
| `registerModel(verifier, operator)` | owner | 登记一个模型的 EZKL 验证合约，返回 modelId；只有 `operator` 能用该模型提交（证明不绑定发送者，防止复制他人证明） |
| `createRound(startTime, bounds)` | 任何人 | `bounds` 为 4 个严格递增的 tick² 边界（5 个桶）；`startTime` 须晚于当前时间；从 `observe()` 快照 16 个特征 |
| `bet(id, bucket, amount)` | 任何人 | `startTime` 前下注（ERC20 `transferFrom`） |
| `submitPrediction(id, modelId, proof, outputs[5])` | 模型 operator | `startTime` 前、每个地址每轮一次、每轮最多 32 个预测者；证明通过才记录 |
| `sample(id, k)` | 任何人 | `t_k` 之后存一个检查点，每个 k 一次 |
| `settle(id)` | 任何人 | `t_N` 之后结算一次：算 RV、定桶、评分或作废 |
| `claim(id)` | 下注者 | 赢家领取 `MarketMath.payout`；作废 / 无人押中时全额退款 |
| `getRound` / `getFeatures` / `getCheckpoint` / `getStake` / `getPrediction` / `predictorCount` / `modelCount` | 只读 | 供 agents 与看板读取 |

事件：`ModelRegistered`、`RoundCreated`（含 bounds 与 features）、`BetPlaced`、`PredictionSubmitted`、`CheckpointSampled`、`RoundSettled`、`RoundVoided`、`PredictionScored`、`Claimed`。

### `lib/MarketMath.sol`

`bucketOf`（半开区间：桶 0 为 `v < b[0]`，桶 i 为 `b[i−1] ≤ v < b[i]`，最后一桶 `v ≥ b[n−1]`）、`log1e18`（1e18 定点自然对数，定义域 [1, 1e18]）、`payout`（`stake × (total − fee) / winners`，向下取整）。`BaseFeeMarket` 与 `VolMarket` 共用。

### `verifier/`

EZKL 生成的 Halo2 验证合约，每个模型一份（`LinearAbsVerifier`、`Mlp16Verifier`、`Mlp32AbsVerifier`），由 `agents/vol_agents/build.py` 安装，只改了合约名；`SpikeModelVerifier` 来自 `spikes/ezkl`，供 `VolMarket.t.sol` 用真实证明 fixture（`test/fixtures/spike_model_proof.json`）测试。这些文件不手改、不参与 `forge fmt`，按 `foundry.toml` 只对该目录开启 optimizer 以满足 EIP-170。

### `BaseFeeMarket.sol`（legacy）

旧方向的 base fee 市场，保留到提交前与 analysis 的 base fee 管线一起删除。

## 4. 波动率口径与公开输入编码

- 检查点：`t_k = startTime + k·Δ`，k = 0..N（当前 Δ = 300 s、N = 12，均为构造参数）。
- 段均值 `ā_k = floorDiv(C_k − C_{k−1}, t_k − t_{k−1})`，向负无穷取整（同 Uniswap `OracleLibrary.consult`）。
- `RV = Σ (ā_k − ā_{k−1})²`，满点时 11 项；缺点时用可用点算可变时长的段均值，项数 m < 11，归一为 `floor(Σ × (N − 1) / m)`。13 个点至少 12 个可读（`count × 10000 ≥ 13 × 9000`），否则作废。
- 特征：开轮时 `secondsAgos = [17Δ, …, 0]`，17 个段均值的 16 个相邻差 `f_j`，`x_int_j = clamp(f_j, −64, 64) × 128`（模型输入 `x = x_int / 4096`，即 EZKL `input_scale = 12`）。
- 域编码：非负 `x` 原样；负数编码为 `R − |x|`，R 为 BN254 标量域模数（`FIELD_R`）。
- instances 顺序：`[16 个特征, 5 个输出]`，共 21 个。每个输出须 `< R/2`、总和 > 0；`probs[i] = out[i] × 1e18 / Σout`（i < 4），余数补到最后一桶，和恰为 1e18。
- 一致性：合约、`agents/vol_agents/contract_math.py` 各自实现，互不 import，靠共享 fixture `contracts/test/fixtures/vol_rv_cases.json` 对拍。

## 5. agents

- 模型：`linear_abs`（85 参数）、`mlp16`（357）、`mlp32_abs`（709），numpy 在合成 tick 路径上训练，标签按占位边界 `[8, 20, 45, 110]` 分桶；都以 `Clip(±3) → Softmax` 结尾，电路都在 logrows 15。
- 构建：`build.py` 按模型缓存 EZKL 产物到 `agents/out/<model>/`（git-ignored），每步一个子进程并记录耗时与峰值内存；验证合约装进 `contracts/src/verifier/`。
- 一轮：`round.py` 启动 anvil，部署 MockERC20、MockPool、VolMarket（Δ = 300、N = 12、fee 0）和 3 个验证合约，每个模型登记各自的 agent 为 operator；`agent.py` 读特征、生成 witness、核对公开输入、证明、提交；结算后写 `out/compare_round.json`。
- 边界：只通过 Foundry（`forge create`）与 `contracts/test/fixtures/` 读合约侧内容；不 import `analysis/` 或 `spikes/`。

## 6. 信任边界

| 由链上保证 | 不由链上保证 |
|---|---|
| 特征（模型输入）由合约从池子 `observe()` 算出，agent 无法自选输入 | 池子价格本身可被操纵；Chainlink 交叉校验为计划中，且只比一个价格点 |
| 预测在 `startTime` 前提交，且附带对已登记模型、对这些输入的有效推理证明 | 已登记的模型是否「好」、训练数据是否真实（目前为合成数据） |
| 只有模型 operator 能用该模型提交，复制证明无效 | owner 决定登记哪些模型（`registerModel` 仅 owner） |
| 结算 RV、获胜桶、对数评分、赔付全部在合约内整数计算 | 区间边界由开轮方传入（当前为占位值，校准为计划中） |
| 观测缺失时作废并全额退款 | EZKL SRS 的来源未校验摘要（首次构建可能联网下载）；验证合约的可信度依赖它 |

另外：特征在 `createRound` 时快照，而预测截止在 `startTime`，两者之间的价格变化不在模型输入里；下注与预测都是公开的；fee 与取整粉尘留在合约内，没有取回函数。

## 7. 计划中

### ERC-8004 信誉（计划中）

接口按 ERC-8004 v2.0.0：单测与离线演示用 `contracts/src/erc8004/` 下按接口写的最小 Identity / Reputation 实现，主网 fork 演示用已部署的注册表（Identity `0x8004A169…a432`、Reputation `0x8004BAa1…9b63`）。收窄后的设计：

- 不改构造函数与 `registerModel` 签名；新增 owner 的 `setReputation(identity, reputation)` 与 operator 的 `linkAgent(modelId, agentId)`（调用者须是该模型 operator 且是 agentId 的 owner；agentId 可为 0，另设绑定标记）。
- `settle` 对每个已绑定预测者 `try giveFeedback(agentId, int128(logScore), 18, "logScore", <由 delta/nSegments 派生的 tag2>, "", uri, hash)`；失败只发事件、不回滚，避免 agent owner 通过授权市场合约卡死结算与赔付。
- 分数取 `getPrediction().logScore`，不重算；未设置 reputation 时行为与现状一致。
- 读取方用 `getSummary(agentId, [市场合约地址], "logScore", "")`，第三方写的反馈不计入。Validation 注册表不做。

### Chainlink 喂价交叉校验（计划中）

- owner 的 `setPriceFeed(feed)` 可选开启，0 地址即关闭；不改构造函数，关闭时结算、作废、退款行为完全不变。
- `settle` 在覆盖率判断之后取池子最近一段 Δ 的 TWAP tick（`observe([Δ, 0])`），自写 1.0001^tick 定点幂换算成 8 位小数 USD 价格（不移植 GPL 的 TickMath），与主网 ETH/USD `latestRoundData` 比较。
- 偏离 > 200 bps、喂价早于 3900 s 或 `answer ≤ 0` 时作废，复用 voided 与全额退款，并发出 `PriceCheckFailed`。迟结算时比较的是结算时刻价格，不是窗口末价格。
- Chainlink CRE / Automation 本阶段不做。

### 区间校准与演示（计划中）

- analysis 拉取 Swap 事件重建 tickCumulative，按第 4 节口径算历史 RV，按 p20/p40/p60/p80 出 4 个严格递增的边界，写 analysis 自己的产物，不改共享 fixture 与 agents 的边界；之后模型需按新边界重训并重建验证合约。
- 主网 fork 回放 + 只读看板（读合约事件与状态，不调用任何写接口）。

## 8. 依赖方向

```text
pool (observe) ──▶ contracts（唯一的结算权威）
agents ──(forge create / cast, 读 test/fixtures)──▶ contracts
agents ──(build.py 安装验证合约)──▶ contracts/src/verifier/
analysis ──(校准出的 bounds，计划中)──▶ createRound 参数
contracts ──(事件 / 状态)──▶ dashboard（计划中，只读）
```

禁止的边：`contracts →` 任何 Python 或链下组件；`agents ↔ analysis` 的 Python import；`dashboard →` 任一写入接口。
