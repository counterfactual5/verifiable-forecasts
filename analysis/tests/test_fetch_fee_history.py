"""Offline tests for the base fee history fetcher.

Every test drives the fetcher through a fake JSON-RPC opener, so the suite
never touches the network and never sleeps.
"""

from __future__ import annotations

import io
import json
import urllib.error
from pathlib import Path

import pytest

from fetch_fee_history import (
    CSV_COLUMNS,
    BlockRecord,
    CsvFormatError,
    InvalidRangeError,
    MalformedBlockError,
    RpcClient,
    RpcError,
    fetch_block,
    fetch_block_with_retry,
    fetch_range,
    main,
    parse_hex_quantity,
    read_history,
    to_hex_block,
    validate_range,
    write_history,
)


class FakeResponse:
    """Minimal stand-in for an ``http.client.HTTPResponse``."""

    def __init__(self, payload: object) -> None:
        self._payload = payload

    def read(self) -> bytes:
        return json.dumps(self._payload).encode("utf-8")

    def close(self) -> None:
        return None


class RawResponse:
    """A response whose body is returned byte for byte."""

    def __init__(self, body: bytes) -> None:
        self._body = body

    def read(self) -> bytes:
        return self._body

    def close(self) -> None:
        return None


class FakeOpener:
    """Replay scripted JSON-RPC outcomes per requested block number.

    Each outcome is either an exception to raise (a transport failure) or the
    payload to return. The queue for a block is consumed in order, which makes
    retry behaviour observable.
    """

    def __init__(self, outcomes: dict[int, list[object]]) -> None:
        self._outcomes = {number: list(items) for number, items in outcomes.items()}
        self.requests: list[dict] = []

    def __call__(self, request, timeout=None):  # urllib-compatible opener signaturenature
        body = json.loads(request.data.decode("utf-8"))
        self.requests.append(body)
        number = int(body["params"][0], 16)
        queue = self._outcomes.get(number)
        if not queue:
            raise AssertionError(f"unexpected request for block {number}")
        outcome = queue.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return FakeResponse(outcome)


def block_payload(number: int, base_fee_wei: int, timestamp: int) -> dict:
    """Build a plausible ``eth_getBlockByNumber`` result."""
    return {
        "number": hex(number),
        "baseFeePerGas": hex(base_fee_wei),
        "timestamp": hex(timestamp),
        "hash": f"0x{number:064x}",
    }


def rpc_result(payload: object) -> dict:
    """Wrap a payload into a JSON-RPC success envelope."""
    return {"jsonrpc": "2.0", "id": 1, "result": payload}


def transport_error(message: str = "boom") -> urllib.error.URLError:
    return urllib.error.URLError(message)


def http_error(code: int = 502) -> urllib.error.HTTPError:
    return urllib.error.HTTPError("http://rpc.invalid", code, "bad gateway", {}, None)


def make_client(outcomes: dict[int, list[object]]) -> tuple[RpcClient, FakeOpener]:
    opener = FakeOpener(outcomes)
    return RpcClient("http://rpc.invalid", opener=opener), opener


def read_csv(path: Path) -> list[list[str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    return [line.split(",") for line in lines]


# --- hex conversion -------------------------------------------------------


def test_to_hex_block_encodes_quantities() -> None:
    assert to_hex_block(0) == "0x0"
    assert to_hex_block(255) == "0xff"
    assert to_hex_block(26000000) == "0x18cba80"


def test_to_hex_block_round_trips() -> None:
    for number in (0, 1, 16, 255, 26000000):
        assert int(to_hex_block(number), 16) == number


def test_to_hex_block_rejects_negative() -> None:
    with pytest.raises(ValueError):
        to_hex_block(-1)


def test_parse_hex_quantity_accepts_hex_and_int() -> None:
    assert parse_hex_quantity("0x1a") == 26
    assert parse_hex_quantity("0X1A") == 26
    assert parse_hex_quantity(26) == 26
    assert parse_hex_quantity("0x0") == 0


def test_parse_hex_quantity_rejects_garbage() -> None:
    with pytest.raises(MalformedBlockError):
        parse_hex_quantity("0xzz")
    with pytest.raises(MalformedBlockError):
        parse_hex_quantity("")
    with pytest.raises(MalformedBlockError):
        parse_hex_quantity(True)


# --- successful fetch and CSV schema --------------------------------------


def test_fetch_block_reads_base_fee_and_timestamp() -> None:
    client, _ = make_client({100: [rpc_result(block_payload(100, 1043683754, 1738000000))]})
    record = fetch_block(client, 100)
    assert record == BlockRecord(block=100, base_fee_wei=1043683754, timestamp=1738000000)


def test_main_writes_csv_with_expected_schema(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    client, _ = make_client(
        {
            10: [rpc_result(block_payload(10, 1000, 1700000000))],
            11: [rpc_result(block_payload(11, 2000, 1700000012))],
        }
    )
    stdout = io.StringIO()
    code = main(
        ["--rpc", "http://rpc.invalid", "--from", "10", "--to", "11", "--out", str(out)],
        client=client,
        stdout=stdout,
    )
    assert code == 0
    assert out.exists()
    rows = read_csv(out)
    assert rows[0] == list(CSV_COLUMNS)
    assert rows[1:] == [["10", "1000", "1700000000"], ["11", "2000", "1700000012"]]
    assert stdout.getvalue().strip() == "fetched=2 skipped=0 failed=0"


def test_main_uses_hex_block_parameter(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    client, opener = make_client({26000000: [rpc_result(block_payload(26000000, 7, 8))]})
    main(
        ["--from", "26000000", "--to", "26000000", "--out", str(out)],
        client=client,
        stdout=io.StringIO(),
    )
    assert opener.requests[0]["method"] == "eth_getBlockByNumber"
    assert opener.requests[0]["params"] == ["0x18cba80", False]


def test_write_history_is_sorted_and_stable(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    write_history(
        out,
        [
            BlockRecord(block=9, base_fee_wei=2, timestamp=3),
            BlockRecord(block=2, base_fee_wei=1, timestamp=1),
        ],
    )
    assert read_csv(out) == [["block", "base_fee_wei", "ts"], ["2", "1", "1"], ["9", "2", "3"]]


def test_write_history_keeps_first_row_of_a_repeated_block(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    write_history(
        out,
        [
            BlockRecord(block=4, base_fee_wei=10, timestamp=20),
            BlockRecord(block=4, base_fee_wei=99, timestamp=99),
        ],
    )
    assert read_csv(out) == [["block", "base_fee_wei", "ts"], ["4", "10", "20"]]


# --- resume / skipping ----------------------------------------------------


def test_resume_skips_blocks_already_present(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    out.write_text(
        "block,base_fee_wei,ts\n10,1000,1700000000\n11,2000,1700000012\n", encoding="utf-8"
    )
    client, opener = make_client({12: [rpc_result(block_payload(12, 3000, 1700000024))]})
    stdout = io.StringIO()
    code = main(
        ["--from", "10", "--to", "12", "--out", str(out)],
        client=client,
        stdout=stdout,
    )
    assert code == 0
    assert [request["params"][0] for request in opener.requests] == ["0xc"]
    assert stdout.getvalue().strip() == "fetched=1 skipped=2 failed=0"
    rows = read_csv(out)
    assert rows[1:] == [
        ["10", "1000", "1700000000"],
        ["11", "2000", "1700000012"],
        ["12", "3000", "1700000024"],
    ]


def test_rows_outside_the_requested_range_are_preserved(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    out.write_text(
        "block,base_fee_wei,ts\n5,500,1700000000\n10,1000,1700000010\n", encoding="utf-8"
    )
    client, _ = make_client({11: [rpc_result(block_payload(11, 1100, 1700000022))]})
    main(
        ["--from", "10", "--to", "11", "--out", str(out)],
        client=client,
        stdout=io.StringIO(),
    )
    rows = read_csv(out)
    assert rows[1:] == [
        ["5", "500", "1700000000"],
        ["10", "1000", "1700000010"],
        ["11", "1100", "1700000022"],
    ]


def test_read_history_keeps_valid_rows_and_drops_broken_ones(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    out.write_text(
        "block,base_fee_wei,ts\n10,1000,1700000000\nbroken,row\n11,nope,1\n12,3000,1700000024\n",
        encoding="utf-8",
    )
    records = read_history(out)
    assert set(records) == {10, 12}


def test_read_history_rejects_foreign_header(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    out.write_text("number,fee\n10,1000\n", encoding="utf-8")
    with pytest.raises(CsvFormatError):
        read_history(out)


# --- retry ----------------------------------------------------------------


def test_retry_then_success() -> None:
    client, opener = make_client(
        {5: [transport_error(), http_error(503), rpc_result(block_payload(5, 42, 99))]}
    )
    delays: list[float] = []
    record = fetch_block_with_retry(client, 5, attempts=3, backoff=0.5, sleep=delays.append)
    assert record == BlockRecord(block=5, base_fee_wei=42, timestamp=99)
    assert delays == [0.5, 1.0]
    assert len(opener.requests) == 3


def test_retry_exhausted_raises_rpc_error() -> None:
    client, opener = make_client({6: [transport_error(), transport_error(), transport_error()]})
    delays: list[float] = []
    with pytest.raises(RpcError):
        fetch_block_with_retry(client, 6, attempts=3, backoff=0.5, sleep=delays.append)
    assert delays == [0.5, 1.0]
    assert len(opener.requests) == 3


def test_invalid_json_body_is_retryable() -> None:
    class BrokenOpener:
        def __init__(self) -> None:
            self.calls = 0

        def __call__(self, request, timeout=None):
            self.calls += 1
            return RawResponse(b"<html>not json</html>")

    opener = BrokenOpener()
    client = RpcClient("http://rpc.invalid", opener=opener)
    delays: list[float] = []
    with pytest.raises(RpcError):
        fetch_block_with_retry(client, 8, attempts=3, backoff=0.25, sleep=delays.append)
    assert opener.calls == 3
    assert delays == [0.25, 0.5]


def test_rpc_error_envelope_is_retryable() -> None:
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
        fetch_block_with_retry(client, 7, attempts=3, backoff=0.25, sleep=delays.append)
    assert opener.calls == 3
    assert delays == [0.25, 0.5]


# --- permanent failure ----------------------------------------------------


def test_permanent_failure_is_counted_and_skipped(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    client, opener = make_client(
        {
            20: [rpc_result(block_payload(20, 111, 222))],
            21: [transport_error(), transport_error(), transport_error()],
        }
    )
    stdout = io.StringIO()
    code = main(
        ["--from", "20", "--to", "21", "--out", str(out)],
        client=client,
        stdout=stdout,
    )
    assert code == 0
    assert stdout.getvalue().strip() == "fetched=1 skipped=0 failed=1"
    rows = read_csv(out)
    assert rows[1:] == [["20", "111", "222"]]
    assert len(opener.requests) == 4


def test_block_without_base_fee_is_not_fabricated(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    payload = {"number": hex(30), "timestamp": hex(1700000000)}
    client, opener = make_client({30: [rpc_result(payload)]})
    stdout = io.StringIO()
    code = main(
        ["--from", "30", "--to", "30", "--out", str(out)],
        client=client,
        stdout=stdout,
    )
    assert code == 0
    assert stdout.getvalue().strip() == "fetched=0 skipped=0 failed=1"
    # A malformed payload is permanent, so it is not retried.
    assert len(opener.requests) == 1
    rows = read_csv(out)
    assert rows == [["block", "base_fee_wei", "ts"]]


def test_fetch_range_reports_failure_for_missing_block() -> None:
    client, _ = make_client({40: [rpc_result(None)]})
    records, summary = fetch_range(client, 40, 40, sleep=lambda _seconds: None)
    assert records == []
    assert summary.failed == 1
    assert summary.fetched == 0


def test_mismatched_block_number_is_rejected() -> None:
    client, _ = make_client({41: [rpc_result(block_payload(999, 1, 2))]})
    with pytest.raises(MalformedBlockError):
        fetch_block(client, 41)


# --- range validation -----------------------------------------------------


def test_validate_range_rejects_inverted_and_negative() -> None:
    with pytest.raises(InvalidRangeError):
        validate_range(10, 9)
    with pytest.raises(InvalidRangeError):
        validate_range(-1, 9)
    with pytest.raises(InvalidRangeError):
        validate_range(1, -9)
    validate_range(9, 9)


def test_main_rejects_invalid_range(tmp_path: Path) -> None:
    out = tmp_path / "history.csv"
    client, opener = make_client({})
    code = main(
        ["--from", "20", "--to", "10", "--out", str(out)],
        client=client,
        stdout=io.StringIO(),
    )
    assert code == 2
    assert not out.exists()
    assert opener.requests == []
