# legacy/

已废弃方向的归档代码，仅供参考。

## vol-agents/

旧「BaseFee 预测市场」方向的预测机器人与回测：

- `src/agents_bots/`：naive、EWMA、TimesFM（`tsfm.py`）三种 BaseFee 预测机器人，概率映射与回测管线
- `scripts/`：`run_backtest.py` 回测入口、`tsfm_runner.py` TimesFM 推理脚本
- `tests/test_m1_acceptance.py`：当时的 M1 验收测试
- `docs/backtest_report.md`：回测报告
- `Makefile.patch`：当时对根 `Makefile` 的改动（未合入）

该方向已被新方向（Uniswap 波动率 + EZKL + ERC-8004，见根目录 `agents/` 等）取代。
本目录**不参与**任何构建、`make verify`、lint 或测试，也不保证可运行。

完整备份（含 roadmap 状态 `docs/.local/`，不含 `.venv`/`__pycache__`）：
`~/Work/_archive/verifiable-forecasts-roadmap-20261021.tar.gz`
