# 架构说明：可验证 AI 预测的链上问责

> 文档状态：[Accepted]
> 所属路线：[plans/路线图.md](./plans/路线图.md)

本文与根目录 `README.md` 配套：README 面向评审快速上手，本文记录已实现的组件边界、数据流、合约接口与信任边界。设计依据见 `docs/plans/实施计划.md` 第 4–8 节；未实现的内容集中在第 9 节。

## 1. 一句话

合约从 Uniswap V3 池子的 `observe()` 自己算出预测输入和结算数据；AI agent 先提交预测哈希（commit，只交哈希、不交预测本身）、窗口开始前再公开；zk 模型的预测只有附带 EZKL 推理证明、且证明的公开输入与合约自算的特征一致时才被接受，可复现与仅提交模型（`verifier = 0`）只需与提交的哈希一致；结算时合约先用 Chainlink ETH/USD 交叉校验池子价格，再按对数评分给每个已公开的预测打分，把分数以市场合约的身份写入该 agent 的 ERC-8004 信誉，并把一部分手续费分给得分高于均匀基线的预测者。

## 2. 数据流

```text
Uniswap V3 ETH/USDC 0.05% 池（离线回合与测试中为 MockPool，演示中为主网 fork 上的真实池）
        │ observe(secondsAgos) → tickCumulative[]
        ▼
VolMarket.createRound(startTime, bounds)
        │ 取 18 个点 [17Δ … 0] → 17 个段均值 → 16 个相邻差 f_j
        │ 存 x_int_j = clamp(f_j, −64, 64) × 128
        ▼
agents/（每个 agent 一个模型、一个 operator 账户、一个 ERC-8004 agentId）
        │ getFeatures(id) → 本地核对与 contract_math 镜像一致
        │ EZKL witness → prove（子进程）
        ▼
VolMarket.commitPrediction(id, modelId, commitment)           ← startTime − commitLead 之前
        │ 校验 operator；commitment = keccak256(abi.encode(id, modelId, outputs, salt, sender))
VolMarket.revealPrediction(id, proof, outputs[5], salt)        ← [startTime − commitLead, startTime − revealLead)
        │ 校验输出范围与提交的哈希一致
        │ zk 模型：instances = [16 个存储特征, 5 个输出]，低层 call verifyProof(proof, instances)
        │ 通过 → 归一化为 probs（和恰为 1e18）并记录；未公开的提交不计分、不分钱
        ▼
窗口内：任何人 sample(id, k) 把 tickCumulative(t_k) 存入检查点（可选兜底）
        ▼
VolMarket.settle(id)                                          ← t_N 之后
        │ 已存检查点 + 其余点批量 observe（失败则逐点 try/catch）
        │ 覆盖率 < 90% → voided（全额退款）
        │ 已配置喂价：池子最近 Δ 的 TWAP 价 vs Chainlink ETH/USD，偏离 > 200 bps 或过期 → voided
        │ RV（tick²）→ MarketMath.bucketOf → 获胜桶
        │ 每个已公开预测：logScore = max(ln p_win, −18e18)；累计超出基线 ln(0.2) 的部分 totalExcess
        │ 已配置信誉：对每个已绑定 agent try giveFeedback(agentId, logScore, 18, "logScore", tag2, …)
        ▼
claim(id)：赢家按比例分池（扣 fee，最后一个赢家拿余数）；作废或获胜桶无人下注时全额退款
collectFee(id)：任何人把该轮协议费减去预测者分成转给 owner
claimPredictorReward(id)：高于基线的预测者按超出分数比例领取分成（最后一位拿余数）
        ▼
agents/round.py → out/compare_round.json；demo/fork_round.py → demo/out/fork_replay.json → dashboard/
```

## 3. 合约

### `VolMarket.sol`

构造参数：`(token, feeBps, predictorShareBps, pool, delta, nSegments, commitLead, revealLead)`；`feeBps < 1000`，`predictorShareBps ≤ 10000`，`revealLead < commitLead`，`nSegments ≥ 2`，`17 × delta` 须放得进 `uint32`。owner 为部署者。

| 接口 | 谁调用 | 作用 |
|---|---|---|
| `registerModel(verifier, operator, modelHash)` | owner | 登记一个模型，返回 modelId；`verifier` 为 EZKL 验证合约，零地址表示不验证证明；`modelHash` 为模型权重、配置与运行代码的哈希，`bytes32(0)` 表示没有；非零时记录并发 `ModelHashSet`；没有验证合约时，`modelHash` 非零为可复现等级、为零为仅提交（有验证合约一律为 zk）；只有 `operator` 能用该模型提交。两参数重载 `registerModel(verifier, operator)` 等同 `modelHash = 0` |
| `isZkModel(modelId)` | 只读 | 模型是否带 zk 验证合约；未知 modelId revert |
| `modelHash(modelId)` | 只读 | 登记时的 `modelHash`，未登记哈希为 0；未知 modelId revert |
| `verificationTier(modelId)` | 只读 | 有验证合约返回 2 = zk（`TIER_ZK`），否则 `modelHash` 非零返回 1 = 可复现（`TIER_REPRODUCIBLE`），否则返回 0 = 仅提交（`TIER_COMMIT_ONLY`）；未知 modelId revert |
| `setReputation(identity, reputation)` | owner | 配置 ERC-8004 两个注册表；两者同为零地址即关闭，只有一侧为零会被拒绝 |
| `linkAgent(modelId, agentId)` | 模型 operator | 把自己拥有的 ERC-8004 agentId 绑定到模型；`agentId == 0` 表示不归属任何 agent |
| `setPriceFeed(feed)` | owner | 配置 Chainlink 喂价，零地址关闭 |
| `createRound(startTime, bounds)` | 任何人 | `bounds` 为 4 个严格递增的 tick² 边界（5 个桶）；`startTime` 须晚于当前时间 + `commitLead`；从 `observe()` 快照 16 个特征 |
| `bet(id, bucket, amount)` | 任何人 | `startTime` 前下注（ERC20 `transferFrom`） |
| `commitPrediction(id, modelId, commitment)` | 模型 operator | `startTime − commitLead` 前、每个地址每轮一次、每轮最多 32 个预测者 |
| `revealPrediction(id, proof, outputs[5], salt)` | 已提交者 | `[startTime − commitLead, startTime − revealLead)` 内；须与提交的哈希一致，zk 模型还须证明通过；可复现与仅提交模型 `proof` 可为空 |
| `sample(id, k)` | 任何人 | `t_k` 之后存一个检查点，每个 k 一次 |
| `settle(id)` | 任何人 | `t_N` 之后结算一次：算 RV、喂价校验、定桶、评分、写信誉，或作废 |
| `claim(id)` | 下注者 | 赢家领取 `MarketMath.payout`，最后一个领取的赢家拿 `total − fee − 已付`；作废 / 无人押中时全额退款 |
| `collectFee(id)` | 任何人 | 把该轮协议费减去 `predictorPool(id)` 转给 owner，每轮一次；作废 / 无人押中的轮次没有费用 |
| `claimPredictorReward(id)` | 预测者 | 得分严格高于基线时领取 `pool × excess / totalExcess`，最后一位领取者拿 `pool − 已付`；每人一次 |
| `getRound` / `getFeatures` / `getCheckpoint` / `getStake` / `getPrediction` / `getCommitment` / `predictorPool` / `predictorCount` / `modelCount` / `priceForTick` | 只读 | 供 agents、演示与看板读取 |

事件：`ModelRegistered`、`ModelHashSet`（仅在 `modelHash` 非零时）、`RoundCreated`（含 bounds 与 features）、`BetPlaced`、`PredictionCommitted`、`PredictionRevealed`、`PredictorRewardClaimed`、`CheckpointSampled`、`RoundSettled`、`RoundVoided`、`PredictionScored`、`Claimed`、`FeeCollected`、`ReputationSet`、`AgentLinked`、`ReputationWriteFailed`、`PriceFeedSet`、`PriceCheckFailed`。

### `lib/MarketMath.sol`、`lib/TickPriceMath.sol`

`MarketMath`：`bucketOf`（半开区间：桶 0 为 `v < b[0]`，桶 i 为 `b[i−1] ≤ v < b[i]`，最后一桶 `v ≥ b[n−1]`）、`log1e18`（1e18 定点自然对数，定义域 [1, 1e18]）、`fee`、`payout`（`stake × (total − fee) / winners`，向下取整）。`TickPriceMath`：整数定点 `1.0001^tick` 换算成 8 位小数的 ETH/USD 价格（不移植 GPL 的 Uniswap TickMath）。

### `erc8004/`

`IdentityRegistryLite` 与 `ReputationRegistryLite`：按 erc-8004-contracts v2.0.0 接口写的最小子集，只供单测与离线回合使用（agentId 从 1 开始；Reputation 按 client 与 `tag1`/`tag2` 过滤，空 tag 为通配）。主网 fork 演示直接使用已部署的 v2.0.0 注册表。注意两者 `getSummary` 返回值不同：Lite 返回一个 `int256` 平均值，已部署版本返回 `(uint64 count, int128 summaryValue, uint8 summaryValueDecimals)`；`VolMarket` 只调用两者一致的 `ownerOf` 与 `giveFeedback`。

### `verifier/`

EZKL 生成的 Halo2 验证合约，每个模型一份（`LinearAbsVerifier`、`Mlp16Verifier`、`Mlp32AbsVerifier`），由 `agents/vol_agents/build.py` 安装，只改了合约名，内容不同时默认拒绝覆盖；`SpikeModelVerifier` 来自 `spikes/ezkl`，供 `VolMarket.t.sol` 用真实证明 fixture 测试。这些文件不手改、不参与 `forge fmt`，按 `foundry.toml` 只对该目录与 `VolMarket.sol` 开启 optimizer 以满足 EIP-170。

## 4. 波动率口径与公开输入编码

- 检查点：`t_k = startTime + k·Δ`，k = 0..N（当前 Δ = 300 s、N = 12，均为构造参数）。
- 段均值 `ā_k = floorDiv(C_k − C_{k−1}, t_k − t_{k−1})`，向负无穷取整（同 Uniswap `OracleLibrary.consult`）。
- `RV = Σ (ā_k − ā_{k−1})²`，满点时 11 项；缺点时用可用点算可变时长的段均值，项数 m < 11，归一为 `floor(Σ × (N − 1) / m)`。13 个点至少 12 个可读（`count × 10000 ≥ 13 × 9000`），否则作废。
- 特征：开轮时 `secondsAgos = [17Δ, …, 0]`，17 个段均值的 16 个相邻差 `f_j`，`x_int_j = clamp(f_j, −64, 64) × 128`（模型输入 `x = x_int / 4096`，即 EZKL `input_scale = 12`）。
- 域编码：非负 `x` 原样；负数编码为 `R − |x|`，R 为 BN254 标量域模数（`FIELD_R`）。
- instances 顺序：`[16 个特征, 5 个输出]`，共 21 个。每个输出须 `< R/2`、总和 > 0；`probs[i] = out[i] × 1e18 / Σout`（i < 4），余数补到最后一桶，和恰为 1e18。
- 一致性：合约、`agents/vol_agents/contract_math.py`、`analysis/` 各自实现，互不 import，靠共享 fixture `contracts/test/fixtures/vol_rv_cases.json` 对拍。演示脚本在主网 fork 上再核对一次：开轮特征与同一区块 `observe()` 的离线计算一致，结算 RV 与检查点的离线重算一致。

## 5. ERC-8004 信誉

- agent 调 Identity 的 `register(agentURI)` 得到 agentId（ERC-721），模型 operator 调 `linkAgent(modelId, agentId)` 绑定；调用者必须是该模型的 operator 且拥有该 agentId。
- `settle` 对每个已绑定且 agentId 非零的预测者，取已存的 `logScore`（不重算），以 try/catch 调用
  `giveFeedback(agentId, int128(logScore), 18, "logScore", tag2, "", "", bytes32(0))`。`tag2` 由构造参数派生为 `vol-<delta>s-<nSegments>`（如 `vol-300s-12`），没有验证合约的模型（可复现与仅提交）附加 `-commit`（如 `vol-300s-12-commit`）；未公开的预测不写。注册表调用失败发 `ReputationWriteFailed`，不回滚结算与赔付。
- 低 gas 防护：每次调用最多转发 `EXTERNAL_CALL_GAS = 500_000` gas（主网实测 `giveFeedback` 约 19.7 万，含 21000 基础费）。按 EIP-150，被调方最多拿到剩余 gas 的 63/64。调用失败时，如果调用前剩余的 gas 不到 `500_000 × (1 + 1/32)`（被调方可能没拿到完整上限），`settle` 以 `InsufficientGas` revert。不能改用“调用后剩余 ≤ 1/64”来判断：已部署的注册表是代理，内部还会调用 Identity，内层调用缺 gas 时外层会带着自己那 1/64 正常 revert，主网 fork 演示中这种情况确实出现过。因此没人能靠压低 gas 上限让写入被跳过；在拿满 50 万的情况下仍然 revert 的注册表只触发事件。gas 足够时写入成功，所以估算出的 gas 上限不会因为这条防护而变高。
- 读取方以市场合约为唯一 client 过滤：`getSummary(agentId, [market], "logScore", tag2)`；第三方写的反馈不会混入。已部署的 Reputation 禁止 agent 的 owner/operator 自评，市场合约作为提交者不受影响。
- 主网 fork 演示中四个 agent 在已部署的 Identity 上注册（agentId 仅存在于 fork 上），24 轮回放结束后每个 agent 的 `getSummary` 计数为 24，均值等于各轮链上 logScore 的平均。

## 6. 结算时的价格校验

### Chainlink 喂价交叉校验

- owner 通过 `setPriceFeed(feed)` 开启；未配置时按池子 RV 照常结算，作废与退款行为不变。
- 配置后，`settle` 在覆盖率通过后读结算时刻前 Δ 秒的 `observe([Δ, 0])`，向负无穷取整得到平均 tick，用 `TickPriceMath` 换算成 8 位小数 ETH/USD；`latestRoundData()` 的 answer 按 `decimals()` 归一到 8 位后比较。
- `answer ≤ 0`、`updatedAt` 在未来或早于 3900 s、喂价调用失败、或绝对偏差严格大于 200 bps 时，发 `PriceCheckFailed` 并作废该轮，沿用 `claim` 全额退款；恰为 200 bps 时通过。迟结算比较的是结算时刻的价格。主网喂价 `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`（8 位小数）。
- `latestRoundData()` 与 `decimals()` 同样受 `EXTERNAL_CALL_GAS` 上限与上述检查约束（Chainlink 代理内部也会调用 aggregator）：gas 不足导致的调用失败会让 `settle` revert，而不是把这一轮作废。`_collect` 里的 `observe()`（批量与逐点兜底）不设上限，因为池子是构造参数，开轮时已经直接信任。Uniswap V3 的 `observe` 在自己的帧内读存储、没有子调用，所以这里沿用“失败后剩余 ≤ 调用前 1/64 即 revert”的检查，低 gas 不能让检查点被丢弃。
- 不做 Chainlink Automation / CRE；`settle` 仍由任何人调用。

## 7. agents 与 analysis

- 模型：`linear_abs`（85 参数）、`mlp16`（357）、`mlp32_abs`（709），numpy 在 ETH/USDC 0.05% 池真实 Swap 历史重建的 tick 路径上按时间切分训练（训练至 10-08、验证 10-08–10-15、测试 10-15–10-22），标签按边界 `[202, 474, 856, 1712]` 分桶（详见 `agents/MODEL_CARD.md`）；都以 `Clip(±3) → Softmax` 结尾，电路都在 logrows 15。
- 构建：`build.py` 按模型缓存 EZKL 产物到 `agents/out/<model>/`（git-ignored），每步一个子进程并记录耗时与峰值内存；KZG SRS 须匹配固定的 sha256；验证合约装进 `contracts/src/verifier/`。
- 离线回合：`round.py` 启动 anvil，部署 MockERC20、MockPool、VolMarket（Δ = 300、N = 12、fee 0）、Lite 注册表和 3 个验证合约，每个 agent 注册身份并绑定；`agent.py` 读特征、生成 witness、核对公开输入、证明，再提交、公开；结算后写 `out/compare_round.json`。
- analysis：按 ≤10k 块分段拉取 Swap 事件，重建 tickCumulative，按第 4 节口径算历史 RV，按 p20/p40/p60/p80 校准边界；`vol_calibrate.py --until` 只读训练期（2026-09-10 至 10-08 UTC）的 Swap，得到当前的 `[202, 474, 856, 1712]` tick²，并导出 agents 训练用的 tickCumulative 网格。
- 边界：agents 只通过 Foundry（`forge create`）与 `contracts/test/fixtures/` 读合约侧内容；agents 与 analysis 互不 import。

## 8. 演示与看板

- 演示比离线回合多三个可复现 agent：`agent-timesfm-3.0`、`agent-timestral-209m`、`agent-chronos-2`，经自部署推理服务预测（`api_agent.tsfm_agents`，`VOL_TSFM_*`），各自以 `registerModel(address(0), operator, modelHash)` 登记（档位与 `modelHash` 由 agent 对象给出，`modelHash` 固定公开权重版本、上下文、推理与后处理参数及运行代码）。timesfm-3.0 读本轮 16 个链上特征，timestral-209m 与 chronos-2 读由主网 Swap 日志重建的 512 点（约 42.7 h）。揭示先量化到 1e-3 网格再提交；设置 `VOL_REPRO_PYTHON`（可用 `VOL_REPRO_PYTHON_<MODEL>` 按模型指定）时，回放在最后一轮之后对 fork 逐个运行 `python -m vol_agents.tsfm_recompute`，用公开权重重算，每桶误差 ≤ 0.001 记为一致（JSON 中的 `reproduced`、`recompute_verdict`、`recompute_max_abs_diff`）。推理失败时该 agent 本轮不参赛（替身预测不是登记的模型），其余 agent 与本轮照常。手续费 1% 中 50% 分给高于基线的预测者；提交提前 90 s、公开提前 30 s 截止。
- `demo/run.sh`（薄入口）→ `demo/fork_round.py`：读 `MAINNET_RPC_URL`（缺省为公共 tenderly gateway），用独立的 Foundry 输出目录编译，以 `PYTHONPATH=agents` 复用 `vol_agents` 的 `Agent`、`build`、`Anvil`、`contract_math`。
- 连续回放 `HOURS`（默认 24）个真实小时，起点 `REPLAY_START`（默认 2026-10-21 06:00 UTC，位于模型测试期内）；一次 fork、一次部署，ERC-8004 信誉跨轮累计。fork 区块在回放网格开始前 10 分钟。
- fork 上的准备：清掉 anvil 公共测试账户在主网上的 EIP-7702 委托代码（否则无法接收 ERC-721 身份），给交易账户发 ETH 并包成 WETH，USDC 直接写入其余额存储槽（只存在于 fork 上）。
- 池子回放：先用主网归档 `observe()` 读出每个 5 分钟网格时刻 t 起 [t, t + 300 s) 的真实段均 tick；在时间戳恰为 t 的区块里把 fork 上的池子 swap 到该 tick 并保持，合约读到的每个段均值都等于主网，脚本逐轮记录特征与 RV 是否与主网重算一致（`features_match_mainnet`、`rv_matches_mainnet`），swap 未落到目标 tick 即停止。
- Chainlink 回放：区间内每笔真实 `transmit` 由原 transmitter（impersonate）在原时间戳重发，每次结算看到的喂价与喂价年龄都与主网一致。
- 每小时一轮：开轮、提交、公开、两名下注者下注、每个检查点 `sample`、结算（任一 `ReputationWriteFailed` 即报错）、领取赔付与预测者分成、`collectFee`；第 0 轮做篡改证明检查并记录 `verifyProof` gas。
- 输出 `demo/out/fork_replay.json`（`schema: "vol-replay/v1"`，git-ignored）；`dashboard/index.html` 是无构建的静态页，只读该 JSON（缺省回退到提交的 `dashboard/sample-replay.json`，旧的单轮格式仍可用 `?data=sample-round.json` 打开），不连钱包、不调用任何写接口。

## 9. 未实现

- 滚动重新校准边界与重训（每次重训都是新的验证合约与 modelId）。
- Chainlink Automation / CRE 自动结算；ERC-8004 Validation 注册表。
- 密封下注（commit-reveal / FHE）、LMSR、真实网络部署。
- TEE 等级、按档位押金与罚没、不公开按最低分记信誉（设计见下文“验证档位与押金”）。

### 分级验证（zk、可复现与仅提交已实现，TEE 为路线图）

问责可以拆成四层，只有最后一层可能依赖 zk：

| 层 | 机制 | 依赖 zk |
|---|---|---|
| 事前提交 | `startTime − commitLead` 前提交预测哈希（只交哈希、不交预测本身），`startTime − revealLead` 前公开 | 否 |
| 客观结算 | 合约读 `observe()`，Chainlink 交叉校验 | 否 |
| 成绩可携带 | 市场合约写入 ERC-8004 | 否 |
| 出处：确实是该模型算的 | 推理的 zk 证明；或登记 `modelHash` 的公开权重，任何人链下重算 | zk 等级是，可复现等级否 |

因此“出处”可以分级提供，由读取方选择信任哪一级：

- **zk**（已实现，仅小模型）：即本文第 2–4 节的 EZKL 路径。
- **可复现**（已实现）：`registerModel(address(0), operator, modelHash)` 登记，适用于权重公开的模型，大小不受电路限制。`modelHash` 是 `tsfm_forecast.model_hash_preimage` 规范 JSON 的 keccak256（权重 `repo@revision`、上下文长度、推理与后处理参数、揭示网格与容差、运行代码的 sha256），固定权重、配置与运行代码；公开时不验证证明，任何人可用 `python -m vol_agents.tsfm_recompute` 从链上数据（16 个特征；512 点模型另用池子 Swap 日志重建上下文）重算并与公开值逐桶比对，每桶误差 ≤ 0.001 为一致（容差复核；揭示先量化到 1e-3 网格并在结果出现前提交），哈希不符、缺公开或任一桶超差即非零退出。演示中的 `agent-timesfm-3.0`、`agent-timestral-209m`、`agent-chronos-2` 在 24 轮回放中各 24/24 轮重算在容差内（72 次均完全一致）。它证明的是出处（确实是这组权重对这些输入算的），不证明预测准确；容差覆盖不同机器与软件栈之间的浮点差异。
- **仅提交**（已实现）：`verifier = 0` 且不带 `modelHash` 登记，任意模型，只证明预测在事前定下，不保证是哪个模型算的。`agents/vol_agents/api_agent.py` 中无法在 CPU 上复现的模型（以及通用预测 API）走这一档；回放里的三个时序模型均可复现，不走此档。
- **TEE 远程证明**（未实现）：适用于权重不公开的闭源大模型 / LLM，需要信任硬件厂商及其证明服务。
- **opML**（乐观验证 + 欺诈证明）：不做每轮结算路径：它需要挑战窗口和链上单步 VM，长于一小时一轮，且依赖 1-of-N 诚实假设（至少一个诚实验证者在盯并愿意发起挑战）。计划作为可复现档的事后争议层（押金 + 挑战，不阻塞结算，未实现），见下文“验证档位与押金”。

所有等级都走 commit-reveal：提交的哈希 `keccak256(abi.encode(roundId, modelId, outputs, salt, msg.sender))` 绑定发送者，抄来的提交哈希别人无法公开；公开阶段在窗口开始前结束，所以预测在提交截止前不可见。zk 模型在公开时验证证明；证明本身不绑定发送者，只有模型 operator 能为该模型提交（第 3 节 `registerModel`）。

链上等级由 `verificationTier(modelId)` 读出，取值与合约常量一致：0 = 仅提交（`TIER_COMMIT_ONLY`），1 = 可复现（`TIER_REPRODUCIBLE`），2 = zk（`TIER_ZK`）。有验证合约即为 zk；否则 `modelHash` 非零为可复现，为零为仅提交。

写入 ERC-8004 时 tag1 = `logScore`，zk 模型 tag2 = `vol-<delta>s-<nSegments>`；没有验证合约的模型（可复现与仅提交）都附加 `-commit`，如 `vol-300s-12-commit`，读取方用链上 `modelHash`（或 `verificationTier`）区分两者，再用 `getSummary` 按自己接受的等级过滤。这与 ERC-8004 原文一致：“Trust models are pluggable and tiered”，列出的信任模型为客户反馈信誉、质押保障的重新执行、zkML 证明和 TEE 预言机（A，<https://eips.ethereum.org/EIPS/eip-8004>）。是否改用 Validation 注册表待定。

### 验证档位与押金（设计，未实现）

本节是设计与实施计划，**合约中均未实现**；现状一节描述的是当前代码（`contracts/src/VolMarket.sol`、`contracts/src/VolFeeConsumer.sol`）。

**现状（已实现）**

- 三档由 `verificationTier(modelId)` 读出：`TIER_COMMIT_ONLY = 0`、`TIER_REPRODUCIBLE = 1`、`TIER_ZK = 2`。
- 计分与 50% 预测者分成三档完全相同：按对数分超出均匀基线 ln(1/5)（`baselineLogScore`，1e18 刻度）的部分按比例分，基线及以下分 0；没有任何押金。
- 未公开的预测保持 `logScore = 0`、`recorded = false`，不进分成，也**不写入信誉**：提供方可以只公开预计得分高的轮次，信誉只留下好轮次（选择性公开漏洞）。
- 信誉 tag2：zk 模型为 `vol-<delta>s-<nSegments>`；可复现与仅提交共用 `-commit` 后缀，信誉层不区分这两档。
- 可复现档的重算在链下进行（看板 / 回放的 `tsfm_recompute`），结果不上链，合约不知道某次揭示是否通过重算。
- `VolFeeConsumer` 按信誉均值超出基线的部分加权，按 `isZkModel` 选读 tag2，没有档位门槛或档位系数。
- opML 与 TEE 均未实现。

**设计**

| 档位 | 公开什么 | 押金 | 押金防什么 |
|---|---|---|---|
| zk 证明 | 模型承诺 + 证明 | 无 | 出处由证明保证 |
| TEE（路线图） | 远程证明 | 无 | 出处由硬件证明保证（需信任硬件厂商） |
| opML（路线图） | 模型 + 输入，可链上挑战 | 有 | 被挑战且复算对不上就扣 |
| 可复现 | 权重哈希 + 输入，链下任何人可复算 | 有 | 复算对不上（链下发现；接上 opML 式挑战后链上扣） |
| 仅提交（黑盒） | 不公开策略/模型（本来就不要求），只公开每轮预测 | 有 | 开很多号、只留运气好的（幸存者偏差 / 女巫攻击） |

所有档位共用的规则：

- **不公开按最低分记信誉**：已提交但未公开的轮次按 `MIN_LOG_SCORE`（−18，1e18 刻度即 −18e18）写入信誉；分成照旧为 0。选择性公开从此变成每轮 −18 的代价。
- **罚没去向**：被扣的押金分给成功的挑战者和该轮高于基线的预测者（后者按超出基线的部分按比例分，与现有分成口径一致）。
- **分成不分档**：commit-reveal 让每一档的分数同样诚实（事前定下、合约结算、谁都改不了），所以三档按同一规则分钱；档位只标注出处，用不用、给多大权重由消费方决定（例如 `minTier` 或每档系数）。
- **仅提交是设计上的黑盒**：它本来就不要求公开策略或模型，押金针对的不是出处，而是“开很多号、只留运气好的”：每个号都要锁一份押金并等提取延迟，弃号也有成本；配合“不公开按最低分”，留号就要背着全部轮次的成绩。押金只把女巫成本按号数线性抬高，不能根除；消费方仍可要求最短历史长度。当前 `registerModel` 仅 owner 可调，本身限制了开号，押金在开放登记后才是主要约束。

这与 ERC-8004 原文列出的信任模型一致：其中“stake-secured re-execution”（质押保障的重新执行）正对应可复现档加押金（A，<https://eips.ethereum.org/EIPS/eip-8004>）。

**实施计划（按顺序，均未实现）**

1. **不公开按最低分写入信誉**（未实现）。范围：`_score` 对 `!p.recorded` 记 `MIN_LOG_SCORE`（`recorded` 仍为 false，`_excess` 仍为 0，不分钱），`_writeReputation` 对已绑定 agent 的未公开预测同样写入；核对 `getPrediction` 的读者（`VolFeeConsumer` 只认 `recorded`，看板与回放脚本的总分口径）。测试：未公开的绑定预测写入 −18e18；未公开仍不分钱；未绑定 agent 仍不写；32 个绑定预测者全部未公开时结算 gas 仍在上限内；作废轮不写；每条新测试先在旧代码上证明会失败。
2. **信誉 tag2 拆成三个后缀**（未实现）。范围：zk `vol-<delta>s-<n>`、可复现 `…-repro`、仅提交 `…-commit`，`_writeReputation` 按 `verificationTier` 选；`VolFeeConsumer` 构造参数改为三个 tag2，按 `verificationTier` 读。旧市场里可复现模型在 `-commit` 下的历史不迁移（新部署从零累计）。测试：每档写入各自后缀；消费方按档读到对应分数；现有 ERC-8004 测试按新后缀更新断言而不放宽；同步 README、PITCH、MODEL_CARD 的 tag 描述。
3. **`VolFeeConsumer` 档位门槛与每档系数**（未实现）。范围：构造参数 `minTier` 与 `tierWeightBps[3]`（10000 = 1 倍，在定义处注明刻度），权重 = (均值 − 基线) × `tierWeightBps[tier]` / 10000，低于 `minTier` 权重为 0；全部为 0 时沿用现有的等权回退。加入 TEE 后各档不再是全序（zk 与 TEE 的信任来源不同），届时改为接受档位的位掩码。测试：门槛排除低档；系数比例正确；全部被排除时回退；乘法不溢出的上界。
4. **按档位的登记押金**（未实现）。范围：押金额为构造参数 `bondByTier`（zk 与 TEE 为 0），由 operator 调 `postBond(modelId)` 存入市场代币，押金不足时 `commitPrediction` revert；`requestWithdraw` 后经构造参数 `bondWithdrawDelay`（应不短于消费方回看的信誉窗口）才能提取，期间仍可被罚没；罚没钩子 `_slash(modelId, amount, challenger, roundId)` 按构造参数 `challengerShareBps` 分给挑战者，余下并入该轮高于基线者的分成；仅提交 / 可复现未公开时按构造参数比例扣押金。所有比例为基点整数运算。测试：无押金不能提交、zk 不需要；延迟前提取 revert、延迟后可提；罚没的分配与守恒（fuzz：总额不增不减）；提取延迟中被罚没；代币回调重入。
5. **可复现档的 opML 式挑战**（未实现）。opML 不用作一小时一轮的每轮结算路径（理由见“分级验证”：挑战窗口、链上单步 VM、1-of-N 诚实假设）；这里计划把它作为可复现档的争议层：结算照常按揭示值进行，挑战只针对押金，挑战窗口（构造参数）可以长于一轮而不拖慢结算。可复现档已经把 `modelHash`、链上输入和每桶 0.001 容差固定下来，“复算对不上”是可判定的命题，所以它是可复现档的自然升级。范围：`challenge(roundId, predictor)` 附挑战押金；窗口内未决的模型不能提取押金；成功则罚没并用 ERC-8004 `revokeFeedback`（市场合约即该条反馈的 client）撤回或追加 −18 记录，失败则挑战押金归被挑战方。裁决的选项与信任假设：
   - 链上欺诈证明（二分到单步，再由链上 VM 执行一步）：信任 1-of-N 诚实挑战者与 VM 实现；要求推理在整数 / 确定性算术下逐位一致（现有容差复核不满足），合约体量大、审计成本高 [待证据]。
   - k-of-m 复算委员会签名裁决（各自跑 `tsfm_recompute`）：信任委员会诚实多数，可作过渡方案。
   - owner 裁决：信任 owner，只适合演示。
   - 对复算做 zk 证明：只对小模型可行，而小模型本来就走 zk 档。
   测试：窗口内外的挑战；成功挑战的罚没与分配；失败挑战的押金去向；同一预测重复挑战；挑战未决时不能提取；结算与赔付不受挑战影响。
6. **TEE 档**（未实现）。范围：新档位常量与登记方式（登记 enclave 度量值与链上远程证明验证合约），公开时附带对 `(roundId, modelId, outputs, 特征哈希)` 的远程证明报告；押金为 0；信任硬件厂商及其证明服务。测试：有效报告通过；度量值不符拒收；其他轮次的报告重放拒收；未配置验证合约时不能登记该档。

## 10. 信任边界与已知问题

| 由链上保证 | 不由链上保证 |
|---|---|
| 特征（模型输入）由合约从池子 `observe()` 算出，agent 无法自选输入 | 池子价格本身可被操纵；Chainlink 交叉校验只比较最近一个 Δ 的 TWAP 与一个喂价点 |
| 预测在提交截止前以绑定发送者的哈希定下；zk 模型公开时附带对已登记模型、对这些输入的有效推理证明 | 已登记的模型是否「好」、训练数据是否真实（仓库可复现训练，但链上不证明）；仅提交模型的预测由谁、用什么模型算出 |
| 可复现模型登记的 `modelHash` 不可更改，其提交哈希与公开值上链 | 合约不重算可复现模型的预测，也不检查公开值与 `modelHash` 对应的权重是否一致；任何人可链下用 `vol_agents.tsfm_recompute` 重算，每桶误差 ≤ 0.001 为一致（容差复核；提交先于结果） |
| 只有模型 operator 能用该模型提交，复制证明或提交哈希无效 | owner 决定登记哪些模型（`registerModel` 仅 owner） |
| 结算 RV、获胜桶、对数评分、赔付全部在合约内整数计算 | 区间边界由开轮方传入（演示用训练期校准值） |
| 观测缺失或喂价不符时作废并全额退款 | 验证合约的可信度依赖 EZKL 与 KZG SRS（构建时校验固定摘要） |
| 信誉由市场合约写入，读取时可只认市场合约；结算 gas 不足以完成写入时整笔 revert，不会静默跳过 | 注册表自身 revert 或超过 50 万 gas 上限时只发 `ReputationWriteFailed`，该分数不进信誉 |

另外：特征在 `createRound` 时快照，而提交截止在 `startTime − commitLead`，两者之间的价格变化不在模型输入里；下注是公开的，预测在公开阶段后公开；不公开只损失分数与分成，没有罚没，也不写信誉，所以可以只公开运气好的轮次（选择性公开；修补设计见第 9 节“验证档位与押金”，未实现）。

链上验证的出处保证只覆盖能放进 EZKL 电路的小模型。上表左列中的事前提交、合约内结算与作废、市场合约写信誉这几项不依赖 zk，已通过仅提交等级复用给任意模型；权重公开的大模型由可复现等级提供出处（登记 `modelHash`，链下重算）；只有权重不公开的闭源模型需要第 9 节的 TEE 等级，目前未实现。

## 11. 依赖方向

```text
pool (observe) ──▶ contracts（唯一的结算权威） ◀── Chainlink feed（交叉校验）
contracts ──(giveFeedback)──▶ ERC-8004 Reputation
agents ──(forge create / cast, 读 test/fixtures)──▶ contracts
agents ──(build.py 安装验证合约)──▶ contracts/src/verifier/
analysis ──(校准出的 bounds，待重训后接入)──▶ createRound 参数
demo ──(PYTHONPATH 复用 vol_agents)──▶ agents；demo ──(JSON)──▶ dashboard（只读）
```

禁止的边：`contracts →` 任何 Python 或链下组件；`agents ↔ analysis` 的 Python import；`dashboard →` 任一写入接口。
