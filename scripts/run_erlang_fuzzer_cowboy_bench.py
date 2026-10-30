#!/usr/bin/env python3
"""Isolated, non-equivalent Cowboy run of the external erlang-fuzzer engine."""
import argparse
import atexit
import csv
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = Path.home() / "test/erlang-fuzzer(1)/erlang-fuzzer/fuzzer"
PROGRESS = re.compile(r"^#(\d+)\s+")
FIELDS = ["elapsed_s", "executions_total", "exec_per_sec_window", "exec_per_sec_total",
          "corpus_size", "global_coverage_count", "new_coverage_events", "crashes",
          "timeouts", "errors", "process_count", "memory_total", "memory_processes",
          "memory_binary", "memory_ets", "rss_kib", "run_queue", "reductions", "gc_count"]


def checked(cmd, *, cwd=ROOT, env=None, output=None):
    result = subprocess.run(cmd, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if output:
        output.write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f"{cmd[0]} failed ({result.returncode}); see {output}:\n"
                           + result.stdout[-1500:])
    return result.stdout


def memory(pid):
    try:
        text = Path(f"/proc/{pid}/status").read_text()
    except OSError:
        return None
    match = re.search(r"^VmRSS:\s*(\d+) kB", text, re.MULTILINE)
    return int(match.group(1)) if match else None


def file_hash(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def latest_progress(log, previous):
    count, features, corpus, discoveries = previous
    for line in log.splitlines():
        match = PROGRESS.match(line)
        if not match:
            continue
        count = max(count, int(match.group(1)))
        ft = re.search(r"\bft:\s*(\d+)", line)
        corp = re.search(r"\bcorp:\s*(\d+)", line)
        if ft:
            features = int(ft.group(1))
        if corp:
            corpus = int(corp.group(1))
        if re.search(r"\b(?:NEW|REDUCE)\b", line):
            discoveries += 1
    return count, features, corpus, discoveries


def numeric(values, key):
    return float(values[key]) if values.get(key) not in (None, "NA", "") else None


def summary(rows, duration, returncode):
    rates = sorted(row["exec_per_sec_window"] for row in rows[1:])
    first, last = rows[0], rows[-1]
    elapsed = last["elapsed_s"]
    def percentile(p):
        return rates[min(len(rates) - 1, max(0, int((len(rates) - 1) * p)))] if rates else 0.0
    def interval_rate(start):
        subset = [row for row in rows if row["elapsed_s"] >= start]
        a = subset[0] if subset else first
        span = last["elapsed_s"] - a["elapsed_s"]
        return (last["executions_total"] - a["executions_total"]) / span if span else 0.0
    return dict(backend="erlang_fuzzer", requested_duration_s=duration,
                actual_duration_s=elapsed, total_executions=last["executions_total"],
                mean_exec_per_sec=(last["executions_total"] - first["executions_total"]) / elapsed if elapsed else 0,
                median_window_exec_per_sec=percentile(.5),
                p10_window_exec_per_sec=percentile(.1), p90_window_exec_per_sec=percentile(.9),
                first_60s_exec_per_sec=next((row["executions_total"] / row["elapsed_s"]
                     for row in rows if row["elapsed_s"] >= min(60, elapsed) and row["elapsed_s"]), 0),
                last_60s_exec_per_sec=interval_rate(max(0, elapsed - 60)),
                global_coverage_final="NA", coverage_discoveries="NA",
                corpus_final_size=last["corpus_size"], crashes="NA", timeouts="NA",
                errors=0 if returncode == 0 else 1, memory_delta="NA", process_delta="NA",
                external_feature_count=last["external_feature_count"],
                external_new_reduce_events=last["new_coverage_events"],
                exit_status=returncode)


def run(args):
    source = args.source.resolve()
    if not (source / "c_src/core.c").is_file() or not (source / "src/fuzzer.erl").is_file():
        raise ValueError(f"not an erlang-fuzzer source tree: {source}")
    out = (args.out or ROOT / "artifacts/cowboy-long-bench" /
           (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-erlang_fuzzer")).resolve()
    out.mkdir(parents=True, exist_ok=False)
    (out / "crashes").mkdir()
    (out / "corpus").mkdir()
    for seed in sorted(args.corpus.iterdir()):
        if seed.is_file():
            shutil.copy2(seed, out / "corpus" / seed.name)
    if not any((out / "corpus").iterdir()):
        raise ValueError("empty seed corpus")
    checked(["rebar3", "compile"], output=out / "efz-build.log")
    wrapper = checked(["escript", "scripts/prepare_erlang_fuzzer_cowboy.escript", str(out)],
                      output=out / "target-build.log").strip().splitlines()[-1]
    # erlang.mk's generated Makefile treats ':' in a path as Make syntax.
    # The EFZ checkout lives below erl:fuzz, so build the external source in /tmp.
    build = Path(tempfile.mkdtemp(prefix="efz-erlang-fuzzer-")) / "fuzzer"
    atexit.register(shutil.rmtree, build.parent, ignore_errors=True)
    shutil.copytree(source, build, ignore=shutil.ignore_patterns("_build", "priv", "*.o", "*.so"))
    makefile = build / "c_src/Makefile"
    original = makefile.read_text()
    if "gdb -batch" not in original:
        raise ValueError("external Makefile no longer matches expected gdb invocation")
    makefile.write_text(original.replace("gdb -batch", "gdb -nx -batch"))
    checked(["rebar3", "escriptize"], cwd=build, output=out / "external-build.log")
    nif = build / "priv/core.so"
    if not nif.is_file():
        raise RuntimeError("external NIF was not built")
    erl = checked(["erl", "-noshell", "-eval",
        'io:format("~s ~s", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().']).strip()
    beam = checked(["erl", "-noshell", "-eval",
        'io:format("~s", [filename:join([code:root_dir(), "erts-" ++ erlang:system_info(version), "bin", "beam.smp"])]), halt().']).strip()
    paths = [str(out / "target-beams"), str(out / "harness-beams")]
    paths += [str(p) for p in sorted((ROOT / "_build/default/lib").glob("*/ebin"))]
    env = os.environ.copy()
    env["CORE_NIF"] = str(nif)
    env["EFZ_COWBOY_BENCH_PATHS"] = "\n".join(paths)
    # fuzzer:main/1 selects line_counters before loading the wrapper and
    # target. +line_coverage is a compiler option, not an emulator flag.
    (out / "environment.txt").write_text(
        f"backend: erlang_fuzzer\ncowboy: \"2.19.0\"\n"
        f"duration_s: {args.duration}\nrandom_seed: {args.seed}\n"
        f"initial_corpus: \"{os.path.relpath(args.corpus, ROOT)}\"\n"
        f"instrumented_modules: [cowboy_http,cowboy_req,cowboy_router,cowboy_stream]\n"
        f"external_source: {source}\nexternal_core_sha256: {file_hash(source/'c_src/core.c')}\n"
        f"external_driver_sha256: {file_hash(source/'src/fuzzer.erl')}\n"
        f"beam_path: {beam}\nbeam_sha256: {file_hash(Path(beam))}\notp_erts: {erl}\n"
        f"engine: libFuzzer (different mutation and corpus policy from EFZ)\n"
        f"coverage: OTP line_counters registered by external NIF; ft is not unique line count\n")
    cmd = [str(build / "_build/default/bin/fuzzer"), wrapper,
           str(out / "corpus"), f"-max_total_time={args.duration}",
           f"-seed={args.seed}", "-max_len=4096", "-print_final_stats=1",
           "-timeout=1", f"-artifact_prefix={out / 'crashes'}/"]
    (out / "command.txt").write_text(" ".join(cmd) + "\n")
    rows = []
    progress = (0, 0, sum(1 for _ in (out / "corpus").iterdir()), 0)
    offset = 0
    started = time.monotonic()
    with (out / "fuzzer.log").open("w+") as log:
        proc = subprocess.Popen(cmd, cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            while True:
                elapsed = time.monotonic() - started
                log.flush()
                log.seek(offset)
                data = log.read()
                offset = log.tell()
                progress = latest_progress(data, progress)
                count, features, _, discoveries = progress
                corpus = sum(1 for p in (out / "corpus").iterdir() if p.is_file())
                prev = rows[-1] if rows else None
                delta = elapsed - prev["elapsed_s"] if prev else 0
                rate = (count - prev["executions_total"]) / delta if delta else 0
                rows.append(dict(elapsed_s=round(elapsed, 3), executions_total=count,
                    exec_per_sec_window=round(rate, 3), exec_per_sec_total=round(count / elapsed, 3) if elapsed else 0,
                    corpus_size=corpus, global_coverage_count="NA", new_coverage_events=discoveries,
                    crashes="NA", timeouts="NA", errors=0, process_count="NA",
                    memory_total="NA", memory_processes="NA", memory_binary="NA", memory_ets="NA",
                    rss_kib=memory(proc.pid) or "NA", run_queue="NA", reductions="NA",
                    gc_count="NA", external_feature_count=features))
                if proc.poll() is not None:
                    break
                time.sleep(min(10, args.duration - elapsed) if elapsed < args.duration else 1)
                if time.monotonic() - started > args.duration + 15:
                    proc.terminate()
                    raise RuntimeError("external fuzzer exceeded duration grace period")
        finally:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
    with (out / "samples.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS + ["external_feature_count"])
        writer.writeheader()
        writer.writerows(rows)
    result = summary(rows, args.duration, proc.returncode)
    log_text = (out / "fuzzer.log").read_text(errors="replace")
    modules = ("cowboy_http", "cowboy_req", "cowboy_router", "cowboy_stream")
    missing = [m for m in modules if f"INFO: module coverage on: {m}" not in log_text]
    if missing or result["external_feature_count"] == 0:
        raise RuntimeError(f"coverage registration failed for {missing}; "
                           f"ft={result['external_feature_count']}; see {out/'fuzzer.log'}")
    with (out / "summary.csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(result))
        writer.writeheader()
        writer.writerow(result)
    print(f"Output: {out}\nExecutions: {result['total_executions']}"
          f"; mean exec/s: {result['mean_exec_per_sec']:.2f}; exit: {proc.returncode}")
    if proc.returncode:
        raise RuntimeError(f"external fuzzer failed; inspect {out/'fuzzer.log'}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--duration", type=int, default=900)
    parser.add_argument("--seed", type=int, default=424242)
    parser.add_argument("--corpus", type=Path,
                        default=ROOT / "test/targets/cowboy/seeds")
    parser.add_argument("--out", type=Path)
    arguments = parser.parse_args()
    if arguments.duration < 1 or arguments.seed < 0:
        parser.error("duration must be positive and seed must be nonnegative")
    try:
        run(arguments)
    except Exception as exc:
        print(f"benchmark failed: {exc}", file=sys.stderr)
        sys.exit(1)
