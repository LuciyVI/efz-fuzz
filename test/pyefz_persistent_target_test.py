"""Real local control transport, persistent target VM and exact sequence replay."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

from pyefz import Client


ROOT = Path(__file__).resolve().parents[1]
EBIN = ROOT / "_build/default/lib/efz/ebin"


class PersistentTargetSDKTests(unittest.TestCase):
    def test_continuous_stop_and_corpus_restart(self):
        if not (EBIN / "efz_control.beam").is_file():
            self.skipTest("Run rebar3 compile first")
        with tempfile.TemporaryDirectory(prefix="efz-persistent-restart-") as temporary:
            directory = Path(temporary)
            artifacts = directory / "artifacts"
            prepared = subprocess.run(
                ["escript", "scripts/prepare_stateful.escript", str(artifacts)],
                cwd=ROOT, capture_output=True, text=True, timeout=30, check=False)
            self.assertEqual(0, prepared.returncode, prepared.stderr)
            config = {
                "target": "efz_persistent_fixture", "artifacts": str(artifacts),
                "seeds": [b"arm", b"fire"], "corpus_dir": str(directory / "corpus"),
                "mutation_mode": "staged", "max_iterations": "infinity",
                "mutation": {"seed": [17, 23, 41], "stages": ["havoc"]},
                "execution": {"mode": "persistent_vm", "state_policy": "accumulate"},
            }
            with Client(ROOT) as client:
                campaign = client.start(config, out=directory / "first")
                deadline = time.monotonic() + 8
                while time.monotonic() < deadline:
                    if campaign.stats()["stats"]["executions"] >= 3:
                        break
                    time.sleep(.05)
                else:
                    self.fail("continuous campaign did not execute three inputs")
                campaign.request_stop()
                first = campaign.await_result(10)
                self.assertEqual("stopped_by_user", first["status"])
                self.assertEqual(1, first["target_session"]["vm_starts"])
                self.assertTrue(first["sequence_journal"]["complete"])
                self.assertTrue(list((directory / "corpus").glob("*/input")))
            restart = dict(config, seeds=[], max_iterations=2)
            with Client(ROOT) as client:
                resumed = client.start(restart, out=directory / "restart")
                second = resumed.await_result(10)
                self.assertEqual("completed", second["status"])
                self.assertEqual(2, second["stats"]["executions"])
                self.assertEqual(1, second["target_session"]["vm_starts"])
                self.assertTrue(second["sequence_journal"]["complete"])
                self.assertNotEqual(first["sequence_journal"]["epoch"],
                                    second["sequence_journal"]["epoch"])

    @unittest.skipUnless(os.environ.get("PYEFZ_CORE_PATH"),
                         "set PYEFZ_CORE_PATH for the pinned Erlamsa core")
    def test_mutation_modes_keep_one_target_epoch(self):
        if not (EBIN / "efz_control.beam").is_file():
            self.skipTest("Run rebar3 compile first")
        with tempfile.TemporaryDirectory(prefix="efz-provider-target-") as temporary:
            directory = Path(temporary)
            artifacts = directory / "artifacts"
            prepared = subprocess.run(
                ["escript", "scripts/prepare_stateful.escript", str(artifacts)],
                cwd=ROOT, capture_output=True, text=True, timeout=30, check=False)
            self.assertEqual(0, prepared.returncode, prepared.stderr)
            for mode, transport in (("native", None), ("erlamsa", "disposable"),
                                    ("erlamsa", "persistent"), ("hybrid", "persistent")):
                with self.subTest(mode=mode, transport=transport), Client(ROOT) as client:
                    config = {
                        "target": "efz_persistent_fixture", "artifacts": str(artifacts),
                        "seeds": [b"arm", b"fire"], "mutation_mode": "staged",
                        "mutation": {"seed": [17, 23, 41], "stages": ["havoc"]},
                        "max_iterations": 10,
                        "execution": {"mode": "persistent_vm", "state_policy": "accumulate"},
                    }
                    if mode != "native":
                        config["mutation_provider"] = {
                            "mode": mode, "core_path": os.environ["PYEFZ_CORE_PATH"],
                            "transport": transport, "max_requests": 100,
                            "on_skip": "skip", "limits": {"operations": 1},
                            "options": {"profile": "bytes", "operators": [["byte_flip", 1]],
                                        "patterns": [["once", 1]]},
                        }
                        if mode == "hybrid":
                            config["mutation_provider"]["weights"] = [
                                ["native", 1], ["erlamsa", 1]]
                    campaign = client.start(config, out=directory / f"{mode}-{transport}")
                    report = campaign.await_result(30)
                    self.assertEqual("completed", report["status"])
                    self.assertEqual(1, report["target_session"]["vm_starts"])
                    self.assertEqual(12, report["sequence_journal"]["step"])
                    self.assertTrue(report["sequence_journal"]["complete"])
                    self.assertEqual(0, report["stats"]["infrastructure_failures"])
                    if mode != "native":
                        self.assertGreater(report["provider_stats"]["requests"], 0)
                        expected_starts = 1 if transport == "persistent" else 0
                        self.assertEqual(expected_starts,
                                         report["provider_stats"]["session"]["vm_starts"])

    def test_sequence_campaign_and_raw_prefix_replay(self):
        if not (EBIN / "efz_control.beam").is_file():
            self.skipTest("Run rebar3 compile first")
        with tempfile.TemporaryDirectory(prefix="efz-sequence-") as temporary:
            directory = Path(temporary)
            artifacts = directory / "artifacts"
            source = ROOT / "examples/stateful/efz_persistent_fixture.erl"
            expression = (
                "application:ensure_all_started(crypto),"
                f"{{ok,_}}=efz_instrument:compile(\"{source}\","
                f"#{{modules=>[efz_persistent_fixture],source_root=>\"{ROOT}\","
                f"outdir=>\"{artifacts}\"}}),halt(0)."
            )
            result = subprocess.run(["erl", "+S", "2:2", "-noshell", "-pa", str(EBIN),
                                     "-eval", expression], cwd=ROOT, capture_output=True,
                                    text=True, timeout=30, check=False)
            self.assertEqual(0, result.returncode, result.stderr)
            config = {
                "target": "efz_persistent_fixture", "artifacts": str(artifacts),
                "execution": {"mode": "persistent_vm", "state_policy": "accumulate"},
                "timeout": 3000,
                "runtime_oracles": {"enabled": True,
                    "resources": {"enabled": False}, "hangs": {"enabled": False},
                    "stability": {"sequence": {"policy": "deferred", "repeats": 2,
                                               "max_calls": 6, "max_elapsed_ms": 30000}}},
            }
            with Client(ROOT) as client:
                campaign = client.start_sequence(config, [b"arm", b"fire", b"fire"],
                                                 out=directory / "out")
                report = campaign.await_result(30)
                self.assertEqual("completed", report["status"])
                self.assertEqual(3, report["sequence_journal"]["step"])
                self.assertTrue(report["sequence_journal"]["complete"])
                self.assertEqual(6, report["target_audit"]["calls"])
                self.assertGreater(report["history_sensitivity"]["changed"], 0)
                self.assertEqual("audited_sequence_steps",
                                 report["feature_stability"]["scope"])
                journal = report["sequence_journal"]["path"]
            with Client(ROOT) as client:
                replay = client.sequence_replay(journal, config=config, step=3)
                self.assertEqual("complete", replay["status"])
                steps = replay["steps"]
                self.assertEqual(3, len(steps))
                self.assertEqual(1, len({row["os_pid"] for row in steps}))
                self.assertEqual(1, len({row["driver"] for row in steps}))
                self.assertIn("armed_path", steps[-1]["outcome"])


if __name__ == "__main__":
    unittest.main()
