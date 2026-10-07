#!/usr/bin/env python3
"""Compare 2-4 independently sampled Cowboy runs without equating coverage units."""
import argparse
import csv
from pathlib import Path
import statistics

METRICS = [
    ("Executions", "total_executions"),
    ("Mean exec/s", "mean_exec_per_sec"),
    ("Median exec/s", "median_window_exec_per_sec"),
    ("P10 exec/s", "p10_window_exec_per_sec"),
    ("P90 exec/s", "p90_window_exec_per_sec"),
    ("First 60s exec/s", "first_60s_exec_per_sec"),
    ("Last 60s exec/s", "last_60s_exec_per_sec"),
    ("Corpus size", "corpus_final_size"),
    ("Coverage discoveries", "coverage_discoveries"),
    ("Memory delta bytes", "memory_delta"),
    ("Process delta", "process_delta"),
    ("Crashes", "crashes"),
    ("Timeouts", "timeouts"),
    ("Infrastructure errors", "errors"),
]
NATIVE = {"otp_native_public", "otp_native_direct"}


def read_run(path: Path):
    with (path / "summary.csv").open(newline="") as handle:
        summary = next(csv.DictReader(handle))
    with (path / "samples.csv").open(newline="") as handle:
        samples = list(csv.DictReader(handle))
    if len(samples) < 2:
        raise ValueError(f"{path}: missing time samples")
    environment = {}
    for line in (path / "environment.txt").read_text(errors="replace").splitlines():
        if ": " in line:
            key, value = line.split(": ", 1)
            environment[key] = value
    return summary, samples, environment


def number(row, key):
    value = row.get(key)
    return None if value in (None, "", "NA") else float(value)


def cell(row, key, width):
    value = number(row, key)
    return f"{value:>{width}.2f}" if value is not None else f"{'n/a':>{width}}"


def nearest(rows, second):
    return min(rows, key=lambda row: abs(number(row, "elapsed_s") - second))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runs", nargs="+", type=Path, help="2-4 run directories")
    args = parser.parse_args()
    if not 2 <= len(args.runs) <= 4:
        parser.error("supply 2-4 run directories")
    runs = [read_run(path) for path in args.runs]
    names = [row[0]["backend"] for row in runs]
    if len(set(names)) != len(names):
        parser.error("each backend must occur once")
    for key in ("cowboy", "random_seed", "initial_corpus", "duration_s", "instrumented_modules"):
        values = [run[2].get(key) for run in runs]
        if len(set(values)) > 1:
            print(f"WARNING: {key} differs: {dict(zip(names, values))}")
    if "erlang_fuzzer" in names:
        print("WARNING: erlang_fuzzer uses libFuzzer mutation, in-process execution and its own "
              "corpus/feedback policy. Exec/s compares whole engines, not coverage cost alone.")
        print("WARNING: external libFuzzer ft/cov values are not EFZ probes or OTP line counts; "
              "its missing VM counters are shown as n/a.")
        for summary, _, _ in runs:
            if summary["backend"] == "erlang_fuzzer":
                print("External-only: ft=" + summary.get("external_feature_count", "n/a") +
                      ", NEW/REDUCE events=" + summary.get("external_new_reduce_events", "n/a"))
    width = 20
    print(f"{'Metric':<28}" + "".join(f"{name:>{width}}" for name in names))
    print("-" * (28 + width * len(names)))
    for label, key in METRICS:
        print(f"{label:<28}" + "".join(cell(row[0], key, width) for row in runs))
    if len(names) == 2 and "erlang_fuzzer" not in names:
        first, second = [number(run[0], "mean_exec_per_sec") for run in runs]
        ratio = f"{second / first:.3f}" if first and second is not None else "n/a"
        print(f"Mean exec/s ratio {names[1]}/{names[0]}: {ratio}")
    print("Coverage counts use different units: ETS/bitmap = EFZ structural probes; "
          "OTP public = executable lines; external libFuzzer = non-equivalent features.")
    for name, (summary, _, _) in zip(names, runs):
        print(f"  {name}: final coverage count = {summary['global_coverage_final']}")
    native = [(name, row) for name, row in zip(names, runs) if name in NATIVE]
    if len(native) == 2:
        if native[0][1][2].get("native_schema") == native[1][1][2].get("native_schema"):
            print("Native schemas match; native coverage counts are directly comparable.")
        else:
            print("WARNING: native schemas differ; native coverage counts are not directly comparable.")
    print("Independent fuzz runs can follow different mutation histories despite equal seeds.")
    for name, (_, rows, _) in zip(names, runs):
        rates = [number(row, "exec_per_sec_window") for row in rows[1:]]
        rates = [rate for rate in rates if rate is not None]
        print(f"{name}: window exec/s min={min(rates):.1f} "
              f"median={statistics.median(rates):.1f} max={max(rates):.1f}")
        for second in (0, 300, 600, 900):
            if second <= number(rows[-1], "elapsed_s") + 0.5:
                row = nearest(rows, second)
                def display(key, unit=""):
                    value = number(row, key)
                    return f"{value:.0f}{unit}" if value is not None else "n/a"
                print(f"  ~{second}s actual={number(row,'elapsed_s'):.1f}s "
                      f"RSS={display('rss_kib', ' KiB')} "
                      f"processes={display('process_count')} "
                      f"ETS={display('memory_ets', ' B')}")
    print("Inspect throughput, corpus, coverage discovery and memory trends together.")


if __name__ == "__main__":
    main()
