#!/usr/bin/env python3
"""Finite serial off/on campaigns; each job uses a fresh BEAM VM and corpus."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True)
    parser.add_argument("--run-timeout", type=int, default=45)
    args = parser.parse_args()
    assert 35 <= args.run_timeout <= 180
    root = Path(__file__).resolve().parents[1]
    out = Path(args.out).resolve()
    assert not out.exists(), "Refuse to overwrite benchmark output"
    cpus = sorted(os.sched_getaffinity(0))[:2]
    assert len(cpus) == 2, "Two available CPUs required by fixed +S 2:2 setting"
    out.mkdir(parents=True)
    source_paths = []
    for folder in ("src", "examples/term_api", "examples/stateful", "examples/xmlrpc",
                   "gleam/efz_semantic/src", "examples/semantic_configs"):
        source_paths.extend(p for p in (root / folder).rglob("*") if p.is_file()
                            and p.suffix in (".erl", ".gleam", ".term", ".escript"))
    jobs = [(kind, mode, repetition) for repetition in range(1, 4)
            for kind in ("generic", "xmlrpc", "stateful") for mode in ("off", "on")]
    random.Random(20261010).shuffle(jobs)
    manifest = {
        "schema_version": 1,
        "head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
        "tracked_diff_sha256": hashlib.sha256(subprocess.check_output(
            ["git", "diff", "--binary"], cwd=root)).hexdigest(),
        "source_sha256": {str(p.relative_to(root)): digest(p) for p in sorted(source_paths)},
        "configuration_sha256": {p: digest(root / p) for p in
                                 ("rebar.config", "rebar.lock", "gleam/efz_semantic/gleam.toml")},
        "driver_sha256": {p: digest(root / p) for p in
                          ("scripts/semantic_bench.escript", "scripts/run_semantic_bench.py")},
        "platform": platform.platform(),
        "cpu_affinity": cpus,
        "cpu_models": sorted({line.partition(":")[2].strip()
                              for line in Path("/proc/cpuinfo").read_text().splitlines()
                              if line.startswith("model name")}),
        "scheduler_flags": "+S 2:2", "rng_seed": [17, 23, 41],
        "mutation_executions_per_campaign": 100, "repetitions": 3,
        "target_timeout_ms": 1000, "campaign_deadline_ms": 30000,
        "driver_run_timeout_s": args.run_timeout,
        "jobs": jobs, "order_seed": 20261010,
        "campaign_warmup_executions": 0,
        "scope": "finite integration smoke; no acceleration or discovery superiority claim",
        "coverage": {"generic": "ETS tuple library only", "xmlrpc": "ETS decoder/util only",
                     "stateful": "ETS admitted counter child only; OTP gen_server internals excluded"},
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    env = dict(os.environ)
    env["ERL_FLAGS"] = "+S 2:2"

    def execute(label, arguments):
        command = ["escript", "scripts/semantic_bench.escript", *arguments, str(out)]
        start = time.monotonic()
        with (out / f"{label}.log").open("w") as log:
            process = subprocess.Popen(command, cwd=root, env=env, stdout=log,
                                       stderr=subprocess.STDOUT,
                                       preexec_fn=lambda: os.sched_setaffinity(0, cpus))
            try:
                code = process.wait(timeout=args.run_timeout)
                timeout = False
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                code, timeout = process.returncode, True
        return {"label": label, "command": command, "exit_code": code,
                "driver_wall_s": time.monotonic() - start, "driver_timeout": timeout}

    preparation = execute("preparation", ["prepare"])
    if preparation["exit_code"]:
        (out / "summary.json").write_text(json.dumps({"preparation": preparation,
            "completed": False, "blocked": "target preparation failed; inspect preparation.log"}, indent=2) + "\n")
        raise SystemExit(1)
    results = []
    for kind, mode, repetition in jobs:
        label = f"{kind}-{mode}-{repetition}"
        row = execute(label, ["campaign", kind, mode, str(repetition)])
        summary_path = out / label / "summary.json"
        if summary_path.exists():
            row["measurement"] = json.loads(summary_path.read_text())
        results.append(row)
        (out / "runs.json").write_text(json.dumps(results, indent=2) + "\n")
    callback_results = [execute(f"{kind}-callbacks", ["callbacks", kind])
                        for kind in ("generic", "qs", "xmlrpc")]
    groups = {}
    for kind in ("generic", "xmlrpc", "stateful"):
        for mode in ("off", "on"):
            measured = [r["measurement"] for r in results if "measurement" in r
                        and r["measurement"]["kind"] == kind and r["measurement"]["mode"] == mode]
            groups[f"{kind}-{mode}"] = {
                "samples": len(measured),
                "completed_samples": sum(m["completed"] for m in measured),
                "median_wall_us": statistics.median([m["wall_us"] for m in measured]) if measured else None,
                "median_primary_per_second": statistics.median(
                    [m["primary_executions_per_second"] for m in measured]) if measured else None,
                "coverage_counts": [m["coverage_count"] for m in measured],
                "semantic_only_novelty": [m["semantic_only_novelty"] for m in measured],
                "provider_successes": [m["provider_successes"] for m in measured],
                "provider_fallbacks": [m["provider_fallbacks"] for m in measured],
            }
    completed = (len(results) == 18 and all(r["exit_code"] == 0 and not r["driver_timeout"]
                 and r.get("measurement", {}).get("completed", False) for r in results)
                 and all(r["exit_code"] == 0 for r in callback_results))
    final = {"completed": completed, "preparation": preparation, "campaigns": groups,
             "callback_jobs": callback_results,
             "limits": "100 mutation executions per campaign; semantic counts are adapter-local",
             "claim": "measurement only; no performance superiority or discovery acceptance claim"}
    (out / "summary.json").write_text(json.dumps(final, indent=2) + "\n")
    print(json.dumps(final, indent=2))
    raise SystemExit(0 if completed else 1)


if __name__ == "__main__":
    main()
