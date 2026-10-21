# 测试报告：项目基线与 analysis 离线管线

> **历史报告**：本文记录旧 BaseFee 方向 analysis 阶段的测试结果，与当前「可验证 AI 预测」方向（`VolMarket` + agents）无关；提交前按新方向重写。

## 范围

本轮交付建立了仓库目录与文档基线（`analysis/`、`agents/`、`dashboard/`、`chainlink/`、`docs/ARCHITECTURE.md`、
`docs/plans/路线图.md`、根 `README.md`），并实现 `analysis/` 离线管线：

- `src/fetch_fee_history.py`：JSON-RPC 拉取区块 `baseFeePerGas`，可断点续抓，瞬态错误指数退避重试。
- `src/calibrate.py`：连续 K 块窗口均值（整数整除）、nearest-rank 整数分位数，按 `(p90-p10)/p50` 交叉相乘选 K，
  边界取去重后的 p25/p50/p75。
- `src/pipeline.py`：先校验分桶 fixture，再可选抓取、校准并写出 `data/params.json`。

合约 `contracts/src/BaseFeeMarket.sol` 本轮未改动。

## 验证入口

```bash
make analysis-sync          # 一次性联网安装锁定依赖
make check && make test     # Foundry fmt/build/test + analysis ruff + pytest（离线、按 uv.lock）
```

## 结果

| 范围 | 命令 | 结果 |
|---|---|---|
| 校准器 | `uv run pytest tests/test_calibrate.py -q` | 39 passed |
| 抓取器 | `uv run pytest tests/test_fetch_fee_history.py -q` | 32 passed |
| analysis 全部 | `uv run pytest tests/ -q` | 112 passed |
| 管线 CLI | `uv run python src/pipeline.py --help` | 正常 |
| 根入口接线 | `make -n check` 含 `forge test` 与 analysis pytest | 通过 |

全量验证（`make check && make test`）在交付时由流水线统一执行一次，结果见终态报告。

## 与合约的一致性保证

- `window_k` ≤ 256（合约窗口上限）；`bounds_wei` 为 1–32 个严格递增的正整数，且不超过 `int256` 最大值。
- `bucket_of` 复刻 `bucketOf` 半开区间语义；`contracts/test/fixtures/basefee_bucket_cases.json` 的 15 个边界用例
  在管线写出任何文件前校验，缺失或不一致即失败退出。

## 审查

- 首轮独立审查：6 个阻塞 + 1 个建议，全部采纳并修复；1 个观察（Solidity 直接消费 fixture）延后。
- 复审结论 ok，无阻塞、无回归。

## 已知限制与后续

- 连接阶段抛出的 `http.client.HTTPException` 尚未纳入重试（读响应阶段已覆盖）。
- `params.json` 与 `calibration.md` 写入非原子。
- Solidity 测试尚未直接读取同一份分桶 fixture。
- 预测机器人、Anvil 回放、Chainlink CRE 模拟按 `docs/plans/路线图.md` 后续里程碑推进。
