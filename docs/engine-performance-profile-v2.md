# EFZ: engine performance profile v2 (2026-10-04)

## 1. Executive summary

The saved 900-second Cowboy runs show 269.54 exec/s for `none`, 107.87 for ETS, 64.74 for bitmap-v2, and 103.36 for OTP public. Therefore coverage alone cannot explain the gap to the external `erlang_fuzzer` (~19k exec/s), which has a different in-process execution and fuzzing policy. No new 900-second run was performed here.

Two short, reverse-order **fixed replays of the same 1000 inputs** place a full no-op EFZ campaign at 490.69 exec/s (2037.9 µs/input) and Cowboy/none at 461.66–496.88 exec/s (2166.1–2012.6 µs/input). The fixed-replay ranges for ETS, bitmap and OTP public are 214.87–220.21, 89.64–91.75 and 364.67–416.51 exec/s. The input SHA256 is `16FD09EF19D76F70ECC4E2000038632E30186175A3A6CA85F9FDC7A107B5F814` for every run. Order and host load changed absolute timings, so differences below are ranges from two runs, not precise isolated cost of a primitive.

In the reverse-order OTP replay, `code:get_coverage/2` takes 5.4 µs/input (0.228%), conversion 14.8 µs (0.629%), and the measured reset+read+conversion+novelty+merge pipeline 24.0 µs (1.022%). Trace setup alone takes ~942 µs (40.1%). A compact/opaque OTP coverage API would have a theoretical upper bound of ~1.01× for that measured pipeline. The first engineering spike should examine trace lifecycle and isolation-preserving alternatives, not OTP internals. ETS remains default; bitmap-v2 remains experimental/reference.

## 2. Saved 15-minute results

Source: `artifacts/cowboy-long-bench/engine-20261004T063922Z-{none,ets,bitmap,otp_native_public}/summary.csv` and `samples.csv`. Same Cowboy version and seed corpus; independent evolving fuzz histories are **not** equal-input comparisons.

| Mode | Executions | Mean exec/s | Median | P10–P90 | First/last 60 s | Final corpus | Coverage units |
|---|---:|---:|---:|---:|---:|---:|---|
| none | 242589 | 269.54 | 276.10 | 222.10–287.90 | 315.73/220.78 | 12 | disabled |
| ETS | 97081 | 107.87 | 108.10 | 105.10–110.20 | 106.18/106.13 | 82 | 296 EFZ probes |
| bitmap-v2 | 58265 | 64.74 | 64.90 | 61.40–68.00 | 63.40/64.83 | 82 | 296 EFZ probes |
| OTP public | 93030 | 103.36 | 59.10 | 20.00–196.80 | 195.12/176.88 | 64 | 336 OTP lines |

ETS and bitmap ended with the same structural coverage count and corpus size, but this does not prove they executed the same inputs. OTP line counts are not comparable to structural probe counts. The external run is described in [Cowboy long benchmark](cowboy-long-benchmark.md); its ~19k exec/s measures another engine and feedback policy.

## 3. No-op engine ceiling and Cowboy without coverage

The real `efz_noop_target:run/1` lives in [test/targets/engine/efz_noop_target.erl](../test/targets/engine/efz_noop_target.erl). `--target noop --backend none` uses the same [worker](../src/efz_worker.erl), [executor](../src/efz_executor.erl), [guardian](../src/efz_guardian.erl), corpus and cleanup as Cowboy. `none` skips coverage storage/reset/read/novelty; it is a benchmark/debug mode. In a 1000-input fixed replay with `+S 2:2` and profiling, no-op gave 490.69 exec/s, 2037.9 µs/input wall, **1988.2 µs measured iteration mean**. A layered full-campaign microbenchmark gave 418.39 exec/s over 300 repetitions; short-run scheduler variation explains why these are not identical ceilings. A Cowboy/none run even reached 496.88 exec/s under different momentary conditions. Thus 490.69 is the measured no-op result, not a strict upper bound.

The forward Cowboy/none run gave 496.88 exec/s and 2012.6 µs/input on the same input bytes; the reverse run gave 461.66 and 2166.1. In the reverse run Cowboy target body averaged about 40 µs/iteration for `none`; no-op target does almost no work. Differences of whole-cycle means also include host scheduling, code loading and input-specific work, so `Cowboy minus no-op` is only an approximation of target cost.

## 4. Iteration data flow and process lifecycle

`efz_worker:handle_info/2` selects a corpus input and invokes a mutator in an evolving run. `execute_allowed/4` hashes/checks it, and `execute_checked/4` calls `efz_executor:run/4`. `efz_executor:run_pinned/4` creates a monitored guardian per testcase. `efz_guardian:start/6` creates a trace session, baseline shared state, monitored coordinator and monitored root. `efz_executor:invoke/4` invokes the target in root and sends the result to coordinator. `efz_guardian:cleanup/2` kills the controlled tree; `loop/1` drains `DOWN` and trace barriers. `efz_guardian:finish/2` seals coverage, destroys trace and checks shared state. Worker then calls `efz_feedback:evaluate/3`, `retain/3`, and records the decision.

```text
persistent EFZ worker
  -> spawn_monitor guardian -> trace session / coordinator / root
  -> root invokes target -> coordinator classifies -> guardian cleans/drains
  -> guardian result + DOWN -> worker feedback/corpus -> next iteration
```

At least three processes (`guardian`, `coordinator`, `root`) and three `spawn_monitor` operations are created per normal testcase in [executor](../src/efz_executor.erl) and [guardian](../src/efz_guardian.erl), plus explicit monitors for caller, guardian and root. The worker is persistent. Application/worker supervisor links are campaign-level, not one new link per testcase. At least the coordinate, ready, start, target-result, coordinator-done, guardian-result, guardian-DOWN and next-iteration messages occur; extra `DOWN`, trace-delivered, execution-context and descendant events make an exact fixed message count invalid. An iteration deadline and a bounded cleanup deadline are checked in guardian receive loops. Per-iteration allocations include context/metadata maps, hashes, sets, tracing state, monitors and three process heaps. Reuse of worker/corpus/global coverage does not remove guardian lifecycle work.

## 5. Stage profiling and accounting

`performance_profile` is false by default in [efz_config:defaults/0](../src/efz_config.erl). With `--profile`, [efz_perf_profile](../src/efz_perf_profile.erl) records calls, total, mean, median, p90 and p99; no clock is read by its disabled path. Worker, guardian and [OTP native collector](../src/efz_cov_native_public.erl) publish separate nested timings. `profile.term` and `scripts/print_engine_profile.escript` expose them. The table uses the **current reverse fixed replay OTP public** run (`v2-current-reverse-otp_native_public`). Its measured iteration mean is 2351.0 µs; wall including campaign start/report is 2400.9 µs/input.

The corresponding stage summary is preserved in [engine-otp-fixed-profile-v2-2026-10-04.term](performance/engine-otp-fixed-profile-v2-2026-10-04.term).

The 900-second `none` mean of 269.54 exec/s is about 3710 µs/execution, but that run had profiling disabled. The percentages from short fixed replay **cannot** be assigned to that exact long-run baseline: mutation/corpus evolution, scheduler conditions and sampling differ. A manually run profiled long campaign is needed for a precise percentage breakdown of the 270 exec/s observation.

| Stage | µs/iteration | % iteration | Boundary |
|---|---:|---:|---|
| Mutation | 0 | 0 | disabled in fixed replay; evolving 20 s run: ~3.9 µs |
| Input preparation | 1.4 | 0.06 | SHA256/check/metadata |
| Worker/executor inclusive | 2162.0 | 91.96 | contains guardian and target |
| Guardian inclusive | ~1908 | ~81.2 | prepare + target + cleanup + finish + gaps |
| Trace setup within guardian | 942.3 | 40.08 | per-iteration trace session |
| Coverage reset | 0.5 | 0.02 | `code:reset_coverage/1` across four modules |
| Target body | 33.7 | 1.44 | Cowboy parser path |
| `code:get_coverage/2` | 5.4 | 0.23 | four modules |
| Coverage conversion | 14.8 | 0.63 | Erlang terms to bitset |
| Novelty | 3.1 | 0.13 | native bitset |
| Global merge | 0.28 amortized | 0.012 | 34 merge calls |
| Feedback inclusive | 129.0 | 5.49 | includes novelty/merge and decode on discoveries |
| Corpus decision | 0.1 | 0.005 | fixed replay suppresses corpus insertion |
| Corpus store | 0 | 0 | disabled for fixed replay; measured separately on discoveries |
| Cleanup wait | 108.1 | 4.60 | guardian waits for quiescence |
| Guardian finish inclusive | 583.8 | 24.83 | includes trace destroy, shared checks, coverage read |
| Worker unaccounted | 58.4 | 2.49 | messages/scheduling and untimed code |

**Do not sum nested rows.** Worker top-level stages plus `worker_unaccounted` equal total by construction. Guardian's own unaccounted mean is 111.3 µs (~4.7% iteration); `executor_outer_us` is 253.6 µs (~10.8%), covering preflight, caller/guardian handoff, result/`DOWN` wait and scheduling outside guardian's measured lifetime. This is identified, not silently buried in “other”; those constituents were not individually timed. The measured top-level unaccounted fraction stays below 10%, but per-stage wall clocks include scheduler pauses and profiling overhead.

## 6. Worker/guardian synthetic layers

The reproducible [lifecycle microbenchmark](../bench/engine_lifecycle.escript) ran with OTP 27, `+S 2:2`; raw result: `docs/performance/engine-lifecycle-v2-2026-10-04.term`.

| Layer | Iterations | µs/call | Notes |
|---|---:|---:|---|
| Direct no-op call | 100000 | 0.006 | JIT/tight-loop lower bound; compiler effects possible |
| Persistent actor message round trip | 10000 | 0.636 | one actor, no isolation |
| Spawn+monitor no-op process | 1000 | 1.195 | one process; no guardian/tracing |
| Real `efz_executor:run/4` | 300 | 2456 | full guardian, no worker/corpus loop |
| Full EFZ fixed campaign | 300 | 2390 | includes worker/feedback; scheduler variance prevents subtraction |

The gap between a process message or one spawn and the full executor is far larger than the target call itself. These synthetic layers have different contracts; their times cannot be mechanically subtracted to price a single EFZ guarantee. Caller reductions and VM GC deltas are stored in the raw term. A precise dynamic count of all guardian trace messages, BEAM heap allocations and monitor operations was **not measured**; the static bounds above are from source.

## 7. Mutation and corpus cost

`bench/engine_mutation_micro.escript` with a fixed 51-byte input and `+S 2:2`: 1000 random mutations median 631 µs, 10k median 6529 µs, 100k median 65605 µs (~1.52 million mutation/s). Mean output size in the 100k batches was ~51.0 bytes. A single mutation is below 1-µs timer resolution. Staged dictionary: 1000 plan visits median 601 µs, yielding 398 candidate inputs in this fixture. Raw repetitions, reductions, process memory deltas and output-byte totals are in `docs/performance/engine-mutation-v2-2026-10-04.term`; process memory delta is not an exact allocation count. Mutation alone cannot explain an engine limited to a few hundred exec/s for this workload.

`bench/engine_corpus_micro.escript` with `+S 2:2`: corpus select/input retrieval 1.21 µs, SHA256 0.18 µs, metadata encoding 0.25 µs, in-memory duplicate check 1.03 µs, in-memory insert 2.74 µs. Thirty durable `efz_corpus_store:save/4` initial-entry writes with fsync averaged 2543 µs; a disk duplicate averaged 187 µs. Raw data: `docs/performance/engine-corpus-v2-2026-10-04.term`. These I/O figures depend on `/tmp` filesystem and cache. On the ordinary no-novelty path [efz_worker:retain/3](../src/efz_worker.erl) does **not** call `efz_corpus:add/2`; the fixed replay additionally forbids growth by design. Novel discoveries can therefore have millisecond-scale persistence cost, but not every iteration writes to disk.

In the subsequent 10-second evolving OTP smoke (`v2-current-otp-timeseries-10s`), 4152 executions grew corpus 12→45. The new nested `corpus_store` timer recorded 155716 µs total, amortized 37.5 µs/iteration (1.56%); its median and p90 are zero because most iterations do not save. `corpus_decision` is inclusive of that time. This short warmup is not the 900-second no-novelty plateau.

The 1-second stage samples from this smoke are saved as [engine-otp-stage-samples-v2-2026-10-04.csv](performance/engine-otp-stage-samples-v2-2026-10-04.csv).

## 8. Fixed replay: equal inputs and backend overhead

`--fixed-replay N` in [Cowboy runner](../scripts/cowboy_long_bench.escript) creates a deterministic sequence from the same 12 seeds and random seed, saves exact `replay-inputs.term` and SHA256, then feeds it directly to the persistent worker. The benchmark branch of [efz_worker:handle_info/2](../src/efz_worker.erl) skips calibration/mutation and advances by list order; [execute_result/6](../src/efz_worker.erl) still computes feedback/global coverage but suppresses corpus insertion, so feedback cannot choose the next input. The result checks exactly `N` executions and `completed`, and keeps the corpus at 12. This branch is benchmark-only and does not change the ordinary fuzz path. Tests cover duplicate replay inputs, default profiling disabled and unchanged decisions when profiling toggles.

Both current 1000-input series used `ERL_FLAGS='+S 2:2'`, `--profile` and the same SHA256 above. Run directories: `artifacts/cowboy-long-bench/v2-current-forward-*` and `v2-current-reverse-*`. Runner wall time starts immediately before `efz:start/1` and includes finite-campaign startup/report; stage percentages use timed iterations. Inputs are identical **within each series and between series**, but target BEAMs differ by instrumentation; code loading/order and external host load still affect results. Earlier `v2-fixed-*` exploratory runs used a timer starting after `efz:start/1`; `v2-final-*` runs predate the separate `corpus_store` timer. Both are excluded from this table.

Compact summary with artifact paths and hashes: [engine-fixed-replay-v2-2026-10-04.term](performance/engine-fixed-replay-v2-2026-10-04.term).

| Mode | Forward exec/s | Forward µs/input | Reverse exec/s | Reverse µs/input |
|---|---:|---:|---:|---:|
| No-op + none (separate run) | — | — | 490.69 | 2037.9 |
| Cowboy + none | 496.88 | 2012.6 | 461.66 | 2166.1 |
| Cowboy + ETS | 220.21 | 4541.1 | 214.87 | 4654.1 |
| Cowboy + bitmap | 91.75 | 10899.1 | 89.64 | 11155.5 |
| Cowboy + OTP public | 364.67 | 2742.2 | 416.51 | 2400.9 |
| Cowboy + OTP native no read | 473.53 | 2111.8 | 448.82 | 2228.1 |

Taking paired `mode - none` wall time gives ETS approximately **+2.53/+2.49 ms/input**, bitmap **+8.89/+8.99 ms**, OTP public **+0.73/+0.23 ms** (forward/reverse). Native no-read is +0.10/+0.06 ms versus none. The OTP pair varies much more than its measured `get_coverage` time; the source is not isolated by these runs. ETS remains ~2.1–2.2× slower than none and bitmap ~5.1–5.4×. These are total mode differences, **not pure coverage primitive overhead**. In particular, the guardian's trace setup differs among structural and native builds, and feedback policy/global state differ.

Bitmap remains slower than ETS on identical inputs, with several milliseconds of its reverse-run iteration mean in the instrumented target body versus ETS ~0.1 ms. Guardian finish also costs more. No bitmap-v3 optimization was attempted; bitmap-v2 stays experimental/reference.

## 9. OTP native breakdown and no-read control

`otp_native_no_read` is a benchmark alias of `none_instrumented`: Cowboy is compiled with OTP `line_coverage`, but EFZ uses `coverage_backend => none` during iterations. Preflight may inspect coverage once at setup; the iteration does not reset, read, convert, compare or merge native coverage. The target and seed/mutation setup match OTP public. This separates presence of native instrumentation from extraction/feedback approximately, without changing the production backend.

In reverse fixed replay, public versus native no-read is **172.8 µs/input** total mode difference; forward it is **630.4 µs**. Measured reset+get+conversion+novelty+merge is 24.0 µs/iteration in reverse, inclusive feedback 129.0 µs. The remainder includes schema checks, diagnostic/new-line decoding, context/result handling and scheduling differences; it is not automatically `code:get_coverage` cost. `get_coverage` alone is 5.4 µs/iteration (0.228%) and `get_coverage+conversion` 20.2 µs (0.857%). This spread limits the precision of end-to-end attribution.

## 10. OTP throughput variability and input sizes

The saved 900-second OTP time series held ~180–200 exec/s early, fell to ~17–26 between ~300–660 s, then recovered to ~180 without corresponding corpus/coverage reversal. Corpus was 61–62 and coverage 333–334 during much of the dip. Process count remained 52, VM run queue 1, and VM memory roughly 46–48 MB. Crucially, reductions/execution stayed ~83k and GC collections/execution ~3.1 both before, during and after the dip. This weakens explanations based on more complex inputs, more executable lines, coverage discoveries or GC frequency. The old run did **not** record input sizes or stage timings, CPU steal/throttling, or per-scheduler utilization. A host/VM scheduling slowdown is plausible but **not proven**; the precise mechanism remains open.

The new 20-second `+S 2:2` OTP run (`v2-otp-timeseries-20s`) completed 7445 executions, mean 372.18 exec/s. `samples.csv` and `stage-samples.csv` record 1-second throughput, corpus, coverage, discoveries, GC, run queue, mean input bytes and per-execution stage costs. Throughput rose from ~255 to ~380–399 exec/s during warmup. Trace setup fell from ~1518 to ~975–1044 µs/execution; `get_coverage` stayed ~5.6–7.3 µs and conversion ~15–19 µs. This short run **did not reproduce** the long dip. Correlation in this warmup window is confounded by simultaneous discoveries and changing scheduler/trace costs; it does not identify a causal mechanism. A future manual diagnostic long run with `--profile --sample-interval 10` is needed if the dip recurs.

```sh
./scripts/run_cowboy_long_bench.sh --backend otp_native_public \
  --duration 900 --seed 424242 --profile --sample-interval 10
```

This command is prepared for a **manual** run; it was not executed here. If the slowdown recurs, align `stage-samples.csv` with OS CPU throttling/steal, per-scheduler utilization and GC pause time. The current telemetry cannot distinguish those causes.

Input buckets are collected only with profiling in [efz_worker:finish_iteration/1](../src/efz_worker.erl). Current reverse fixed OTP replay:

| Input bytes | Count | Mean target µs | Mean iteration µs |
|---|---:|---:|---:|
| 0–64 | 583 | 20.9 | 2344.9 |
| 65–256 | 334 | 57.8 | 2356.9 |
| 257–1024 | 83 | 27.2 | 2370.3 |
| 1025–4096 | 0 | not tested | not tested |
| >4096 | 0 | rejected by campaign limit | rejected by campaign limit |

The iteration mean changes little across the measured buckets despite target-time differences. Old long-run input-size correlation remains unknown.

## 11. Instrumentation gaps

The EFZ manifests in `v2-fixed-1000-ets/target-beams/*.efz-manifest` list `preserved_without_internal_probes` for the following constructs. For the native column, the exact OTP 27 `line_coverage` BEAMs from the fixed run were loaded and their executable line lists queried with `code:get_coverage(line, Module)`.

| Module / source line | Construct | EFZ internal probe | OTP executable line | Consequence |
|---|---|---|---|---|
| `cowboy_http:121` | record default | no | no | Neither gives an internal point there; surrounding function probes may fire |
| `cowboy_http:1499` | list comprehension | no | yes | OTP can observe line reach; neither necessarily captures each comprehension outcome |
| `cowboy_req:488,1056` | list comprehensions | no | yes | EFZ may miss an internal behavior distinction |
| `cowboy_router:66,90,328,330` | list comprehensions | no | yes | EFZ may miss an internal behavior distinction |

This is a semantic gap, not proof that OTP line coverage is globally richer: EFZ structural probes can distinguish outcomes on the same line that OTP line coverage merges. Instrumentation placement was not changed in this task.

## 12. External erlang_fuzzer and persistent execution

| Property | EFZ | External erlang_fuzzer | Cost and safety consequence |
|---|---|---|---|
| Execution / invocation | target in new controlled root | persistent in-process call | Less setup externally; EFZ isolates BEAM process tree |
| Mutation | Erlang random/staged | libFuzzer | Different sequence and corpus pressure |
| Worker/guardian | persistent worker, new guardian/coordinator/root | no EFZ guardian | EFZ pays trace, monitors and barriers |
| Coverage/feedback | EFZ structural or OTP lines, EFZ novelty | native counters/features | Different coverage units and acceptance |
| Corpus scheduling | EFZ queue and durable entries | libFuzzer corpus policy | Different growth and I/O |
| Crash/timeout | controlled tree and classified cleanup | libFuzzer/NIF runtime | Different safety contract |
| IPC/process lifecycle | messages, monitored processes per testcase | direct in-process loop | Large expected throughput difference |

The measured full no-op EFZ floor is roughly 2.1 ms at `+S 2:2`; the external result is about 52 µs/iteration, but those are **not matched workloads**. Trace setup/destroy and controlled process/IPC lifecycle are EFZ bottlenecks; libFuzzer mutation/feedback and target invocation differ too. No causal numerical decomposition of the 19k versus 270 gap is justified.

A persistent-root EFZ mode would require a separate safety design: deadline enforcement when a target blocks, restart after crash, stale-message removal, process dictionary/ETS and target-state reset, descendant ownership, coverage generation retirement, and verification that cleanup really quiesced every writer. A process pool can retain a safe fallback that retires contaminated workers; a fast in-process mode would offer weaker isolation and must be explicitly labeled. **No redesign is implemented.** The next step is a bounded trace-lifecycle experiment with deterministic crash/timeout/late-writer tests, not deleting guardian checks on the strength of a microbenchmark.

## 13. Amdahl analysis and default-backend decision

In the current reverse OTP replay `get_coverage+conversion` is 0.857% of iteration time, giving a theoretical maximum speedup `1/(1-0.00857) ≈ 1.009×` if both became free. The entire measured native pipeline is 1.022%, giving `≈1.010×`. Even eliminating the whole inclusive feedback stage (5.49%) would cap speedup at `≈1.058×` for this replay. These bounds are workload-specific and cannot explain the long-run 20–200 exec/s variability.

The next engineering step with the largest measured potential is to profile and prototype a cheaper **isolation-preserving trace lifecycle**, then benchmark it on identical inputs and validate crash/timeout/descendant cleanup. Reducing shared-state checks or IPC comes after their own measurements and safety proof. Optimizing or patching OTP coverage API is low priority now; no DWARF/raw-pointer work was resumed. ETS remains default for structural-probe semantic fidelity. `otp_native_public` is an opt-in alternative with different line semantics and unresolved long-run variability. Bitmap-v2 remains experimental/reference because both long and fixed replay show it slower than ETS.

## 14. Reproduction and validation

Short fixed replay:

```sh
for backend in none ets bitmap otp_native_public otp_native_no_read; do
  ERL_FLAGS='+S 2:2' ./scripts/run_cowboy_long_bench.sh \
    --backend "$backend" --fixed-replay 1000 --seed 424242 --profile \
    --out "artifacts/cowboy-long-bench/my-fixed-$backend"
done
```

No-op and component benches:

```sh
ERL_FLAGS='+S 2:2' ./scripts/run_cowboy_long_bench.sh --backend none \
  --target noop --fixed-replay 1000 --seed 424242 --profile \
  --out artifacts/cowboy-long-bench/my-fixed-noop
ERL_FLAGS='+S 2:2' escript bench/engine_lifecycle.escript /tmp/efz-engine-lifecycle.term
ERL_FLAGS='+S 2:2' escript bench/engine_mutation_micro.escript /tmp/efz-mutation.term
ERL_FLAGS='+S 2:2' escript bench/engine_corpus_micro.escript /tmp/efz-corpus.term
```

Checks after changes: `ERL_FLAGS='+S 1:1' rebar3 eunit` **260 PASS**; CT **3 PASS**; xref and Dialyzer **PASS**. The new EUnit case checks fixed replay, no-coverage mode, profiling off by default, profiling behavior and input buckets. The `none`/OTP public/OTP no-read fixed runs completed without crashes or timeouts; output terms written with `~w` are consultable even for arbitrary mutated binary bytes. One early 45-second telemetry run completed target execution but failed while writing stage samples due to an unequal-list `zip`; the exporter was fixed and the subsequent 20-second run passed. The failed run is not counted as a successful telemetry result. Long-run leak behavior and the OTP mid-run slowdown mechanism remain unverified.
