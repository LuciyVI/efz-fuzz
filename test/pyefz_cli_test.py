"""Real local CLI behavior, enabled with the same runtime switch as SDK E2E."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(os.environ.get("PYEFZ_EFZ_ROOT"), "set PYEFZ_EFZ_ROOT for compiled CLI checks")
class CLITests(unittest.TestCase):
    def invoke(self, script, *args, cwd):
        runtime = Path(os.environ.get("PYEFZ_RUNTIME", "erl"))
        executable = runtime.with_name("escript") if runtime.is_absolute() else Path("escript")
        return subprocess.run([str(executable), str(ROOT / script), *map(str, args)], cwd=cwd,
            capture_output=True, timeout=15, check=False)

    def test_native_help_and_binary_output_from_foreign_cwd(self):
        with tempfile.TemporaryDirectory(prefix="efz-cli-") as directory:
            root = Path(directory)
            original = bytes(range(256))
            (root / "input").write_bytes(original)
            result = self.invoke("scripts/mutate.escript", "--help", cwd=root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(b"--mutation-provider", result.stdout)
            result = self.invoke("scripts/mutate.escript", "--input", root / "input",
                "--out", root / "output", "--seed", "17,23,41", cwd=root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotEqual((root / "output").read_bytes(), original)
            repeated = self.invoke("scripts/mutate.escript", "--input", root / "input",
                "--out", root / "output", "--seed", "17,23,41", cwd=root)
            self.assertNotEqual(repeated.returncode, 0)

    @unittest.skipUnless(os.environ.get("PYEFZ_CORE_PATH"), "set PYEFZ_CORE_PATH for actual core CLI")
    def test_provider_generation_and_identity_mismatch(self):
        with tempfile.TemporaryDirectory(prefix="efz-provider-cli-") as directory:
            root = Path(directory)
            setup = self.invoke("test/efz_provider_cli_fixture.escript", root,
                                os.environ["PYEFZ_CORE_PATH"], cwd=root)
            self.assertEqual(setup.returncode, 0, setup.stderr + setup.stdout)
            expected = (root / "expected.input").read_bytes()
            (root / "original.input").write_bytes(bytes(range(256)))
            mutation = self.invoke("scripts/mutate.escript", "--input", root / "original.input",
                "--out", root / "mutated.input", "--seed", "17,23,41", "--config", root / "provider.term",
                "--operator", "byte_flip", "--pattern", "once", "--budget", "1", cwd=root)
            self.assertEqual(mutation.returncode, 0, mutation.stderr + mutation.stdout)
            self.assertEqual((root / "mutated.input").read_bytes(), expected)
            regenerated = self.invoke("scripts/replay.escript", "--recipe", root / "artifact.recipe",
                "--provider-config", root / "provider.term", "--provider-regenerate", root / "verified.input", cwd=root)
            self.assertEqual(regenerated.returncode, 0, regenerated.stderr + regenerated.stdout)
            self.assertEqual((root / "verified.input").read_bytes(), expected)
            mismatch = self.invoke("scripts/replay.escript", "--recipe", root / "artifact.recipe",
                "--provider-config", root / "mismatch.term", "--provider-regenerate", root / "bad.input", cwd=root)
            self.assertEqual(mismatch.returncode, 2, mismatch.stderr + mismatch.stdout)
            self.assertIn(b"provider_recipe_configuration_mismatch", mismatch.stderr)
            self.assertFalse((root / "bad.input").exists())
            raw = self.invoke("scripts/replay.escript", root / "artifact.recipe", root / "raw.input", cwd=root)
            self.assertEqual(raw.returncode, 0, raw.stderr + raw.stdout)
            self.assertEqual((root / "raw.input").read_bytes(), expected)


if __name__ == "__main__":
    unittest.main()
