#!/usr/bin/env python3
"""Five-seed local target-session benchmark; JSON keeps every lifecycle run."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "packages/pyefz/src"))
from pyefz import Client  # noqa: E402

SEEDS = (17, 29, 43, 61, 89)
MODES = ("isolated_stateless", "persistent_stateless",
         "persistent_stateful", "persistent_stateful_audit")


def instrument(source, module, directory):
    expression = ("application:ensure_all_started(crypto),"
        f"{{ok,_}}=efz_instrument:compile(\"{source}\","
        f"#{{modules=>[{module}],source_root=>\"{ROOT}\","
        f"outdir=>\"{directory}\"}}),halt(0).")
    result = subprocess.run(["erl", "+S", "2:2", "-noshell", "-pa",
        str(ROOT / "_build/default/lib/efz/ebin"), "-eval", expression],
        cwd=ROOT, capture_output=True, text=True, timeout=30, check=False)
    if result.returncode:
        raise RuntimeError(f"instrument {source}: {result.stderr}")


def inputs(mode, seed, count):
    rng = random.Random(seed)
    if "stateless" in mode:
        return [f"a={rng.randrange(10000)}&b={rng.randrange(10000)}".encode()
                for _ in range(count)]
    return [b"arm", b"fire", b"fire", b"noop"] * (count // 4)


def proc_tree_rss_kib(root):
    seen, pending, total = set(), [root], 0
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        try:
            status = Path(f"/proc/{pid}/status").read_text()
            for line in status.splitlines():
                if line.startswith("VmRSS:"):
                    total += int(line.split()[1])
                    break
            children = Path(f"/proc/{pid}/task/{pid}/children").read_text()
            pending.extend(int(item) for item in children.split())
        except (OSError, ValueError):
            pass
    return total


def one(mode, seed, number, directory, artifacts, count):
    persistent = mode.startswith("persistent")
    stateful = "stateful" in mode and "stateless" not in mode
    audited = mode.endswith("_audit")
    config = {"target": "efz_persistent_fixture" if stateful else "efz_example_target",
              "artifacts": str(artifacts["stateful" if stateful else "stateless"]),
              "execution": {"mode": "persistent_vm", "state_policy": "accumulate"}
                  if persistent else {"mode": "isolated"},
              "timeout": 3000,
              "runtime_oracles": {"enabled": audited,
                  "resources": {"enabled": False}, "hangs": {"enabled": False},
                  "stability": {"sequence": {"policy": "deferred", "repeats": 2,
                                              "max_calls": 2 * count,
                                              "max_elapsed_ms": 60000}}}}
    started = time.monotonic()
    peak = 0
    with Client(ROOT) as client:
        campaign = client.start_sequence(config, inputs(mode, seed, count),
                                         out=directory / f"{number:05d}")
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
            future = pool.submit(campaign.await_result, 90)
            while not future.done():
                peak = max(peak, proc_tree_rss_kib(client.pid))
                time.sleep(.02)
            report = future.result()
        peak = max(peak, proc_tree_rss_kib(client.pid))
    elapsed = time.monotonic() - started
    stats = report.get("stats", {})
    primary = stats.get("executions", 0) + stats.get("calibrations", 0)
    diagnostic = stats.get("verification_executions", 0)
    return {"mode": mode, "seed": seed, "number": number,
            "elapsed_s": elapsed, "primary_calls": primary,
            "diagnostic_calls": diagnostic, "total_calls": primary + diagnostic,
            "primary_per_s": primary / elapsed,
            "total_per_s": (primary + diagnostic) / elapsed,
            "coverage_count": report.get("coverage_count"),
            "status": report.get("status"), "peak_tree_rss_kib_sampled": peak,
            "vm_starts": report.get("target_session", {}).get("vm_starts", 0),
            "audit_vm_starts": report.get("target_audit", {}).get("vm_starts", 0),
            "target_timing": report.get("target_timing", {}),
            "feature_stability": report.get("feature_stability", {})}


def git(*arguments):
    result = subprocess.run(["git", *arguments], cwd=ROOT,
                            capture_output=True, text=True, check=True)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / "_build/persistent-target-benchmark")
    parser.add_argument("--seconds", type=float, default=3.0)
    parser.add_argument("--cases", type=int, default=80)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 120 or not 4 <= args.cases <= 1000 or args.cases % 4:
        parser.error("seconds must be 1..120 and cases a multiple of four in 4..1000")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    artifacts = {"stateless": out / "stateless", "stateful": out / "stateful"}
    instrument(ROOT / "examples/simple_parser/efz_example_parser.erl",
               "efz_example_parser", artifacts["stateless"])
    instrument(ROOT / "examples/stateful/efz_persistent_fixture.erl",
               "efz_persistent_fixture", artifacts["stateful"])
    environment = {"git_head": git("rev-parse", "HEAD"),
        "git_diff_sha256": hashlib.sha256(git("diff", "--binary").encode()).hexdigest(),
        "python": platform.python_version(), "os": platform.platform(),
        "otp_erts": subprocess.run(["erl", "+S", "2:2", "-noshell", "-eval",
            'io:format("~s/~s",[erlang:system_info(otp_release),erlang:system_info(version)]),halt().'],
            capture_output=True, text=True, check=True).stdout,
        "beam_sha256": {key: hashlib.sha256((path / ("efz_persistent_fixture.beam"
            if key == "stateful" else "efz_example_parser.beam")).read_bytes()).hexdigest()
            for key, path in artifacts.items()},
        "seeds": SEEDS, "seconds_per_mode_seed": args.seconds,
        "cases_per_campaign": args.cases,
        "rss_method": "sum VmRSS for /proc child tree, sampled every 20 ms; lower bound",
        "scheduler_flags": "+S 2:2 parent, +S 1:1 target peer",
        "warmup": "one complete campaign per mode/seed excluded",
        "order": "rotate four modes by seed index"}
    rows = []
    number = 0
    try:
        for offset, seed in enumerate(SEEDS):
            turn = offset % len(MODES)
            ordered = MODES[turn:] + MODES[:turn]
            for mode in ordered:
                number += 1
                warm = one(mode, seed, number, out, artifacts, args.cases)
                warm["warmup"] = True
                rows.append(warm)
                deadline = time.monotonic() + args.seconds
                while time.monotonic() < deadline:
                    number += 1
                    row = one(mode, seed, number, out, artifacts, args.cases)
                    row["warmup"] = False
                    rows.append(row)
                    if row["status"] != "completed":
                        raise RuntimeError(f"{mode}/{seed} returned {row['status']}")
                measured = [r for r in rows if r["mode"] == mode and r["seed"] == seed
                            and not r["warmup"]]
                print(f"{mode} seed={seed} runs={len(measured)} "
                      f"median_primary/s={statistics.median(r['primary_per_s'] for r in measured):.1f}",
                      flush=True)
    finally:
        (out / "raw.json").write_text(json.dumps({"environment": environment,
            "runs": rows}, indent=2, sort_keys=True))
        print(f"Raw results: {out / 'raw.json'}", flush=True)


if __name__ == "__main__":
    main()
