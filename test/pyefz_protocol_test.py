import io
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "packages/pyefz/src"))
from pyefz import BadConfig, ProtocolError
from pyefz.protocol import decode_bytes, decode_json, encode_bytes, frame, read_frame


class Fragmented(io.BytesIO):
    def read(self, size=-1):
        return super().read(min(size, 3))


class ProtocolTests(unittest.TestCase):
    def test_binary_roundtrip_and_fragmented_frames(self):
        for data in (b"", bytes(range(256)), b"\x00\n\r\xff" * 1000):
            value = {"bytes": encode_bytes(data), "string": '[]"\\'}
            decoded = read_frame(Fragmented(frame(value)))
            self.assertEqual(decode_bytes(decoded["bytes"]), data)

    def test_length_and_truncation(self):
        for wire in (struct.pack("!I", 0), struct.pack("!I", 8388609), b"\x00\x00", b"\x00\x00\x00\x04{}"):
            with self.assertRaises((ProtocolError, EOFError)):
                read_frame(io.BytesIO(wire))

    def test_json_bounds_and_duplicate_keys(self):
        for data in (b'{"a":1,"a":2}', b"[" * 25 + b"0" + b"]" * 25,
                     b'{"x":NaN}', b"\xff"):
            with self.assertRaises(ProtocolError):
                decode_json(data)
        self.assertEqual(decode_json(b'{"literal":"[[[[\\\""}'), {"literal": '[[[["'})

    def test_explicit_bytes_and_canonical_base64(self):
        for value in ({"base64": "AA==", "other": 1}, {"base64": "AB=="}, {"base64": "!"}, "text"):
            with self.assertRaises(ProtocolError):
                decode_bytes(value)
        with self.assertRaises(BadConfig):
            encode_bytes("not bytes")


if __name__ == "__main__":
    unittest.main()
