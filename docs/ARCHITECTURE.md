# 架构说明：verifiable-forecasts

本文与仓库根目录的 `README.md` 配套：README 面向评审快速上手，本文件记录组件边界与数据流。

## 1. 一句话

`verifiable-forecasts` 把 EIP-1559 的原生 `BASEFEE` 值变成可结算的区间预测市场，并把 AI 的概率预测与真实结果放在同一个链上评分考场里。

## 2. 数据流

```text
Ethereum JSON-RPC (可选、只在离线分析阶段访问)
        │  eth_getBlockByNumber → block.baseFeePerGas
        ▼
analysis/src/fetch_fee_history.py
        │  data/basefee_history.csv（git-ignored）
        ▼
analysis/src/calibrate.py
        │  data/params.json { window_k, bounds_wei[] }
        ├─────────────────────────────┐
        ▼                             ▼
contracts/ createRound          agents/ forecast bots
(startBlock, endBlock,          (naive / EWMA / TimesFM)
 bounds)                               │ probability vector
        │                               ▼
        │                         recordPrediction()
        │                               │
        ├── sample() ────────────┘      │ before window start
        │   block.basefee                │
        ▼                               ▼
settle(): average → bucket       PredictionScored(logscore)
        │                               │
        └────────────── claim() ◄──────┘
                    payouts + leaderboard data

chainlink/workflow.ts（可选的 CRE 编排 / CLI simulation）
        └── reads the same parameter + forecast artifacts; it is not the settlement oracle
```

## 3. 组件职责

### `contracts/`

Foundry 项目是唯一的结算权威。`BaseFeeMarket.sol` 不读取 RPC、不调用 Python、不依赖 Chainlink；任何地址都能
在窗口内提交当前块的 `block.basefee` 样本。覆盖率不足 90% 时轮次作废并按原押注退款。

关键接口：

- `createRound(startBlock, endBlock, bounds)`：把窗口和边界写入轮次。
- `bet(roundId, bucket, amount)`：向区间彩池下注。
- `recordPrediction(roundId, probs)`：在开窗前写入 `1e18` 缩放的概率向量。
- `sample(roundId)`：读取当前 EVM 块的 `BASEFEE`，每块最多一次。
- `settle(roundId)` / `claim(roundId)`：计算均值、确定分桶、评分并支付。

### `analysis/`

只负责参数校准，不负责预测，也不负责合约调用。真实历史数据可下载到 git-ignored 的 `data/`；测试只
使用小型、固定、可审阅的 fixture。

### `agents/`

读取 `data/params.json` 的窗口定义并输出概率向量。它不能导入 `analysis` 的 Python 源码，模型进程与
下注/提交进程隔离，现场模型故障可以降级到 EWMA 或 naive。

### `dashboard/`

只读展示层，可被删掉。静态校准图、回测图、Anvil 终端日志是没有 dashboard 时的可靠 fallback。

### `chainlink/`

演示 Chainlink CRE 的 orchestration surface。它不是 `contracts/` 的依赖，也不是 base fee 结算的 oracle。

## 4. 依赖方向

```text
analysis ──(JSON artifacts)──▶ agents
analysis ──(calibration JSON)─▶ contracts deployment/demo config
agents ────(probability JSON)─▶ contracts.recordPrediction()
analysis ──(params + forecast)─▶ chainlink (CRE simulation)
contracts ──(events/state)─────▶ dashboard (read-only, optional)
```

禁止的边：

- `contracts → analysis/agents/dashboard/chainlink`
- `agents ↔ analysis` 的 Python import
- `contracts → Chainlink` 的 settlement 依赖
- `dashboard →` 任一写入接口

## 5. 可靠性边界

- **链上事实**：窗口、样本、均值、分桶、彩池支付、log score。
- **离线建议**：`window_k`、`bounds_wei`、TSFM/EWMA/naive 的预测分布。
- **演示编排**：Anvil 回放与 CRE CLI simulation。它们是可复现的操作路径，不是对协议安全性的额外假设。
