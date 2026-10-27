"""Opt-in real local-runtime checks. No remote service is contacted."""
import os
import concurrent.futures
from pathlib import Path
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/pyefz/src"))
from pyefz import BadConfig, Cancelled, Client, ProviderTimeout, load_summary


@unittest.skipUnless(os.environ.get("PYEFZ_EFZ_ROOT"), "set PYEFZ_EFZ_ROOT for compiled-runtime checks")
class RuntimeTests(unittest.TestCase):
    def client(self):
        paths = list(filter(None, os.environ.get("PYEFZ_CODE_PATHS", "").split(os.pathsep)))
        return Client(os.environ["PYEFZ_EFZ_ROOT"], runtime=os.environ.get("PYEFZ_RUNTIME", "erl"),
                      code_paths=paths, profile=os.environ.get("PYEFZ_PROFILE", "default"))

    def test_native_binary_and_rejection(self):
        with self.client() as client:
            data = bytes(range(256))
            result = client.mutate(data, seed=(17, 23, 41))
            repeat = client.mutate(data, seed=(17, 23, 41))
            self.assertEqual((result.status, result.data), (repeat.status, repeat.data))
            if result.changed:
                self.assertNotEqual(data, result.data)
            with self.assertRaises(BadConfig):
                client.start({"target": "fixture", "untrusted_module": "never_intern_me"})

    @unittest.skipUnless(os.environ.get("PYEFZ_CORE_PATH"), "set PYEFZ_CORE_PATH for Erlamsa core checks")
    def test_core_batch(self):
        with self.client() as client:
            provider = {"mode": "erlamsa", "core_path": os.environ["PYEFZ_CORE_PATH"],
                        "on_skip": "skip", "options": {"profile": "bytes"}}
            results = client.mutate_batch([b"a\x00b", b"c\xffd"], provider=provider,
                seeds=[(1, 2, 3), (4, 5, 6)], requests=[{"operator": "byte_flip"}] * 2)
            self.assertTrue(all(r.changed for r in results), results)
            repeated = client.mutate(b"a\x00b", provider=provider, seed=(1, 2, 3),
                                    request={"operator": "byte_flip"})
            self.assertEqual(repeated.data, results[0].data)
            with self.assertRaises(BadConfig):
                client.mutate(b"a", provider={"mode": "erlamsa", "core_path": "/missing/erlamsa"}, seed=(1, 2, 3))
            with self.assertRaises(ProviderTimeout):
                client.mutate(b"a", provider=dict(provider, timeout=1), seed=(1, 2, 3))

    @unittest.skipUnless(os.environ.get("PYEFZ_ARTIFACTS"), "set PYEFZ_ARTIFACTS for campaign checks")
    def test_campaign_and_saved_results(self):
        with tempfile.TemporaryDirectory(prefix="pyefz-e2e-") as out:
            with self.client() as client:
                campaign = client.start({"target": os.environ.get("PYEFZ_TARGET", "efz_example_target"),
                    "artifacts": os.environ["PYEFZ_ARTIFACTS"], "seeds": [b"a", b"BOOM!"],
                    "mutation_mode": "staged", "max_iterations": "infinity",
                    "mutation": {"seed": [17, 23, 41], "stages": ["havoc"]}}, out=out)
                self.assertIn("stats", campaign.stats())
                campaign.stop()
                report = campaign.await_result(10)
                self.assertEqual(report["status"], "stopped_by_user")
                self.assertEqual(load_summary(out)["status"], "stopped_by_user")
                saved = client.results()
                self.assertIsNotNone(saved.summary)

    @unittest.skipUnless(os.environ.get("PYEFZ_ARTIFACTS") and os.environ.get("PYEFZ_CORE_PATH"),
                         "set PYEFZ_ARTIFACTS and PYEFZ_CORE_PATH for provider campaign checks")
    def test_provider_campaign_stop_and_report(self):
        with tempfile.TemporaryDirectory(prefix="pyefz-provider-e2e-") as out:
            with self.client() as client:
                campaign = client.start({"target": os.environ.get("PYEFZ_TARGET", "efz_example_target"),
                    "artifacts": os.environ["PYEFZ_ARTIFACTS"], "seeds": [b"ABC"],
                    "mutation_mode": "staged", "max_iterations": "infinity",
                    "mutation_provider": {"mode": "hybrid", "core_path": os.environ["PYEFZ_CORE_PATH"],
                        "weights": [["native", 0], ["erlamsa", 1]], "on_skip": "skip",
                        "limits": {"operations": 1}, "options": {"profile": "bytes",
                            "operators": [["byte_flip", 1]], "patterns": [["once", 1]]}},
                    "mutation": {"seed": [17, 23, 41], "stages": ["havoc"]}}, out=out)
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if campaign.stats()["stats"].get("executions", 0) >= 2:
                        break
                    time.sleep(.05)
                campaign.request_stop()
                report = campaign.await_result(10)
                self.assertEqual(report["status"], "stopped_by_user")
                self.assertGreaterEqual(report["stats"]["executions"], 2)
                self.assertGreaterEqual(report["provider_stats"]["changed"], 2)
                self.assertEqual(report["provider_stats"]["errors"], 0)
                self.assertEqual(load_summary(out)["provider"]["mode"], "hybrid")

    @unittest.skipUnless(os.environ.get("PYEFZ_ARTIFACTS") and
                         os.environ.get("PYEFZ_TARGET", "efz_example_target") == "efz_example_target",
                         "set PYEFZ_ARTIFACTS to the synthetic simple_parser fixture")
    def test_saved_raw_replay_in_fresh_client(self):
        # FF is a deliberate synthetic exception, not a third-party defect.
        with tempfile.TemporaryDirectory(prefix="pyefz-replay-e2e-") as out:
            with self.client() as client:
                campaign = client.start({"target": "efz_example_target",
                    "artifacts": os.environ["PYEFZ_ARTIFACTS"], "seeds": [b"\xff"],
                    "mutation_mode": "staged", "max_iterations": 0}, out=out)
                campaign.await_result(10)
                representative = client.results().findings[0]["representatives"][0]
            with self.client() as replay_client:
                result = replay_client.raw_replay(representative["input"], target="efz_example_target",
                    artifacts=os.environ["PYEFZ_ARTIFACTS"], expect=representative["expect"])
                self.assertEqual(result["status"], "reproduced")
                self.assertEqual(result["target_executions"], 1)
                self.assertEqual(result["input_sha256"], representative["input_sha256"])

    @unittest.skipUnless(os.environ.get("PYEFZ_CORE_PATH") and Path("/proc/self").exists(),
                         "set PYEFZ_CORE_PATH on Linux for actual provider cancellation")
    def test_close_cancels_active_provider_and_reaps_descendants(self):
        def descendants(pid):
            # task/*/children is absent on kernels without CHECKPOINT_RESTORE.
            # PPid from stat is available independently of that optional file.
            parents = {}
            for path in Path("/proc").iterdir():
                if path.name.isdecimal():
                    try:
                        fields = (path / "stat").read_text().rsplit(")", 1)[1].split()
                        parents.setdefault(int(fields[1]), set()).add(int(path.name))
                    except (OSError, ValueError, IndexError):
                        continue
            pending, found = [pid], set()
            while pending:
                children = parents.get(pending.pop(), set()) - found
                found.update(children)
                pending.extend(children)
            return found

        client = self.client()
        provider = {"mode": "erlamsa", "core_path": os.environ["PYEFZ_CORE_PATH"],
                    "timeout": 60000, "options": {"profile": "bytes"}}
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                pending = pool.submit(client.mutate, b"ABC", provider=provider,
                                      seed=(17, 23, 41), timeout=None)
                deadline = time.monotonic() + 5
                observed = set()
                while time.monotonic() < deadline and not pending.done():
                    for pid in descendants(client.pid):
                        try:
                            command = Path(f"/proc/{pid}/cmdline").read_bytes()
                        except OSError:
                            continue
                        if b"efz_mutation_launcher.py" in command:
                            observed = {pid} | descendants(pid)
                            break
                    if observed:
                        break
                    time.sleep(.001)
                if not observed and pending.done():
                    self.fail(f"provider finished before bootstrap was observed: {pending.result()}")
                self.assertTrue(observed, "observe a real provider bootstrap before cancellation")
                client.close()
                with self.assertRaises(Cancelled):
                    pending.result(timeout=3)
                deadline = time.monotonic() + 3
                while any(Path(f"/proc/{pid}").exists() for pid in observed) and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertFalse([pid for pid in observed if Path(f"/proc/{pid}").exists()])
                self.assertIsNotNone(client._process.poll())
                client.close()
        finally:
            client.close()


if __name__ == "__main__":
    unittest.main()
