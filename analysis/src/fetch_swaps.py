"""Fetch Uniswap V3 ``Swap`` event logs into a resumable file of block, tick and timestamp.

The fetcher depends on the standard library only and is fully offline-testable: the
HTTP transport is an injected callable, so a test can replay scripted JSON-RPC
responses without touching the network.

Target pool: the Uniswap V3 ETH/USDC 0.05% pool
``0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640`` (``--pool``). The event is
``Swap(address,address,int256,int256,uint160,uint128,int24)``; its topic0 is
``0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67``.

Output schema (``data/swaps.csv``)::

    block,tick,timestamp
    17000000,201000,1700000000

``tick`` is the pool tick index as a signed 24-bit integer, ``timestamp`` the
block timestamp in unix seconds. Both are plain integers, so no rounding enters
the value. ``--format jsonl`` writes one JSON object per line with the same
three fields.

The block range is walked in segments of at most ``SEGMENT_BLOCKS`` (10 000)
blocks, because a public gateway silently truncates a larger ``eth_getLogs``
request (see ``spikes/facts/FACTS.md`` section 3). A response is accepted only
when every log it carries lies inside the requested segment; a log outside the
segment is a permanent error naming the segment, never a silent short read. An
empty response is accepted, and so is a response that covers only part of the
segment: the JSON-RPC answer carries no way to tell a sparse segment from a
truncated one, so the segment size is the guard against truncation. Gateways
also cap the answer by log count, commonly 10 000 logs per response, and this
pool exceeds that in dense segments; a response that reaches
``LOG_COUNT_WARN_THRESHOLD`` logs is therefore a permanent error naming the
segment and the count, never data.

Timestamps are resolved with ``eth_getBlockByNumber`` per distinct block and
cached for the whole run; ``eth_getLogs`` carries no timestamp in the
JSON-RPC specification.

Resume rule: the highest block number already in the output file marks
everything up to it as covered, so a re-run starts at ``last_block + 1`` and
adds no duplicate rows. A gap the output file does not cover therefore has to
be filled through a fresh output file. This makes a failed segment a permanent
hole: a later successful segment raises the highest block past it, so a re-run
never comes back for it. The CLI therefore exits 1 whenever a segment failed;
a non-zero exit means the output file must not be treated as complete.

This module is self-contained on purpose: the sibling base-fee fetcher is legacy
and scheduled for removal, so nothing here may import it.

CLI::

    python src/fetch_swaps.py --rpc https://mainnet.gateway.tenderly.co \
        --from 17000000 --to 17100000 --out data/swaps.csv

Exit codes: 0 when every segment succeeded (a nothing-to-do resume run is a
success), 1 when at least one segment failed, 2 for a usage error.
"""

from __future__ import annotations

import argparse
import csv
import http.client
import json
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

CSV_COLUMNS: tuple[str, str, str] = ("block", "tick", "timestamp")
DEFAULT_POOL = "0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640"
SWAP_TOPIC0 = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"
SEGMENT_BLOCKS = 10_000
# Gateways cap eth_getLogs by log count as well as by block range, commonly at
# 10 000 logs per response. Measured: pool 0x88e6...5640 returned 11 769 Swap
# logs in one SEGMENT_BLOCKS-sized segment (analysis/data/swaps.csv, first
# segment), so a response at this count cannot be assumed complete for it.
LOG_COUNT_WARN_THRESHOLD = 10_000
# The tenderly gateway serves the deep history this fetcher needs; publicnode
# only answers for the most recent blocks (spikes/facts/FACTS.md section 3).
DEFAULT_RPC_URL = "https://mainnet.gateway.tenderly.co"
DEFAULT_OUT_PATH = "data/swaps.csv"
DEFAULT_ATTEMPTS = 3
DEFAULT_BACKOFF_SECONDS = 0.5
DEFAULT_TIMEOUT_SECONDS = 30.0
FORMATS = ("csv", "jsonl")
HEX_DIGITS = frozenset("0123456789abcdefABCDEF")
WORD_HEX_LENGTH = 64
TICK_WORD_INDEX = 4
SWAP_DATA_WORDS = 5
INT24_MIN = -(2**23)
INT24_MAX = 2**23 - 1
TWO_POW_255 = 2**255
TWO_POW_256 = 2**256


class FetchError(Exception):
    """Base class for every error this module raises on purpose."""


class InvalidRangeError(FetchError):
    """The requested block range cannot be fetched."""


class InvalidPoolError(FetchError):
    """The requested pool address is not an address."""


class RpcError(FetchError):
    """A transient JSON-RPC or transport failure that is worth retrying."""


class MalformedPayloadError(FetchError):
    """A payload that cannot be read and will never become readable."""


class SegmentRangeError(MalformedPayloadError):
    """A log outside the requested segment, which means the read was short."""


class SegmentTruncatedError(MalformedPayloadError):
    """A response at the log-count cap, which may have been truncated."""


class CsvFormatError(FetchError):
    """The existing output file does not use the expected header."""


class OutputFormatError(FetchError):
    """The requested output format is not one this module writes."""


@dataclass(frozen=True)
class ParsedLog:
    """One raw ``Swap`` log, reduced to what the output file keeps."""

    block: int
    tick: int
    log_index: int


@dataclass(frozen=True)
class SwapRecord:
    """One row of the output file."""

    block: int
    tick: int
    timestamp: int
    log_index: int = 0


@dataclass
class FetchSummary:
    """Counters the CLI reports at the end of a run.

    The ``skipped`` count of the summary line is the number of rows already
    present in the output file, so ``main`` derives it from the existing rows
    instead of a counter here.
    """

    fetched: int = 0
    failed: int = 0


def to_hex_block(number: int) -> str:
    """Encode a block number as a JSON-RPC hex quantity."""
    if number < 0:
        raise ValueError(f"block number must not be negative: {number}")
    return f"0x{number:x}"


def parse_hex_quantity(value: Any, *, field_name: str = "quantity") -> int:
    """Parse a JSON-RPC quantity into an integer.

    Hex strings are the spec form; plain integers are accepted because some
    providers return them. Anything else is rejected instead of guessed.
    """
    if isinstance(value, bool):
        raise MalformedPayloadError(f"{field_name} is not a quantity: {value!r}")
    if isinstance(value, int):
        if value < 0:
            raise MalformedPayloadError(f"{field_name} is negative: {value!r}")
        return value
    if not isinstance(value, str):
        raise MalformedPayloadError(f"{field_name} is not a quantity: {value!r}")
    text = value.strip()
    if text[:2].lower() == "0x":
        text = text[2:]
    if not text or any(char not in HEX_DIGITS for char in text):
        raise MalformedPayloadError(f"{field_name} is not a hex quantity: {value!r}")
    return int(text, 16)


def validate_pool(address: str) -> str:
    """Reject anything that is not a 20-byte hex address."""
    if not isinstance(address, str):
        raise InvalidPoolError(f"pool address is not a string: {address!r}")
    text = address.strip()
    if not text.startswith("0x") or len(text) != 42:
        raise InvalidPoolError(f"pool address is not a 20-byte hex address: {address!r}")
    if any(char not in HEX_DIGITS for char in text[2:]):
        raise InvalidPoolError(f"pool address is not a 20-byte hex address: {address!r}")
    return text


def validate_range(start: int, end: int) -> None:
    """Reject ranges that cannot be fetched."""
    if start < 0:
        raise InvalidRangeError(f"--from must not be negative: {start}")
    if end < 0:
        raise InvalidRangeError(f"--to must not be negative: {end}")
    if start > end:
        raise InvalidRangeError(f"--from ({start}) must not be greater than --to ({end})")


class RpcClient:
    """A small JSON-RPC 2.0 client over ``urllib``.

    ``opener`` follows the ``urllib.request.urlopen`` convention: it is called
    with a request object and a timeout, and returns a response exposing
    ``read()``. Tests inject a fake opener instead of a socket.
    """

    def __init__(
        self,
        url: str,
        *,
        opener: Callable[..., Any] | None = None,
        timeout: float = DEFAULT_TIMEOUT_SECONDS,
    ) -> None:
        if not url:
            raise ValueError("rpc url must not be empty")
        self._url = url
        self._opener = opener if opener is not None else urllib.request.urlopen
        self._timeout = timeout
        self._request_id = 0

    @property
    def url(self) -> str:
        return self._url

    def call(self, method: str, params: Sequence[Any] = ()) -> Any:
        """Perform one JSON-RPC call and return its ``result`` member."""
        self._request_id += 1
        body = {
            "jsonrpc": "2.0",
            "id": self._request_id,
            "method": method,
            "params": list(params),
        }
        request = urllib.request.Request(
            self._url,
            data=json.dumps(body).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "basefee-analysis/0.1",
            },
            method="POST",
        )
        try:
            response = self._opener(request, timeout=self._timeout)
        except urllib.error.HTTPError as exc:
            raise RpcError(f"{method}: HTTP {exc.code}") from exc
        except urllib.error.URLError as exc:
            raise RpcError(f"{method}: transport error: {exc.reason}") from exc
        except OSError as exc:
            raise RpcError(f"{method}: transport error: {exc}") from exc
        try:
            raw = response.read()
        except (OSError, http.client.HTTPException) as exc:
            raise RpcError(f"{method}: transport error while reading: {exc!r}") from exc
        finally:
            self._close_quietly(response)
        return self._parse_response(method, raw)

    @staticmethod
    def _close_quietly(response: Any) -> None:
        """Close the response; a failing close never masks the read outcome."""
        close = getattr(response, "close", None)
        if not callable(close):
            return
        try:
            close()
        except (OSError, http.client.HTTPException):
            pass

    @staticmethod
    def _parse_response(method: str, raw: Any) -> Any:
        if isinstance(raw, (bytes, bytearray)):
            try:
                text = bytes(raw).decode("utf-8")
            except UnicodeDecodeError as exc:
                raise RpcError(f"{method}: response is not valid UTF-8") from exc
        else:
            text = str(raw)
        try:
            body = json.loads(text)
        except json.JSONDecodeError as exc:
            raise RpcError(f"{method}: response is not valid JSON") from exc
        if not isinstance(body, dict):
            raise RpcError(f"{method}: response is not a JSON object")
        error = body.get("error")
        if error:
            raise RpcError(f"{method}: JSON-RPC error: {error}")
        if "result" not in body:
            raise RpcError(f"{method}: response has no result")
        return body["result"]


def parse_tick(data: Any) -> int:
    """Read the tick out of a ``Swap`` log's data field.

    The event carries five non-indexed words; the last one is the ``int24``
    tick, sign extended into the full 32-byte word. The word is read as a
    two's-complement 256-bit integer, so a negative tick comes out negative
    without any bit masking guesswork.
    """
    if not isinstance(data, str):
        raise MalformedPayloadError("swap log data is not a hex string")
    text = data.strip()
    if text[:2].lower() != "0x":
        raise MalformedPayloadError(f"swap log data is not hex encoded: {data!r}")
    text = text[2:]
    if not text or len(text) % 2 or any(char not in HEX_DIGITS for char in text):
        raise MalformedPayloadError(f"swap log data is not a hex payload: {data!r}")
    if len(text) != SWAP_DATA_WORDS * WORD_HEX_LENGTH:
        raise MalformedPayloadError(
            f"swap log data has {len(text) // WORD_HEX_LENGTH} words, "
            f"expected {SWAP_DATA_WORDS}"
        )
    word = text[TICK_WORD_INDEX * WORD_HEX_LENGTH : (TICK_WORD_INDEX + 1) * WORD_HEX_LENGTH]
    value = int(word, 16)
    if value >= TWO_POW_255:
        value -= TWO_POW_256
    if not INT24_MIN <= value <= INT24_MAX:
        raise MalformedPayloadError(f"swap log tick does not fit in int24: {value}")
    return value


def parse_swap_log(log: Mapping[str, Any], *, position: int = 0) -> ParsedLog:
    """Reduce one ``Swap`` log to its block number, tick and log index.

    A log that does not carry the Swap topic or a complete data field is
    rejected; nothing about it is guessed.
    """
    if not isinstance(log, Mapping):
        raise MalformedPayloadError(f"swap log is not an object: {log!r}")
    topics = log.get("topics")
    if not isinstance(topics, list) or not topics:
        raise MalformedPayloadError("swap log has no topics")
    if str(topics[0]).lower() != SWAP_TOPIC0:
        raise MalformedPayloadError(f"swap log topic0 is not the Swap event: {topics[0]!r}")
    if "blockNumber" not in log:
        raise MalformedPayloadError("swap log has no blockNumber")
    block = parse_hex_quantity(log["blockNumber"], field_name="swap log blockNumber")
    raw_index = log.get("logIndex")
    log_index = (
        parse_hex_quantity(raw_index, field_name="swap log logIndex")
        if raw_index is not None
        else position
    )
    if "data" not in log:
        raise MalformedPayloadError(f"swap log {block} has no data")
    return ParsedLog(block=block, tick=parse_tick(log["data"]), log_index=log_index)


def validate_segment_logs(
    logs: Sequence[Mapping[str, Any]],
    low: int,
    high: int,
    pool: str = DEFAULT_POOL,
) -> None:
    """Reject a response whose logs do not all lie inside the requested segment.

    A log outside the segment means the gateway answered a different range
    than the one asked for, so the read is short and must not be accepted. A
    log from another pool means the address filter was ignored, which would
    mix another market into the volatility sample.
    """
    for position, log in enumerate(logs):
        if "blockNumber" not in log:
            raise MalformedPayloadError(
                f"segment [{low}, {high}]: log {position} has no blockNumber"
            )
        block = parse_hex_quantity(
            log["blockNumber"], field_name=f"segment [{low}, {high}] log blockNumber"
        )
        if not low <= block <= high:
            raise SegmentRangeError(
                f"segment [{low}, {high}]: log {position} is in block {block}, outside the segment"
            )
        address = log.get("address")
        if not isinstance(address, str) or address.lower() != pool.lower():
            raise MalformedPayloadError(
                f"segment [{low}, {high}]: log {position} is not from pool {pool}: {address!r}"
            )


def fetch_logs(
    client: RpcClient,
    low: int,
    high: int,
    pool: str = DEFAULT_POOL,
) -> list[Mapping[str, Any]]:
    """Read one segment of ``Swap`` logs and validate the answer."""
    result = client.call(
        "eth_getLogs",
        [
            {
                "address": pool,
                "fromBlock": to_hex_block(low),
                "toBlock": to_hex_block(high),
                "topics": [SWAP_TOPIC0],
            }
        ],
    )
    if not isinstance(result, list):
        raise MalformedPayloadError(
            f"segment [{low}, {high}]: eth_getLogs did not return a list"
        )
    logs: list[Mapping[str, Any]] = []
    for position, entry in enumerate(result):
        if not isinstance(entry, dict):
            raise MalformedPayloadError(
                f"segment [{low}, {high}]: log {position} is not an object"
            )
        logs.append(entry)
    validate_segment_logs(logs, low, high, pool)
    if len(logs) >= LOG_COUNT_WARN_THRESHOLD:
        raise SegmentTruncatedError(
            f"segment [{low}, {high}]: response carries {len(logs)} logs, at or above the "
            f"{LOG_COUNT_WARN_THRESHOLD}-log gateway cap, so it may be truncated"
        )
    return logs


def fetch_logs_with_retry(
    client: RpcClient,
    low: int,
    high: int,
    pool: str = DEFAULT_POOL,
    *,
    attempts: int = DEFAULT_ATTEMPTS,
    backoff: float = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
) -> list[Mapping[str, Any]]:
    """Read one segment, retrying transient failures with exponential backoff.

    Only :class:`RpcError` is retried. A malformed payload is permanent: a log
    outside the segment does not move into the segment by asking again.
    """
    if attempts < 1:
        raise ValueError("attempts must be at least 1")
    delay = backoff
    last_error: RpcError | None = None
    for attempt in range(1, attempts + 1):
        try:
            return fetch_logs(client, low, high, pool)
        except RpcError as exc:
            last_error = exc
            if attempt == attempts:
                break
            sleep(delay)
            delay *= 2
    raise RpcError(
        f"segment [{low}, {high}]: gave up after {attempts} attempts ({last_error})"
    ) from last_error


def fetch_block_timestamp(
    client: RpcClient,
    number: int,
) -> int:
    """Read the timestamp of one block."""
    result = client.call("eth_getBlockByNumber", [to_hex_block(number), False])
    if not isinstance(result, dict):
        raise MalformedPayloadError(
            f"block {number}: unexpected payload type {type(result).__name__}"
        )
    if "timestamp" not in result:
        raise MalformedPayloadError(f"block {number}: payload has no timestamp")
    timestamp = parse_hex_quantity(result["timestamp"], field_name=f"block {number} timestamp")
    raw_number = result.get("number")
    if raw_number is not None:
        reported = parse_hex_quantity(raw_number, field_name=f"block {number} number")
        if reported != number:
            raise MalformedPayloadError(f"block {number}: RPC returned block {reported}")
    return timestamp


def fetch_block_timestamp_with_retry(
    client: RpcClient,
    number: int,
    *,
    attempts: int = DEFAULT_ATTEMPTS,
    backoff: float = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
) -> int:
    """Read one block timestamp, retrying transient failures."""
    if attempts < 1:
        raise ValueError("attempts must be at least 1")
    delay = backoff
    last_error: RpcError | None = None
    for attempt in range(1, attempts + 1):
        try:
            return fetch_block_timestamp(client, number)
        except RpcError as exc:
            last_error = exc
            if attempt == attempts:
                break
            sleep(delay)
            delay *= 2
    raise RpcError(
        f"block {number}: gave up after {attempts} attempts ({last_error})"
    ) from last_error


def parse_swap_logs(
    client: RpcClient,
    logs: Sequence[Mapping[str, Any]],
    *,
    cache: dict[int, int] | None = None,
    attempts: int = DEFAULT_ATTEMPTS,
    backoff: float = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
) -> list[SwapRecord]:
    """Turn raw logs into rows, resolving every distinct block timestamp once.

    A log marked as removed was reorged out of the chain, so it is left out
    of the sample instead of being priced as a swap that never happened.
    """
    records: list[SwapRecord] = []
    timestamps: dict[int, int] = {} if cache is None else cache
    for position, log in enumerate(logs):
        if log.get("removed") is True:
            continue
        parsed = parse_swap_log(log, position=position)
        timestamp = timestamps.get(parsed.block)
        if timestamp is None:
            timestamp = fetch_block_timestamp_with_retry(
                client, parsed.block, attempts=attempts, backoff=backoff, sleep=sleep
            )
            timestamps[parsed.block] = timestamp
        records.append(
            SwapRecord(
                block=parsed.block,
                tick=parsed.tick,
                timestamp=timestamp,
                log_index=parsed.log_index,
            )
        )
    return records


def segment_ranges(start: int, end: int, size: int = SEGMENT_BLOCKS) -> list[tuple[int, int]]:
    """Split ``[start, end]`` into segments of at most ``size`` blocks."""
    if size < 1:
        raise ValueError("segment size must be at least 1")
    ranges: list[tuple[int, int]] = []
    low = start
    while low <= end:
        high = min(low + size - 1, end)
        ranges.append((low, high))
        low = high + 1
    return ranges


def fetch_swaps(
    client: RpcClient,
    start: int,
    end: int,
    pool: str = DEFAULT_POOL,
    *,
    cache: dict[int, int] | None = None,
    segment_blocks: int = SEGMENT_BLOCKS,
    attempts: int = DEFAULT_ATTEMPTS,
    backoff: float = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
    on_failure: Callable[[tuple[int, int], Exception], None] | None = None,
) -> tuple[list[SwapRecord], FetchSummary]:
    """Fetch every ``Swap`` log of ``[start, end]``, segment by segment.

    A segment that stays unreadable is counted as failed and left out of the
    returned records; the other segments are still fetched.
    """
    validate_range(start, end)
    records: list[SwapRecord] = []
    summary = FetchSummary()
    timestamps: dict[int, int] = {} if cache is None else cache
    for low, high in segment_ranges(start, end, segment_blocks):
        try:
            logs = fetch_logs_with_retry(
                client,
                low,
                high,
                pool,
                attempts=attempts,
                backoff=backoff,
                sleep=sleep,
            )
            segment_records = parse_swap_logs(
                client,
                logs,
                cache=timestamps,
                attempts=attempts,
                backoff=backoff,
                sleep=sleep,
            )
        except FetchError as exc:
            summary.failed += 1
            if on_failure is not None:
                on_failure((low, high), exc)
            continue
        records.extend(segment_records)
        summary.fetched += len(segment_records)
    return records, summary


def read_swaps(path: Path, output_format: str = "csv") -> list[SwapRecord]:
    """Read an existing output file into records.

    Rows that do not match the schema are dropped so a half-written file can
    still be resumed; a foreign header is an error, because rewriting it would
    silently discard data.
    """
    if output_format not in FORMATS:
        raise OutputFormatError(f"unknown output format: {output_format!r}")
    if not path.exists():
        return []
    if output_format == "jsonl":
        return _read_jsonl(path)
    return _read_csv(path)


def _read_csv(path: Path) -> list[SwapRecord]:
    with path.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.reader(handle))
    if not rows:
        return []
    header = [cell.strip() for cell in rows[0]]
    if header != list(CSV_COLUMNS):
        raise CsvFormatError(
            f"{path}: expected header {','.join(CSV_COLUMNS)}, got {','.join(header)}"
        )
    records: list[SwapRecord] = []
    for row in rows[1:]:
        if not row or all(not cell.strip() for cell in row):
            continue
        if len(row) != len(CSV_COLUMNS):
            continue
        try:
            block = int(row[0].strip())
            tick = int(row[1].strip())
            timestamp = int(row[2].strip())
        except ValueError:
            continue
        if block < 0 or timestamp < 0:
            continue
        records.append(SwapRecord(block=block, tick=tick, timestamp=timestamp))
    return records


def _read_jsonl(path: Path) -> list[SwapRecord]:
    records: list[SwapRecord] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            text = line.strip()
            if not text:
                continue
            if not text.startswith("{"):
                # A CSV file read as JSONL would look empty and be overwritten.
                raise CsvFormatError(f"{path}: expected one JSON object per line")
            try:
                payload = json.loads(text)
            except json.JSONDecodeError:
                continue
            if not isinstance(payload, dict):
                continue
            try:
                block = parse_jsonl_int(payload["block"])
                tick = parse_jsonl_int(payload["tick"])
                timestamp = parse_jsonl_int(payload["timestamp"])
            except (KeyError, TypeError, ValueError):
                continue
            if block < 0 or timestamp < 0:
                continue
            records.append(SwapRecord(block=block, tick=tick, timestamp=timestamp))
    return records


def parse_jsonl_int(value: Any) -> int:
    """Read one integer field of a JSONL row.

    A float is rejected instead of truncated, so a fractional value never
    enters the sample as a rounded integer.
    """
    if isinstance(value, bool):
        raise TypeError(f"not an integer: {value!r}")
    if isinstance(value, float):
        raise ValueError(f"not an integer: {value!r}")
    return int(value)


def write_swaps(
    path: Path,
    records: Iterable[SwapRecord],
    output_format: str = "csv",
) -> int:
    """Write the records, ordered by block number and log index.

    The file is replaced atomically so an interrupted run cannot leave a
    half-written file behind.
    """
    if output_format not in FORMATS:
        raise OutputFormatError(f"unknown output format: {output_format!r}")
    ordered = sorted(records, key=lambda record: (record.block, record.log_index))
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(path.name + ".tmp")
    if output_format == "jsonl":
        with tmp_path.open("w", encoding="utf-8") as handle:
            for record in ordered:
                handle.write(
                    json.dumps(
                        {
                            "block": record.block,
                            "tick": record.tick,
                            "timestamp": record.timestamp,
                        }
                    )
                    + "\n"
                )
    else:
        with tmp_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.writer(handle, lineterminator="\n")
            writer.writerow(CSV_COLUMNS)
            for record in ordered:
                writer.writerow((record.block, record.tick, record.timestamp))
    tmp_path.replace(path)
    return len(ordered)


def resume_start(existing: Sequence[SwapRecord], start: int) -> int:
    """Return the first block that still has to be fetched.

    Every block up to the highest recorded one counts as covered, so a re-run
    of the same range fetches nothing and adds no duplicate rows.
    """
    if not existing:
        return start
    return max(start, max(record.block for record in existing) + 1)


def build_parser() -> argparse.ArgumentParser:
    """Build the command line parser."""
    parser = argparse.ArgumentParser(
        description="Fetch Uniswap V3 Swap event logs into a file of block, tick and timestamp."
    )
    parser.add_argument(
        "--rpc",
        default=DEFAULT_RPC_URL,
        help=f"JSON-RPC endpoint (default: {DEFAULT_RPC_URL})",
    )
    parser.add_argument(
        "--pool",
        default=DEFAULT_POOL,
        help=f"pool address (default: {DEFAULT_POOL})",
    )
    parser.add_argument(
        "--from",
        dest="from_block",
        type=int,
        required=True,
        help="first block of the range, inclusive",
    )
    parser.add_argument(
        "--to",
        dest="to_block",
        type=int,
        required=True,
        help="last block of the range, inclusive",
    )
    parser.add_argument(
        "--out",
        default=DEFAULT_OUT_PATH,
        help=f"output file path (default: {DEFAULT_OUT_PATH})",
    )
    parser.add_argument(
        "--format",
        dest="output_format",
        choices=FORMATS,
        default="csv",
        help="output file format (default: csv)",
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    client: RpcClient | None = None,
    sleep: Callable[[float], None] = time.sleep,
    stdout: Any = None,
) -> int:
    """Run the fetcher once and report the fetched/skipped/failed counts.

    A failed segment is a permanent hole under the resume rule, so the exit
    code is 1 and the output file must not be treated as complete.
    """
    args = build_parser().parse_args(argv)
    out = stdout if stdout is not None else sys.stdout
    try:
        validate_range(args.from_block, args.to_block)
        validate_pool(args.pool)
    except FetchError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    path = Path(args.out)
    try:
        existing = read_swaps(path, args.output_format)
    except CsvFormatError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    start = resume_start(existing, args.from_block)
    rpc_client = client if client is not None else RpcClient(args.rpc)

    def report_failure(segment: tuple[int, int], error: Exception) -> None:
        print(f"segment {segment[0]}-{segment[1]} failed: {error}", file=sys.stderr)

    if start > args.to_block:
        records: list[SwapRecord] = []
        summary = FetchSummary()
    else:
        records, summary = fetch_swaps(
            rpc_client,
            start,
            args.to_block,
            args.pool,
            sleep=sleep,
            on_failure=report_failure,
        )
    write_swaps(path, list(existing) + records, args.output_format)
    print(
        f"fetched={summary.fetched} skipped={len(existing)} failed={summary.failed}",
        file=out,
    )
    return 1 if summary.failed > 0 else 0


if __name__ == "__main__":
    raise SystemExit(main())
