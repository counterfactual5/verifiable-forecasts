"""Offline tests for the Uniswap V3 Swap log fetcher.

Every test drives the fetcher through a fake JSON-RPC opener, so the suite
never touches the network and never sleeps.
"""

from __future__ import annotations

import io
import json
import urllib.error
from pathlib import Path
from typing import Any

import pytest

from fetch_swaps import (
    CSV_COLUMNS,
    DEFAULT_POOL,
    LOG_COUNT_WARN_THRESHOLD,
    SEGMENT_BLOCKS,
    SWAP_TOPIC0,
    CsvFormatError,
    FetchSummary,
    InvalidPoolError,
    InvalidRangeError,
    MalformedPayloadError,
    RpcClient,
    RpcError,
    SegmentRangeError,
    SegmentTruncatedError,
    fetch_block_timestamp,
    fetch_logs,
    fetch_logs_with_retry,
    fetch_swaps,
    main,
    parse_hex_quantity,
    parse_swap_log,
    parse_tick,
    read_swaps,
    resume_start,
    segment_ranges,
    to_hex_block,
    validate_pool,
    validate_range,
    write_swaps,
)

FIXTURE_PATH = Path(__file__).parent / "fixtures" / "swap_logs_fixture.json"


class FakeResponse:
    """Minimal stand-in for an ``http.client.HTTPResponse``."""

    def __init__(self, payload: object) -> None:
        self._payload = payload

    def read(self) -> bytes:
        return json.dumps(self._payload).encode("utf-8")

    def close(self) -> None:
        return None


def rpc_result(payload: object) -> dict:
    """Wrap a payload into a JSON-RPC success envelope."""
    return {"jsonrpc": "2.0", "id": 1, "result": payload}


def block_payload(number: int, timestamp: int) -> dict:
    """Build a plausible ``eth_getBlockByNumber`` result."""
    return {
        "number": hex(number),
        "timestamp": hex(timestamp),
        "hash": f"0x{number:064x}",
    }


def load_fixture() -> dict:
    """Read the recorded Swap log fixture."""
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def make_log(
    block: int,
    tick: int,
    *,
    log_index: int = 0,
    pool: str = DEFAULT_POOL,
    topics: list[str] | None = None,
) -> dict:
    """Build one ``Swap`` log with the given block and tick."""

    def word(value: int) -> str:
        return f"{value & ((1 << 256) - 1):064x}"

    data = "0x" + "".join(
        word(-1500000000000000000)
        + word(1500000000000000000)
        + word(1962877650000000000000000)
        + word(12345678901234567890)
        + word(tick)
    )
    if topics is None:
        topics = [SWAP_TOPIC0, "0x" + "0" * 24 + "1", "0x" + "0" * 24 + "2"]
    return {
        "address": pool,
        "blockNumber": hex(block),
        "blockHash": f"0x{block:064x}",
        "transactionHash": f"0x{block * 1000 + log_index:064x}",
        "logIndex": hex(log_index),
        "removed": False,
        "topics": topics,
        "data": data,
    }


class ScriptedOpener:
    """Answer JSON-RPC calls from a per-method script.

    ``get_logs`` is either a list of payloads returned in call order or a
    callable receiving the request params. ``blocks`` maps a block number to
    the ``eth_getBlockByNumber`` payload.
    """

    def __init__(
        self,
        *,
        get_logs: Any = None,
        blocks: dict[int, object] | None = None,
        errors: dict[str, list[Exception]] | None = None,
    ) -> None:
        self._get_logs = get_logs if get_logs is not None else []
        self._blocks = dict(blocks or {})
        self._errors = {method: list(items) for method, items in (errors or {}).items()}
        self.requests: list[dict] = []

    def __call__(self, request, timeout=None):  # urllib-compatible opener signature
        body = json.loads(request.data.decode("utf-8"))
        self.requests.append(body)
        method = body["method"]
        queue = self._errors.get(method)
        if queue:
            outcome = queue.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return FakeResponse(rpc_result(outcome))
        if method == "eth_getLogs":
            params = body["params"][0]
            if callable(self._get_logs):
                return FakeResponse(rpc_result(self._get_logs(params)))
            if not self._get_logs:
                raise AssertionError("unexpected eth_getLogs call")
            return FakeResponse(rpc_result(self._get_logs.pop(0)))
        if method == "eth_getBlockByNumber":
            number = int(body["params"][0], 16)
            payload = self._blocks.get(number)
            if payload is None:
                raise AssertionError(f"unexpected request for block {number}")
            return FakeResponse(rpc_result(payload))
        raise AssertionError(f"unexpected method {method}")

    @property
    def get_logs_calls(self) -> list[dict]:
        return [body for body in self.requests if body["method"] == "eth_getLogs"]

    @property
    def block_calls(self) -> list[int]:
        return [
            int(body["params"][0], 16)
            for body in self.requests
            if body["method"] == "eth_getBlockByNumber"
        ]


def make_client(opener: ScriptedOpener) -> RpcClient:
    return RpcClient("http://rpc.invalid", opener=opener)


# --- hex and payload parsing ----------------------------------------------


def test_to_hex_block_encodes_quantities() -> None:
    assert to_hex_block(0) == "0x0"
    assert to_hex_block(255) == "0xff"
    assert to_hex_block(17000000) == "0x1036640"


def test_parse_hex_quantity_accepts_hex_and_int() -> None:
    assert parse_hex_quantity("0x1a") == 26
    assert parse_hex_quantity(26) == 26


def test_parse_hex_quantity_rejects_garbage() -> None:
    with pytest.raises(MalformedPayloadError):
        parse_hex_quantity("0xzz")
    with pytest.raises(MalformedPayloadError):
        parse_hex_quantity(True)


def test_parse_tick_reads_positive_and_negative_ticks() -> None:
    assert parse_tick(make_log(1, 201000)["data"]) == 201000
    assert parse_tick(make_log(1, -201000)["data"]) == -201000
    assert parse_tick(make_log(1, 0)["data"]) == 0
    assert parse_tick(make_log(1, -1)["data"]) == -1


def test_parse_tick_rejects_a_missing_tick_word() -> None:
    truncated = make_log(1, 5)["data"][: 2 + 4 * 64]
    with pytest.raises(MalformedPayloadError):
        parse_tick(truncated)


def test_parse_swap_log_rejects_a_log_without_the_tick_word() -> None:
    log = make_log(1, 5)
    log["data"] = log["data"][: 2 + 4 * 64]
    with pytest.raises(MalformedPayloadError):
        parse_swap_log(log)


def test_parse_tick_rejects_a_word_that_is_not_sign_extended() -> None:
    # A negative tick must arrive sign extended into the full 32-byte word.
    unpadded = "0x" + "0" * 56 + "fffffe98"
    with pytest.raises(MalformedPayloadError):
        parse_tick(unpadded)


def test_parse_tick_rejects_a_tick_outside_int24() -> None:
    with pytest.raises(MalformedPayloadError):
        parse_tick(make_log(1, 2**23)["data"])


def test_parse_swap_log_rejects_a_foreign_topic() -> None:
    log = make_log(1, 5, topics=["0x" + "11" * 32])
    with pytest.raises(MalformedPayloadError):
        parse_swap_log(log)


def test_parse_swap_log_rejects_a_log_without_block_number() -> None:
    log = make_log(1, 5)
    del log["blockNumber"]
    with pytest.raises(MalformedPayloadError):
        parse_swap_log(log)


def test_parse_swap_log_rejects_a_log_without_data() -> None:
    log = make_log(1, 5)
    del log["data"]
    with pytest.raises(MalformedPayloadError):
        parse_swap_log(log)


# --- the pinned acceptance test --------------------------------------------


def test_parse_swap_log_extracts_tick_and_timestamp() -> None:
    fixture = load_fixture()
    logs = fixture["logs"]
    blocks = {entry["number"]: entry for entry in fixture["blocks"]}
    opener = ScriptedOpener(
        get_logs=lambda params: [
            log
            for log in logs
            if int(params["fromBlock"], 16)
            <= int(log["blockNumber"], 16)
            <= int(params["toBlock"], 16)
        ],
        blocks=blocks,
    )
    client = make_client(opener)

    parsed = [parse_swap_log(log) for log in logs]
    assert [(item.block, item.tick) for item in parsed] == [
        (17000000, 201000),
        (17000001, -201000),
        (17000001, 195000),
        (17000003, 100000),
        (17000005, -100),
    ]

    records, summary = fetch_swaps(
        client,
        17000000,
        17000005,
        sleep=lambda _seconds: None,
    )
    assert summary.failed == 0
    assert [(record.block, record.tick, record.timestamp) for record in records] == [
        (17000000, 201000, 1700000000),
        (17000001, -201000, 1700000012),
        (17000001, 195000, 1700000012),
        (17000003, 100000, 1700000036),
        (17000005, -100, 1700000060),
    ]
    # One timestamp request per distinct block, not per log.
    assert opener.block_calls == [17000000, 17000001, 17000003, 17000005]


# --- segment validation ----------------------------------------------------


def test_segment_without_logs_is_accepted() -> None:
    opener = ScriptedOpener(get_logs=[[]])
    client = make_client(opener)
    assert fetch_logs(client, 100, 200) == []
    assert opener.get_logs_calls[0]["params"][0]["fromBlock"] == "0x64"
    assert opener.get_logs_calls[0]["params"][0]["toBlock"] == "0xc8"


def test_logs_inside_the_segment_are_accepted_even_without_reaching_its_end() -> None:
    # A response that covers only part of the segment cannot be told apart from
    # a segment whose tail has no swaps, so it is accepted.
    opener = ScriptedOpener(get_logs=[[make_log(150, 1000)]])
    client = make_client(opener)
    assert len(fetch_logs(client, 100, 200)) == 1


def test_logs_outside_the_requested_segment_are_rejected() -> None:
    opener = ScriptedOpener(get_logs=[[make_log(500, 1000)]])
    client = make_client(opener)
    with pytest.raises(SegmentRangeError) as excinfo:
        fetch_logs(client, 100, 200)
    assert "[100, 200]" in str(excinfo.value)
    assert "500" in str(excinfo.value)


def test_a_log_below_the_segment_is_rejected() -> None:
    opener = ScriptedOpener(get_logs=[[make_log(99, 1000)]])
    client = make_client(opener)
    with pytest.raises(SegmentRangeError):
        fetch_logs(client, 100, 200)


def test_a_log_from_another_pool_is_rejected() -> None:
    opener = ScriptedOpener(get_logs=[[make_log(150, 1000, pool="0x" + "11" * 20)]])
    client = make_client(opener)
    with pytest.raises(MalformedPayloadError):
        fetch_logs(client, 100, 200)


def test_an_out_of_range_segment_is_a_permanent_failure() -> None:
    opener = ScriptedOpener(get_logs=[[make_log(500, 1000)]])
    client = make_client(opener)
    delays: list[float] = []
    with pytest.raises(SegmentRangeError):
        fetch_logs_with_retry(client, 100, 200, sleep=delays.append)
    # A malformed answer is not retried; asking again cannot move the log.
    assert delays == []
    assert len(opener.get_logs_calls) == 1


def test_a_failing_segment_is_counted_and_the_rest_is_fetched() -> None:
    def logs_for(params: dict) -> list[dict]:
        low = int(params["fromBlock"], 16)
        if low == 100:
            # A log from before the segment: the read does not answer the question.
            return [make_log(50, 1000)]
        if low == 700:
            return [make_log(1100, 2000)]
        return []

    opener = ScriptedOpener(get_logs=logs_for, blocks={1100: block_payload(1100, 1700000100)})
    client = make_client(opener)
    records, summary = fetch_swaps(
        client, 100, 1200, segment_blocks=600, sleep=lambda _seconds: None
    )
    assert summary.failed == 1
    assert summary.fetched == 1
    assert [(record.block, record.tick) for record in records] == [(1100, 2000)]


# --- segmentation ----------------------------------------------------------


def test_segment_ranges_split_at_the_segment_size() -> None:
    assert segment_ranges(0, 0) == [(0, 0)]
    assert segment_ranges(0, 9) == [(0, 9)]
    assert segment_ranges(0, 10, 10) == [(0, 9), (10, 10)]
    assert segment_ranges(0, 25, 10) == [(0, 9), (10, 19), (20, 25)]


def test_a_long_range_produces_one_call_per_segment() -> None:
    start = 17_000_000
    end = start + 2 * SEGMENT_BLOCKS + 5
    opener = ScriptedOpener(get_logs=[[], [], []])
    client = make_client(opener)
    records, summary = fetch_swaps(client, start, end, sleep=lambda _seconds: None)
    assert summary.failed == 0
    assert records == []
    calls = opener.get_logs_calls
    assert len(calls) == 3
    assert [(call["params"][0]["fromBlock"], call["params"][0]["toBlock"]) for call in calls] == [
        (to_hex_block(start), to_hex_block(start + SEGMENT_BLOCKS - 1)),
        (to_hex_block(start + SEGMENT_BLOCKS), to_hex_block(start + 2 * SEGMENT_BLOCKS - 1)),
        (to_hex_block(start + 2 * SEGMENT_BLOCKS), to_hex_block(end)),
    ]


def test_the_get_logs_request_carries_the_pool_and_the_swap_topic() -> None:
    opener = ScriptedOpener(get_logs=[[]])
    client = make_client(opener)
    fetch_logs(client, 100, 200)
    params = opener.get_logs_calls[0]["params"][0]
    assert params["address"] == DEFAULT_POOL
    assert params["topics"] == [SWAP_TOPIC0]


# --- timestamps ------------------------------------------------------------


def test_fetch_block_timestamp_reads_the_block_time() -> None:
    opener = ScriptedOpener(blocks={42: block_payload(42, 1700000042)})
    client = make_client(opener)
    assert fetch_block_timestamp(client, 42) == 1700000042


def test_a_block_without_timestamp_is_not_fabricated() -> None:
    opener = ScriptedOpener(blocks={42: {"number": hex(42)}})
    client = make_client(opener)
    with pytest.raises(MalformedPayloadError):
        fetch_block_timestamp(client, 42)


def test_a_transport_failure_is_retried_with_backoff() -> None:
    opener = ScriptedOpener(
        errors={"eth_getBlockByNumber": [urllib.error.URLError("boom")]},
        blocks={42: block_payload(42, 1700000042)},
    )
    client = make_client(opener)
    delays: list[float] = []
    from fetch_swaps import fetch_block_timestamp_with_retry

    assert (
        fetch_block_timestamp_with_retry(client, 42, attempts=3, backoff=0.5, sleep=delays.append)
        == 1700000042
    )
    assert delays == [0.5]
    assert len(opener.block_calls) == 2


# --- CSV output and resume -------------------------------------------------


def read_csv(path: Path) -> list[list[str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    return [line.split(",") for line in lines]


def test_main_writes_csv_with_the_expected_schema(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    opener = ScriptedOpener(
        get_logs=[[make_log(10, 201000), make_log(11, -201000)]],
        blocks={10: block_payload(10, 1700000000), 11: block_payload(11, 1700000012)},
    )
    stdout = io.StringIO()
    code = main(
        ["--rpc", "http://rpc.invalid", "--from", "10", "--to", "11", "--out", str(out)],
        client=make_client(opener),
        stdout=stdout,
    )
    assert code == 0
    rows = read_csv(out)
    assert rows[0] == list(CSV_COLUMNS)
    assert rows[1:] == [["10", "201000", "1700000000"], ["11", "-201000", "1700000012"]]
    assert stdout.getvalue().strip() == "fetched=2 skipped=0 failed=0"
    # The file is written in place, without a leftover temporary file.
    assert not (tmp_path / "swaps.csv.tmp").exists()


def test_a_removed_log_is_left_out(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    removed = make_log(11, 2)
    removed["removed"] = True
    opener = ScriptedOpener(
        get_logs=[[removed, make_log(10, 1)]],
        blocks={10: block_payload(10, 1700000000)},
    )
    code = main(
        ["--from", "10", "--to", "11", "--out", str(out)],
        client=make_client(opener),
        stdout=io.StringIO(),
    )
    assert code == 0
    assert read_csv(out)[1:] == [["10", "1", "1700000000"]]


def test_rows_are_ordered_by_block_and_log_index(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    opener = ScriptedOpener(
        get_logs=[
            [
                make_log(12, 3, log_index=1),
                make_log(11, 2, log_index=0),
                make_log(12, 1, log_index=0),
            ]
        ],
        blocks={11: block_payload(11, 1700000012), 12: block_payload(12, 1700000024)},
    )
    main(
        ["--from", "11", "--to", "12", "--out", str(out)],
        client=make_client(opener),
        stdout=io.StringIO(),
    )
    assert read_csv(out)[1:] == [
        ["11", "2", "1700000012"],
        ["12", "1", "1700000024"],
        ["12", "3", "1700000024"],
    ]


def test_a_rerun_does_not_duplicate_rows(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    out.write_text(
        "block,tick,timestamp\n10,201000,1700000000\n11,-201000,1700000012\n",
        encoding="utf-8",
    )
    opener = ScriptedOpener(
        get_logs=[[make_log(12, 5)]],
        blocks={12: block_payload(12, 1700000024)},
    )
    stdout = io.StringIO()
    code = main(
        ["--from", "10", "--to", "12", "--out", str(out)],
        client=make_client(opener),
        stdout=stdout,
    )
    assert code == 0
    assert read_csv(out)[1:] == [
        ["10", "201000", "1700000000"],
        ["11", "-201000", "1700000012"],
        ["12", "5", "1700000024"],
    ]
    assert stdout.getvalue().strip() == "fetched=1 skipped=2 failed=0"
    # The already covered blocks are not requested again.
    assert opener.get_logs_calls[0]["params"][0]["fromBlock"] == to_hex_block(12)


def test_a_rerun_of_the_same_range_fetches_nothing(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    out.write_text("block,tick,timestamp\n10,201000,1700000000\n", encoding="utf-8")
    opener = ScriptedOpener(get_logs=[])
    stdout = io.StringIO()
    code = main(
        ["--from", "10", "--to", "10", "--out", str(out)],
        client=make_client(opener),
        stdout=stdout,
    )
    assert code == 0
    assert opener.get_logs_calls == []
    assert stdout.getvalue().strip() == "fetched=0 skipped=1 failed=0"
    assert read_csv(out)[1:] == [["10", "201000", "1700000000"]]


def test_resume_start_covers_every_block_up_to_the_highest_row() -> None:
    from fetch_swaps import SwapRecord

    assert resume_start([], 5) == 5
    assert resume_start([SwapRecord(block=9, tick=1, timestamp=2)], 5) == 10
    assert resume_start([SwapRecord(block=9, tick=1, timestamp=2)], 20) == 20


def test_reading_a_csv_file_as_jsonl_is_refused(tmp_path: Path) -> None:
    out = tmp_path / "swaps.jsonl"
    out.write_text("block,tick,timestamp\n10,1,2\n", encoding="utf-8")
    with pytest.raises(CsvFormatError):
        read_swaps(out, "jsonl")


def test_read_swaps_drops_broken_rows_and_rejects_a_foreign_header(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    out.write_text(
        "block,tick,timestamp\n10,1,2\nbroken,row\n11,nope,3\n12,4,5\n",
        encoding="utf-8",
    )
    assert [(record.block, record.tick) for record in read_swaps(out)] == [(10, 1), (12, 4)]
    out.write_text("number,fee\n10,1\n", encoding="utf-8")
    with pytest.raises(CsvFormatError):
        read_swaps(out)


def test_the_jsonl_format_carries_the_same_fields(tmp_path: Path) -> None:
    out = tmp_path / "swaps.jsonl"
    opener = ScriptedOpener(
        get_logs=[[make_log(10, 201000)]],
        blocks={10: block_payload(10, 1700000000)},
    )
    code = main(
        ["--from", "10", "--to", "10", "--out", str(out), "--format", "jsonl"],
        client=make_client(opener),
        stdout=io.StringIO(),
    )
    assert code == 0
    payloads = [json.loads(line) for line in out.read_text(encoding="utf-8").splitlines()]
    assert payloads == [{"block": 10, "tick": 201000, "timestamp": 1700000000}]


def test_write_swaps_sorts_and_replaces_atomically(tmp_path: Path) -> None:
    from fetch_swaps import SwapRecord

    out = tmp_path / "swaps.csv"
    write_swaps(
        out,
        [
            SwapRecord(block=9, tick=2, timestamp=3, log_index=0),
            SwapRecord(block=2, tick=1, timestamp=1, log_index=0),
        ],
    )
    assert read_csv(out) == [["block", "tick", "timestamp"], ["2", "1", "1"], ["9", "2", "3"]]
    assert not (tmp_path / "swaps.csv.tmp").exists()


# --- CLI -------------------------------------------------------------------


def test_main_reports_a_summary_line(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    opener = ScriptedOpener(
        get_logs=[[make_log(10, 1)]],
        blocks={10: block_payload(10, 1700000000)},
    )
    stdout = io.StringIO()
    code = main(
        ["--from", "10", "--to", "10", "--out", str(out)],
        client=make_client(opener),
        stdout=stdout,
    )
    assert code == 0
    assert stdout.getvalue().strip() == "fetched=1 skipped=0 failed=0"


def test_main_rejects_an_invalid_range(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    opener = ScriptedOpener()
    code = main(
        ["--from", "20", "--to", "10", "--out", str(out)],
        client=make_client(opener),
        stdout=io.StringIO(),
    )
    assert code == 2
    assert not out.exists()
    assert opener.requests == []


def test_main_rejects_a_pool_that_is_not_an_address(tmp_path: Path) -> None:
    out = tmp_path / "swaps.csv"
    opener = ScriptedOpener()
    code = main(
        ["--from", "10", "--to", "10", "--pool", "0xdead", "--out", str(out)],
        client=make_client(opener),
        stdout=io.StringIO(),
    )
    assert code == 2
    assert not out.exists()
    assert opener.requests == []


def test_validate_pool_accepts_the_eth_usdc_pool() -> None:
    assert validate_pool(DEFAULT_POOL) == DEFAULT_POOL
    with pytest.raises(InvalidPoolError):
        validate_pool("0x1234")


def test_validate_range_rejects_inverted_and_negative() -> None:
    with pytest.raises(InvalidRangeError):
        validate_range(10, 9)
    with pytest.raises(InvalidRangeError):
        validate_range(-1, 9)


def test_a_transport_failure_is_counted_as_failed_and_exits_non_zero(tmp_path: Path) -> None:
    # A failed segment is a permanent hole under the resume rule, so the CLI
    # must not exit 0; this pinned exit 0 before the review fix.
    out = tmp_path / "swaps.csv"
    opener = ScriptedOpener(
        errors={"eth_getLogs": [urllib.error.URLError("boom")] * 3},
    )
    stdout = io.StringIO()
    delays: list[float] = []
    code = main(
        ["--from", "10", "--to", "10", "--out", str(out)],
        client=make_client(opener),
        sleep=delays.append,
        stdout=stdout,
    )
    assert code == 1
    assert stdout.getvalue().strip() == "fetched=0 skipped=0 failed=1"
    assert delays == [0.5, 1.0]
    assert read_csv(out) == [list(CSV_COLUMNS)]


def test_a_rpc_error_is_reported_as_a_retryable_failure() -> None:
    class ErrorOpener:
        def __init__(self) -> None:
            self.calls = 0

        def __call__(self, request, timeout=None):
            self.calls += 1
            return FakeResponse(
                {"jsonrpc": "2.0", "id": 1, "error": {"code": -32000, "message": "nope"}}
            )

    opener = ErrorOpener()
    client = RpcClient("http://rpc.invalid", opener=opener)
    delays: list[float] = []
    with pytest.raises(RpcError):
        fetch_logs_with_retry(client, 10, 20, sleep=delays.append)
    assert opener.calls == 3
    assert delays == [0.5, 1.0]


def test_a_response_at_the_log_count_cap_is_a_permanent_segment_error() -> None:
    # A count-capped gateway silently truncates, and this pool can exceed the
    # cap inside one segment, so the answer is refused instead of trusted.
    assert LOG_COUNT_WARN_THRESHOLD == 10_000
    logs = [make_log(100, 1000 + position) for position in range(LOG_COUNT_WARN_THRESHOLD)]
    opener = ScriptedOpener(get_logs=[logs])
    client = make_client(opener)
    with pytest.raises(SegmentTruncatedError) as excinfo:
        fetch_logs(client, 100, 200)
    assert "[100, 200]" in str(excinfo.value)
    assert str(LOG_COUNT_WARN_THRESHOLD) in str(excinfo.value)


def test_a_response_below_the_log_count_cap_is_accepted() -> None:
    logs = [make_log(100, position) for position in range(LOG_COUNT_WARN_THRESHOLD - 1)]
    opener = ScriptedOpener(get_logs=[logs])
    client = make_client(opener)
    assert len(fetch_logs(client, 100, 200)) == LOG_COUNT_WARN_THRESHOLD - 1


def test_a_truncated_segment_counts_as_failed_and_exits_non_zero(tmp_path: Path) -> None:
    logs = [make_log(10, position) for position in range(LOG_COUNT_WARN_THRESHOLD)]
    opener = ScriptedOpener(get_logs=[logs])
    stdout = io.StringIO()
    code = main(
        ["--from", "10", "--to", "10", "--out", str(tmp_path / "swaps.csv")],
        client=make_client(opener),
        stdout=stdout,
    )
    assert code == 1
    assert stdout.getvalue().strip() == "fetched=0 skipped=0 failed=1"


def test_fetch_summary_has_no_skipped_counter() -> None:
    # The CLI derives skipped from the existing rows, so the dataclass must not
    # carry a field a reader could believe is maintained.
    assert not hasattr(FetchSummary(), "skipped")
