# 事实核实结果（2026-10-21，主网区块约 26,235,0xx）

脚本：`spikes/facts/obs_hist.sh`、`observe_gas.sh`、`swap_logs.py`；ERC-8004 参考实现克隆在 `spikes/facts/` 下。

## 1. Uniswap V3 池子观测窗口

| 池 | cardinality / next | 当前可回溯 | 最坏下限（每块一条观测 × 12s） |
|---|---|---|---|
| ETH/USDC 0.05% `0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640` | 723 / 723 | 6.29h（最大 secondsAgo=22680s，再大 revert `OLD`） | 2.41h |
| ETH/USDC 0.3% `0x8ad599c3A0ff1De082011EFDDc58f1908eb6e6D8` | 1440 / 1440 | 121.6h | 4.8h |
| WBTC/ETH 0.05% `0x4585…` | 300 / 300 | 8.0h | 1.0h |
| WBTC/ETH 0.3% `0xCBCd…` | 360 / 360 | 102.4h | 1.2h |

- 0.05% 池近 30 天抽样 6 个区块，可回溯 4.63h–23.2h；行情剧烈时 swap 最密、窗口最短。
- 结论：4h 窗口在 0.05% 池上**不能保证**结算时一次 observe 取全。
- 0.3% 池价格与 0.05% 池几乎一致（tick 198329 vs 198316）。

## 2. observe gas（外部调用，含 21000 基础费）

| 点数 | 间隔 | gas |
|---|---|---|
| 1 | 0s（当前） | 30,518 |
| 1 | 1h / 4h 前 | ≈71,200 |
| 2 | 4h 跨度 | 72,284 |
| 13 | 5 分钟 | 341,556 |
| 25 | 5 分钟 | 660,591 |
| 49 | 5 分钟 | 1,267,689 |

- 每个历史点约 2.5 万 gas（723 条观测里二分查找，约 10 次冷读存储）。
- 合约内部调用估算：仅当前点 ≈1 万；首尾两点 ≈5.3 万；13 点 ≈32 万；49 点 ≈125 万。
- 先前假设“3.8–9.2 万 gas”只对 1–2 个点成立。

## 3. Swap 历史数据（0.05% 池）

- 平均每块约 0.70–0.80 次 swap，约 54% 的区块有 swap，单块最多 5 次。
- 各公共 RPC 的 getLogs 情况：
  - publicnode：只能拉近 10k 块，更早的区块报 403。
  - tenderly gateway：单次 ≤10k–20k 块可用，30 天前的数据也能拉。**请求 50k 块时会静默截断**，所以必须分段拉，并校验首尾区块号。
  - drpc：每次 ≤100 块，不实用。
  - blastapi：报 400，不可用。
- 返回的日志自带 `blockTimestamp`。
- 30 天约 21.6 万块、15–17 万条 swap；用 tenderly 按 10k 块一段，约 22 次请求，1.5–2 分钟拉完。

## 4. ERC-8004（规范仍为 Draft；参考实现 erc-8004/erc-8004-contracts，getVersion()="2.0.0"，UUPS 可升级）

- **Identity**（ERC-721）：`register()` / `register(string agentURI)` / `register(string, MetadataEntry[])`，返回 agentId；`setAgentURI`、`get/setMetadata`、`setAgentWallet(agentId, newWallet, deadline, sig)`；事件 `Registered(agentId, agentURI, owner)`。
- **Reputation**：
  - 写入：`giveFeedback(uint256 agentId, int128 value, uint8 valueDecimals, string tag1, string tag2, string endpoint, string feedbackURI, bytes32 feedbackHash)`，触发事件 `NewFeedback`。
  - 读取：`getSummary(agentId, address[] clientAddresses（必须非空）, tag1, tag2)` 返回 `(uint64 count, int128 summaryValue, uint8 summaryValueDecimals)`：未撤销记录先归一到 18 位小数求平均，再缩放到出现最多的 `valueDecimals`；`readFeedback(agentId, clientAddress, uint64 feedbackIndex)` 返回单条 `(value, valueDecimals, tag1, tag2, isRevoked)`；另有 `readAllFeedback`、`getClients`、`revokeFeedback`、`appendResponse`。（2026-10-25 按 erc-8004-contracts `b9e466c` 源码更正）
  - **没有 feedbackAuth**：任何地址都能写反馈，唯一限制是提交者不能是该 agent 的 owner 或 operator。合约可以作为提交者（不检查 EOA）。value 可以为负。
  - gas（2026-10-22 主网 `cast estimate`，含 21000 基础费）：从未写过该 agent 的新提交者调用 `giveFeedback(agentId, -1.5e18, 18, "logScore", "vol-300s-12", "", "", 0)`，agentId 1 与 2 均为 196,795。`VolMarket.EXTERNAL_CALL_GAS`（50 万）按此取约 2.5 倍余量。
- **Validation**（官方说明仍在修订）：
  - `validationRequest(validator, agentId, requestURI, requestHash)`：只能由 agent 的 owner 或 operator 调用。
  - `validationResponse(requestHash, uint8 response 0–100, responseURI, responseHash, tag)`：只能由指定的 validator 调用。

已部署地址（已核实链上有代码，版本 2.0.0）：

| 网络 | Identity | Reputation | Validation |
|---|---|---|---|
| 主网 / Base | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` | `0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58`（仅主网确认） |
| Optimism 主网 | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` | 未核实 |
| Sepolia / Base Sepolia | `0x8004A818BFB912233c491871b3d84c89A494BD9e` | `0x8004B663056A597Dffe9eCcC1965A193B7388713` | `0x8004Cb1BF31DAf7788923b405b754f57acEB4272`（地址来自 scripts/addresses.ts） |

Optimism 主网一行的核实（2026-10-24，区块约 158,588,016）：公开 RPC `https://mainnet.optimism.io` 与 `https://optimism-rpc.publicnode.com`（`eth_chainId` = `0xa`）上 `eth_getCode` 两个地址均返回 130 字节的代理合约代码，`cast call <addr> "getVersion()(string)"` 均返回 `"2.0.0"`。

## 5. Chainlink ETH/USD（主网）

- `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`，8 位小数，`latestRoundData` 正常（2435.09，与池子 tick 换算的 ≈2436 一致），调用约 3.7 万 gas。
- 心跳 1h、偏离阈值 0.5% 是公开参数，未在链上核实。

## 6. Uniswap v4 PoolManager（主网）

- `0x000000000004444c5dc75cB358380D2e3dE08A90`。来源：Uniswap 官方文档 [v4 Deployments](https://docs.uniswap.org/contracts/v4/deployments)（Ethereum: 1 表，2026-10-24 读取），证据等级 A（官方一手）。
- 链上核实（2026-10-24，tenderly gateway，区块约 26,260,425）：`eth_getCode` 约 24 KB 运行时代码，`owner()` = `0x1a9C8182C09F50C8318d769245beA52c32BE35BC`。
- `contracts/test/VolFeeHookFork.t.sol` 在区块 26,260,000 的 fork 上对它初始化 WETH/USDC 动态费率池并 swap 通过。

## 建议（供实施计划阶段采用）

1. **窗口参数**：Δ=300s，N=12（1h 窗口、13 个观测点），合约内部调用约 32 万 gas，0.05% 池在最坏 2.4h 下限内也能覆盖。
   - 如果需要更长窗口，改为 keeper 每段调用 `sample()` → `observe([0])` 存检查点（每次约 3–4.5 万 gas），结算时只读存储；或者改用 0.3% 池（下限 4.8h，但 49 点仍要约 125 万 gas）。
2. **ERC-8004**：直接使用 Sepolia / Base Sepolia 上已部署的注册表，本地演示时 fork 这些网络，不必自己部署。
   - 预测 agent 调用 `register(agentURI)` 注册身份。
   - 结算合约在同一笔交易里调用 `giveFeedback`：`value` = 对数评分定点数，`tag1`="logScore"，`tag2`="vol-5m-12"，`feedbackURI` 指向预测内容和证明。
   - 读取方用 `getSummary(agentId, [结算合约地址], "logScore", …)` 过滤，只认结算合约写的分数。
   - Validation（EZKL 验证合约作为 validator，回写 100，tag="ezkl"）作为加分项，因为规范还在变。
3. **analysis 数据源**：用 tenderly gateway 按 10k 块分段拉取 Swap 日志，并校验每段的首尾区块号，防止静默截断。
