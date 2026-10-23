# SPEC：可验证 AI 预测的链上问责

> 文档状态：[Accepted]
> 确认方式：用户确认

本文取代旧的 BaseFee 预测市场方向（`block.basefee` 结算、naive/EWMA/TimesFM 机器人、Chainlink CRE 仅做编排模拟；旧版见 git 历史）。新方向的详细规格以 `docs/plans/实施计划.md` 第 4–8 节为准，本文只做精简摘要；两者冲突时以实施计划和代码为准。

## 目标与范围

ETH Shenzhen 2026 Hackathon 参赛项目（截止 10/24 现场演示）。

**状态**：已完成核心链路（`VolMarket` 合约 + EZKL 验证合约 + 3 个预测 agent，本地 anvil 端到端跑通）、ERC-8004 信誉、Chainlink 交叉校验、先承诺后公开 / 仅承诺模型 / 预测者分成（R4）、可复现等级（登记 `modelHash`，timesfm-3.0 / timestral-209m / chronos-2 开源权重可重算，容差复核）、区间校准、按训练期边界在真实池子历史上重训 3 个模型并重建验证合约（R5）、主网 fork 连续 24 小时回放演示与看板。

**问题**：AI 预测者可以事后挑选好看的结果来宣传，评委和用户无法核实「这个预测确实是这个模型在事前、对这些输入算出来的」，也没有公开、不可篡改的成绩记录。

**做什么**：一个链上考场。考题是 Uniswap V3 ETH/USDC 0.05% 池（`0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`）未来 1 小时的 TWAP 已实现波动率（Δ = 300 s、N = 12 段，单位 tick²），按 5 个区间彩池（parimutuel）下注。AI 预测 agent 先提交预测的哈希承诺，承诺截止后、结果窗口开始前再公开预测；zk 模型用 EZKL 为小模型推理生成 zk 证明，公开时链上验证，公开输入（16 个特征）由合约在开轮时自己从链上 `observe()` 算出；开源权重的时序大模型（timesfm-3.0、timestral-209m、chronos-2）登记 `modelHash` 以「可复现」等级参赛，任何人可从链上数据重算（每桶误差 ≤ 0.001 的容差复核）；第三方时序大模型 API 这类既无证明又无公开权重的模型以「仅承诺」等级参赛。结算时用 `observe()` 算实际波动率（`sample()` 检查点兜底），按对数评分给每个公开的预测打分，分数由市场合约写入 ERC-8004 v2.0.0 信誉注册表（可复现与仅承诺模型用单独的 tag2，靠链上 `modelHash` 区分）；跑赢均匀分布基线的预测者按超额分数分得手续费的 `predictorShareBps`；结算时可用 Chainlink ETH/USD 喂价交叉校验池子价格。

**不做**（写入 README「Known limitations / Future work」）：LMSR 做市、blob 费用市场（`BLOBBASEFEE`）、FHE / commit-reveal 密封下注（预测已是先承诺后公开，下注仍公开）、提交质押与罚没、x402 付费、真实资金与真实网络部署（只归用户）、ERC-8004 Validation 注册表（规范仍在变）、Chainlink CRE / Automation（本阶段不做）。

## 功能

| 功能 | 状态 | 位置 |
|---|---|---|
| 波动率市场合约：开轮存特征、下注、`sample` 检查点、`settle`（`observe` 批量 + 逐点兜底，缺点归一，覆盖率 < 90% 作废退款）、`claim` | 已完成 | `contracts/src/VolMarket.sol` |
| 彩池 / 分桶 / 对数评分数学 | 已完成 | `contracts/src/lib/MarketMath.sol` |
| zk 证明校验：每个模型一份 EZKL 生成的验证合约；`registerModel(verifier, operator, modelHash)`（`modelHash` 可为 0，两参数重载等同 0）；公开时证明通过才记录 | 已完成 | `contracts/src/verifier/`、`VolMarket.revealPrediction` |
| 先承诺后公开：`commitPrediction` 在 `startTime − commitLead` 前提交承诺，`revealPrediction` 在 `startTime − revealLead` 前公开；未公开的不计分不分钱 | 已完成（R4） | `VolMarket.commitPrediction` / `revealPrediction` |
| 仅承诺模型：`registerModel(address(0), operator)`，公开时不验证证明，ERC-8004 tag2 加 `-commit`；agents 的 TSFM API 适配器 | 已完成（R4） | `VolMarket`、`agents/vol_agents/api_agent.py` |
| 可复现等级：`registerModel(verifier, operator, modelHash)` 以 `verifier = 0` 和非零 `modelHash`（权重、配置、运行代码的哈希）登记，`verificationTier` 返回 1；公开权重的 timesfm-3.0、timestral-209m、chronos-2 三个 agent，任何人用 `python -m vol_agents.tsfm_recompute` 从链上数据重算比对，每桶误差 ≤ 0.001；主网 fork 回放 三个 agent 各 24/24 轮在容差内（72 次均完全一致） | 已完成 | `contracts/src/VolMarket.sol`、`agents/vol_agents/api_agent.py`、`agents/vol_agents/tsfm_recompute.py` |
| 预测者分成：手续费的 `predictorShareBps` 按超过均匀基线的对数分比例分给预测者，`claimPredictorReward` 自取 | 已完成（R4） | `VolMarket.settle` / `claimPredictorReward` / `collectFee` |
| 预测 agent：3 个模型（`linear_abs` / `mlp16` / `mlp32_abs`）训练、EZKL 构建、读特征→证明→提交→结算→比较链上分数 | 已完成（本地 anvil + MockPool） | `agents/` |
| 合约 / agents 共享口径 fixture（tickCumulative → 段均值 → RV → 桶） | 已完成 | `contracts/test/fixtures/vol_rv_cases.json` |
| `make verify` 接入 agents 的 ruff 与 pytest | 已完成 | `Makefile` |
| analysis 拉取 Swap 事件、按合约口径算历史 RV、校准 4 个区间边界 | 已完成 | `analysis/` |
| ERC-8004 v2.0.0 身份注册 + 结算后 `giveFeedback` 写信誉（写入失败只发事件；gas 不足以完成写入时结算 revert） | 已完成 | `VolMarket.setReputation` / `linkAgent` / `settle`，`contracts/src/erc8004/`（Lite 实现） |
| Chainlink ETH/USD 喂价交叉校验（`setPriceFeed` 可选开启） | 已完成 | `VolMarket.settle` |
| 主网 fork 回放演示 + 只读静态看板 | 已完成 | `demo/`（`make demo`）、`dashboard/` |
| 删除旧 `BaseFeeMarket` 与 analysis 的 base fee 管线 | 已完成 | 见 git 历史 |

## 第一个功能

新方向的第一个功能是波动率市场合约 `VolMarket.sol`（已完成）：轮次状态机（createRound → bet / commitPrediction → revealPrediction → sample → settle → claim / claimPredictorReward / collectFee），开轮时由合约从 `observe()` 自算 16 个特征作为 zk 证明的公开输入，提交预测时链上校验 EZKL 证明，结算按对数评分。参数：Δ、N、`commitLead`、`revealLead`、`feeBps`、`predictorShareBps` 为构造参数，区间边界为 `createRound` 参数。

**验收标准**：
1. `cd contracts && forge test --match-path test/VolMarket.t.sol` 全绿，覆盖完整生命周期、彩池按比例分配、缺点归一与覆盖率作废退款、`observe` 过旧时用 `sample` 检查点兜底、证明篡改被拒、非 operator 提交被拒。
2. 合约与 agents 读同一份 `contracts/test/fixtures/vol_rv_cases.json`，RV 与桶逐项一致。
3. 评分统一为 `max(ln p_win, −18e18)`（1e18 缩放），概率为 0 与极小概率同样记 −18e18。

## 技术选型

| 项 | 选择 | 理由 | 证据等级 |
|---|---|---|---|
| 合约与测试 | Foundry（forge 1.5.1，solc 0.8.28） | 本机已装；cheatcodes 适配时间回放 | X（本机）+ C（官方文档） |
| 结算数据源 | Uniswap V3 `observe()`（0.05% 池），`sample()` 检查点兜底 | 池子 cardinality 723，最坏可回溯约 2.41 h，1 h 窗口一次取全；13 点合约内调用约 32 万 gas | X（`spikes/facts/FACTS.md` 主网实测） |
| zk 证明 | EZKL 23.0.5（Halo2/KZG，logrows 15，`input_scale = 12`，参数 fixed） | spike：prove ≈ 9 s / 1.23 GB；当前 3 个验证合约约 21.8 KB < EIP-170 的 24,576 B，`verifyProof` ≈ 84.9 万 gas | X（`spikes/ezkl/README.md`、`agents/MODEL_CARD.md` 实测） |
| 预测模型 | numpy 训练的小 MLP / 线性模型 → ONNX | 电路小、证明快；模型重依赖隔离在子进程 | X（`agents/` 实测） |
| 信誉 | ERC-8004 v2.0.0：本地 Lite 实现用于测试与离线演示，主网 fork 用已部署合约 | 池子与喂价只在主网 | X（`spikes/facts/FACTS.md` 链上核实） |
| 价格交叉校验 | Chainlink ETH/USD `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`（8 位小数） | 与池子 tick 换算价一致（2435.09 vs ≈2436） | X（`spikes/facts/FACTS.md`） |
| Python 环境 | uv 0.11.2；agents Python ≥ 3.12，analysis ≥ 3.11 | 本机已装，锁文件可复现 | X（本机） |

## 结构与依赖

```
contracts/        # Foundry：VolMarket、MarketMath、EZKL 验证合约、ERC-8004 Lite 注册表
agents/           # Python：模型训练、EZKL 构建、证明与提交、anvil 端到端
analysis/         # Python：Swap 事件拉取、按合约口径算 RV、区间边界校准
spikes/           # 事实核实（facts/）与 EZKL 可行性实验（ezkl/）
chainlink/        # 喂价交叉校验说明
demo/             # 主网 fork 连续回放 N 个真实小时（run.sh → fork_round.py）
dashboard/        # 只读静态看板（读 demo 输出 JSON）
docs/
```

单向依赖：`agents`、`analysis` 互不引用；合约不依赖任何 Python；agents 只通过 Foundry 构建产物与 `contracts/test/fixtures/` 读取合约侧内容。Δ、N 是构造参数，区间边界是 `createRound` 参数，不写死。

## Full Verify

```
make check && make test
```

`make check` 会运行 agents 的 pytest；可复现档的测试 `test_api_agent` 用替身 runner 在 anvil 上走完三参数登记、揭示与 `tsfm_recompute` 的 exact / tolerant / fail 判定，不需要 `VOL_REPRO_PYTHON`，也不下载权重。

用真实公开权重重算时，未设置 `VOL_REPRO_PYTHON` 则 `tsfm_recompute` 直接失败退出、不回退；它应指向装有 torch 与各模型运行时的 Python 解释器，配置见 `agents/README.md`「Reproducible tier」。

## 界面与冒烟验证

看板是静态页面，本地起 http 服务即可打开；冒烟检查打开下列页面并跑一次数据接口断言。页面显式指定已提交的样例数据：不带 `?data=` 时看板先探测 git 忽略的 `demo/out/`，干净检出里浏览器会把这次 404 记为控制台错误。

- UI_Kind: web
- UI_Start: python3 -m http.server 8765 --bind 127.0.0.1
- UI_Url: http://127.0.0.1:8765
- UI_Pages: /dashboard/?data=sample-replay.json /dashboard/?data=sample-round.json
- UI_Selectors: #app .card;;#subtitle;;#source
- UI_E2e: python3 -c "import json,os,urllib.request as u; b=os.environ['UI_BASE_URL']; h=u.urlopen(b+'/dashboard/',timeout=10).read().decode(); assert '<main id=\"app\">' in h; r=json.load(u.urlopen(b+'/dashboard/sample-replay.json',timeout=10)); assert r['schema']=='vol-replay/v1' and r['rounds'] and r['agents']; s=json.load(u.urlopen(b+'/dashboard/sample-round.json',timeout=10)); assert s['round'] is not None and s['outcome'] is not None; print('e2e ok')"

## 假设

- 赛程以官方公告为准（10/24 下午现场演示，评审前公开仓库）；未逐条在官方渠道核实。
- 离线回合在本地 anvil（MockPool）；主网 fork 演示在本地 anvil fork 上进行（`make demo`），不广播任何交易。不做真实网络部署。
- 区间边界当前为 `[202, 474, 856, 1712]` tick²，由 analysis 只用训练期（2026-09-10 至 10-08 UTC）主网 Swap 按 p20/p40/p60/p80 校准；3 个模型在同一池子真实历史上按时间切分重训（测试期 10-15 至 10-22）。行情换挡后边界需重新校准、模型需重训并重建验证合约（见 `agents/MODEL_CARD.md`）。
- 彩池冷启动由协议方注入种子资金；公开下注可被跟单是已知问题，密封下注列为 Future work。预测在承诺截止后公开，下注者在窗口开始前可读到全部预测，这是设计目的而非泄漏。
- 首次构建 EZKL 电路时若本地没有 SRS 且未用 `--srs` / `VOL_AGENTS_SRS` 指定来源，会联网下载；无论来源，SRS 的 sha256 必须等于 `agents/vol_agents/build.py` 里固定的 `SRS_SHA256`，否则构建中止。已提交的验证合约与新构建结果不同时默认拒绝覆盖，需显式 `--force`。

## 后续

已完成：analysis 区间校准、ERC-8004 接入、Chainlink 交叉校验、主网 fork 演示与看板、README / 架构 / 演示 / pitch 文档、SRS 摘要校验、验证合约覆盖保护、结算取整 fuzz 与协议费提取、删除旧 base fee 代码、按训练期边界重训模型并重建 EZKL 验证合约、24 小时连续回放（R5）、4 折滚动离线评估（R8，4 折均值 linear_abs −1.345）。

1. 滚动重训上线（重建验证合约并重新登记 modelId）。
