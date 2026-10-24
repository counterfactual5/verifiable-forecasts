"""VolFeeHook on the fork: a WETH/USDC dynamic-fee pool of the real Uniswap v4 PoolManager whose
hook charges the fee VolFeeConsumer recorded for the round in progress (V4_HOOK=1 in
demo/fork_round.py). Each round, one USDC -> WETH swap inside the window measures the fee the
pool actually charged from its LP fee growth; a WETH -> USDC swap buying the same USDC back then
returns the price to where it was, so hourly probes never walk the price out of the LP range.

Simulation only: the pool, its liquidity and the swaps exist on the local fork.
"""

import subprocess
from pathlib import Path

from vol_agents.chain import as_int

CONTRACTS = Path(__file__).resolve().parent.parent / "contracts"
POOL_MANAGER = "0x000000000004444c5dc75cB358380D2e3dE08A90"  # spikes/facts/FACTS.md §6
CREATE2_DEPLOYER = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
# Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG; the low 14 address bits must equal it
# and the two above them are left 0.
HOOK_ADDRESS_SUFFIX = "1080"
DYNAMIC_FEE_FLAG = 0x800000
TICK_SPACING = 10
LOOKBACK = 4
FALLBACK_FEE_PIPS = 500  # the V3 pool's own tier
LIQUIDITY = 10**16
RANGE_TICKS = 2000
SWAP_USDC = 10_000 * 10**6
# PoolManager storage: pools mapping at slot 6; Pool.State feeGrowthGlobal0X128 at +1,
# liquidity at +3 (v4-core StateLibrary).
POOLS_SLOT, FEE_GROWTH0_OFFSET, LIQUIDITY_OFFSET = 6, 1, 3
Q128 = 2**128
PIPS = 10**6
KEY_T = "(address,address,uint24,int24,address)"
MIN_SQRT_PRICE_PLUS_1 = 4295128740
MAX_SQRT_PRICE_MINUS_1 = 1461446703485210103287273052203988822378723970341
GAS = 3_000_000


def _cast(*args):
    return subprocess.run(["cast", *map(str, args)], check=True, capture_output=True,
                          text=True, timeout=600).stdout.strip()


def _forge_bytecode(target):
    return subprocess.run(["forge", "inspect", "--root", str(CONTRACTS), target, "bytecode"],
                          check=True, capture_output=True, text=True, timeout=900).stdout.strip()


class HookPool:
    def __init__(self, c, owner, fee_consumer, market, window, usdc, weth, v3_pool,
                 min_fee, max_fee):
        self.c, self.trader = c, c.trader
        self.usdc, self.weth = usdc, weth
        self.swap_router = c.deploy(owner, "lib/v4-core/src/test/PoolSwapTest.sol:PoolSwapTest",
                                    POOL_MANAGER)
        lp_router = c.deploy(owner, "lib/v4-core/src/test/PoolModifyLiquidityTest.sol:"
                                    "PoolModifyLiquidityTest", POOL_MANAGER)
        self.hook = self._deploy_hook(fee_consumer, market, window, min_fee, max_fee)
        currency0, currency1 = sorted([usdc, weth], key=lambda a: int(a, 16))
        if currency0 != usdc:
            raise RuntimeError("expected USDC as currency0")
        self.key = f"({currency0},{currency1},{DYNAMIC_FEE_FLAG},{TICK_SPACING},{self.hook})"
        self.pool_id = _cast("keccak", _cast("abi-encode", f"f({KEY_T})", self.key))
        self.state_slot = int(_cast("keccak", "0x" + self.pool_id[2:] + f"{POOLS_SLOT:064x}"), 16)
        approve = "approve(address,uint256)"
        for token in (usdc, weth):
            for spender in (self.swap_router, lp_router):
                self._send(token, approve, spender, 2**256 - 1)
        slot0 = "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)"
        sqrt_price, tick = c.call(v3_pool, slot0)[:2]
        tick = as_int(tick)
        self._send(POOL_MANAGER, f"initialize({KEY_T},uint160)", self.key, as_int(sqrt_price))
        lower = (tick // TICK_SPACING) * TICK_SPACING - RANGE_TICKS
        self._send(lp_router, f"modifyLiquidity({KEY_T},(int24,int24,int256,bytes32),bytes)",
                   self.key, f"({lower},{lower + 2 * RANGE_TICKS},{LIQUIDITY},{'0x' + '00' * 32})",
                   "0x")

    def _deploy_hook(self, fee_consumer, market, window, min_fee, max_fee):
        ctor = "f(address,address,address,uint256,uint256,uint24,uint24,uint24)"
        args = _cast("abi-encode", ctor, POOL_MANAGER, fee_consumer, market, window, LOOKBACK,
                     min_fee, max_fee, FALLBACK_FEE_PIPS)
        init = _forge_bytecode("src/hooks/VolFeeHook.sol:VolFeeHook") + args[2:]
        out = _cast("create2", "--deployer", CREATE2_DEPLOYER, "--init-code", init,
                    "--ends-with", HOOK_ADDRESS_SUFFIX)
        fields = dict(line.split(": ", 1) for line in out.splitlines() if ": " in line)
        address, salt = fields["Address"].strip(), fields["Salt"].split()[0]
        salt_hex = f"{int(salt, 0):064x}"
        self.c.receipt(self.c.rpc_call("eth_sendTransaction", {
            "from": self.trader, "to": CREATE2_DEPLOYER, "data": "0x" + salt_hex + init[2:],
            "gas": hex(GAS)}))
        if self.c.rpc_call("eth_getCode", address, "latest") in ("0x", ""):
            raise RuntimeError(f"VolFeeHook not deployed at {address}")
        return address

    def _send(self, to, sig, *args):
        data = _cast("calldata", sig, *args)
        return self.c.receipt(self.c.rpc_call("eth_sendTransaction", {
            "from": self.trader, "to": to, "data": data, "gas": hex(GAS)}))

    def _word(self, offset):
        return int(self.c.call(POOL_MANAGER, "extsload(bytes32)(bytes32)",
                               f"0x{self.state_slot + offset:064x}")[0], 16)

    def probe(self):
        """One SWAP_USDC USDC -> WETH swap now; the fee the hook quotes and the fee charged."""
        growth0 = self._word(FEE_GROWTH0_OFFSET)
        liquidity = self._word(LIQUIDITY_OFFSET) & (2**128 - 1)
        receipt = self._send(self.swap_router,
                             f"swap({KEY_T},(bool,int256,uint160),(bool,bool),bytes)", self.key,
                             f"(true,-{SWAP_USDC},{MIN_SQRT_PRICE_PLUS_1})", "(false,false)", "0x")
        block = int(receipt["blockNumber"], 0)
        ts = int(self.c.rpc_call("eth_getBlockByNumber", hex(block), False)["timestamp"], 16)
        fee, rid, recorded = self.c.call_at(block, self.hook, "feeAt(uint256)(uint24,uint256,bool)",
                                            ts)
        lp_fee = (self._word(FEE_GROWTH0_OFFSET) - growth0) * liquidity // Q128
        self._send(self.swap_router, f"swap({KEY_T},(bool,int256,uint160),(bool,bool),bytes)",
                   self.key, f"(false,{SWAP_USDC},{MAX_SQRT_PRICE_MINUS_1})", "(false,false)", "0x")
        return {"hook_fee_pips": as_int(fee), "recorded": recorded in (True, "true"),
                "round_id": as_int(rid) if recorded in (True, "true") else None,
                "effective_fee_pips": round(lp_fee * PIPS / SWAP_USDC, 3),
                "lp_fee_usdc": lp_fee / 10**6, "swap_usdc": SWAP_USDC / 10**6,
                "swap_gas": int(receipt["gasUsed"], 0), "tx": receipt["transactionHash"],
                "timestamp": ts}

    def info(self):
        return {"pool_manager": POOL_MANAGER, "hook": self.hook, "pool_id": self.pool_id,
                "swap_router": self.swap_router, "fallback_fee_pips": FALLBACK_FEE_PIPS,
                "tick_spacing": TICK_SPACING}
