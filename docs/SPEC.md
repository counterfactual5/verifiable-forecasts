# SPEC：可验证 AI 预测的链上问责

> 文档状态：[Accepted]
> 确认方式：用户确认

本文取代旧的 BaseFee 预测市场方向（`block.basefee` 结算、naive/EWMA/TimesFM 机器人、Chainlink CRE 仅做编排模拟；旧版见 git 历史）。新方向的详细规格以 `docs/plans/实施计划.md` 第 4–8 节为准，本文只做精简摘要；两者冲突时以实施计划和代码为准。

## 目标与范围

ETH Shenzhen 2026 Hackathon 参赛项目（截止 10/24 现场演示）。

**状态**：核心链路已完成（`VolMarket` 合约 + EZKL 验证合约 + 3 个预测 agent，本地 anvil 端到端跑通）；ERC-8004 信誉、Chainlink 交叉校验、区间校准、主网 fork 演示与看板为计划中。

**问题**：AI 预测者可以事后挑选好看的结果来宣传，评委和用户无法核实「这个预测确实是这个模型在事前、对这些输入算出来的」，也没有公开、不可篡改的成绩记录。

**做什么**：一个链上考场。考题是 Uniswap V3 ETH/USDC 0.05% 池（`0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`）未来 1 小时的 TWAP 已实现波动率（Δ = 300 s、N = 12 段，单位 tick²），按 5 个区间彩池（parimutuel）下注。AI 预测 agent 用 EZKL 为小模型推理生成 zk 证明；合约在开轮时自己从链上 `observe()` 算出公开输入（16 个特征），提交时链上验证证明，结算时用 `observe()` 算实际波动率（`sample()` 检查点兜底），按对数评分给每个预测打分。计划中：分数写入 ERC-8004 v2.0.0 信誉注册表，结算时用 Chainlink ETH/USD 喂价交叉校验池子价格。

**不做**（写入 README「Known limitations / Future work」）：LMSR 做市、blob 费用市场（`BLOBBASEFEE`）、FHE / commit-reveal 密封下注、x402 付费、真实资金与真实网络部署（只归用户）、ERC-8004 Validation 注册表（规范仍在变）、Chainlink CRE / Automation（本阶段不做）。

## 功能

| 功能 | 状态 | 位置 |
|---|---|---|
| 波动率市场合约：开轮存特征、下注、`sample` 检查点、`settle`（`observe` 批量 + 逐点兜底，缺点归一，覆盖率 < 90% 作废退款）、`claim` | 已完成 | `contracts/src/VolMarket.sol` |
| 彩池 / 分桶 / 对数评分数学 | 已完成 | `contracts/src/lib/MarketMath.sol` |
| zk 证明校验：每个模型一份 EZKL 生成的验证合约；`registerModel(verifier, operator)`；`submitPrediction` 截止前、证明通过才记录 | 已完成 | `contracts/src/verifier/`、`VolMarket.submitPrediction` |
| 预测 agent：3 个模型（`linear_abs` / `mlp16` / `mlp32_abs`）训练、EZKL 构建、读特征→证明→提交→结算→比较链上分数 | 已完成（本地 anvil + MockPool） | `agents/` |
| 合约 / agents 共享口径 fixture（tickCumulative → 段均值 → RV → 桶） | 已完成 | `contracts/test/fixtures/vol_rv_cases.json` |
| `make verify` 接入 agents 的 ruff 与 pytest | 已完成 | `Makefile` |
| analysis 拉取 Swap 事件、按合约口径算历史 RV、校准 4 个区间边界 | 已完成 | `analysis/` |
| ERC-8004 v2.0.0 身份注册 + 结算后 `giveFeedback` 写信誉 | 计划中 | `contracts/src/erc8004/`（未创建） |
| Chainlink ETH/USD 喂价交叉校验（`setPriceFeed` 可选开启） | 计划中 | `VolMarket.settle` |
| 主网 fork 回放演示 + 简单看板 | 计划中 | `demo/`、`dashboard/`（未实现） |
| 删除旧 `BaseFeeMarket` 与 analysis 的 base fee 管线 | 已完成 | 见 git 历史 |

## 第一个功能

新方向的第一个功能是波动率市场合约 `VolMarket.sol`（已完成）：轮次状态机（createRound → bet / submitPrediction → sample → settle → claim），开轮时由合约从 `observe()` 自算 16 个特征作为 zk 证明的公开输入，提交预测时链上校验 EZKL 证明，结算按对数评分。参数：Δ、N 为构造参数，区间边界为 `createRound` 参数。

**验收标准**：
1. `cd contracts && forge test --match-path test/VolMarket.t.sol` 全绿，覆盖完整生命周期、彩池按比例分配、缺点归一与覆盖率作废退款、`observe` 过旧时用 `sample` 检查点兜底、证明篡改被拒、非 operator 提交被拒。
2. 合约与 agents 读同一份 `contracts/test/fixtures/vol_rv_cases.json`，RV 与桶逐项一致。
3. 评分统一为 `max(ln p_win, −18e18)`（1e18 缩放），概率为 0 与极小概率同样记 −18e18。

## 技术选型

| 项 | 选择 | 理由 | 证据等级 |
|---|---|---|---|
| 合约与测试 | Foundry（forge 1.5.1，solc 0.8.28） | 本机已装；cheatcodes 适配时间回放 | X（本机）+ C（官方文档） |
| 结算数据源 | Uniswap V3 `observe()`（0.05% 池），`sample()` 检查点兜底 | 池子 cardinality 723，最坏可回溯约 2.41 h，1 h 窗口一次取全；13 点合约内调用约 32 万 gas | X（`spikes/facts/FACTS.md` 主网实测） |
| zk 证明 | EZKL 23.0.5（Halo2/KZG，logrows 15，`input_scale = 12`，参数 fixed） | prove ≈ 9 s / 1.23 GB；验证合约 19,656 B < EIP-170；验证交易 ≈ 79.5 万 gas | X（`spikes/ezkl/README.md` 实测） |
| 预测模型 | numpy 训练的小 MLP / 线性模型 → ONNX | 电路小、证明快；模型重依赖隔离在子进程 | X（`agents/` 实测） |
| 信誉（计划中） | ERC-8004 v2.0.0：本地 Lite 实现用于测试与离线演示，主网 fork 用已部署合约 | 池子与喂价只在主网 | X（`spikes/facts/FACTS.md` 链上核实） |
| 价格交叉校验（计划中） | Chainlink ETH/USD `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`（8 位小数） | 与池子 tick 换算价一致（2435.09 vs ≈2436） | X（`spikes/facts/FACTS.md`） |
| Python 环境 | uv 0.11.2；agents Python ≥ 3.12，analysis ≥ 3.11 | 本机已装，锁文件可复现 | X（本机） |

## 结构与依赖

```
contracts/        # Foundry：VolMarket、MarketMath、EZKL 验证合约、ERC-8004 Lite 注册表
agents/           # Python：模型训练、EZKL 构建、证明与提交、anvil 端到端
analysis/         # Python：Swap 事件拉取、按合约口径算 RV、区间边界校准
spikes/           # 事实核实（facts/）与 EZKL 可行性实验（ezkl/）
chainlink/        # 喂价交叉校验说明（计划中）
dashboard/        # 看板（计划中）
docs/
```

单向依赖：`agents`、`analysis` 互不引用；合约不依赖任何 Python；agents 只通过 Foundry 构建产物与 `contracts/test/fixtures/` 读取合约侧内容。Δ、N 是构造参数，区间边界是 `createRound` 参数，不写死。

## Full Verify

```
make check && make test
```

## 假设

- 赛程以官方公告为准（10/24 下午现场演示，评审前公开仓库）；未逐条在官方渠道核实。
- 主演示在本地 anvil（离线、MockPool）；主网 fork 演示为计划中。不做真实网络部署。
- 区间边界当前为占位 `[8, 20, 45, 110]` tick²，3 个模型也按它在合成数据上训练；按粗估真实 RV 在千级 tick²，需由 analysis 用真实 Swap 历史校准，校准后模型需重训并重建验证合约。
- 彩池冷启动由协议方注入种子资金；公开下注可被跟单是已知问题，密封下注列为 Future work。
- 首次构建 EZKL 电路时若本地没有 SRS 且未用 `--srs` / `VOL_AGENTS_SRS` 指定来源，会联网下载；无论来源，SRS 的 sha256 必须等于 `agents/vol_agents/build.py` 里固定的 `SRS_SHA256`，否则构建中止。已提交的验证合约与新构建结果不同时默认拒绝覆盖，需显式 `--force`。

## 后续

1. analysis 改为拉取 Swap 事件，按合约同一口径算历史波动率，校准 4 个严格递增的区间边界。
2. ERC-8004 接入：注册 agent 身份，结算后由市场合约把分数写进信誉；写信誉失败不影响结算与赔付。
3. Chainlink 喂价交叉校验：owner 可选开启，偏离 > 200 bps 或喂价早于 3900 s 即作废退款。
4. 用校准后的区间边界重训模型并重建 EZKL 验证合约。
5. 演示：主网 fork 回放 + 简单看板。
6. 提交前：README / 架构文档终稿、pitch 讲稿（SRS 摘要校验、验证合约覆盖保护、结算取整 fuzz 与协议费提取、删除旧 base fee 代码已完成）。
