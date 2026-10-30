import concurrent.futures
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/pyefz/src"))
from pyefz import (BadConfig, Cancelled, Client, ProtocolError, ProviderFailure, ProviderTimeout,
                   RequestTimeout, StorageError, load_summary, read_input)


class FakeClient(Client):
    hang_close = False

    def _launch(self, command):
        self.command = command
        env = dict(os.environ)
        if self.hang_close:
            env["PYEFZ_FAKE_CLOSE_HANG"] = "1"
        return subprocess.Popen([sys.executable, "-u", str(ROOT / "test/pyefz_fake_runtime.py")],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True, bufsize=0, env=env)


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        ebin = self.root / "_build/default/lib/efz/ebin"
        ebin.mkdir(parents=True)
        (ebin / "efz_control.beam").touch()

    def tearDown(self):
        self.tmp.cleanup()

    def client(self, **options):
        return FakeClient(self.root, runtime=sys.executable, **options)

    def test_binary_mutation_and_typed_errors(self):
        with self.client() as client:
            data = bytes(range(256))
            result = client.mutate(data, seed=(1, 2, 3))
            self.assertTrue(result.changed)
            self.assertEqual(result.data, b"\x01" + data[1:])
            self.assertEqual(result.recipe["seed"], [1, 2, 3])
            self.assertFalse(client.mutate(b"").changed)
            for provider, error in (("missing", ProviderFailure), ("bad_config", BadConfig),
                                    ("timeout", RequestTimeout), ("provider_timeout", ProviderTimeout),
                                    ("cancelled", Cancelled)):
                with self.assertRaises(error):
                    client.mutate(data, provider=provider)
            with self.assertRaises(ProtocolError):
                client.mutate(data, provider="lie")
            self.assertNotIn("-eval", client.command)
        self.assertIsNotNone(client._process.poll())
        client.close()

    def test_batch_per_item_seeds_and_limits(self):
        with self.client() as client:
            results = client.mutate_batch([b"A", b"B"], seeds=[(1, 2, 3), (4, 5, 6)])
            self.assertEqual([r.recipe["seed"] for r in results], [[1, 2, 3], [4, 5, 6]])
            for inputs, options in (([b"A"] * 65, {}), ([b"A"], {"seeds": []}),
                                    ([b"A"] * 3, {"max_input_bytes": 1048576})):
                with self.assertRaises(BadConfig):
                    client.mutate_batch(inputs, **options)
            failures = client.mutate_batch([b"A", b"B"], provider="missing")
            self.assertTrue(all(isinstance(result.error, ProviderFailure) for result in failures))

    def test_wait_does_not_block_stop_and_timeout_is_reusable(self):
        with self.client() as client:
            campaign = client.start({"target": "fixture", "seeds": [b"a"]}, out=self.root / "out")
            with self.assertRaises(RequestTimeout):
                campaign.await_result(0)
            started = threading.Event()
            def wait():
                started.set()
                return campaign.await_result()
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                waiting = pool.submit(wait)
                started.wait(1)
                self.assertEqual(campaign.stats()["stats"]["executions"], 3)
                campaign.stop()
                self.assertEqual(waiting.result(timeout=2)["status"], "stopped_by_user")

    def test_pending_wait_is_canceled_and_owned_process_reaped(self):
        client = self.client()
        client.start({"target": "fixture"})
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            pending = pool.submit(client.mutate, b"a", provider="hang", timeout=None)
            client.close()
            with self.assertRaises(Cancelled):
                pending.result(timeout=2)
        self.assertIsNotNone(client._process.poll())

    def test_force_cleanup_after_close_deadline(self):
        class HungClient(FakeClient):
            hang_close = True
        client = HungClient(self.root, runtime=sys.executable, close_timeout=.1)
        with self.assertRaises(RequestTimeout):
            client.close()
        self.assertIsNotNone(client._process.poll())
        client.close()

    def test_summary_and_raw_bytes_need_no_provider(self):
        raw = self.root / "artifact.input"
        raw.write_bytes(bytes(range(256)))
        digest = hashlib.sha256(raw.read_bytes()).hexdigest()
        self.assertEqual(read_input(raw, sha256=digest), raw.read_bytes())
        with self.assertRaises(StorageError):
            read_input(raw, max_input_bytes=1)
        with self.assertRaises(StorageError):
            read_input(raw, sha256="0" * 64)
        (self.root / "report.json").write_text('{"schema_version":1,"status":"completed"}')
        (self.root / "report.term").write_bytes(b"not trusted or decoded")
        self.assertEqual(load_summary(self.root)["status"], "completed")


if __name__ == "__main__":
    unittest.main()
