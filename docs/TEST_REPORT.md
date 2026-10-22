# 测试报告：R1 analysis 波动率口径与区间校准

> 本报告对应 roadmap 第 2 轮 R1 阶段（`docs/plans/路线图.md`）：analysis 新增 Swap 事件拉取与
> 合约口径的已实现波动率校准。上一轮（旧 BaseFee 方向）的历史报告见文末归档节。
> 本报告是 R1 当时的记录：其中 7 天校准值 `[342, 620, 1124, 2052]` 已被 R5 只用训练期校准的
> `[202, 474, 856, 1712]` 取代（见 `agents/MODEL_CARD.md`）。

## 交付范围

新增两个独立模块（不改动合约、共享 fixture、agents 与旧 base fee 管线）：

- `analysis/src/fetch_swaps.py`：按 ≤10k 块分段 `eth_getLogs` 拉取 Uniswap V3 ETH/USDC 0.05% 池
  （`0x88e6...5640`）的 Swap 事件，解析出 block / tick（int24 原码反码都不猜）/ timestamp，
  写出升序 CSV（原子替换、可断点续抓）。段响应逐条校验区块范围与池地址；响应条数达到
  `LOG_COUNT_WARN_THRESHOLD = 10_000`（实测单段峰值 11,769 条）时按永久错误拒绝；任一段失败
  时 CLI 退出码为 1（失败段是永久空洞，续抓不会回填，调用方必须视为数据不完整）。
- `analysis/src/vol_calibrate.py`：从 Swap 事件重建 `tickCumulative`（同块取末笔、块间保持前值），
  按合约口径（`VolMarket._realizedVol` / `_floorDiv`：floor 除、`rv = floor(sumSquares·(N−1)/m)`、
  覆盖率 90% 作废、半开分桶）逐窗口计算已实现波动率，按 p20/p40/p60/p80 出恰好 4 个严格递增
  整数边界，写 `analysis/data/vol_params.json` 与校准报告。

## 验证入口

```bash
make check && make test                                # 全量（流水线在交付时统一跑）
cd analysis && uv run pytest -q tests/test_fetch_swaps.py tests/test_vol_calibrate.py
bash tests/acceptance/next_analysis.sh                 # R1 验收探针（起点红 → 现在绿）
```

## 结果

| 范围 | 命令 | 结果 |
|---|---|---|
| Swap 拉取模块 | `uv run pytest -q tests/test_fetch_swaps.py` | 46 passed（离线、录制响应，不联网） |
| 校准模块 | `uv run pytest -q tests/test_vol_calibrate.py` | 21 passed（含共享 fixture 8 用例逐项对拍） |
| 验收探针 | `bash tests/acceptance/next_analysis.sh` | PASS（探针在实现前先验证为红） |
| 受影响测试（含合约） | `plan.sh verify affected` | 37 passed |
| 旧管线回归 | `uv run pytest -q tests/test_calibrate.py tests/test_pipeline.py tests/test_fetch_fee_history.py` | 112 passed |
| Lint | `uv run ruff check src tests` | 通过 |

## 与合约的一致性保证

- 合约口径逐项钉死：`contracts/test/fixtures/vol_rv_cases.json` 的全部 8 个用例
  （tickCumulatives / segmentMeans / sumSquares / terms / rv / bucket / voided）由
  `test_rv_cases_fixture_parity` 逐字段断言，其中 `negative_floor`（rv 42，截断除法会得 53）与
  `missing_first_negative`（rv 45，截断会得 58）专测 floor 语义；`voided_two_missing` 专测作废规则。
- 独立审查（reviewer d3）自行用另一套积分器复算了全部 8 个用例并逐行对照
  `VolMarket.sol:275-392` 与 `MarketMath.bucketOf`，结论一致；复审（d6）确认 5 项修复落地。
- 数值路径全程整数（分位级别经 `Fraction(str(level))` 转精确有理数），无浮点。

## 真实数据校准结果

7 天主网 Swap 历史（40,383 笔、23,076 个块）→ 2,010 个 1 小时窗口（Δ=300s、N=12）：

- 边界 **[342, 620, 1124, 2052] tick²**（分位 p20/p40/p60/p80），桶占比 19/19/20/20/20 %。
- RV 范围 12–50,201 tick²，均值 1,886。占位边界 [8, 20, 45, 110] 会让几乎每轮落进最高桶
  （占位值只有 p20 的 1/43），印证了路线图对占位值的判断。
- 产物在 `analysis/data/`（git-ignored，可由模块命令复现）。

## 已知偏差（重要）

Swap 事件重建与池 `observe()` oracle 的等价性**依赖日志完整**。eth_getLogs 网关可能按
**条数**（常见 10k 条/响应）静默截断——实测该池单个 10k 块段含 11,769 条日志。对 8 个实盘
窗口的对照：6 个完全一致，2 个不符（RV 117 vs oracle 54；1132 vs 1114），归因未定论（日志
完整性是首要嫌疑，模块 docstring 与校准报告均已如实记录）。**校准边界应视为结算分布的近似，
不是保证**；下游使用时以完整日志重跑对照为准。

## 审查

- 首轮独立审查（d3）：verdict ok，3 should-fix + 3 nit；5 项采纳修复（文档如实记录偏差、
  失败段退出码与条数截断防护、load_swaps 升序校验、死字段清理、去重），1 项推迟
  （`--format jsonl` 无消费者，留待移除旧管线时一并处理）。
- 复审（d6）：verdict ok，5 项修复全部核实落地，无测试被削弱（60 → 67 个测试），
  无范围外改动。遗留观察：条数阈值对合法的高密度段会误拒（安全方向），建议后续加
  `--segment` CLI 参数。

## 历史归档（旧 BaseFee 方向，与本轮无关）

旧 analysis 管线（`fetch_fee_history` / `calibrate` / `pipeline`）本轮按计划保留未动，
其测试（112 passed）作为 Keep 回归继续通过；提交前将与 `BaseFeeMarket.sol` 一起移除。
旧方向的完整测试记录见上一版报告（git 历史 `docs/TEST_REPORT.md@2d634ac^`）。
