# 长期计划：消费方示例、可复现层、讲稿重写（2026-10-23 讨论结论）

> 文档状态：[Completed]
> 制定时间：2026-10-23
> 所属路线：[plans/路线图.md](./plans/路线图.md)

背景：评委会问「谁消费这个预测」「为什么需要 agent 而不是 keeper 脚本」「大模型怎么验证」。以下三项按顺序做，演示在 2026-10-24 16:00（北京时间），提交表单截止可能在 10-24 08:00。

## 阶段 1 消费方示例：动态手续费（VolFeeConsumer）
- [x] 新合约 `contracts/src/VolFeeConsumer.sol`：揭示窗口结束后、`startTime` 前读取该轮已揭示的预测，按 ERC-8004 信誉加权合成一个 5 桶分布（无信誉的模型退回 VolMarket 内部历史得分或等权，取最简单稳妥的一种并写明），映射为该小时的 AMM 交易手续费。
- [x] 费率依据 LVR：LP 被套利损失速率 ∝ σ²（Milionis et al. 2022，CPMM 瞬时 LVR = σ²/8 × 池子价值，证据 A）。预期方差由各桶代表值（构造参数）算出，换算成费率并夹在 [minFee, maxFee]（构造参数）；纯整数、缩放因子在定义处写明，不写魔数。
- [x] 读取已揭示预测需要 `VolMarket.predictorAt(id, i)` 只读 getter：`contracts/test/VolMarket.t.sol` 里已有先写的失败测试 `test_PredictorAtListsCommittersInOrder`（未提交），实现 getter 让它通过。
- [x] ERC-8004：主网信誉合约 `getSummary` 返回 `(uint64 count, int128 value, uint8 decimals)`，仓库本地精简版返回单个 `int256`，读取逻辑两种都要处理。
- [x] 测试 `contracts/test/VolFeeConsumer.t.sol`：加权、合成后总和守恒 1e18（允许取整误差）、费率随波动单调、上下限夹取、揭示窗口未结束时 revert、未揭示模型被忽略；关键测试先证明能失败。
- [x] 接入 24 小时主网分叉回放（`demo/run.sh`、`demo/fork_round.py`）：每轮链上记录消费方费率；按实际波动换算「LVR 意义下该收的费率」，对比三种策略：固定 5 bps（池子真实档位）、按上一小时实际波动定费、按预测定费；给出简单指标（对事后最优费率（参照）的平均绝对误差，和/或 LP 的 LVR 覆盖率）。重跑一次回放，更新 `dashboard/sample-replay.json`。
- [x] 看板 `dashboard/index.html` 加一个三种策略 vs 事后最优费率（参照）的逐轮对比图；注意 UI 质量（布局、配色、图例、移动端不破版、和现有面板风格一致），更新 `docs/img/dashboard.png`。
- [x] 文档：README 加消费方一节；如实说明是模拟、没有真实收费；借贷抵押率写进路线图（需要更长窗口，窗口长度本就是构造参数；宏观事件更适合能读外部信息的大模型 agent）。

## 阶段 2 可复现档（reproducible tier）
- [x] 三档验证：zk（EZKL 证明）/ 可复现（公开权重 + 推理代码，任何人可重算）/ 仅提交（commit-only）。
- [x] 登记时记录 `modelHash`（权重与推理代码的哈希）：在 `registerModel` 增加字段（合约改动，配测试）；回放 JSON 与看板同步给出 `modelHash`。
- [x] 大模型用开源权重的 timesfm-3.0、timestral-209m、chronos-2（固定权重版本，CPU 推理），经自部署推理服务预测；用户可自部署并公开权重。
- [x] 重算脚本 `tsfm_recompute`：从链上数据（16 个特征；512 点模型另用池子 Swap 日志）用公开权重重跑，揭示先量化到 1e-3 网格（1e18 尺度上 1e15），每桶误差 ≤ 1e15 为一致。
- [x] 看板徽章：zk / 可复现-已核验 / 仅提交。

## 阶段 3 讲稿重写（docs/PITCH.md）
- [x] agent vs keeper：settle / createRound 是 keeper 活（无许可）；预测 agent 是 ERC-8004 意义上的 agent（不确定性下的判断、要担责、需要信誉）；真正的 agent 经济在消费方（按信誉挑预测者，x402 付费为路线图）。
- [x] 消费方故事：动态手续费 + 回放对比数字。
- [x] 验证分层与 opML 问答（为何不做每轮结算路径：需挑战窗口与链上单步 VM；1-of-N 诚实假设；计划作可复现档的争议层，见 `docs/ARCHITECTURE.md`“验证档位与押金”，未实现）、zkML 参数量表（链上实用约 1e5–1e6 参数）。

## 阶段 4 看板首屏直给 + 相关工作（2026-10-23 晚，用户：看板「会不会太复杂了？或者不够美观和直接」）
对标往届获奖作品的结论：现看板像审计报告（11 卡、6 图、3 表），首屏只有回放参数、直方图、合约地址，5 秒内看不出做什么、谁赢了、证明是否通过。
- [x] 在 `#app` 外加 hero 区：一句话主张（AI 预测先提交、再证明、链上按真实结果打分，AMM 直接读它定费率）+ 三步卡（① 提交+证明：agent 数、zk 数、篡改证明被拒；② 链上结算：24/24 RV 与主网一致；③ 被使用：信誉加权定费，如实写 MAE 2.31 vs 固定 5bps 1.84、暂未赢过固定费率）+ 一个大数字（最佳 zk agent 24h 累计比均匀基线高 +3.1 nats）；数字全部从回放 JSON 计算，不写死。
- [x] 卡片重排：累计得分图 → Agents 表 → 费率卡在前；其余审计细节放后（可选折叠，折叠须在重绘后保持状态）。未做折叠：改为「审计证据」分隔条，回放参数 / 获胜档位 / 合约三卡同排。
- [x] 标题改白话，nats / tick² / LVR 各配一句解释；修 1440 宽首行右侧空列；重拍 `docs/img/dashboard.png`。
- [x] 约束：hero 放 `#app` 外（无 fee 数据时卡片数恰少 1 的断言）；`#fee-card` 与 Agents 卡不可折叠；第一张宽卡须可见（图宽依赖它）；`--win: #a371f7` 与 agent 色板不改；改完跑 tests/acceptance 下全部 dashboard 验收脚本。
- [x] README 加「相关工作」一节：Uniswap v4 动态费 hook、Algebra 自适应费、Synth（SN50），各一句与本项目区别（我们的创新在上游可验证预测市场与信誉加权，动态费只是消费示例）；外部事实附链接与证据等级。
