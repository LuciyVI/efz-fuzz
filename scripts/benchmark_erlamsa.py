#!/usr/bin/env python3
"""Serial paired local benchmarks; no downloads, network targets, or shell eval.

Build both engines first. Results are written incrementally and are never
overwritten. The same native target artifact, harness, seeds, CPU affinity and
sampling are used in every mode. Optional EFZ stage profiling is a separate
diagnostic run. Run --seconds 1 --seeds 17 as a probe; accepted measurements
require at least five seeds and 30 seconds.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import statistics
import subprocess
import sys
import time


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def beam_identity(build):
    return {p.name:sha(p) for p in sorted((build/"lib/efz/ebin").glob("*.beam"))}


def process_tree_rss(root):
    """Sample /proc resident sets, including transient mutation VMs.

    Shared pages may be counted multiple times. This is sampled aggregate RSS,
    not a hard memory bound and not peak proportional/private memory.
    """
    # Some managed kernels omit task/TID/children. PPID in /proc/PID/stat is
    # available here, so do not silently degrade to root-only RSS.
    children = {}
    for process in Path('/proc').iterdir():
        if not process.name.isdecimal():
            continue
        try:
            fields=(process/'stat').read_text().rsplit(')',1)[1].split()
            children.setdefault(int(fields[1]),[]).append(int(process.name))
        except (OSError,ValueError,IndexError):
            continue
    pending, seen, rss = [root], set(), 0
    while pending:
        pid = pending.pop()
        if pid in seen:
            continue
        seen.add(pid)
        try:
            status = Path(f"/proc/{pid}/status").read_text()
            rss += next((int(line.split()[1])*1024 for line in status.splitlines()
                         if line.startswith("VmRSS:")), 0)
            pending.extend(children.get(pid,[]))
        except (OSError, ValueError):
            continue
    return rss


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", required=True, help="Integration _build/erlamsa+gleam")
    parser.add_argument("--baseline", required=True, help="Pristine baseline _build/default")
    parser.add_argument("--baseline-source-commit", required=True,
                        help="Commit used to build the baseline engine")
    parser.add_argument("--baseline-build-note", default="",
                        help="Local build detail, such as dependency cache reuse")
    parser.add_argument("--core", required=True, help="Clean built core checkout")
    parser.add_argument("--out", required=True, help="New output directory")
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--profile", action="store_true",
        help="Enable EFZ stage profiling for a separate diagnostic run; omit for acceptance throughput")
    parser.add_argument("--seeds", default="17,29,43,61,89")
    parser.add_argument("--modes", default=("baseline,native,native_semantic,erlamsa,"
                                             "erlamsa_persistent,hybrid,hybrid_persistent,"
                                             "semantic_persistent"))
    parser.add_argument("--cpus", default="0,1")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    out, core = Path(args.out).resolve(), Path(args.core).resolve()
    engine, baseline = Path(args.engine).resolve(), Path(args.baseline).resolve()
    seeds = [int(s) for s in args.seeds.split(",")]
    modes = args.modes.split(",")
    cpus = [int(s) for s in args.cpus.split(",")]
    if (not 1 <= args.seconds <= 3600 or not seeds or len(set(seeds)) != len(seeds)
            or any(not 0 < s < 2**31 for s in seeds)
            or len(set(modes)) != len(modes)
            or any(m not in ("baseline", "native", "erlamsa", "erlamsa_persistent",
                             "hybrid", "hybrid_persistent", "semantic_persistent",
                             "native_semantic") for m in modes)
            or not cpus or not set(cpus).issubset(os.sched_getaffinity(0))):
        parser.error("Invalid duration, seeds, modes, or CPU affinity")
    if len(args.baseline_source_commit) != 40 or any(
            c not in "0123456789abcdef" for c in args.baseline_source_commit.lower()):
        parser.error("--baseline-source-commit must be a 40-character commit SHA")
    if out.exists():
        parser.error("Refusing to overwrite existing results")
    out.mkdir(parents=True)
    env = dict(os.environ, ERL_FLAGS="+S 2:2", ERL_CRASH_DUMP=str(out/"erl_crash.dump"),
        EFZ_BENCH_PROFILE="1" if args.profile else "0")
    source = out/"source"
    source.mkdir()
    for name in ("src/cow_qs.erl", "include/cow_inline.hrl"):
        shutil.copy2(root/"_build/default/lib/cowlib"/name, source/Path(name).name)
    artifact = out/"shared-artifact.term"
    prepare = ["erl", "+S", "2:2", "-noshell", "-pa", str(engine/"lib/efz/ebin"),
               "-eval", '[Source,TargetDir,Artifact]=init:get_plain_arguments(),'
               '{ok,A}=efz_cov_native_public:compile(Source,TargetDir),'
               'ok=file:write_file(Artifact,io_lib:format("~tp.~n",[A])),halt(0).',
               "-extra", str(source/"cow_qs.erl"), str(out/"target"), str(artifact)]
    with (out/"prepare.log").open("w") as log:
        subprocess.run(prepare, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT,
                       check=True, timeout=30)
    jobs = [(seed, mode) for seed in seeds for mode in modes]
    random.Random(20261027).shuffle(jobs)
    cpu_model = next((line.split(":",1)[1].strip() for line in
        Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")), "unknown")
    source_paths = sorted(set([*root.glob("src/*.erl"),
        *root.glob("scripts/benchmark_erlamsa*"),root/"scripts/benchmark_erlamsa_target.erl",
        *root.glob("packages/pyefz/src/pyefz/*.py"),
        *root.glob("packages/pyefz/test/*.py"),root/"test/efz_erlamsa_integration_tests.erl"]))
    shared_dependencies = {p.relative_to(root).as_posix():sha(p)
        for app in ("cowlib", "cowboy", "ranch")
        for p in sorted((root/"_build/default/lib"/app/"ebin").glob("*.beam"))}
    manifest = {"schema_version": 1, "seed_triples": [[s,s+1,s+2] for s in seeds],
        "mutation_wall_seconds": args.seconds, "cpu_affinity": cpus, "ERL_FLAGS": "+S 2:2",
        "environment":{"platform":platform.platform(),"kernel":platform.release(),
            "machine":platform.machine(),"cpu_model":cpu_model,"cpu_count":os.cpu_count(),
            "python":sys.version.split()[0],
            "rebar3":subprocess.check_output(["rebar3","--version"],text=True).strip()},
        "warmup_mutations": 10, "target_timeout_ms": 1000, "provider_timeout_ms": 2000,
        "profile": "bytes", "hybrid_weights": {"native":70,"erlamsa":30},
        "semantic_adapter": "efz_qs_adapter", "structured_fraction":10,
        "feedback":"guided", "oracle":"disabled", "performance_profile":args.profile,
        "coverage_domain":["cow_qs"], "coverage_backend":"otp_native_public",
        "target_artifact_sha256":sha(out/"target/cow_qs.beam"),
        "order_seed":20261027, "jobs":jobs, "off_overhead_tolerance_percent":5.0,
        "sampling_ms":{"coverage_vm_memory":1000,"os_process_tree_rss":100},
        "rss_sampler":"proc_stat_ppid_v2",
        "candidate_source_selection":"independent state-threaded planner RNG",
        "decode_definition":"ordinary cow_qs harness returned accepted pairs; separate from coverage",
        "persistent_worker":{"one_external_vm_per_campaign":True,"max_requests":10000,
            "one_inflight_request":True,"request_process":"fresh per mutation"},
        "benchmark_kind":"accepted_wall_time" if len(seeds)>=5 and args.seconds>=30 else "probe_only",
        "source_sha256":{str(p.relative_to(root)):sha(p) for p in source_paths},
        "engine_beams":{mode:beam_identity(build)
                         for mode,build in (("baseline",baseline),("integration",engine))},
        "baseline_source_commit":args.baseline_source_commit.lower(),
        "baseline_build_note":args.baseline_build_note,
        "shared_runtime_dependency_beams":shared_dependencies,
        "core_beams":{p.name:sha(p) for p in sorted((core/"core/_build/default/lib/erlamsa_core/ebin").glob("*.beam"))},
        "core_commit":subprocess.check_output(["git","rev-parse","HEAD"],cwd=core,text=True).strip(),
        "efz_commit":subprocess.check_output(["git","rev-parse","HEAD"],cwd=root,text=True).strip()}
    write(out/"manifest.json",manifest)
    results=[]
    def check_identity():
        return (beam_identity(baseline)==manifest["engine_beams"]["baseline"] and
            beam_identity(engine)==manifest["engine_beams"]["integration"] and
            {p.relative_to(root).as_posix():sha(p)
                for app in ("cowlib", "cowboy", "ranch")
                for p in sorted((root/"_build/default/lib"/app/"ebin").glob("*.beam"))}==
                manifest["shared_runtime_dependency_beams"] and
            {p.name:sha(p) for p in sorted((core/"core/_build/default/lib/erlamsa_core/ebin").glob("*.beam"))}==manifest["core_beams"] and
            subprocess.check_output(["git","rev-parse","HEAD"],cwd=core,text=True).strip()==manifest["core_commit"] and
            not subprocess.check_output(["git","status","--porcelain"],cwd=core,text=True).strip())
    for seed,mode in jobs:
        if not check_identity():
            results.append({"mode":mode,"seed":seed,"exit_code":None,"build_identity_changed":True})
            write(out/"runs.json",results)
            break
        label=f"{mode}-s{seed}"
        destination=out/label
        destination.mkdir()
        command=["escript",str(root/"scripts/benchmark_erlamsa.escript"),
            str(baseline if mode=="baseline" else engine),mode,str(seed),str(args.seconds),
            str(destination),str(root),str(artifact),str(core)]
        start,peak=time.monotonic(),0
        with (out/(label+".log")).open("w") as log:
            process=subprocess.Popen(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,
                preexec_fn=lambda:os.sched_setaffinity(0,cpus),start_new_session=True)
            deadline=start+args.seconds+90
            while process.poll() is None and time.monotonic()<deadline:
                peak=max(peak,process_tree_rss(process.pid))
                time.sleep(0.1)
            timed_out=process.poll() is None
            if timed_out:
                os.killpg(process.pid,9)
            code=process.wait()
        row={"mode":mode,"seed":seed,"command":command,"exit_code":code,
             "driver_timeout":timed_out,"driver_wall_seconds":time.monotonic()-start,
             "sampled_process_tree_rss_peak_bytes":peak,"build_identity_changed":not check_identity()}
        if (destination/"summary.json").exists():
            row["measurement"]=json.loads((destination/"summary.json").read_text())
        results.append(row)
        write(out/"runs.json",results)
        print(label,code,round(row["driver_wall_seconds"],2),flush=True)
        if code or row["build_identity_changed"]:
            print((out/(label+".log")).read_text()[-6000:],flush=True)
            break
    completed=len(results)==len(jobs) and all(r["exit_code"]==0 and not r["build_identity_changed"] for r in results)
    summaries={}
    for mode in modes:
        rows=[r for r in results if r["mode"]==mode and "measurement" in r]
        data=[r["measurement"] for r in rows]
        def spread(key):
            values=[m[key] for m in data if m.get(key) is not None]
            return {"median":statistics.median(values),"min":min(values),"max":max(values)} if values else None
        summaries[mode]={"samples":len(data),"executions_per_second":spread("target_executions_per_second"),
            "steady_state_executions_per_second":spread("steady_state_target_executions_per_second"),
            "coverage":spread("target_coverage_count"),"accepted_fraction":spread("accepted_fraction"),
            "input_bytes":spread("mean_input_bytes"),"provider_p50_us":spread("provider_latency_p50_us"),
            "provider_p95_us":spread("provider_latency_p95_us"),
            "legacy_core_wrapper_p50_us":spread("provider_core_p50_us"),
            "legacy_core_wrapper_p95_us":spread("provider_core_p95_us"),
            "direct_core_p50_us":statistics.median(m["direct_core_mutation_p50_p95_us"]["p50"]
                for m in data if m.get("direct_core_mutation_p50_p95_us",{}).get("p50") is not None)
                if any(m.get("direct_core_mutation_p50_p95_us",{}).get("p50") is not None for m in data) else None,
            "identity_check_p50_us":statistics.median(m["identity_check_p50_p95_us"]["p50"]
                for m in data if m.get("identity_check_p50_p95_us",{}).get("p50") is not None)
                if any(m.get("identity_check_p50_p95_us",{}).get("p50") is not None for m in data) else None,
            "warm_request_p50_us":statistics.median(m["warm_request_p50_p95_us"]["p50"]
                for m in data if m.get("warm_request_p50_p95_us",{}).get("p50") is not None)
                if any(m.get("warm_request_p50_p95_us",{}).get("p50") is not None for m in data) else None,
            "warm_request_p95_us":statistics.median(m["warm_request_p50_p95_us"]["p95"]
                for m in data if m.get("warm_request_p50_p95_us",{}).get("p95") is not None)
                if any(m.get("warm_request_p50_p95_us",{}).get("p95") is not None for m in data) else None,
            "worker_startup_p50_us":statistics.median(m["worker_startup_p50_p95_us"]["p50"]
                for m in data if m.get("worker_startup_p50_p95_us",{}).get("p50") is not None)
                if any(m.get("worker_startup_p50_p95_us",{}).get("p50") is not None for m in data) else None,
            "recycle_cleanup_p50_us":statistics.median(m["recycle_cleanup_p50_p95_us"]["p50"]
                for m in data if m.get("recycle_cleanup_p50_p95_us",{}).get("p50") is not None)
                if any(m.get("recycle_cleanup_p50_p95_us",{}).get("p50") is not None for m in data) else None,
            "process_tree_rss_bytes":{"median":statistics.median(r["sampled_process_tree_rss_peak_bytes"] for r in rows)} if rows else None}
    ratios=[]
    for seed in seeds:
        pair={r["mode"]:r["measurement"]["target_executions_per_second"] for r in results
              if r["seed"]==seed and "measurement" in r}
        if "baseline" in pair and "native" in pair:
            ratios.append({"seed":seed,"throughput_change_percent":100*(pair["native"]/pair["baseline"]-1)})
    final={"completed":completed,"accepted":completed and manifest["benchmark_kind"]=="accepted_wall_time",
        "kind":manifest["benchmark_kind"],"groups":summaries,
        "native_off_paired_changes":ratios,
        "native_off_median_change_percent":statistics.median(r["throughput_change_percent"] for r in ratios) if ratios else None,
        "limitations":["Single local query-string workload and one pinned OTP/ERTS build; no discovery advantage claim.",
            "Diagnostic message, performance profiling, corpus persistence, and sampling enabled equally in every mode.",
        "Full campaign throughput includes startup, count-based recycle, and orderly shutdown; request percentiles distinguish warm requests from startup/recycle.",
            "Memory is sampled; aggregate RSS double-counts shared pages and may miss short peaks."]}
    write(out/"summary.json",final)
    print(json.dumps(final,indent=2))
    return 0 if completed else 1


if __name__=="__main__":
    raise SystemExit(main())
