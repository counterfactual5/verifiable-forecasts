# verifiable-forecasts SPEC

> 文档状态：[Accepted]
> 确认方式：用户确认

## 目标与范围

ETH Shenzhen 2026 Hackathon 参赛项目（截止 10/24 现场演示）。

**做什么**：一个以太坊原生的 base fee（EIP-1559 基础费）预测市场。每轮押注"未来 K 个区块的 base fee 平均值落在哪个区间"；合约用 `BASEFEE` 操作码（EIP-3198）读取协议自带的数值结算，无需预言机。TSFM（零样本时序模型）作为预测者入场，预测分布事前上链、事后由链上真实值打分，形成"AI 预测能力的公开可验证考场"。彩池（parimutuel）分配。

**不做**（均写入 README「Future Work」）：LMSR 做市、blob 费用市场（`BLOBBASEFEE`）、FHE/commit-reveal 密封下注、ERC-8004 信誉、x402 付费、真实资金、主网部署。Chainlink CRE 仅做 CLI 模拟（专项奖达标线），不依赖其可用性。

## 技术选型

| 项 | 选择 | 理由 | 证据等级 |
|---|---|---|---|
| 合约与测试 | Foundry（forge） | 本机已装（forge 1.x）；以太坊黑客松事实标准， cheatcodes 适配 basefee 回放 | X（本机）+ C（官方文档） |
| 结算数据源 | `BASEFEE` opcode (EIP-3198) | 协议原生值，2 gas 读取，无预言机争议 | A（EIP 最终态） |
| 回放驱动 | Anvil `anvil_setNextBlockBaseFeePerGas` | 主演示不依赖网络与真实尖峰出现 | C（Foundry 文档） |
| 预测模型 | 零样本 TSFM（timesfm/chronos，复用 `~/Work/chronos-experiment/.venv`） | 本机已有可跑环境；TSFM 为主角而非插件 | X（本机） |
| Python 环境 | uv（Python ≥3.11，不用系统 3.15） | 本机已装；3.15 无 torch 轮子 | X（本机） |
| TSFM 服务化 | 独立推理进程（stdio/HTTP 适配器） | 模型重依赖隔离在适配层，机器人只读输出，现场故障可降级 | D（工程经验） |
| 前端看板 | Streamlit | Python 单文件最快出可视化 | C（官方文档） |
| Chainlink CRE | TypeScript SDK + CRE CLI 模拟 | 2026 年 Chainlink 黑客松规则：Automation/Functions 已弃用，CRE 模拟即可达标 | C（Chainlink 官方 prize 页） |

### 工具链版本

- forge 1.3.5（`forge --version`）
- uv 0.11.2
- python 3.11+（uv 管理）
- node v24.18.0（仅 CRE 步骤用）
- git 2.54.0

## 结构与依赖

```
contracts/        # Foundry 项目（src/ test/ script/）
agents/           # Python：预测机器人（tsfm/ewma/naive）+ 推理适配器
analysis/         # 数据抓取、窗口/区间参数统计、回测
dashboard/        # Streamlit 看板（后置）
chainlink/        # CRE workflow（后置，仅 CLI 模拟）
docs/
```

单向依赖：`agents`、`analysis` 互不引用；合约不依赖任何 Python。组合根=各子项目入口脚本。窗口长度与区间边界是合约构造参数，不是硬编码。

## 第一个功能：市场合约内核

范围：`BaseFeeMarket.sol`——轮次状态机（createRound → bet → sample → settle → claim）+ 预测记录（recordPrediction）与链上评分（logscore）。参数：窗口 K、区间边界数组、下注截止。

**验收标准（判定规则先写，不挪门）**：
1. `forge test` 全绿，覆盖：完整生命周期、彩池按押注比例分配、结算落各区间边界值、覆盖率 <90% 轮次作废退款、重复 claim 拒绝、错窗口 sample 拒绝。
2. Foundry cheatcode 测试证明合约读取的是**当前块** `BASEFEE`（roll+fee 设定后断言结算均值）。
3. 预测评分：构造已知分布与已知结果，断言 logscore 数值正确（先证红再变绿）。

## Full Verify

```
cd <repo>/contracts && forge fmt --check && forge build && forge test
```

## 假设

- 赛程以官方公告为准（报名 10/22 截止；10/24 下午现场演示，评审前公开仓库）；尚未在官方渠道逐条核实，仅依据主办方宣传文案。
- 主演示在本地 Anvil（离线安全）；Sepolia 仅部署留地址。
- 窗口 K=50、区间按对数倍数划分为初值，待 analysis 用 2–4 周主网数据校准后回填合约默认参数。
- 彩池模式冷启动由协议方注入种子资金，README 说明。
- 公开下注可被跟单是已知问题，README 记录 commit-reveal/FHE 为未来方案。

## 后续（交给 goal 的候选任务）

1. 数据管线：抓取主网 fee history → 窗口均值分布统计 → 定参图（10/20 晚）。
2. Anvil 回放驱动 + 三机器人（tsfm/ewma/naive）跑通一整轮（10/21）。
3. 离线回测与累计盈亏/校准图（10/21）。
4. Streamlit 看板 + 预测者排行榜（10/22，可砍）。
5. Chainlink CRE workflow CLI 模拟 + README 标注（10/22，可砍）。
6. README/录屏/仓库公开（10/22）。
7. 边界测试：goal 建出第二个功能目录时加（agents 不引用 analysis 等）。

## 脚手架记录

- 生成器命令：`forge init contracts --empty`（forge 1.5.1-stable），结果：成功（foundry.toml / lib/forge-std v1.17.0；嵌套 .git 已移除；solc 0.8.28）
- Python（agents/analysis）尚未初始化：留给 goal 第一个相关任务时 `uv init`（记录于「后续」）
- 手写（原因：测试辅助合约无官方生成器）：MockERC20、ExposedHelpers
