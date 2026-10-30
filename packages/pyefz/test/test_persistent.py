import os
from pathlib import Path
import unittest

from pyefz import Cancelled, Client
from pyefz.protocol import decode_bytes, encode_bytes


class BinaryContractTests(unittest.TestCase):
    def test_binary_json_encoding_preserves_every_byte(self):
        raw = bytes(range(256)) + b"\x00\xff\xc3("
        self.assertEqual(raw, decode_bytes(encode_bytes(raw), len(raw)))


@unittest.skipUnless(os.environ.get("PYEFZ_CORE_PATH"), "set PYEFZ_CORE_PATH for real core IPC")
class PersistentClientTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(os.environ.get("PYEFZ_EFZ_ROOT", Path(__file__).resolve().parents[3])).resolve()
        self.core = Path(os.environ["PYEFZ_CORE_PATH"]).resolve()
        self.client = Client(self.root, runtime=os.environ.get("PYEFZ_RUNTIME", "erl"))

    def tearDown(self):
        pid = self.client.pid
        self.client.close()
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def provider(self):
        return {"mode": "erlamsa", "core_path": str(self.core),
                "transport": "persistent", "max_requests": 10000,
                "timeout": 5000, "on_skip": "skip",
                "options": {"profile": "bytes"}}

    def test_repeated_mutation_and_batch_share_sdk_session(self):
        provider = self.provider()
        first = self.client.mutate(b"sdk\x00\xff", provider=provider,
            seed=(17, 23, 41), request={"operator": "byte_flip"})
        second = self.client.mutate(b"sdk\x00\xff", provider=provider,
            seed=(17, 23, 41), request={"operator": "byte_flip"})
        self.assertEqual((first.status, first.data, first.recipe),
                         (second.status, second.data, second.recipe))
        self.assertEqual(first.runtime["vm_starts"], 1)
        self.assertEqual(second.runtime["completed_requests"], 2)
        batch = self.client.mutate_batch([b"one\x00", bytes(range(32))],
            provider=provider, seeds=[(31, 37, 41), (43, 47, 53)],
            requests=[{"operator": "byte_flip"}, {"operator": "byte_insert"}])
        self.assertEqual(2, len(batch))
        self.assertTrue(all(item.status in ("changed", "skipped", "error") for item in batch))
        self.assertEqual([3, 4], [item.runtime["completed_requests"] for item in batch])
        self.assertTrue(all(item.runtime["vm_starts"] == 1 for item in batch))

    def test_async_cancel_is_correlated_and_client_remains_usable(self):
        provider = self.provider()
        payload = bytes(range(256)) * 256
        count = 32
        call = self.client.mutate_batch_async([payload] * count, provider=provider,
            seeds=[(59 + i, 61 + i, 67 + i) for i in range(count)],
            requests=[{"operator": "byte_flip"} for _ in range(count)],
            max_input_bytes=65536, timeout=10)
        cancellation = call.cancel(timeout=5)
        self.assertIn(cancellation.get("status"), ("cancelling", "not_running"))
        results = call.result(timeout=10)
        self.assertTrue(any(isinstance(item.error, Cancelled) for item in results))
        next_result = self.client.mutate(b"after cancellation", provider=provider,
            seed=(71, 73, 79), request={"operator": "byte_flip"})
        self.assertIn(next_result.status, ("changed", "skipped"))
        self.assertEqual(next_result.runtime["transport"], "persistent")
        self.assertEqual({}, self.client._pending)


if __name__ == "__main__":
    unittest.main()
