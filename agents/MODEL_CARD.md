# 模型说明（Model Card）：三个波动率预测模型

本文写给路演和评委问答用。所有数字取自代码和已提交的产物（`agents/models/*/meta.json`、`settings.json`），
或取自本机实测记录；出处写在每处后面。没有出处、无法从仓库核实的说法标 `[待证据]`。

> **一句话限定**：三个模型在 ETH/USDC 0.05% 池**真实 Swap 历史**（2026-09-10 至 10-22，约 42 天）上
> 按时间切分训练和评估；气候基线分位数只用训练期。测试期只有 7 天、一个行情阶段，下文的测试期分数
> 只说明「在这一周跑赢了简单基线」，不是长期表现的保证。

## 1. 概述

每个模型预测一件事：Uniswap V3 ETH/USDC 0.05% 池在**接下来 12 个 300 秒段（共 1 小时）**里的
实现波动率（realized volatility, RV，tick²）取对数后 `y = ln(max(RV, 1))` 的 **5 个分位数**，
分位水平 τ = 0.1 / 0.25 / 0.5 / 0.75 / 0.9。输入是开局时合约自己从池子 `observe()` 算出的 16 个特征，
输出是 5 个严格递增的有符号整数 `outputs[k] = q_k × 2^12`。

模型故意做得很小（85 / 357 / 709 个参数），因为每次预测都要用 EZKL 生成零知识证明（zk proof），
并在链上验证后才算数（以下为 2026-10-24 重训后本机实测，Apple M5 16 GB）：

- 电路规模：三个电路都固定在 `logrows = 15`，实际用 683 / 1,227 / 1,987 行（各模型 `settings.json`
  的 `num_rows`）。输出头只有加法、ReLU 与常数矩阵乘法，不再需要 exp 查找表。
- 证明耗时：每次 `prove` 约 4–7 s，峰值内存约 0.38–0.41 GB（4 个证明并行时，
  `agents/out/<model>/timing.jsonl`，git 忽略）；`setup` 约 1 s / 0.31 GB；proving key 138 MB。
- 链上验证成本：三个验证合约运行时均为 13,440 B（低于 EIP-170 的 24,576 B，`forge build --sizes`）；
  证明 3,072 B；单独调用 `verifyProof` 约 552,7xx gas（`cast estimate`，含 21k 基础费：linear_abs 552,682、
  mlp16 552,670、mlp32_abs 552,658；改动一个输出即被拒绝）。

## 2. 输入特征（16 个）

定义在 `contracts/src/VolMarket.sol` 的 `_features()`（约 244–262 行），链下镜像在
`agents/vol_agents/contract_math.py`。

1. `createRound` 时合约调用 `pool.observe(secondsAgos)`，`secondsAgos = [17Δ, 16Δ, …, 0]`，Δ = 300 s，
   得到 18 个 `tickCumulative` C_0..C_17。
2. 17 个段均 tick（segment mean tick）：`b_j = floorDiv(C_{j+1} − C_j, Δ)`。`floorDiv` 向负无穷取整，
   与 Uniswap `OracleLibrary.consult` 一致（`_floorDiv`，约 578 行）。
3. 16 个相邻差：`f_j = b_{j+1} − b_j`（单位 tick）。
4. 截断（CLAMP）：`f_j` 截到 [−64, 64]（`FEATURE_CLAMP = 64`）。
5. 放大（MULT）：`x_int_j = clamp(f_j) × 128`（`FEATURE_MULT = 128`），合约把这 16 个整数存进轮次。
6. 模型输入：`x_j = x_int_j / 4096`（`SCALE = 4096 = 2^12`，对应 EZKL `input_scale = 12`），
   即 `x = f / 32`，取值范围 [−2, 2]。

**为什么模型无法用别的输入造假**：证明的公共输入（public inputs）由合约自己拼。`revealPrediction` 里
`_instances(r.features, outputs)`（约 316–329 行）把存下的 16 个特征按域编码（负数编码为 `R − |x|`，
R 为 BN254 标量域模数 `FIELD_R`），再接上提交的 5 个输出，共 21 个 instance，交给验证合约。agent
只能提交证明和输出，不能提交特征；用别的输入生成的证明会被拒绝（测试
`contracts/test/VolMarket.t.sol::test_FeatureMismatchRejected`）。agent 在链下也先检查 witness 的输入
与合约编码一致，再去证明（`agents/vol_agents/agent.py` 41–56 行）。

## 3. 输出与打分

- **目标**：`y = ln(max(RV, RV_FLOOR))`，`RV_FLOOR = 1` tick²（RV = 0 时 y = 0），自然对数。RV 口径不变
  （`_realizedVol`：13 个检查点 → 12 个段均 tick → 11 个相邻差，`RV = Σ(差)²`，整数 tick²；缺点时按项数
  m 归一 `floor(Σ × 11 / m)`，可读点不足 90% 则作废退款）。链上 `MarketMath.lnWad` 计算 y（1e18 单位）。
- **输出尺度**：`outputs[k] = q_k × 2^12`（`OUTPUT_SCALE_BITS = 12`，等于 EZKL `model_output_scales = [12]`），
  链上换成 1e18 单位 `q_e18 = outputs[k] × (1e18 >> 12)`，因 1e18 = 2^18·5^18 所以是精确整数
  （`1e18 >> 12 = 244,140,625,000,000`）。合约要求长度 K、严格递增、且每个值在 [−20e18, 60e18] 内。
  负数输出在证明的公共输入里编码为 `R − |x|`（与特征相同），agent 解码时大于 R/2 的域元素视为负数。
- **单调输出头**：`q_1 = a_1`，`q_k = q_{k−1} + relu(a_k) + 2/4096`。相邻分位数至少差 2 个网格单位，
  所以 EZKL 定点取整后仍严格递增（`train.py` 的 `HEAD_GAP`；ONNX 里用常数矩阵 `first`/`cum` 与 `gaps` 实现）。
- **pinball 评分**（1e18 单位，`MarketMath.pinball`，链下镜像 `contract_math.pinball_e18`）：
  每档 `u = y − q_k`；`u ≥ 0` 时 `ρ_k = floor(τ_k·u / 1e18)`，否则 `ρ_k = floor((1e18 − τ_k)·(−u) / 1e18)`；
  `L = floor(Σρ_k / K)`。分数 `score = −L`（越接近 0 越好），写入 ERC-8004 信誉（tag1 `pinball`，
  tag2 `vol-300s-12`）。超额 `excess = max(L_baseline − L, 0)` 决定预测者分成。
- **基线**：每轮 `createRound` 带入训练期气候分位数（`models/baseline_quantiles.json`，由
  `analysis/src/vol_calibrate.py --until 1791417600 --baseline-quantiles` 生成：训练期 8,000 个 1 小时窗口的
  nearest-rank 分位数，量化到 2^-12 网格）：`[4.6914, 5.5872, 6.4409, 7.2766, 8.0024]`，训练期平均 pinball
  0.3668，训练切点之后的 4,122 个窗口 0.3685。
- **训练损失与链上评分一致**：训练最小化平均 pinball 损失（`train.py` 的 `loss_grad`），与链上 `L / 1e18`
  是同一个量；差别只在链上用的是电路量化到 2^-12 网格后的分位数，以及整数向下取整（每项误差 < 1e-18）。

## 4. 三个模型

| 模型 | 结构（`train.py` 的 `SPECS`） | 参数量 | 电路行数 | ONNX sha256 前 12 位 |
|---|---|---:|---:|---|
| `linear_abs` | `abs(x)` → 线性 16→5 → 单调分位数头 | 85 | 683 | `d5b78e7b22ef` |
| `mlp16` | 有符号 `x` → 16 ReLU → 5 → 单调分位数头 | 357 | 1,227 | `02725299dfe6` |
| `mlp32_abs` | `abs(x)` → 32 ReLU → 5 → 单调分位数头 | 709 | 1,987 | `baba23c1cd67` |

参数量来自 `meta.json` 的 `params`（85 = 5×16+5；357 = 16×16+16+5×16+5；709 = 32×16+32+5×32+5）。
`_abs` 版本先取绝对值：波动大小不取决于涨跌方向。`mlp16` 故意保留有符号输入，作为结构不同的对照。

**训练超参**（`agents/vol_agents/train.py`）：

| 项 | 值 | 位置 |
|---|---|---|
| 损失 | 5 档平均 pinball，τ = 0.1/0.25/0.5/0.75/0.9 | `pinball()` / `loss_grad()` |
| 优化器 | Adam，β1 = 0.9，β2 = 0.999，ε = 1e-8 | `train()` |
| 学习率 | 0.02，指数衰减 `0.02 × 0.1^(t/steps)` | `train()` |
| 步数 | 3,000 | `--steps`，`meta.json` |
| batch | 每步从训练集有放回抽 2,048 条 | `train()` |
| L2 | `L2 = 1e-6`，只作用于权重 W | `loss_grad()` |
| 输出头初值 | 偏置使初始预测等于训练目标的 5 个分位数（常数预测） | `head_init()` |
| LEAK | 0.01：只在训练时让关闭的头部 ReLU 仍有梯度，间隔可以重新打开 | 模块常量 |
| 随机种子 | 模型初始化 100 / 101 / 102，校准边缘样本 9 | `SEED_*` |

## 5. 训练数据：真实池子历史

- **来源**：`analysis/src/fetch_swaps.py` 从主网拉取的 ETH/USDC 0.05% 池全部 Swap 事件，区块
  25,944,554–26,246,949（2026-09-10 04:19 – 10-22 08:26 UTC），299,046 笔，2,000 区块一段、无失败段
  （`analysis/data/swaps_6w.csv`，git 忽略）。`vol_calibrate.py --export-grid` 把它重建成每 60 s 一个
  `tickCumulative` 的网格（与池子 oracle 只差一个常数，差分时抵消）。
- **样本**（`vol_agents/dataset.py`）：每个网格时刻 T 当作一次 `createRound`：特征是合约在 T 从 18 个
  `tickCumulative` 算出的 16 个整数（同一个 `features_from_cumulatives`，含 floorDiv、CLAMP、MULT）；
  目标是 `startTime = T + 300 s` 起 1 小时的 RV（同一个 `realized_vol_from_cumulatives`）取
  `y = ln(max(RV, 1))`。开轮提前一个段（300 s）与 fork 演示一致，特征的段与上一轮窗口的段对齐。样本每 60 s 一个，
  相邻样本重叠。
- **按时间切分**（`split_by_time`，不打乱）：训练期 T 的读取区间 `[T − 17Δ, T + Δ + 12Δ]` 全部早于
  2026-10-08 00:00 UTC，验证期全部落在 10-08 00:00 – 10-15 00:00，测试期全部晚于 10-15 00:00；跨切点的
  样本直接丢掉，所以三段之间没有任何一秒数据被共用。样本数：训练 39,910、验证 9,930、测试 10,437。
- **基线只用训练期**：气候分位数来自 `vol_calibrate.py --until 1791417600`，只读 10-08 00:00 之前的 Swap；
  `train.py` 检查 `baseline_quantiles.json` 的 `until` 与分位水平和代码一致才开始训练。投注桶边界
  `[202, 474, 856, 1712]` 同样只用训练期，但模型不再使用它。
- **特征量级**：真实 5 分钟段均差的绝对值中位数 4 tick、p99 43 tick、最大 218 tick；CLAMP（±64）只截了
  0.33% 的特征、3.6% 的样本至少有一个特征被截，所以缩放常数（CLAMP 64、MULT 128、scale 4096）不需要改，
  合约与电路口径不变。
- **不加合成数据**：`synth()` 只留给特征公式的单测，最终模型**只用真实数据**。

## 6. 评估结果（测试期 2026-10-15 – 10-22，真实数据）

指标是平均 pinball 损失（ln 单位，与链上 `−score / 1e18` 同一个量，越小越好），以及 50% / 80% 区间覆盖率
（y 落在 [q.25, q.75] / [q.1, q.9] 内的比例，理想值 0.5 / 0.8）。全部样本 10,437 个（每 60 s 一个，重叠），
出自 `models/eval.json`：

| 预测 | 平均 pinball | 覆盖率 50% | 覆盖率 80% |
|---|---:|---:|---:|
| 训练期气候分位数（链上基线） | 0.3325 | 0.574 | 0.817 |
| 上一小时 y + 训练期残差分位数 | 0.3254 | 0.512 | 0.813 |
| `linear_abs` | 0.2874 | 0.550 | 0.827 |
| `mlp16` | 0.2912 | 0.513 | 0.817 |
| `mlp32_abs` | **0.2856** | 0.478 | 0.777 |

- 三个模型都跑赢链上的气候基线，平均 pinball 低 0.041–0.047（约 12–14%），也都跑赢「上一小时 y + 残差」
  基线（低 0.034–0.040）。
- 验证期（10-08 – 10-15，未用于任何选择）：气候基线 0.4085、上一小时基线 0.3379，`linear_abs` 0.3204、
  `mlp16` 0.3244、`mlp32_abs` 0.2985。验证周的分布偏离训练期更多，气候基线明显变差。
- 覆盖率：`mlp32_abs` 的区间偏窄（80% 区间只覆盖 77.7%），另外两个接近名义值。
- 单测 `test_model_beats_climatological_baseline_on_real_test_rounds` 用提交的测试期抽样
  `tests/fixtures/real_holdout.json`（每小时一轮，174 轮）要求每个模型的平均 pinball 比气候基线至少低 0.02
  （实际：基线 0.3326，三个模型 0.283–0.291）。

主网 fork 上连续 24 小时的逐轮链上成绩见 `docs/DEMO.md`；那是 24 个样本，波动大，只作演示，不作评估。

### 6.1 滚动多折评估（walk-forward，离线）

上面只有一个测试周。为了看分数是否稳定，`vol_agents/walkforward.py` 把同一份 42 天数据切成 4 折：
切点 09-24、10-01、10-08、10-15（UTC 0 点），3 个模型结构用切点之前的样本重训，然后在切点之后 7 天内的样本上
打分（最后一折测试段是 10-15 至 10-22 0 点）。跨切点的样本丢弃。每折的气候基线是该折训练样本 y 的
nearest-rank 分位数（量化到 2^-12 网格；已部署基线用 analysis 的 300 s 步长 Swap 窗口，10-08 折两者相差
< 0.05，单测 `test_walkforward_anchor.py`）。表格由脚本从 `models/walkforward.json` 生成，单测
`tests/test_walkforward.py` 核对二者一致（平均 pinball，越小越好）：

<!-- walkforward:begin (generated by vol_agents.walkforward) -->
| 折（测试周起点） | 训练轮数 | 测试轮数 | linear_abs | mlp16 | mlp32_abs | climatological | train_lag_residual |
|---|---|---|---|---|---|---|---|
| 2026-09-24 | 19750 | 9930 | 0.2938 | 0.2927 | 0.2991 | 0.3581 | 0.3243 |
| 2026-10-01 | 29830 | 9930 | 0.3348 | 0.3337 | 0.2968 | 0.4360 | 0.3309 |
| 2026-10-08 | 39910 | 9930 | 0.3204 | 0.3244 | 0.2985 | 0.4092 | 0.3379 |
| 2026-10-15 | 49990 | 9930 | 0.2940 | 0.2945 | 0.2889 | 0.3404 | 0.3295 |
| 平均 |  |  | 0.3108 | 0.3113 | 0.2958 | 0.3859 | 0.3306 |
<!-- walkforward:end -->

- 4 个测试周里，3 个模型都跑赢气候基线（低 0.05–0.14）。
- 对「上一小时 y + 残差」基线：`mlp32_abs` 4 折全胜（低 0.025–0.041）；`linear_abs` 与 `mlp16` 3 胜 1 负
  （10-01 那折分别输 0.004 与 0.003）。
- 训练超参（步数 3000、学习率）没有在任何一折的测试周上调过；10-08 这一折与第 6 节的训练完全相同，
  其测试周就是第 6 节的验证期，分数逐位一致（单测 `test_walkforward_anchor.py`）。
- 分数随行情变化明显（`linear_abs` 在 0.294 到 0.335 之间）：单周的数字只能说明那一周。
- **链上用的是第 6 节那组模型**（10-08 切点）。这里的其他模型只为评估而训练，没有导出、没有登记上链。
- 数据文件被 git 忽略（`analysis/data/`），评委无法直接复现；有数据时的复现命令：

```bash
cd analysis && uv run python src/vol_calibrate.py --swaps data/swaps_6w.csv --export-grid data/tick_cumulative_grid.csv
cd ../agents && uv run python -m vol_agents.walkforward   # 写 models/walkforward.json 与本节表格
```

### 6.2 自部署推理服务上的三个时序大模型 agent（离线）

三个独立 agent（`api_agent.tsfm_agents`，模型跑在运营方自部署的推理服务上，后处理在 `tsfm_forecast.py`）：
`agent-timesfm-3.0`、`agent-timestral-209m`、`agent-chronos-2`。输入有两种
（`history.round_context`，`Context.source`）：`onchain` 是和 zk 模型一样的链上 16 个特征（÷128 后是
tick 差分，下称 c16）；`swaps` 是链下 swap 缓存算出的 512 个 5 分钟段均值差分（约 42.7 小时，最后 16 点
与链上特征一致，下称 c512）。timestral-209m 和 chronos-2 请求 c512，缓存缺失或与链上特征对不上时
回退 c16；timesfm-3.0 固定用 c16（理由见下）。模型给出后 13 步每一步差分的分位数；agent 对窗口内
11 步各自独立抽样 4000 次（固定种子），乘以按模型设定的 spread，平方求和得到每条路径的实际方差，
再取 `y = ln(max(RV_path, 1))` 在 τ = [0.1, 0.25, 0.5, 0.75, 0.9] 上的经验分位数（numpy 线性插值）。
**不做分位数相加**：相加会把水平低估约 42%，并得到 U 形分布。

- **spread**（按模型和输入，在验证期 10-08 至 10-15 的 165 个整点轮次上按 ln RV 分位数的平均 pinball 损失
  重选，候选 {0.2 … 1.2}，每轮单独请求一次推理服务；测试期没有参与）。原来与均匀分布混合的那一步只对分桶
  概率有意义，已去掉。验证期 pinball 损失（越低越好；训练期气候基线分位数在同一 165 轮上为 0.4102）：

  | 模型 | 输入 | 旧 spread（分桶时选定） | 旧 spread 损失 | 新 spread | 新 spread 损失 |
  |---|---|---|---|---|---|
  | timesfm-3.0 | c16 | 0.5 | 0.4162 | **0.6** | 0.4012 |
  | timestral-209m | c16 | 0.5 | 0.4092 | 0.5 | 0.4092 |
  | timestral-209m | c512 | 0.8 | 0.3127 | 0.8 | 0.3127 |
  | chronos-2 | c16 | 0.35 | 0.3772 | **0.4** | 0.3658 |
  | chronos-2 | c512 | 0.8 | 0.3401 | **0.9** | 0.3355 |

  c16 上 timesfm-3.0 与 timestral-209m 和气候基线基本持平（0.401 / 0.409 对 0.410），chronos-2 低 0.044；
  c512 的 timestral-209m 与 chronos-2 比基线低 0.07–0.10。
  这是选参所用的同一批轮次，不是样本外结果。
- **校准跟着输入走**（`tsfm_forecast.calibration(model, source)`）：`onchain` 用 `tsfm_forecast.MODELS` 的
  spread；`swaps` 用 `history.LONG_CONTEXT_SPREAD`（timesfm-3.0 0.8 沿用分桶时的值，它固定用 c16）。
  揭示记录里 `context_source` / `context_points` / `context_reason` 写明这一轮实际用的是哪种输入。

以下测试期表格都是**改为分位数输出之前**的分桶 log score 结果，留作历史；分位数输出的测试期 pinball
损失尚未测 `[待证据]`。

测试期（10-15 至 10-22，174 个整点轮次，每轮单独请求一次推理服务，和实盘一致）平均对数得分；
uniform = −1.6094，linear_abs = −1.3906（回放 24 轮：−1.4795），transition = −1.4350：

| agent | 档位 | 测试期 174 轮 | 相对 uniform | 相对 linear_abs | 回放 24 轮（总分） |
|---|---|---|---|---|---|
| agent-timesfm-3.0 | 可复现 | −1.5250 | +0.084 ± 0.058 | −0.135 ± 0.037 | −1.564（−37.54） |
| agent-timestral-209m | 可复现 | −1.5005 | +0.109 ± 0.045 | −0.110 ± 0.026 | −1.566（−37.59） |
| agent-chronos-2 | 可复现 | −1.4964 | +0.113 ± 0.044 | −0.106 ± 0.027 | −1.625（−39.00） |

回放 24 轮 uniform 的总分是 −38.63，linear_abs 是 −35.51。三个模型都没赢过 linear_abs；timestral 和
chronos 在测试期上相对 uniform 的优势约为 2.5 个标准误，timesfm 只有约 1.5 个。在回放的 24 轮上，
三个模型和 uniform 之间的差别都落在噪声范围内。

同一测试期改用 c512（c512 校准；测试期请求为批量请求，前面已验证批量与单独请求逐位一致）。
`history.round_context` 在 6 周 swap 缓存上为验证期加测试期 339 轮重建的 512 点序列与评测所用序列
339/339 逐位一致：

| agent | c16 测试期 | c512 测试期 | c512 相对 uniform | c512 相对 linear_abs | c512 回放 24 轮（总分） |
|---|---|---|---|---|---|
| agent-timesfm-3.0 | −1.5250 | −1.4834 | +0.126 ± 0.042 | −0.093 ± 0.042 | −1.531（−36.75） |
| agent-timestral-209m | −1.5005 | −1.4177 | +0.192 ± 0.043 | −0.027 ± 0.029 | −1.449（−34.77） |
| agent-chronos-2 | −1.4964 | −1.4465 | +0.163 ± 0.045 | −0.056 ± 0.035 | −1.493（−35.83） |

长上下文让三个模型都提升了 0.04–0.08，三者相对 uniform 都超过 3 个标准误。测试期上仍然没有一个赢过
linear_abs；timestral 只差 0.027 ± 0.029，在噪声内。回放 24 轮上 timestral 的总分（−34.77）高于
linear_abs（−35.51），但 24 轮的标准误约 0.12/轮，不能据此说它更好。上线时实际用 c512 还是回退 c16 取决于
`VOL_HISTORY_CACHE` 是否及时刷新，看揭示记录的 `context_source`。

timesfm-3.0 用 c512 也能提升（−1.5250 → −1.4834），但仍保持 c16：它的本地 c512 重算还没有逐轮对过。

**揭示量化与容差**：分位数在提交前取整到 2^-12 网格，`outputs[k] = round(q_k · 4096)`，再逐个抬到严格递增
（至少比前一个大一格）；链上存 `outputs[k] · (1e18 >> 12)`（1e18 ln 单位）。提交先于结果，链上提交的哈希
照旧绑定揭示的整数；只有“揭示 = 公开权重算出的值”这一步是容差检查：每个分位数
|重算 − 揭示| ≤ `RECOMPUTE_TOLERANCE_E18` = 1e15（1e18 ln 单位，约 4 格），结论为 exact（整数相同）、
tolerant 或 fail（`tsfm_forecast.compare_reveal`）。固定种子下经验分位数只在浮点噪声让少数路径换序时才变。

**c512 从链上重建**：`swap_logs.py` 通过 JSON-RPC 拉池子的 Swap 日志（从第一个检查点前 1 小时到
createRound 段末的第一个区块），写成与 swap 缓存相同的格式，再交给 `history.round_context`。主网日志
重建的 512 点序列与评测所用序列在回放轮次上逐位一致（见下）。若重建序列对不上揭示，重算再试 agent 缓存
过期时回退用的 16 点链上特征；两者都只依赖链上数据。

**本地重算 vs 推理服务**（分桶输出时测得；每轮单独请求一次，与实盘一致；本地 CPU float32，公开权重，
同一后处理与取整。分位数输出尚未重新逐轮比对 `[待证据]`）：

| 模型 | 上下文 | 测试期 174 轮 | 回放 24 轮 | 最大桶差（1e18） | 取整前最大概率差 |
|---|---|---|---|---|---|
| timesfm-3.0 | c16 | 174 exact | 24 exact | 0 | 0 |
| timestral-209m | c512 | 174 exact | 24 exact | 0 | 0 |
| timestral-209m | c16（回退） | 174 exact | 24 exact | 0 | 1.75e-4 |
| chronos-2 | c512 | 174 exact | 24 exact | 0 | 1.75e-4 |
| chronos-2 | c16（回退） | 174 exact | 24 exact | 0 | 1.75e-4 |

timestral-209m 的本地推理要开 symmetric averaging（与镜像序列的预测取平均），关掉时 174 轮里 170 轮 fail。

**档位判断**（要求：权重公开、推理服务在固定参数下重复调用逐位一致、本地用公开权重重算的揭示在全部
检查轮次上落在容差内）：三个模型都是**可复现**。登记方式：`registerModel(address(0), operator, modelHash)`，
`modelHash = keccak256(规范 JSON{公开权重 repo@revision, 上下文定义与长度, 推理参数, 后处理参数,
输出（分位数水平、scale bits、网格、容差）,
sha256(tsfm_forecast.py), sha256(tsfm_local.py), c512 模型另加 sha256(history.py)})`
（`tsfm_forecast.model_hash`）。任何人都可以用
`python -m vol_agents.tsfm_recompute --model chronos-2 ...` 在本地重算并比对，过程完全不经过推理服务。
许可：timesfm-3.0 为 TimesFM 非商用许可，timestral-209m 为 Mistral Modified MIT，chronos-2 为 Apache-2.0。

## 7. 从训练到上链的流水线

```
train.py ──► models/<name>/model.onnx (+ meta.json, cal.json)
               │  opset 13；输入 x[1,16] float，输出 y[1,5]（单调分位数头，ln RV）
               ▼
build.py / ezkl_step.py（每步独立子进程，记录耗时与峰值内存）
  settings   input_scale = param_scale = 12（输出尺度也是 12），logrows 15，输入/输出 public，参数 fixed
  calibrate  用 cal.json（32 条按幅度均匀抽取的真实训练期样本 + 32 条 [-2,2] 均匀边缘样本）校准；
             若校准改动了 input_scale 或 logrows > 15 就中止
             → 校准后的 settings 钉在 models/<name>/settings.json（onnx_sha256 不变时复用）
  compile    → out/<name>/model.compiled
  setup      先校验 KZG SRS 的 sha256 = 90807800…3ebb45（4,194,564 B），不符即拒绝 → pk / vk
  evm        → Verifier.sol，改名后放 contracts/src/verifier/<Name>Verifier.sol
               ▼
链上：owner 调 registerModel(verifier, operator) 得 modelId
               ▼
每轮：agent 读 getFeatures → witness（核对公共输入 = 合约编码）→ prove（或读证明缓存）
      → 解码有符号输出、检查严格递增与取值范围 → commitPrediction(keccak256(abi.encode(id, modelId,
      int256[] outputs, salt, sender))) → 提交截止后 revealPrediction(proof, int256[] outputs, salt)，
      合约验证通过才记录
               ▼
结算：settle 读 observe() 算 RV、定赢桶（投注用）、算 y = lnWad(max(RV,1))、给每个预测打 pinball 分、写 ERC-8004 信誉
```

依据：`build.py`、`ezkl_step.py` 的 `step()`、`agent.py` 的 `prove_round()`；
`VolMarket.sol` `registerModel`、`commitPrediction`、`revealPrediction`、`settle`。

EZKL 的 settings 里 range check 顺序来自哈希表，两次校准可能得到不同电路，所以校准结果被钉住；
固定 settings 后 compile → setup → evm 可逐字节复现已提交的验证合约（`build.py` 5–8 行，
测试 `agents/tests/test_models.py::test_models_export_to_ezkl`）。已提交的验证合约与新构建不同时，
构建会停下，只有 `--force` 才覆盖。

**复现命令**（在 `agents/` 下）：

```bash
uv sync
uv run python -m vol_agents.train     # 重训（会改变 ONNX，之后必须 --force 重建验证合约并重新部署）
uv run python -m vol_agents.build     # EZKL 构建；SRS 可用 --srs PATH 或 VOL_AGENTS_SRS 提供
uv run python -m vol_agents.round     # 本地 anvil：部署、3 个 agent 证明并提交、结算、对比
uv run python -m vol_agents.precache --start 2026-10-21T06:00:00Z --hours 24   # 预生成整点轮次的证明缓存
```

**证明缓存**：证明只绑定公共输入（本轮特征）与输出，所以按 `(模型, 特征)` 缓存：
`agents/out/proof-cache/<model>/<sha256(model.onnx 字节 + json.dumps(features))[:32]>/{proof.json,timing.json}`。
`vol_agents.precache` 用一次主网归档 `observe()` 算出整点轮次（开轮时间 = startTime − 300 s）的特征，与 fork
回放的 `features_match_mainnet` 同一口径，提前把证明写进缓存；ONNX 一变，键随之改变，旧证明自然失效。

## 8. 局限与下一步

**局限**

- **评估期短**：测试期只有 7 天（约 168 个不重叠小时），一个行情阶段；60 s 步长的重叠样本让数字看起来
  更稳，实际有效样本远少于 10,437。
- **分布漂移**：气候基线按训练期定，验证周的基线损失（0.41）明显高于测试周（0.33）；行情换挡时
  基线需要重算、模型需要重训，旧 modelId 的验证合约不能改权重。
- **离强基线的距离**：比「上一小时 y + 残差」基线在测试周好 0.034–0.040，walk-forward 里
  `linear_abs`、`mlp16` 有一折输给它。
- **区间校准**：`mlp32_abs` 的 80% 区间在测试周只覆盖 77.7%，偏窄。
- **数据完整性**：网格来自 Swap 日志重建；网关截断日志会让个别窗口与 oracle 不一致（`vol_calibrate.py`
  的 Known deviation）。fork 回放用的目标值直接取自主网 `observe()`，不受这一点影响。
- **单池、单窗口**：只覆盖 ETH/USDC 0.05% 池、Δ = 300 s × 12 段。
- **模型很小**：受电路规模和证明成本约束，只看过去 85 分钟的 16 个差分。

**下一步**

1. 滚动重训：每周用新的训练期重算基线分位数、重训、`build --force` 重建验证合约并重新 `registerModel`。
2. 更长的测试期与按月分段的稳定性评估（4 个周的滚动评估见 6.1；更长的历史需要先拉更多 Swap）。
3. 特征里加入更长的历史（受 `FEATURES = 16` 和电路规模约束，需要改合约口径）。

## 9. 评委问答（Q&A）

**Q1：训练数据是真实的吗？**
是。最早为打通链路用合成随机游走训练；现在用主网 ETH/USDC 0.05% 池 42 天的全部 Swap 重建的 tick 历史，
按合约同一口径构造特征与目标 ln RV，按时间切成训练 / 验证 / 测试，基线只用训练期（第 5 节）。

**Q2：模型这么小有什么用？**
本项目的卖点是"预测可验证、可问责"，不是模型本身多强。小模型能在约 4–7 s 内出证明、在 logrows 15
电路里放下，链上单独验证一次约 55 万 gas。在真实测试期上平均 pinball 损失从气候基线的 0.333 降到
0.286–0.291（第 6 节），比「上一小时 y + 残差」基线也低 0.034–0.040。

**Q3：zk 证明到底证明了什么？没证明什么？**
证明了：对**这一轮合约算出的 16 个特征**，用**已登记验证合约里固定的那组权重**跑推理，得到的就是提交的
5 个分位数输出（`_instances` + `_verify`，`VolMarket.sol`）。
没证明：模型好不好、训练数据是否真实、训练过程是否诚实；也不证明验证合约对应的就是仓库里那个 ONNX
文件——这一点靠公开复现：任何人可用 `model.onnx` + 钉住的 `settings.json` + 校验过的 SRS 重建验证合约逐字节比对。

**Q4：怎么防止抄别人的证明？**
证明本身不绑定发送者，所以合约给每个 modelId 绑定唯一的 operator（`registerModel(verifier, operator)`），
`commitPrediction` 要求 `msg.sender == modelOperator[modelId]`，否则 `NotModelOperator`
（`VolMarket.sol` 165–175、287 行；测试 `test_CopiedProofFromOtherSenderRejected`）。

**Q5：怎么防止模型事后换权重？**
EZKL 参数可见性是 `fixed`：权重写死在电路和验证合约里，换权重就得换验证合约。合约里 `models` 只能
由 owner 追加（`models.push`，172 行），没有修改已有 modelId 验证合约的函数；而且预测必须在 `startTime`
之前提交（`TooLateToPredict`），每个地址每轮只能提交一次（`AlreadyPredicted`），结果出来后无法改。

**Q6：agent 能不能挑对自己有利的输入？**
不能。特征在 `createRound` 时由合约从池子 `observe()` 算好并存储（229–262 行），验证时公共输入由合约
从存储里取，不接受 agent 传入。改一个特征，证明即失效（`test_FeatureMismatchRejected`）。

**Q7：为什么用 pinball 损失？**
对单个分位水平 τ，pinball（check）损失的期望在报出真实 τ 分位数时最小，所以它是分位数预测的适当评分规则，
不能靠夸大或保守获利；对 K 个水平取平均仍然适当。Gneiting & Raftery (2007), *Strictly Proper Scoring Rules,
Prediction, and Estimation*, JASA 102(477):359–378, DOI 10.1198/016214506000001437，第 6 节给出分位数预测的
适当评分规则族 `S(r, x) = Σ_i (1{x ≤ r_i} − α_i)(g(r_i) − g(x))`（g 非降），取 g 为恒等即 pinball
（B，按论文结论转述，未逐字核对原文）。我们对 ln RV 打分，相当于对 RV 的分位数取 g = ln，仍在该族内。
相比原先的 5 桶 log score，分位数不依赖桶边界，也没有概率为 0 时的底线问题；训练损失与链上评分是同一个量（第 3 节）。

**Q8：模型用的波动率口径和合约一致吗？**
一致。`contract_math.py` 逐条镜像合约的特征公式、`floorDiv`、域编码和 RV；测试读合约侧的共享 fixture
`contracts/test/fixtures/vol_rv_cases.json` 和真证明 fixture `spike_model_proof.json` 比对
（`agents/tests/test_contract_math.py`）。限制：链下镜像只覆盖无缺点的窗口，缺点情形只在合约与 analysis 测试中覆盖。

**Q9：电路量化有多大误差？**
电路用定点数（scale 2^12 = 4096），输出是 1/4096 ln 单位的整数倍。测试要求电路输出与 onnxruntime 每个分位数差
≤ 0.02 ln 单位（`test_models.py::test_models_export_to_ezkl`），链上分位数与 ONNX 差 ≤ 0.02
（`test_round.py::test_agent_proves_and_submits`）。实际最大误差的系统性统计 `[待证据]`。

**Q10：证明要多久、多贵？**
本机（Apple M5 16 GB）每次证明约 4–7 s、峰值约 0.4 GB 内存；proving key 138 MB（`agents/out/<model>/`）。
三个验证合约单独调用 `verifyProof` 约 552,7xx gas（含 21k 基础费），证明 3,072 B。

**Q11：模型在真实市场上表现如何？**
按时间切分的 7 天测试期上平均 pinball 比气候基线低 0.041–0.047，比「上一小时 y + 残差」基线低 0.034–0.040
（第 6 节）；4 个滚动测试周里都跑赢气候基线（6.1）。主网 fork 连续 24 小时回放给出 24 轮链上成绩
（`docs/DEMO.md`），样本太少，不当作评估。

**Q12：可信设置（trusted setup）安全吗？**
用的是 KZG SRS（logrows 15），构建时强制校验 sha256，不符就拒绝（`build.py` 33–35、76–79 行）。
该 SRS 来自 EZKL 的 `get_srs` 下载，其仪式来源 `[待证据]`。

**Q13：Chainlink 不是已经有波动率喂价吗？**
Chainlink 曾推出 Realized Volatility 喂价：24h / 7d / 30d 滚动窗口，数据提供方每 10 分钟采样价格
（文档 <https://docs.chain.link/data-feeds/rates-feeds>，A）；close-to-close 口径见其博客
<https://chain.link/blog/volatility-oracles>（C）。但它在主网从未上线：官方 reference data directory
`feeds-mainnet.json` 中没有一条 volatility 条目，主网 ENS `ethusd-24hr-realized-volatility.data.eth`
无法解析（2026-10-22 实测，X）；测试网（Sepolia、Arbitrum Sepolia、Polygon Amoy、Avalanche Fuji）的数据
全部停在 2024-08-30（例如 Sepolia ETH-USD 24hr `0x31D04174D0e1643963b38d87f26b0675Bb7dC96e`，
`updatedAt = 1725059400`，同日实测，X）。
而且它衡量的是过去 ≥ 24 小时已经发生的波动；我们做的是对**未来 1 小时**的可问责预测，结算由合约直接从
Uniswap `observe()` 读取，不需要波动率喂价。Chainlink 在本项目里的角色是 ETH/USD 价格交叉校验
（`docs/ARCHITECTURE.md` 第 6 节）。

量级换算（估算，X）：本项目 RV（tick²）约对应年化波动率 `1.2% × √RV`。推导：1 tick ≈ ln(1.0001) ≈ 1e-4
的对数价格；RV 是 11 个相邻段均差的平方和（`_realizedVol` 归一到 `nSegments − 1 = 11` 项，
`VolMarket.sol` 593–617 行），布朗运动下两段 300 s 均值之差的方差为 (2/3)×300 s 的方差，11 项合计有效时长约
11 × (2/3) × 300 = 2,200 s，所以年化波动率 ≈ 1e-4 × √(RV × 31,536,000 / 2,200) ≈ 0.012 × √RV。
例如年化 60% ≈ 2,500 tick²。这只是量级参考：真实价格有跳变和微观结构噪声，不满足布朗运动假设。

**Q14：大模型 / 无法用 zk 的模型怎么办？**
问责的四层里，事前提交（链上时间戳）、客观结算（`observe()` + Chainlink 交叉校验）、成绩可携带
（ERC-8004）都不依赖 zk，可以直接复用；只有“出处：确实是该模型算的”需要 zk 或可复现重算。分级验证：zk
（已实现，小模型）、可复现（已实现：开源权重的 timesfm-3.0、timestral-209m、chronos-2，登记 `modelHash`，
任何人用 `python -m vol_agents.tsfm_recompute` 从链上数据重算，每个分位数误差 ≤ 0.001（ln 单位）为一致，分桶输出时回放 72/72 次一致；
证明出处，不证明准确）、commit-reveal
仅提交（已实现，任意模型，不保证出处）、TEE 远程证明（大模型 / LLM，需信任硬件厂商，**未实现**）。opML 不做每轮结算路径：
它需要挑战窗口与链上单步 VM，并依赖 1-of-N 诚实假设；计划作为可复现档的争议层（押金 + 挑战，未实现，见
`docs/ARCHITECTURE.md`“验证档位与押金”）。非 zk 等级必须用 commit-reveal，否则后提交者能照抄
公开的预测。写入 ERC-8004 时用 tag 标注等级，读取方自选信任哪一级。详见 `docs/ARCHITECTURE.md` 第 9 节
“分级验证”与 `docs/PITCH.md` “Tiered verification”。
