"""Read EFZ's portable summaries and authoritative raw inputs without a provider."""
from dataclasses import dataclass
import hashlib
from pathlib import Path

from .errors import BadConfig, StorageError
from .protocol import MAX_INPUT, decode_json


def read_input(path, *, max_input_bytes=MAX_INPUT, sha256=None):
    if type(max_input_bytes) is not int or not 0 <= max_input_bytes <= MAX_INPUT:
        raise BadConfig("max_input_bytes must be in 0..1048576")
    try:
        with Path(path).open("rb") as stream:
            data = stream.read(max_input_bytes + 1)
    except OSError as exc:
        raise StorageError(str(exc)) from exc
    if len(data) > max_input_bytes:
        raise StorageError("Saved input exceeds max_input_bytes")
    if sha256 is not None and hashlib.sha256(data).hexdigest() != sha256:
        raise StorageError("Saved input checksum mismatch")
    return data


def load_summary(out):
    """Read report.json only; diagnostic report.term is never decoded by Python."""
    try:
        with (Path(out) / "report.json").open("rb") as stream:
            data = stream.read(65537)
    except OSError as exc:
        raise StorageError(str(exc)) from exc
    if len(data) > 65536:
        raise StorageError("Summary exceeds 64 KiB")
    value = decode_json(data)
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise StorageError("Unsupported summary schema")
    return value


@dataclass(frozen=True)
class MutationResult:
    status: str
    data: object = None
    recipe: object = None
    reason: object = None
    input_sha256: object = None
    output_sha256: object = None
    error: object = None

    @property
    def changed(self):
        return self.status == "changed"


@dataclass(frozen=True)
class SavedResults:
    summary: object
    findings: list
    next_offset: object
