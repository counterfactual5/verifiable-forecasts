# 模型说明（Model Card）：三个波动率预测模型

本文写给路演和评委问答用。所有数字取自代码和已提交的产物（`agents/models/*/meta.json`、`settings.json`），
或取自本机实测记录；出处写在每处后面。没有出处、无法从仓库核实的说法标 `[待证据]`。

> **一句话限定**：三个模型都只在**合成数据**上训练和评估，用的是**占位分桶边界**。下文所有准确率、log loss
> 都不代表真实市场表现。

## 1. 概述

每个模型预测一件事：Uniswap V3 ETH/USDC 0.05% 池在**接下来 12 个 300 秒段（共 1 小时）**里的
实现波动率（realized volatility, RV）落进 5 个桶的**概率分布**。输入是开局时合约自己从池子
`observe()` 算出的 16 个特征，输出是 5 个概率。

模型故意做得很小（85 / 357 / 709 个参数），因为每次预测都要用 EZKL 生成零知识证明（zk proof），
并在链上验证后才算数：

- 电路规模：三个电路都固定在 `logrows = 15`（最多 2^15 = 32,768 行），实际用 779 / 1,323 / 2,083 行
  （各模型 `settings.json` 的 `num_rows`）。`logrows` 越大，证明越慢、内存越大，SRS 文件也越大。
- 证明耗时（本机实测，Apple M5 16 GB，`agents/out/<model>/timing.jsonl`，git 忽略）：每次 `prove`
  3.7–10.6 s，峰值内存约 0.70–1.19 GB；`setup` 约 1.6 s / 0.72 GB。
- 链上验证成本：同配置的 spike 模型（16→32→5 MLP + Softmax，fixed 参数，logrows 15）验证合约运行时
  19,656 B（低于 EIP-170 的 24,576 B），验证交易约 794,589 gas（`spikes/ezkl/README.md`）。
  三个正式模型各自验证交易的 gas 没有单独记录 `[待证据]`。

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

**为什么模型无法用别的输入造假**：证明的公共输入（public inputs）由合约自己拼。`submitPrediction` 里
`_instances(r.features, outputs)`（约 316–329 行）把存下的 16 个特征按域编码（负数编码为 `R − |x|`，
R 为 BN254 标量域模数 `FIELD_R`），再接上提交的 5 个输出，共 21 个 instance，交给验证合约。agent
只能提交证明和输出，不能提交特征；用别的输入生成的证明会被拒绝（测试
`contracts/test/VolMarket.t.sol::test_FeatureMismatchRejected`）。agent 在链下也先检查 witness 的输入
与合约编码一致，再去证明（`agents/vol_agents/agent.py` 41–56 行）。

## 3. 输出与打分

- **5 个桶，4 个边界**（tick²）：`bucketOf` 半开区间（`contracts/src/lib/MarketMath.sol` 10–13 行）：
  桶 0：RV < b0；桶 i：b_{i−1} ≤ RV < b_i；桶 4：RV ≥ b3。当前训练用的边界是占位值 `[8, 20, 45, 110]`
  （`contract_math.py` 的 `BOUNDS`）。边界是 `createRound` 的参数，不写死在合约里。
- **RV 口径**（`_realizedVol`，约 552–575 行）：结算窗口 13 个检查点 → 12 个段均 tick → 11 个相邻差，
  `RV = Σ(差)²`，整数，单位 tick²；缺点时按项数 m 归一 `floor(Σ × 11 / m)`，可读点不足 90% 则作废退款。
- **概率归一到 1e18**（`submitPrediction`，约 292–308 行）：电路输出 5 个域元素，每个须 `< R/2`、
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
| `linear_abs` | `abs(x)` → 线性 16→5 → Clip(±3) → Softmax | 85 | 779 | `e5ee7971b942` |
| `mlp16` | 有符号 `x` → 16 ReLU → 5 → Clip(±3) → Softmax | 357 | 1,323 | `7d31060d1d67` |
| `mlp32_abs` | `abs(x)` → 32 ReLU → 5 → Clip(±3) → Softmax | 709 | 2,083 | `686e5c3c501b` |

参数量来自 `meta.json` 的 `params`（85 = 5×16+5；357 = 16×16+16+5×16+5；709 = 32×16+32+5×32+5）。
`_abs` 版本先取绝对值：桶只取决于波动大小，不取决于涨跌方向（`train.py` 36 行注释）。
`mlp16` 故意保留有符号输入，作为结构不同的对照。

**训练超参**（`agents/vol_agents/train.py`）：

| 项 | 值 | 位置 |
|---|---|---|
| 优化器 | Adam，β1 = 0.9，β2 = 0.999，ε = 1e-8 | 125、133 行 |
| 学习率 | 0.05，指数衰减 `0.05 × 0.1^(t/steps)`，最后降到 0.005 | 125、129 行 |
| 步数 | 3,000 | 177 行，`meta.json` |
| batch | 每步从训练集有放回抽 2,048 条 | 127 行 |
| L2 | `L2 = 1e-3`，只作用于权重 W，实际系数再除以 1000（等效 1e-6） | 27、113–116 行 |
| logit clip | ±3（`LOGIT_CLIP = 3.0`） | 28–30 行 |
| LEAK | 0.05：clip 饱和时梯度乘 0.05，饱和样本仍能训练 | 31、100 行 |
| 初始化 | 第一层 W ~ N(0, 8)（输入是 tick/32），b1 ~ N(0, 0.1)，W2 ~ N(0, 1/√H) | 63–72 行 |
| 随机种子 | 训练数据 7，测试数据 8，模型初始化 100 / 101 / 102，校准边缘样本 9 | 179–185、209 行 |

**logit clip ±3 的原因**：电路里的 Softmax 用 exp 查找表（lookup，`settings.json` 的
`required_lookups: Exp, scale 4096`）。把 logit 限制在 [−3, 3]，任意输入下 exp 的自变量跨度最多 6，
查找表范围有界，三个电路因此都能放在 `logrows 15`（`train.py` 28–29 行注释，
`settings.json` 的 `lookup_range = [-49152, 0]`）。代价是模型最高只能给出约 99.0% 的置信度。

## 5. 训练数据：合成随机游走

数据由 `train.py` 的 `synth()`（49–59 行）生成，**不是真实池子数据**：

- 每条样本先抽一个波动率 σ（单位 tick）：`σ = exp(Uniform(ln 0.25, ln 6))`，即在 0.25–6 之间对数均匀。
- 窗口波动率在 σ 上加扰动：`σ_w = σ × exp(N(0, 0.3²))`，模拟"过去不完全决定未来"。
- 16 个历史特征 `f_j = round(N(0,1) × σ)`，独立同分布；经 CLAMP、MULT、/4096 得到模型输入，
  与合约公式一致（测试 `agents/tests/test_contract_math.py::test_synthetic_features_use_contract_formula`）。
- 窗口 11 个相邻差 `round(N(0,1) × σ_w)`，`RV = Σ 差²`，按占位边界 `[8, 20, 45, 110]` 得标签。
- 训练集 40,000 条，测试集 10,000 条（独立种子），`meta.json` 的 `train.samples`。

用同样的种子重跑数据生成器（不训练）可得：训练集桶分布约 `[37.1%, 15.7%, 13.5%, 14.1%, 19.7%]`；
合成 RV 的 p20 / p50 / p80 / p95 约为 3 / 16 / 107 / 360 tick²；CLAMP 在合成数据里从未触发
（σ 最大 6 tick，远小于 64）。

## 6. 评估结果（仅合成数据）

测试集是独立种子生成的 10,000 条合成样本（`meta.json`）：

| 模型 | test log loss | test accuracy |
|---|---:|---:|
| 先验基准（按训练集桶频率给固定分布） | 1.5368 | — |
| `linear_abs` | 0.8972 | 61.6% |
| `mlp16` | 0.9129 | 61.1% |
| `mlp32_abs` | **0.8712** | **62.3%** |

**这些数字仅在合成数据上得到，不代表真实市场表现。** 合成数据由已知 σ 生成，特征和标签之间的关系
比真实市场干净得多。真实数据上的 log loss 和准确率 `[待证据]`。

本地 anvil 一轮端到端演示（`vol_agents.round`，固定 tick 序列，RV = 49，落入桶 3）的链上 log score：
`mlp32_abs` −0.880、`mlp16` −1.021、`linear_abs` −1.064（`agents/out/compare_round.json`，git 忽略）。
这是单轮演示，不是评估。

## 7. 从训练到上链的流水线

```
train.py ──► models/<name>/model.onnx (+ meta.json, cal.json)
               │  opset 13；输入 x[1,16] float，输出 y[1,5]（Softmax）
               ▼
build.py / ezkl_step.py（每步独立子进程，记录耗时与峰值内存）
  settings   input_scale = param_scale = 12，logrows 15，输入/输出 public，参数 fixed
  calibrate  用 cal.json（32 条合成测试样本 + 32 条 [-2,2] 均匀边缘样本）校准；
             若校准改动了 input_scale 或 logrows > 15 就中止
             → 校准后的 settings 钉在 models/<name>/settings.json（onnx_sha256 不变时复用）
  compile    → out/<name>/model.compiled
  setup      先校验 KZG SRS 的 sha256 = 90807800…3ebb45（4,194,564 B），不符即拒绝 → pk / vk
  evm        → Verifier.sol，改名后放 contracts/src/verifier/<Name>Verifier.sol
               ▼
链上：owner 调 registerModel(verifier, operator) 得 modelId
               ▼
每轮：agent 读 getFeatures → witness（核对公共输入 = 合约编码）→ prove
      → submitPrediction(roundId, modelId, proof, outputs[5])，合约验证通过才记录
               ▼
结算：settle 读 observe() 算 RV、定赢桶、给每个预测打 log score、写 ERC-8004 信誉
```

依据：`build.py` 1–15、35–37、76–105 行；`ezkl_step.py` 54–79 行；`agent.py` 33–66 行；
`VolMarket.sol` `registerModel`（168–175 行）、`submitPrediction`（280–314 行）、`settle`（360–386 行）。

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

- **合成数据**：独立同分布高斯增量，σ 在 0.25–6 tick；真实市场的厚尾、聚集、跳变都没有。
- **占位边界**：`[8, 20, 45, 110]` 是为合成数据设的。本机 analysis 用 40,383 笔真实 Swap、2,010 个窗口
  校准出的 p20/p40/p60/p80 是 `[342, 620, 1124, 2052]` tick²、RV 均值 1,886（`analysis/data/vol_params.json`，
  git 忽略）。真实 RV 的 p20（342）已高于占位上界 110，所以按占位边界大约 80% 以上的真实窗口会落在
  桶 4，模型面对的是训练分布之外的输入。
- **单池、单窗口**：只覆盖 ETH/USDC 0.05% 池、Δ = 300 s × 12 段。
- **模型很小**：受电路规模和证明成本约束；合成数据没有建模 `createRound` 与 `startTime` 之间的间隔，
  也没有建模历史与窗口之间的连续性。

**下一步**

1. 用 `analysis/` 管线（`fetch_swaps.py` → `vol_calibrate.py`）拉更长的真实 Swap 历史，按 p20/40/60/80 定边界。
2. 用真实 tickCumulative 构造特征和标签，**按时间切分**训练/测试，避免未来信息泄漏。
3. 对照两个基准：先验分布（固定桶频率）和"上一窗口波动率"（用上一小时 RV 所在桶附近的分布）。
4. 重训后 `vol_agents.build --force` 重新生成验证合约、重新 `registerModel`。旧 modelId 不会被覆盖。

## 9. 评委问答（Q&A）

**Q1：为什么用合成数据？**
黑客松时间内先打通"合约自算输入 → zk 证明推理 → 链上验证 → log score 结算 → ERC-8004 信誉"的整条链路。
合成数据在合约单位下生成（`train.py` 1–6 行），特征公式和合约完全一致，方便验证管线正确。真实数据
训练是下一步，analysis 的真实边界已经算出来了（第 8 节）。

**Q2：模型这么小有什么用？**
本项目的卖点是"预测可验证、可问责"，不是模型本身多强。小模型能在约 4–11 s 内出证明、在 logrows 15
电路里放下，链上验证一次约 79 万 gas（spike 实测）。在合成测试集上 log loss 从先验的 1.54 降到 0.87–0.91，
说明它确实从特征里学到了东西（测试 `test_model_is_trained` 要求至少比先验低 0.3）。

**Q3：zk 证明到底证明了什么？没证明什么？**
证明了：对**这一轮合约算出的 16 个特征**，用**已登记验证合约里固定的那组权重**跑推理，得到的就是提交的
5 个输出（`_instances` + `_verify`，`VolMarket.sol` 316–336 行）。
没证明：模型好不好、训练数据是否真实、训练过程是否诚实；也不证明验证合约对应的就是仓库里那个 ONNX
文件——这一点靠公开复现：任何人可用 `model.onnx` + 钉住的 `settings.json` + 校验过的 SRS 重建验证合约逐字节比对。

**Q4：怎么防止抄别人的证明？**
证明本身不绑定发送者，所以合约给每个 modelId 绑定唯一的 operator（`registerModel(verifier, operator)`），
`submitPrediction` 要求 `msg.sender == modelOperator[modelId]`，否则 `NotModelOperator`
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
不能靠夸大或保守获利 `[待证据：文献出处]`。它和训练用的交叉熵是同一个量（第 3 节），模型训练目标与链上
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
本机（Apple M5 16 GB）每次证明 3.7–10.6 s、峰值 0.70–1.19 GB 内存；proving key 约 364 MiB，
verifying key 96,391 B（`agents/out/<model>/`）。同配置 spike 的链上验证交易约 794,589 gas。
三个正式验证合约的确切 gas `[待证据]`。

**Q11：模型在真实市场上表现如何？**
`[待证据]`。目前没有真实数据上的评估。主网分叉演示只跑了一轮，而且仍用占位边界，不能当作评估。
如实说：真实表现要等第 8 节的重训和按时间切分的回测。

**Q12：可信设置（trusted setup）安全吗？**
用的是 KZG SRS（logrows 15），构建时强制校验 sha256，不符就拒绝（`build.py` 33–35、76–79 行）。
该 SRS 来自 EZKL 的 `get_srs` 下载，其仪式来源 `[待证据]`。
