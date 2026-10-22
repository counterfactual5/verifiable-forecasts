"""Local chain plumbing over Foundry's CLI: an anvil subprocess, `forge create` deployments and
`cast` calls/sends. Kept to subprocesses so the agents need no web3 dependency."""

import json
import socket
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONTRACTS = ROOT.parent / "contracts"

# anvil's default dev accounts (mnemonic "test test ... junk"); local chain only
DEV_KEYS = [
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
    "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
    "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
]


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _run(cmd, timeout=600):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        head = " ".join(cmd[:4])
        raise RuntimeError(f"{head} ... failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")
    return r.stdout.strip()


class Anvil:
    def __init__(self):
        self.port = _free_port()
        self.rpc = f"http://127.0.0.1:{self.port}"
        self.proc = None

    def __enter__(self):
        self.proc = subprocess.Popen(
            ["anvil", "--port", str(self.port), "--silent"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.time() + 20
        while time.time() < deadline:
            try:
                self.block_number()
                return self
            except RuntimeError:
                time.sleep(0.2)
        self.close()
        raise RuntimeError("anvil did not start")

    def __exit__(self, *exc):
        self.close()

    def close(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()

    # ------------------------------------------------------------ cast
    def block_number(self):
        return int(_run(["cast", "block-number", "--rpc-url", self.rpc], timeout=5))

    def timestamp(self):
        return int(_run(["cast", "block", "latest", "--field", "timestamp", "--rpc-url", self.rpc]))

    def set_next_timestamp(self, ts):
        _run(["cast", "rpc", "evm_setNextBlockTimestamp", str(ts), "--rpc-url", self.rpc])

    def call(self, to, sig, *args):
        """Returns the decoded outputs as a list (cast --json)."""
        out = _run(["cast", "call", to, sig, *map(str, args), "--rpc-url", self.rpc, "--json"])
        return json.loads(out)

    def send(self, key, to, sig, *args):
        out = _run([
            "cast", "send", to, sig, *map(str, args),
            "--private-key", key, "--rpc-url", self.rpc, "--json",
        ])
        receipt = json.loads(out)
        if receipt.get("status") not in ("0x1", 1, "1"):
            raise RuntimeError(f"{sig} reverted: {receipt}")
        return receipt

    def deploy(self, key, target, *ctor_args):
        """`forge create` a contract from contracts/ (e.g. 'src/VolMarket.sol:VolMarket')."""
        cmd = [
            "forge", "create", target, "--root", str(CONTRACTS), "--rpc-url", self.rpc,
            "--private-key", key, "--broadcast", "--json",
        ]
        if ctor_args:
            cmd += ["--constructor-args", *map(str, ctor_args)]
        out = _run(cmd, timeout=900)
        return json.loads(out[out.index("{") :])["deployedTo"]


def address_of(key):
    return _run(["cast", "wallet", "address", "--private-key", key])


def keccak(data: bytes) -> str:
    """keccak256 computed locally: a commitment must not reach an RPC node before it is sent."""
    return _run(["cast", "keccak", "0x" + data.hex()])


def as_int(v):
    """cast --json renders integers as strings, sometimes with a ' [1e18]' annotation."""
    if isinstance(v, int):
        return v
    return int(str(v).split()[0], 0)
