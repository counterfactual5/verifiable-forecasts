"""Fetch mainnet base fee history over a block range into a resumable CSV file.

The fetcher depends on the standard library only and is fully offline-testable:
the HTTP transport is an injected callable, so a test can replay scripted
JSON-RPC responses without touching the network.

Output schema (``data/basefee_history.csv``)::

    block,base_fee_wei,ts
    26000000,1043683754,1738000000

``base_fee_wei`` is the block's ``baseFeePerGas`` in wei, kept as an integer so
no rounding ever enters the value. ``ts`` is the block timestamp in unix
seconds. A block that cannot be read is skipped and counted, never guessed.

CLI::

    python src/fetch_fee_history.py --rpc https://ethereum-rpc.publicnode.com \
        --from 26000000 --to 26200000 --out data/basefee_history.csv
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

CSV_COLUMNS: tuple[str, str, str] = ("block", "base_fee_wei", "ts")
DEFAULT_RPC_URL = "https://ethereum-rpc.publicnode.com"
DEFAULT_OUT_PATH = "data/basefee_history.csv"
DEFAULT_ATTEMPTS = 3
DEFAULT_BACKOFF_SECONDS = 0.5
DEFAULT_TIMEOUT_SECONDS = 30.0


class FetchError(Exception):
    """Base class for every error this module raises on purpose."""


class InvalidRangeError(FetchError):
    """The requested block range cannot be fetched."""


class RpcError(FetchError):
    """A transient JSON-RPC or transport failure that is worth retrying."""


class MalformedBlockError(FetchError):
    """A block payload that cannot be read and will never become readable."""


class CsvFormatError(FetchError):
    """The existing output file does not use the expected header."""


@dataclass(frozen=True)
class BlockRecord:
    """One row of the history file."""

    block: int
    base_fee_wei: int
    timestamp: int


@dataclass
class FetchSummary:
    """Counters the CLI reports at the end of a run."""

    fetched: int = 0
    skipped: int = 0
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
        raise MalformedBlockError(f"{field_name} is not a quantity: {value!r}")
    if isinstance(value, int):
        if value < 0:
            raise MalformedBlockError(f"{field_name} is negative: {value!r}")
        return value
    if not isinstance(value, str):
        raise MalformedBlockError(f"{field_name} is not a quantity: {value!r}")
    text = value.strip()
    if text[:2].lower() == "0x":
        text = text[2:]
    if not text or any(char not in "0123456789abcdefABCDEF" for char in text):
        raise MalformedBlockError(f"{field_name} is not a hex quantity: {value!r}")
    return int(text, 16)


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


def fetch_block(client: RpcClient, number: int) -> BlockRecord:
    """Read one block's base fee and timestamp.

    Raises :class:`MalformedBlockError` when the payload cannot yield a base
    fee: a missing ``baseFeePerGas`` is never replaced by an invented value.
    """
    result = client.call("eth_getBlockByNumber", [to_hex_block(number), False])
    if result is None:
        raise MalformedBlockError(f"block {number}: RPC returned no block")
    if not isinstance(result, dict):
        raise MalformedBlockError(
            f"block {number}: unexpected payload type {type(result).__name__}"
        )
    if "baseFeePerGas" not in result:
        raise MalformedBlockError(f"block {number}: payload has no baseFeePerGas")
    base_fee = parse_hex_quantity(
        result["baseFeePerGas"], field_name=f"block {number} baseFeePerGas"
    )
    if "timestamp" not in result:
        raise MalformedBlockError(f"block {number}: payload has no timestamp")
    timestamp = parse_hex_quantity(result["timestamp"], field_name=f"block {number} timestamp")
    raw_number = result.get("number")
    if raw_number is not None:
        reported = parse_hex_quantity(raw_number, field_name=f"block {number} number")
        if reported != number:
            raise MalformedBlockError(f"block {number}: RPC returned block {reported}")
    return BlockRecord(block=number, base_fee_wei=base_fee, timestamp=timestamp)


def fetch_block_with_retry(
    client: RpcClient,
    number: int,
    *,
    attempts: int = DEFAULT_ATTEMPTS,
    backoff: float = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
) -> BlockRecord:
    """Fetch one block, retrying transient failures with exponential backoff.

    Only :class:`RpcError` is retried. A malformed payload is permanent: a
    missing ``baseFeePerGas`` does not become present by asking again.
    """
    if attempts < 1:
        raise ValueError("attempts must be at least 1")
    delay = backoff
    last_error: RpcError | None = None
    for attempt in range(1, attempts + 1):
        try:
            return fetch_block(client, number)
        except RpcError as exc:
            last_error = exc
            if attempt == attempts:
                break
            sleep(delay)
            delay *= 2
    raise RpcError(
        f"block {number}: gave up after {attempts} attempts ({last_error})"
    ) from last_error


def validate_range(start: int, end: int) -> None:
    """Reject ranges that cannot be fetched."""
    if start < 0:
        raise InvalidRangeError(f"--from must not be negative: {start}")
    if end < 0:
        raise InvalidRangeError(f"--to must not be negative: {end}")
    if start > end:
        raise InvalidRangeError(f"--from ({start}) must not be greater than --to ({end})")


def fetch_range(
    client: RpcClient,
    start: int,
    end: int,
    *,
    existing: Mapping[int, BlockRecord] | None = None,
    attempts: int = DEFAULT_ATTEMPTS,
    backoff: float = DEFAULT_BACKOFF_SECONDS,
    sleep: Callable[[float], None] = time.sleep,
    on_failure: Callable[[int, Exception], None] | None = None,
) -> tuple[list[BlockRecord], FetchSummary]:
    """Fetch every block of ``[start, end]`` that is not already known.

    Blocks already present in ``existing`` are skipped, blocks that stay
    unreadable are counted as failed and skipped, and both kinds of block are
    left out of the returned records.
    """
    validate_range(start, end)
    known: Mapping[int, BlockRecord] = existing or {}
    records: list[BlockRecord] = []
    summary = FetchSummary()
    for number in range(start, end + 1):
        if number in known:
            summary.skipped += 1
            continue
        try:
            record = fetch_block_with_retry(
                client, number, attempts=attempts, backoff=backoff, sleep=sleep
            )
        except FetchError as exc:
            summary.failed += 1
            if on_failure is not None:
                on_failure(number, exc)
            continue
        records.append(record)
        summary.fetched += 1
    return records, summary


def read_history(path: Path) -> dict[int, BlockRecord]:
    """Read an existing history file into ``block -> record``.

    Rows that do not match the schema are dropped so a half-written file can
    still be resumed; a foreign header is an error, because rewriting it would
    silently discard data.
    """
    if not path.exists():
        return {}
    with path.open("r", encoding="utf-8", newline="") as handle:
        rows = list(csv.reader(handle))
    if not rows:
        return {}
    header = [cell.strip() for cell in rows[0]]
    if header != list(CSV_COLUMNS):
        raise CsvFormatError(
            f"{path}: expected header {','.join(CSV_COLUMNS)}, got {','.join(header)}"
        )
    records: dict[int, BlockRecord] = {}
    for row in rows[1:]:
        if not row or all(not cell.strip() for cell in row):
            continue
        if len(row) != len(CSV_COLUMNS):
            continue
        try:
            block = int(row[0].strip())
            base_fee = int(row[1].strip())
            timestamp = int(row[2].strip())
        except ValueError:
            continue
        if block < 0 or base_fee < 0 or timestamp < 0:
            continue
        if block in records:
            # The first occurrence wins so repeated reads stay deterministic.
            continue
        records[block] = BlockRecord(block=block, base_fee_wei=base_fee, timestamp=timestamp)
    return records


def write_history(path: Path, records: Iterable[BlockRecord]) -> int:
    """Write the records as CSV, sorted by block number.

    The file is replaced atomically so an interrupted run cannot leave a
    half-written history behind. A repeated block number keeps its first
    record, so the output stays deterministic.
    """
    unique: dict[int, BlockRecord] = {}
    for record in records:
        unique.setdefault(record.block, record)
    ordered = [unique[block] for block in sorted(unique)]
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(path.name + ".tmp")
    with tmp_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(CSV_COLUMNS)
        for record in ordered:
            writer.writerow((record.block, record.base_fee_wei, record.timestamp))
    tmp_path.replace(path)
    return len(ordered)


def build_parser() -> argparse.ArgumentParser:
    """Build the command line parser."""
    parser = argparse.ArgumentParser(
        description="Fetch mainnet baseFeePerGas per block into a resumable CSV file."
    )
    parser.add_argument(
        "--rpc",
        default=DEFAULT_RPC_URL,
        help=f"JSON-RPC endpoint (default: {DEFAULT_RPC_URL})",
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
        help=f"output CSV path (default: {DEFAULT_OUT_PATH})",
    )
    return parser


def main(
    argv: Sequence[str] | None = None,
    *,
    client: RpcClient | None = None,
    sleep: Callable[[float], None] = time.sleep,
    stdout: Any = None,
) -> int:
    """Run the fetcher once and report the fetched/skipped/failed counts."""
    args = build_parser().parse_args(argv)
    out = stdout if stdout is not None else sys.stdout
    try:
        validate_range(args.from_block, args.to_block)
    except InvalidRangeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    path = Path(args.out)
    try:
        existing = read_history(path)
    except CsvFormatError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    rpc_client = client if client is not None else RpcClient(args.rpc)

    def report_failure(number: int, error: Exception) -> None:
        print(f"block {number} failed: {error}", file=sys.stderr)

    records, summary = fetch_range(
        rpc_client,
        args.from_block,
        args.to_block,
        existing=existing,
        sleep=sleep,
        on_failure=report_failure,
    )
    write_history(path, list(existing.values()) + records)
    print(
        f"fetched={summary.fetched} skipped={summary.skipped} failed={summary.failed}",
        file=out,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
