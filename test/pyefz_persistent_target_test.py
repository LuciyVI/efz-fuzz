"""Real local control transport, persistent target VM and exact sequence replay."""
from pathlib import Path
import subprocess
import tempfile
import unittest

from pyefz import Client


ROOT = Path(__file__).resolve().parents[1]
EBIN = ROOT / "_build/default/lib/efz/ebin"


class PersistentTargetSDKTests(unittest.TestCase):
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
