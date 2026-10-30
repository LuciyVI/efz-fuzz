"""Version-one length-prefixed JSON, with explicit byte envelopes."""
import base64
import json
import struct

from .errors import BadConfig, ProtocolError

MAX_FRAME = 8 * 1024 * 1024
MAX_INPUT = 1024 * 1024
MAX_BATCH_BYTES = 2 * MAX_INPUT
MAX_BATCH = 64


def encode_bytes(value):
    if not isinstance(value, (bytes, bytearray, memoryview)):
        raise BadConfig("Inputs must be bytes")
    return {"base64": base64.b64encode(value).decode("ascii")}


def decode_bytes(value, limit=MAX_INPUT):
    if not isinstance(value, dict) or set(value) != {"base64"}:
        raise ProtocolError("Invalid byte envelope")
    encoded = value["base64"]
    if not isinstance(encoded, str) or len(encoded) > 4 * ((limit + 2) // 3):
        raise ProtocolError("Byte envelope exceeds its limit")
    try:
        result = base64.b64decode(encoded, validate=True)
    except (ValueError, TypeError) as exc:
        raise ProtocolError("Invalid base64") from exc
    if len(result) > limit or base64.b64encode(result).decode("ascii") != encoded:
        raise ProtocolError("Invalid byte envelope")
    return result


def _depth(data):
    depth = nodes = 0
    quoted = escaped = False
    for char in data:
        if quoted:
            if escaped:
                escaped = False
            elif char == 92:
                escaped = True
            elif char == 34:
                quoted = False
        elif char == 34:
            quoted = True
        elif char in (91, 123):
            depth += 1
            nodes += 1
            if depth > 24 or nodes > 32768:
                raise ProtocolError("JSON complexity limit")
        elif char in (93, 125):
            depth -= 1
            if depth < 0:
                raise ProtocolError("Invalid JSON nesting")
    if depth or quoted:
        raise ProtocolError("Incomplete JSON")


def _object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ProtocolError("Duplicate JSON key")
        value[key] = item
    return value


def decode_json(data):
    if len(data) > MAX_FRAME:
        raise ProtocolError("Frame exceeds 8 MiB")
    _depth(data)
    try:
        return json.loads(data, object_pairs_hook=_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite number")))
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise ProtocolError("Invalid JSON") from exc


def frame(value):
    try:
        data = json.dumps(value, separators=(",", ":"), ensure_ascii=True,
                          allow_nan=False).encode("utf-8")
    except (ValueError, TypeError, RecursionError) as exc:
        raise BadConfig("Request must contain JSON-compatible data") from exc
    if not 0 < len(data) <= MAX_FRAME:
        raise BadConfig("Request exceeds 8 MiB")
    try:
        _depth(data)
    except ProtocolError as exc:
        raise BadConfig(str(exc)) from exc
    return struct.pack("!I", len(data)) + data


def read_exact(stream, size):
    chunks = bytearray()
    while len(chunks) < size:
        part = stream.read(size - len(chunks))
        if not part:
            if not chunks:
                raise EOFError("Runtime closed its protocol stream")
            raise ProtocolError("Truncated frame")
        chunks.extend(part)
    return bytes(chunks)


def read_frame(stream):
    size, = struct.unpack("!I", read_exact(stream, 4))
    if not 0 < size <= MAX_FRAME:
        raise ProtocolError("Invalid frame length")
    return decode_json(read_exact(stream, size))
