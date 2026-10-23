"""Offline tests for the rolling ``--tail`` cache of the Swap log fetcher.

A fake chain answers ``eth_blockNumber``, ``eth_getLogs`` and ``eth_getBlockByNumber``; block ``b``
has timestamp ``T0 + 12 * b`` and, unless listed as empty, one Swap with tick ``b``.
"""

from __future__ import annotations

import io
import json
from pathlib import Path

import pytest

from fetch_swaps import (
    BLOCKS_PER_DAY,
    DEFAULT_POOL,
    SWAP_TOPIC0,
    TAIL_SEGMENT_BLOCKS,
    RpcClient,
    coverage_path,
    main,
    tail_start,
)

T0 = 1_700_000_000
DAYS = "0.001"  # 7 blocks of backfill, 86 s of retention
BACKFILL = 7


def ts(block: int) -> int:
    return T0 + 12 * block


class FakeChain:
    def __init__(self, head: int, *, empty=(), failing=()) -> None:
        self.head = head
        self.empty = set(empty)
        self.failing = set(failing)
        self.get_logs_ranges: list[tuple[int, int]] = []
        self.block_calls: list[int] = []

    def log(self, block: int) -> dict:
        word = f"{block:064x}"
        return {
            "address": DEFAULT_POOL,
            "blockNumber": hex(block),
            "blockTimestamp": hex(ts(block)),
            "logIndex": "0x0",
            "topics": [SWAP_TOPIC0],
            "data": "0x" + "0" * 64 * 4 + word,
        }

    def __call__(self, request, timeout=None):
        body = json.loads(request.data.decode("utf-8"))
        method = body["method"]
        if method == "eth_blockNumber":
            result: object = hex(self.head)
        elif method == "eth_getLogs":
            low = int(body["params"][0]["fromBlock"], 16)
            high = int(body["params"][0]["toBlock"], 16)
            self.get_logs_ranges.append((low, high))
            if low in self.failing:
                return Reply({"jsonrpc": "2.0", "id": 1, "error": {"code": -32000}})
            result = [self.log(b) for b in range(low, high + 1) if b not in self.empty]
        elif method == "eth_getBlockByNumber":
            number = int(body["params"][0], 16)
            self.block_calls.append(number)
            result = {"number": hex(number), "timestamp": hex(ts(number))}
        else:
            raise AssertionError(f"unexpected method {method}")
        return Reply({"jsonrpc": "2.0", "id": 1, "result": result})


class Reply:
    def __init__(self, payload: object) -> None:
        self._payload = payload

    def read(self) -> bytes:
        return json.dumps(self._payload).encode("utf-8")


def run(chain: FakeChain, out: Path, *extra: str) -> tuple[int, str]:
    stdout = io.StringIO()
    code = main(
        ["--tail", "--days", DAYS, "--confirmations", "2", "--out", str(out), *extra],
        client=RpcClient("http://rpc.invalid", opener=chain),
        sleep=lambda _seconds: None,
        stdout=stdout,
    )
    return code, stdout.getvalue().strip()


def blocks_in(out: Path) -> list[int]:
    return [int(line.split(",")[0]) for line in out.read_text().splitlines()[1:]]


def coverage(out: Path) -> dict:
    return json.loads(coverage_path(out).read_text())


def test_first_run_backfills_the_window_below_the_confirmed_head(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    chain = FakeChain(head=102)
    code, summary = run(chain, out)
    assert code == 0
    assert blocks_in(out) == list(range(94, 101))
    assert coverage(out) == {"pool": DEFAULT_POOL, "to_block": 100, "to_timestamp": ts(100)}
    assert summary == "fetched=7 skipped=0 failed=0 to_block=100"


def test_a_rerun_fetches_only_after_the_covered_block_and_appends(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    run(FakeChain(head=102), out)
    chain = FakeChain(head=105)
    code, summary = run(chain, out)
    assert code == 0
    assert chain.get_logs_ranges == [(101, 103)]
    assert blocks_in(out)[-3:] == [101, 102, 103]
    assert coverage(out)["to_block"] == 103
    assert summary.startswith("fetched=3 skipped=7")


def test_nothing_new_makes_no_log_request(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    run(FakeChain(head=102), out)
    chain = FakeChain(head=102)
    code, _ = run(chain, out)
    assert code == 0
    assert chain.get_logs_ranges == []


def test_coverage_beyond_the_last_swap_reads_the_block_timestamp(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    chain = FakeChain(head=102, empty={99, 100})
    run(chain, out)
    assert blocks_in(out)[-1] == 98
    assert coverage(out) == {"pool": DEFAULT_POOL, "to_block": 100, "to_timestamp": ts(100)}
    assert chain.block_calls == [100]
    rerun = FakeChain(head=103)
    run(rerun, out)
    assert rerun.get_logs_ranges == [(101, 101)]


def test_a_failed_segment_stops_the_run_and_the_next_run_retries_it(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    chain = FakeChain(head=102, failing={97})
    code, _ = run(chain, out, "--segment-blocks", "3")
    assert code == 1
    assert sorted(set(chain.get_logs_ranges)) == [(94, 96), (97, 99)]
    assert blocks_in(out) == [94, 95, 96]
    assert coverage(out)["to_block"] == 96
    retry = FakeChain(head=102)
    code, _ = run(retry, out, "--segment-blocks", "3")
    assert code == 0
    assert retry.get_logs_ranges == [(97, 99), (100, 100)]
    assert blocks_in(out) == list(range(94, 101))


def test_a_failure_in_the_first_segment_writes_nothing(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    code, _ = run(FakeChain(head=102, failing={94}), out)
    assert code == 1
    assert not out.exists()
    assert not coverage_path(out).exists()


def test_a_cache_older_than_the_window_is_dropped_instead_of_leaving_a_hole(
    tmp_path: Path,
) -> None:
    out = tmp_path / "swaps.csv"
    run(FakeChain(head=52), out)
    chain = FakeChain(head=102)
    code, summary = run(chain, out)
    assert code == 0
    assert chain.get_logs_ranges == [(94, 100)]
    assert blocks_in(out) == list(range(94, 101))
    assert "skipped=0" in summary


def test_rows_older_than_the_window_are_pruned(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    run(FakeChain(head=102), out)
    run(FakeChain(head=106), out)
    cutoff = ts(104) - 86
    assert blocks_in(out) == [b for b in range(94, 105) if ts(b) >= cutoff]
    assert blocks_in(out)[0] > 94


def test_tail_start_keeps_rows_only_when_the_fetch_continues_after_them() -> None:
    assert tail_start(None, 100, 7) == (94, False)
    assert tail_start(92, 100, 7) == (94, False)
    assert tail_start(93, 100, 7) == (94, True)
    assert tail_start(97, 100, 7) == (98, True)


def test_the_backfill_is_days_of_twelve_second_blocks(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    confirmed = 3 * BLOCKS_PER_DAY + 1000
    chain = FakeChain(head=confirmed + 3, empty=set(range(confirmed + 4)))
    code = main(
        ["--tail", "--out", str(out)],
        client=RpcClient("http://rpc.invalid", opener=chain),
        sleep=lambda _seconds: None,
        stdout=io.StringIO(),
    )
    assert code == 0
    assert chain.get_logs_ranges[0] == (1001, 1000 + TAIL_SEGMENT_BLOCKS)
    assert chain.get_logs_ranges[-1][1] == confirmed
    assert sum(high - low + 1 for low, high in chain.get_logs_ranges) == 3 * BLOCKS_PER_DAY
    assert coverage(out)["to_block"] == confirmed


@pytest.mark.parametrize(
    "argv",
    [
        ["--tail", "--from", "1"],
        ["--tail", "--days", "0"],
        ["--tail", "--confirmations", "-1"],
        ["--from", "1"],
    ],
)
def test_usage_errors_exit_2_without_requests(tmp_path: Path, argv: list[str]) -> None:
    chain = FakeChain(head=10)
    code = main(
        [*argv, "--out", str(tmp_path / "swaps.csv")],
        client=RpcClient("http://rpc.invalid", opener=chain),
        stdout=io.StringIO(),
    )
    assert code == 2
    assert chain.get_logs_ranges == []
