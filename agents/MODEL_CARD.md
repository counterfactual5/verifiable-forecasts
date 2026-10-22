# 模型说明（Model Card）：三个波动率预测模型

本文写给路演和评委问答用。所有数字取自代码和已提交的产物（`agents/models/*/meta.json`、`settings.json`），
或取自本机实测记录；出处写在每处后面。没有出处、无法从仓库核实的说法标 `[待证据]`。

> **一句话限定**：三个模型在 ETH/USDC 0.05% 池**真实 Swap 历史**（2026-09-10 至 10-22，约 42 天）上
> 按时间切分训练、选择和评估；分桶边界只用训练期校准。测试期只有 7 天、一个行情阶段，下文的测试期分数
> 只说明「在这一周跑赢了简单基线」，不是长期表现的保证。

## 1. 概述

每个模型预测一件事：Uniswap V3 ETH/USDC 0.05% 池在**接下来 12 个 300 秒段（共 1 小时）**里的
实现波动率（realized volatility, RV）落进 5 个桶的**概率分布**。输入是开局时合约自己从池子
`observe()` 算出的 16 个特征，输出是 5 个概率。

模型故意做得很小（85 / 357 / 709 个参数），因为每次预测都要用 EZKL 生成零知识证明（zk proof），
并在链上验证后才算数：

- 电路规模：三个电路都固定在 `logrows = 15`（最多 2^15 = 32,768 行），实际用 779 / 1,323 / 2,083 行
  （各模型 `settings.json` 的 `num_rows`）。`logrows` 越大，证明越慢、内存越大，SRS 文件也越大。
- 证明耗时（本机实测，Apple M5 16 GB，`agents/out/<model>/timing.jsonl`，git 忽略；2026-10-22 重训后
  `pytest tests/` 并发运行时）：每次 `prove` 7.3–17.8 s，峰值内存约 0.87–0.99 GB；`setup` 约 4 s /
  0.56–0.63 GB。fork 多小时回放里每次证明的耗时见 `docs/DEMO.md`。
- 链上验证成本（2026-10-22 重训后实测）：三个验证合约运行时 21,829–21,830 B（低于 EIP-170 的
  24,576 B，`forge build --sizes`）；证明 5,664 B；单独调用 `verifyProof` 约 848,8xx gas
  （`cast estimate`，含 21k 基础费：linear_abs 848,960、mlp16 848,816、mlp32_abs 848,972）。

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

- **5 个桶，4 个边界**（tick²）：`bucketOf` 半开区间（`contracts/src/lib/MarketMath.sol` 10–13 行）：
  桶 0：RV < b0；桶 i：b_{i−1} ≤ RV < b_i；桶 4：RV ≥ b3。当前边界是 `[202, 474, 856, 1712]` tick²
  （`contract_math.py` 的 `BOUNDS`）：训练期（2026-09-10 04:19 至 10-08 00:00 UTC）8,000 个 1 小时窗口
  RV 的 p20/p40/p60/p80（nearest rank，`analysis/src/vol_calibrate.py --until 1791417600`）。
  边界是 `createRound` 的参数，不写死在合约里。
- **RV 口径**（`_realizedVol`，约 552–575 行）：结算窗口 13 个检查点 → 12 个段均 tick → 11 个相邻差，
  `RV = Σ(差)²`，整数，单位 tick²；缺点时按项数 m 归一 `floor(Σ × 11 / m)`，可读点不足 90% 则作废退款。
- **概率归一到 1e18**（`revealPrediction`，约 292–308 行）：电路输出 5 个域元素，每个须 `< R/2`、
  总和 > 0；`probs[i] = out[i] × 1e18 / Σout`（前 4 个向下取整），余数全部补给最后一个桶，
  所以概率和恰为 1e18。
- **对数评分（log score）**（`_score`，约 436–447 行）：结算后每个预测得分
  `max(ln p_win, −18) × 1e18`，p_win 为实际落入桶的概率；p_win = 0 也记 −18e18（`MIN_LOG_SCORE`）。
  `log1e18` 是整数实现，误差 < 1e9（即 1e-9 的自然对数单位，`MarketMath.sol` 21 行）。
  分数越接近 0 越好，并写入 ERC-8004 信誉（tag1 `logScore`，tag2 `vol-300s-12`）。
- **训练损失与链上评分一致**：训练最小化平均交叉熵（cross-entropy）`−mean ln p_y`
  （`train.py` 92–97 行），正好是链上 log score 的负平均。差别只有两点：训练里加了 1e-12 防 ln 0，
  链上底线是 −18；链上用的是电路量化后的概率（见 Q&A 第 9 条）。
- **logit clip 让底线实际触发不到**：logit 被截到 [−3, 3]，浮点下单桶概率最低
  `1/(1+4e^6) ≈ 6.2e-4`（ln ≈ −7.39），最高 `1/(1+4e^−6) ≈ 0.990`（ln ≈ −0.0099），离 −18 很远。
  电路量化后的确切最低值 `[待证据]`。

## 4. 三个模型

| 模型 | 结构（`train.py` 43–46 行） | 参数量 | 电路行数 | ONNX sha256 前 12 位 |
|---|---|---:|---:|---|
| `linear_abs` | `abs(x)` → 线性 16→5 → Clip(±3) → Softmax | 85 | 779 | `5771090f6d25` |
| `mlp16` | 有符号 `x` → 16 ReLU → 5 → Clip(±3) → Softmax | 357 | 1,323 | `bb405dcd2efb` |
| `mlp32_abs` | `abs(x)` → 32 ReLU → 5 → Clip(±3) → Softmax | 709 | 2,083 | `e9b2d11cbb60` |

参数量来自 `meta.json` 的 `params`（85 = 5×16+5；357 = 16×16+16+5×16+5；709 = 32×16+32+5×32+5）。
`_abs` 版本先取绝对值：桶只取决于波动大小，不取决于涨跌方向（`train.py` 36 行注释）。
`mlp16` 故意保留有符号输入，作为结构不同的对照。

**训练超参**（`agents/vol_agents/train.py`）：

| 项 | 值 | 位置 |
|---|---|---|
| 优化器 | Adam，β1 = 0.9，β2 = 0.999，ε = 1e-8 | `train()` |
| 学习率 | 0.05，指数衰减 `0.05 × 0.1^(t/steps)`，最后降到 0.005 | `train()` |
| 步数 | 3,000 | `--steps`，`meta.json` |
| batch | 每步从训练集有放回抽 2,048 条 | `train()` |
| L2 | `L2 = 1e-6`，只作用于权重 W | `loss_grad()` |
| logit clip | ±3（`LOGIT_CLIP = 3.0`） | 模块常量 |
| LEAK | 0.05：clip 饱和时梯度乘 0.05，饱和样本仍能训练 | 模块常量 |
| 初始化 | 第一层 W ~ N(0, 1/(rms(x)·√16))，b1 ~ N(0, 0.1)，W2 ~ N(0, 1/√H) | `init_params()` |
| 随机种子 | 合成增强 7（仅用于验证期选择），模型初始化 100 / 101 / 102，校准边缘样本 9 | `SEED_*` |

**logit clip ±3 的原因**：电路里的 Softmax 用 exp 查找表（lookup，`settings.json` 的
`required_lookups: Exp, scale 4096`）。把 logit 限制在 [−3, 3]，任意输入下 exp 的自变量跨度最多 6，
查找表范围有界，三个电路因此都能放在 `logrows 15`（`train.py` 28–29 行注释，
`settings.json` 的 `lookup_range = [-49152, 0]`）。代价是模型最高只能给出约 99.0% 的置信度。

## 5. 训练数据：真实池子历史

- **来源**：`analysis/src/fetch_swaps.py` 从主网拉取的 ETH/USDC 0.05% 池全部 Swap 事件，区块
  25,944,554–26,246,949（2026-09-10 04:19 – 10-22 08:26 UTC），299,046 笔，2,000 区块一段、无失败段
  （`analysis/data/swaps_6w.csv`，git 忽略）。`vol_calibrate.py --export-grid` 把它重建成每 60 s 一个
  `tickCumulative` 的网格（与池子 oracle 只差一个常数，差分时抵消）。
- **样本**（`vol_agents/dataset.py`）：每个网格时刻 T 当作一次 `createRound`：特征是合约在 T 从 18 个
  `tickCumulative` 算出的 16 个整数（同一个 `features_from_cumulatives`，含 floorDiv、CLAMP、MULT）；
  标签是 `startTime = T + 300 s` 起 1 小时的 RV（同一个 `realized_vol_from_cumulatives`）按 `BOUNDS`
  落的桶。开轮提前一个段（300 s）与 fork 演示一致，特征的段与上一轮窗口的段对齐。样本每 60 s 一个，
  相邻样本重叠。
- **按时间切分**（`split_by_time`，不打乱）：训练期 T 的读取区间 `[T − 17Δ, T + Δ + 12Δ]` 全部早于
  2026-10-08 00:00 UTC，验证期全部落在 10-08 00:00 – 10-15 00:00，测试期全部晚于 10-15 00:00；跨切点的
  样本直接丢掉，所以三段之间没有任何一秒数据被共用。样本数：训练 39,910、验证 9,930、测试 10,437。
- **边界只用训练期**：`vol_calibrate.py --until 1791417600` 只读 10-08 00:00 之前的 Swap；`train.py` 检查
  `vol_params.json` 的 `until` 与 `bounds` 和代码一致才开始训练。之前的 7 天值 `[342, 620, 1124, 2052]`
  和 6 周全量值 `[213, 487, 885, 1734]`（含测试期，有泄漏）都没有用。
- **特征量级**：真实 5 分钟段均差的绝对值中位数 4 tick、p99 43 tick、最大 218 tick；CLAMP（±64）只截了
  0.33% 的特征、3.6% 的样本至少有一个特征被截，所以缩放常数（CLAMP 64、MULT 128、scale 4096）不需要改，
  合约与电路口径不变。
- **合成增强**：保留 `synth()`（随机游走，σ 在 2–40 tick 对数均匀），只在验证期平均 log score 更好时
  加入训练；本次验证期不加更好（−1.356 vs −1.361），所以最终模型**只用真实数据**。

## 6. 评估结果（测试期 2026-10-15 – 10-22，真实数据）

指标是平均 log score `mean ln p_win`（与链上 `logScore / 1e18` 同一个量，越接近 0 越好），全部样本
10,437 个（每 60 s 一个，重叠），出自 `models/eval.json`：

| 预测 | 平均 log score | 命中最大概率桶 |
|---|---:|---:|
| 均匀分布（每桶 0.2，ln 0.2） | −1.6094 | — |
| 训练期经验频率 `[0.195, 0.199, 0.194, 0.201, 0.211]` | −1.6060 | 23.5% |
| 上一小时 RV 所在桶（平滑 one-hot，训练期拟合） | −1.5415 | 35.9% |
| 上一小时桶 → 下一小时桶转移矩阵（训练期拟合） | −1.4522 | 34.5% |
| 仅承诺 agent 的占位预测（尾随 RV × 0.24 / 0.94 / 4.63 分位） | −1.6619 | 30.8% |
| `linear_abs` | **−1.4177** | 35.0% |
| `mlp16` | −1.4233 | 34.2% |
| `mlp32_abs` | −1.4692 | 32.4% |

- 三个模型都跑赢了两个要求的基线（均匀、训练期频率），差距约 0.14–0.19 nat。
- 更强的「上一小时转移矩阵」基线只被 `linear_abs`、`mlp16` 跑赢（约 0.03 nat），`mlp32_abs` 输给它。
  也就是说模型学到的主要是「波动聚集」，比直接查上一小时的桶只好一点。
- 占位预测（无 TSFM API 时仅承诺 agent 用的）在测试期**输给均匀分布**，只是占位，不代表任何 TSFM 模型。
- 落档分布有漂移：测试期实际桶分布 `[9.0%, 23.1%, 22.1%, 22.4%, 23.5%]`（训练期各约 20%，验证期
  `[26.8%, 15.9%, 16.2%, 21.3%, 19.8%]`）。测试周低波动小时少，桶 0 只有 9%。
- 验证期（只用于选择是否加合成增强）：`linear_abs` −1.333、`mlp16` −1.357、`mlp32_abs` −1.377。
- 单测 `test_model_beats_baselines_on_real_test_rounds` 用提交的测试期抽样
  `tests/fixtures/real_holdout.json`（每小时一轮，174 轮）要求每个模型比均匀和训练期频率至少高 0.1 nat；
  旧的占位边界模型在同一抽样上只有 −3.31，会失败。

主网 fork 上连续 24 小时的逐轮链上成绩见 `docs/DEMO.md`；那是 24 个样本，波动大，只作演示，不作评估。

### 6.1 滚动多折评估（walk-forward，离线）

上面只有一个测试周。为了看分数是否稳定，`vol_agents/walkforward.py` 把同一份 42 天数据切成 4 折：
切点 09-24、10-01、10-08、10-15（UTC 0 点），每折的边界只用切点之前的 Swap 校准
（`analysis` 的 `vol_calibrate.py --until <切点>`），3 个模型结构用切点之前的样本重训（不加合成增强），
然后在切点之后 7 天内的样本上打分（最后一折数据到 10-22 11:06 为止）。跨切点的样本丢弃。
表格由脚本从 `models/walkforward.json` 生成，单测 `tests/test_walkforward.py` 核对二者一致：

<!-- walkforward:begin (generated by vol_agents.walkforward) -->
| 折（测试周起点） | 训练轮数 | 测试轮数 | 边界 tick² | linear_abs | mlp16 | mlp32_abs | uniform | train_prior | train_lag_transition |
|---|---|---|---|---|---|---|---|---|---|
| 2026-09-24 | 19750 | 9930 | [334, 637, 1120, 2094] | -1.4015 | -1.4599 | -1.4889 | -1.6094 | -1.6149 | -1.4281 |
| 2026-10-01 | 29830 | 9930 | [280, 573, 999, 1976] | -1.2383 | -1.2985 | -1.2833 | -1.6094 | -1.6200 | -1.3202 |
| 2026-10-08 | 39910 | 9930 | [202, 474, 856, 1712] | -1.3327 | -1.3568 | -1.3774 | -1.6094 | -1.6103 | -1.3924 |
| 2026-10-15 | 49990 | 9930 | [187, 462, 857, 1701] | -1.4064 | -1.4169 | -1.4424 | -1.6094 | -1.6055 | -1.4399 |
| 平均 |  |  |  | -1.3447 | -1.3830 | -1.3980 | -1.6094 | -1.6127 | -1.3951 |
<!-- walkforward:end -->

- 4 个测试周里，3 个模型都跑赢均匀分布和训练期经验频率（`linear_abs` 比均匀高 0.21–0.37 nat，
  比训练期频率高 0.20–0.38 nat）。
- 对更强的「上一小时转移矩阵」基线：`linear_abs` 4 折全胜（高 0.03–0.08 nat）；`mlp16` 3 胜 1 负
  （09-24 那折输 0.03 nat）；`mlp32_abs` 2 胜 2 负（09-24 输 0.06、10-15 输 0.003，10-01 赢 0.04、
  10-08 赢 0.02），4 折平均 −1.3980 略差于该基线的 −1.3951。所以「比查表只好一点」只对 `linear_abs`
  在 4 周里都成立；两个 MLP 并不稳定地跑赢查表。
- 各折统一的超参（不加合成增强、训练步数 3000）是在 10-08 至 10-15 这个验证周上选定的
  （`models/eval.json` 的 `selection.synthetic_augmentation=false`，`models/linear_abs/meta.json` 的
  `train.steps`），对 09-24、10-01 两折是轻度前视。
- 分数随行情变化明显（`linear_abs` 在 −1.24 到 −1.41 之间）：单周的数字只能说明那一周。
- 最后一折比第 6 节多用了一周训练数据（验证期也进了训练），所以 `linear_abs` 是 −1.4064 而不是 −1.4177。
- **链上用的仍是第 6 节那组模型**（10-08 切点、边界 `[202, 474, 856, 1712]`）。这里的模型只为评估而训练，
  没有导出、没有重建验证合约、没有登记上链。
- 10-08 这一折的边界与已部署的边界完全一致（同一条校准命令），测试周就是第 6 节的验证期。
- 数据文件被 git 忽略（`analysis/data/`），评委无法直接复现；有数据时的复现命令：

```bash
cd analysis && for c in 1790208000 1790812800 1791417600 1792022400; do
  uv run python -m src.vol_calibrate --swaps data/swaps_6w.csv --until $c --out data/folds/$c/vol_params.json
done
cd ../agents && uv run python -m vol_agents.walkforward   # 写 models/walkforward.json 与本节表格
```

## 7. 从训练到上链的流水线

```
train.py ──► models/<name>/model.onnx (+ meta.json, cal.json)
               │  opset 13；输入 x[1,16] float，输出 y[1,5]（Softmax）
               ▼
build.py / ezkl_step.py（每步独立子进程，记录耗时与峰值内存）
  settings   input_scale = param_scale = 12，logrows 15，输入/输出 public，参数 fixed
  calibrate  用 cal.json（32 条按幅度均匀抽取的真实训练期样本 + 32 条 [-2,2] 均匀边缘样本）校准；
             若校准改动了 input_scale 或 logrows > 15 就中止
             → 校准后的 settings 钉在 models/<name>/settings.json（onnx_sha256 不变时复用）
  compile    → out/<name>/model.compiled
  setup      先校验 KZG SRS 的 sha256 = 90807800…3ebb45（4,194,564 B），不符即拒绝 → pk / vk
  evm        → Verifier.sol，改名后放 contracts/src/verifier/<Name>Verifier.sol
               ▼
链上：owner 调 registerModel(verifier, operator) 得 modelId
               ▼
每轮：agent 读 getFeatures → witness（核对公共输入 = 合约编码）→ prove
      → commitPrediction(hash) → 承诺截止后 revealPrediction(proof, outputs[5], salt)，合约验证通过才记录
               ▼
结算：settle 读 observe() 算 RV、定赢桶、给每个预测打 log score、写 ERC-8004 信誉
```

依据：`build.py` 1–15、35–37、76–105 行；`ezkl_step.py` 54–79 行；`agent.py` 33–66 行；
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
```

## 8. 局限与下一步

**局限**

- **评估期短**：测试期只有 7 天（约 168 个不重叠小时），一个行情阶段；60 s 步长的重叠样本让数字看起来
  更稳，实际有效样本远少于 10,437。
- **分布漂移**：边界按训练期定，测试期桶分布已经偏离 20/20/20/20/20（桶 0 只有 9%）；行情换挡时
  边界需要重新校准、模型需要重训，旧 modelId 的验证合约不能改权重。
- **离强基线不远**：只比「上一小时转移矩阵」好约 0.03 nat，`mlp32_abs` 还更差。
- **数据完整性**：网格来自 Swap 日志重建；网关截断日志会让个别窗口与 oracle 不一致（`vol_calibrate.py`
  的 Known deviation）。fork 回放用的目标值直接取自主网 `observe()`，不受这一点影响。
- **单池、单窗口**：只覆盖 ETH/USDC 0.05% 池、Δ = 300 s × 12 段。
- **模型很小**：受电路规模和证明成本约束，只看过去 85 分钟的 16 个差分。

**下一步**

1. 滚动重训：每周用新的训练期重算边界、重训、`build --force` 重建验证合约并重新 `registerModel`。
2. 更长的测试期与按月分段的稳定性评估（4 个周的滚动评估见 6.1；更长的历史需要先拉更多 Swap）。
3. 特征里加入更长的历史（受 `FEATURES = 16` 和电路规模约束，需要改合约口径）。

## 9. 评委问答（Q&A）

**Q1：训练数据是真实的吗？**
是。最早为打通链路用合成随机游走训练；现在用主网 ETH/USDC 0.05% 池 42 天的全部 Swap 重建的 tick 历史，
按合约同一口径构造特征与标签，按时间切成训练 / 验证 / 测试，边界只用训练期（第 5 节）。

**Q2：模型这么小有什么用？**
本项目的卖点是"预测可验证、可问责"，不是模型本身多强。小模型能在约 7–18 s 内出证明、在 logrows 15
电路里放下，链上单独验证一次约 85 万 gas。在真实测试期上平均 log score 从均匀分布的 −1.609 提高到
−1.418 至 −1.469（第 6 节），但只比「上一小时转移矩阵」基线略好。

**Q3：zk 证明到底证明了什么？没证明什么？**
证明了：对**这一轮合约算出的 16 个特征**，用**已登记验证合约里固定的那组权重**跑推理，得到的就是提交的
5 个输出（`_instances` + `_verify`，`VolMarket.sol` 316–336 行）。
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

**Q7：为什么用 log score？**
log score 是严格适当评分规则（strictly proper scoring rule）：只有报出自己真实相信的概率才能期望得分最高，
不能靠夸大或保守获利。出处：Gneiting & Raftery (2007), *Strictly Proper Scoring Rules, Prediction, and
Estimation*, JASA 102(477):359–378, DOI 10.1198/016214506000001437，原文 “The logarithmic score is strictly
proper relative to the class L¹ of the probability measures dominated by µ”（A）。它和训练用的交叉熵是同一个量（第 3 节），模型训练目标与链上
考核目标一致。合约设 −18 的底线，避免概率为 0 时得负无穷、也避免极小概率比 0 得分更低的倒挂
（`docs/plans/实施计划.md` 第 7 节）。

**Q8：模型用的波动率口径和合约一致吗？**
一致。`contract_math.py` 逐条镜像合约的特征公式、`floorDiv`、域编码和 RV；测试读合约侧的共享 fixture
`contracts/test/fixtures/vol_rv_cases.json` 和真证明 fixture `spike_model_proof.json` 比对
（`agents/tests/test_contract_math.py`）。限制：链下镜像只覆盖无缺点的窗口，缺点情形只在合约与 analysis 测试中覆盖。

**Q9：电路量化有多大误差？**
电路用定点数（scale 2^12 = 4096），输出概率是 1/4096 的整数倍（例如演示里 `mlp16` 的 0.0439453125 = 180/4096）。
测试要求电路输出与 onnxruntime 每桶差 ≤ 0.02（`test_models.py` 75 行），链上概率与 ONNX 概率差 ≤ 0.03
（`test_round.py` 62 行）。实际最大误差的系统性统计 `[待证据]`。

**Q10：证明要多久、多贵？**
本机（Apple M5 16 GB）每次证明 7.3–17.8 s、峰值 0.87–0.99 GB 内存；proving key 约 364 MiB
（`agents/out/<model>/`）。三个验证合约单独调用 `verifyProof` 约 848,8xx gas（含 21k 基础费）。

**Q11：模型在真实市场上表现如何？**
按时间切分的 7 天测试期上跑赢均匀分布和训练期频率约 0.14–0.19 nat，只比上一小时转移矩阵基线略好
（第 6 节）。主网 fork 连续 24 小时回放给出 24 轮链上成绩（`docs/DEMO.md`），样本太少，不当作评估。

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
问责的四层里，事前承诺（链上时间戳）、客观结算（`observe()` + Chainlink 交叉校验）、成绩可携带
（ERC-8004）都不依赖 zk，可以直接复用；只有“出处：确实是该模型算的”需要 zk。路线图是分级验证：zk
（已实现，小模型）、TEE 远程证明（大模型 / LLM，需信任硬件厂商）、commit-reveal 仅承诺（任意模型，不保证
出处），opML 乐观验证也可作为选项；后三者**均未实现**。非 zk 等级必须用 commit-reveal，否则后提交者能照抄
公开的预测。写入 ERC-8004 时用 tag 标注等级，读取方自选信任哪一级。详见 `docs/ARCHITECTURE.md` 第 9 节
“分级验证”与 `docs/PITCH.md` “Tiered verification”。
