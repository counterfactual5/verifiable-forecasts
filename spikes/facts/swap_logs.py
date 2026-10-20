"""Swap-event density and public-RPC eth_getLogs range limits for a V3 pool.

Usage: python3 swap_logs.py <rpc> [<rpc> ...]
"""
import json
import sys
import time
import urllib.request

POOL = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"
SWAP = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "facts/0.1"})
    t = time.time()
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            out = json.loads(r.read())
    except Exception as e:  # noqa: BLE001
        return None, f"{type(e).__name__}: {str(e)[:160]}", time.time() - t
    if "error" in out:
        return None, str(out["error"])[:200], time.time() - t
    return out["result"], None, time.time() - t


def logs(url, lo, hi):
    return rpc(url, "eth_getLogs", [{"address": POOL, "topics": [SWAP], "fromBlock": hex(lo), "toBlock": hex(hi)}])


def main():
    urls = sys.argv[1:]
    head = int(rpc(urls[0], "eth_blockNumber", [])[0], 16)
    res, err, dt = logs(urls[0], head - 299, head)
    if err:
        print("300-block fetch failed:", err)
    else:
        blocks = {}
        for lg in res:
            blocks[int(lg["blockNumber"], 16)] = blocks.get(int(lg["blockNumber"], 16), 0) + 1
        print(f"head={head} 300 blocks: swaps={len(res)} avg/block={len(res)/300:.2f} "
              f"blocks_with_swap={len(blocks)}/300={len(blocks)/300:.1%} max/block={max(blocks.values())} t={dt:.2f}s")
    for url in urls:
        for span in (1000, 5000, 10000):
            res, err, dt = logs(url, head - span + 1, head)
            print(f"{url} span={span}: " + (f"ERR {err}" if err else f"ok logs={len(res)}") + f" t={dt:.1f}s")
            time.sleep(1)
            if err:
                break


if __name__ == "__main__":
    main()
