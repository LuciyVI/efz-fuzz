"""Small diagnostic, same safe target/seed/mutation limit; sync stays enabled."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
fixture = Path(sys.argv[1]).absolute()
out = Path(tempfile.mkdtemp(prefix="p1-bench-", dir=root / "_build"))
seed = out / "seeds"
seed.mkdir()
(seed / "safe").write_bytes(b"SAFE")
rows = []
for repetition in range(3):
    for mode in ["legacy", "supervised"] if repetition % 2 == 0 else ["supervised", "legacy"]:
        dest = out / f"{mode}-{repetition}"
        args = ["escript", "scripts/fuzz.escript", "--target", "efz_external_target", "--artifacts", str(fixture / "artifacts"),
                "--code-path", str(fixture / "plain"), "--seeds", str(seed), "--out", str(dest),
                "--max-iterations", "300", "--mutation", "staged", "--timeout", "1000",
                "--corpus-dir", str(dest / "corpus")]
        if mode == "supervised":
            args += ["--supervised"]
        start = time.monotonic()
        p = subprocess.run(args, cwd=root, env=dict(os.environ, ERL_FLAGS="+S 4:4"), capture_output=True, timeout=90)
        elapsed = time.monotonic() - start
        if p.returncode:
            raise RuntimeError(p.stdout + p.stderr)
        commit = None
        if mode == "supervised":
            report = json.loads((dest / "external-report.json").read_text())
            assert report["executions"] == 301
            commit = report["durable_prepare_seconds"]
        row = {"mode": mode, "repetition": repetition, "wall_seconds": elapsed, "mutation_executions": 300,
               "executions": 301, "mutation_per_second": 300 / elapsed, "total_per_second": 301 / elapsed,
               "durable_prepare_seconds": commit}
        rows.append(row)
        print(json.dumps(row), flush=True)
(out / "measurements.json").write_text(json.dumps(rows, indent=2))
print("BENCH_EVIDENCE=" + str(out), flush=True)
