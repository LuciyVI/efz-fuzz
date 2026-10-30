# EFZ: cost profile of one iteration

**English** · [Русский](i18n/ru/engine-performance-profile.md) · [Español](i18n/es/engine-performance-profile.md) · [简体中文](i18n/zh-CN/engine-performance-profile.md) · [All languages](i18n/README.md)

The next stage, with 15-minute results, fixed replay and analysis of OTP
nonstationarity: [engine-performance-profile-v2.md](engine-performance-profile-v2.md).

## 1. Executive summary

Experimental `coverage_backend => none` keeps EFZ's ordinary mutation, corpus, worker, guardian, timeout and cleanup, but does not collect coverage. On this host, a short 30-second Cowboy run achieved **60.70 exec/s** without instrumentation, while the no-op target achieved **63.13 exec/s** with profiling and **63.70 exec/s** without it. The mean no-op iteration cost with 16 schedulers was **15.82 ms**. This is the ceiling of *this configuration and host load*, not an architectural limit of EFZ: with `+S 1:1`, a separate 10-second no-op run achieved **163.88 exec/s**, with a mean iteration of **6.09 ms**. The minimum individual iteration was not measured as a reliable characteristic.

In the `otp_native_public` profile, `code:get_coverage/2` took **15.25 µs/iteration (0.081%)**. The sum of reset, get, conversion, novelty and merge was **74.77 µs (0.398%)**. The main measured costs were the guardian lifecycle: trace setup, trace destroy and shared-state checking. A compact/opaque OTP coverage API patch is not currently justified as the next step to accelerate EFZ. This is a local stage profile; stable throughput conclusions require paired repeated runs.

## 2. Context and reproducibility

The user's 15-minute results: ETS 54.66, bitmap-v2 27.56, `otp_native_public` 96.59, external `erlang_fuzzer` 19019.08 exec/s. Raw runs are stored respectively in `artifacts/cowboy-long-bench/20261003T065733Z-ets/`, `20261003T065741Z-bitmap/`, `20261003T065750Z-otp_native_public/`, `20261004T053054Z-erlang_fuzzer/`. The last uses libFuzzer mutation, an in-process loop and its own feedback/corpus features. The ~197 ratio between it and OTP public **is not** an estimate of coverage cost.

The short runs below used OTP 27.0, ERTS 15.0, x86_64 Linux, 16 online schedulers, Cowboy 2.19.0, the same 12 seeds, seed 424242, duration 30 s and `--profile`, unless noted otherwise. The host was loaded (load average about 18–22). The first no-op/none runs achieved only 17.60/19.57 exec/s with trace setup of 35.4/31.1 ms; repeats achieved 63.13/60.70. A single pair and absolute percentages therefore do not transfer to another scheduler/host load. No 900-second run was started during this stage.

| Short workload | Run | Executions | exec/s | Mean iteration |
|---|---|---:|---:|---:|
| No-op, none, profile | `20261004T061445Z-noop-none` | 1895 | 63.13 | 15,819 µs |
| No-op, none, without profile | `20261004T061406Z-noop-none` | 1912 | 63.70 | — |
| Cowboy, none | `20261004T061152Z-none` | 1822 | 60.70 | 16,455 µs |
| Cowboy, none_instrumented | `20261004T061050Z-none_instrumented` | 1799 | 59.93 | 16,676 µs |
| Cowboy, ETS | `20261004T061244Z-ets` | 1172 | 39.03 | 25,606 µs |
| Cowboy, bitmap-v2 | `20261004T061324Z-bitmap` | 734 | 24.43 | 40,916 µs |
| Cowboy, OTP public | `20261004T061001Z-otp_native_public` | 1598 | 53.23 | 18,768 µs |

`none_instrumented` compiles Cowboy with `line_coverage`, but does not call reset/get/feedback. The difference from raw `none` in one short pair is small and has not been separated from noise. These runs should not be compared by corpus/coverage count as identical fuzzing histories.

## 3. Iteration architecture and IPC

`efz_worker:handle_info/2` selects and mutates a corpus input; `execute_allowed/4` hashes and validates the input; `execute_checked/4` calls `efz_executor:run/4`. `efz_executor:run_pinned/4` creates and monitors a guardian **on every iteration**, waiting for a result and `DOWN`. `efz_guardian:start/6` creates a trace session, captures the shared-state baseline, creates a monitored coordinator and monitored root, and installs the context; `efz_executor:invoke/4` executes the target in the root. The coordinator classifies the result, the guardian terminates the tree and waits for `DOWN`/trace barriers, then `efz_guardian:finish/2` collects coverage, destroys the trace session and checks shared state. The worker calls `efz_feedback:evaluate/3`, then `retain/2` and `accepted/5`. The campaign worker persists between iterations; the guardian, coordinator and root are recreated. Additional descendants are created at the target's request.

The minimal normal path includes 3 `spawn_monitor` calls (guardian, coordinator, root), additional `monitor` calls (caller/root/guardian), a worker→guardian message through the spawn closure, `coordinate`, `coordinator_ready`, `start_owned`, `target_result`, `coordinator_done`, a guardian→worker result and corresponding `DOWN`/trace barrier events. The exact message count depends on the runtime sampler, trace and descendants; a fixed IPC count per testcase **has not been proven**. `efz_guardian:cleanup/2` terminates the admitted tree even for no-op; this is part of the safety model, not coverage overhead. `efz_cov_integrity:trace_setup/3` and `efz_cov_integrity:close/0` continue to run in `none` mode to check the lifecycle.

## 4. No-coverage ceiling and no-op harness

`none` requires `automatic + presence`, does not load a coverage schema, open storage or call `code:reset_coverage/1` or `code:get_coverage/2`. `efz_feedback:evaluate/3` returns no new points, but preserves calibration and target-failure retention reasons. Corpus selection, mutation and retention decisions follow the ordinary path. `none` is a performance/debug baseline, not a production coverage-guided mode. `none_instrumented` is useful for an approximate estimate of OTP line instrumentation cost. No-op `test/targets/engine/efz_noop_target.erl` executes `run(_Input) -> ok` through the real EFZ engine.

No-op with 16 schedulers: 63.13 exec/s and 15,819 µs/iteration with profiling. With `ERL_FLAGS='+S 1:1'`, the 10-second run `20261004T062318Z-noop-none` achieved 163.88 exec/s and 6093 µs/iteration, with trace setup of 2479 µs. This demonstrates trace setup's sensitivity to scheduler settings/load. In `none`, the Cowboy target took a mean 104 µs inside the guardian and the no-op target 2.25 µs; the full-cycle difference cannot be treated solely as target cost because the runs were not paired.

Short reproduction commands:

```sh
./scripts/run_cowboy_long_bench.sh --backend none --target noop --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend none --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend none_instrumented --duration 30 --seed 424242 --profile
./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 30 --seed 424242 --profile
escript scripts/print_engine_profile.escript artifacts/cowboy-long-bench/RUN_DIR
```

## 5. Stage timing and accounting

Profiling is enabled only with `performance_profile => true`/`--profile`. `efz_perf_profile:measure/2` does not call the clock when the flag is off; the summary stores at most 20,000 samples per stage while totals/calls continue accumulating. Median/p90/p99 are in `profile.term`; view them with `scripts/print_engine_profile.escript`. The figures below are means across 30-second runs, as percentages of `iteration_total`. Nested stages **must not be added together**.

| Stage | No-op none µs | OTP public Cowboy µs | OTP % |
|---|---:|---:|---:|
| Corpus select | 32.6 | see `profile.term` | — |
| Mutation | 12.8 | see `profile.term` | — |
| Entire executor | 15,472 | 17,909 | 95.4% |
| Entire guardian | 15,074 | 16,753 | 89.3% |
| Guardian prepare | 9,416 | see `profile.term` | — |
| Trace setup (inside prepare) | 8,924 | 8,507 | 45.3% |
| Guardian finish | see `profile.term` | 5,677 | 30.2% |
| Trace destroy (inside finish) | 3,039 | see `profile.term` | — |
| Shared state check (inside finish) | 1,736 | see `profile.term` | — |
| Cleanup wait | 595 | 1,152 | 6.1% |
| Target body | 2.25 | 92.9 | 0.50% |
| Entire feedback | see `profile.term` | 389.7 | 2.1% |
| Corpus decision/save | see `profile.term` | 86.1 | 0.46% |

Worker accounting divides `iteration_total` into corpus select, mutation, input preparation, executor, feedback, corpus decision and `worker_unaccounted`; guardian accounting similarly divides guardian total into prepare, target, cleanup wait, finish and unaccounted. Both sum to 100% **by definition of the calculation**, rather than proving the absence of hidden cost. In no-op, `worker_unaccounted` is 293 µs and `guardian_unaccounted` 122 µs. These include gaps between measurements, IPC/scheduling, metadata creation, messages and code without its own timer. `executor_outer` is the difference between executor call time and guardian total; about 1156 µs/iteration in the OTP run. Further precise analysis should measure `DOWN` waiting, scheduler wait, reductions and GC separately instead of calling everything “other”.

To illustrate variability: no-op `executor` median/p90/p99 = 15,112/21,497/27,289 µs, `trace_setup` = 8,598/13,546/18,487 µs. In the OTP run, `get_coverage` = 14/17/44 µs, conversion = 38/51/79 µs and `feedback` = 324/540/1645 µs. These quantiles describe individual stages, not synchronous percentiles of a single iteration.

## 6. OTP native breakdown

In run `20261004T061001Z-otp_native_public`, the 1599 native read/reset calls include calibration. Mean per call: reset 1.82 µs, `code:get_coverage(line, M)` across four modules 15.25 µs, conversion 41.26 µs, novelty 15.88 µs. Merge ran 34 times at 26.4 µs per call; amortized, ~0.56 µs/iteration. The sum of the five stages was 74.77 µs/iteration, 0.398% wall time. `native_read` at 20.5 µs already includes get and schema checks; do not add it to `get_coverage`. `feedback` at 389.7 µs includes novelty, decoding new lines, schema checks and forming the decision; do not add the whole value to its nested stages. Even eliminating the entire measured public coverage pipeline alone would provide no more than ~0.4% speedup in this profile. This is an Amdahl upper bound for this run, not a forecast for a new OTP API.

## 7. Mutation and corpus

`bench/engine_mutation_micro.escript` with a fixed 51-byte input: one random mutation — median 1 µs (100 samples, resolution 1 µs); 1000 random mutations — median 879 µs per batch (10 batches, 865–918), about 1.14 million mutations/s; 1000 staged dictionary plan visits — median 654 µs (10 batches, 398 candidates per batch), **not** 1000 ready mutated inputs. Raw result: `docs/performance/engine-mutation-2026-10-04.term`. This is a local mutation estimate, not a comparison with libFuzzer's internal implementation. Random mutation is not the main limit at the current no-op ceiling. The worker's `mutation` stage in staged mode also measures `efz_mutation_plan:next/2` when profiling.

`efz_corpus:select/0` runs on every random iteration; `efz_worker:execute_allowed/4` calculates the input SHA256; `efz_worker:retain/3` decides retention. With no novelty, feedback returns `equivalent_coverage`, so no new corpus entry is written. `corpus_decision` at 86.1 µs/iteration in the OTP run **includes** occasional discoveries and filesystem writes, so it is not the pure price of the no-novelty path. Selection, hashing and retention require a separate controlled benchmark with a fixed history to estimate I/O; the current data do not reliably estimate maximum disk-write cost.

## 8. Worker/guardian cost and top bottlenecks

The top measured nonoverlapping substages for the no-op run:

| Stage | µs/iteration | Share | Candidate and risk | Limit if fully eliminated |
|---|---:|---:|---|---:|
| Trace setup | 8924 | 56.4% | Spike trace-session reuse; high risk to descendant control | 2.29× |
| Trace destroy | 3039 | 19.2% | Joint spike with trace setup; high stale-event risk | 1.24× |
| Shared-state check | 1736 | 11.0% | Measure components, then seek an equivalent; high risk of missing contamination | 1.12× |
| Cleanup wait | 595 | 3.8% | Reduce only with proven quiescence; high late-writer risk | 1.04× |
| Executor outer/IPC | ~398 | ~2.5% | Measure result/`DOWN` waiting separately; medium risk | ~1.03× |

The limits are calculated using Amdahl separately for each stage and **are not forecasts** of achievable speedup. Trace setup+destroy totals ~11.96 ms (~75.6%); eliminating both with no replacement cost would give a theoretical ~4.1× limit in this run. Removing them **without replacing their guarantees** is unacceptable. A practical first step is a limited spike on trace-session creation/reuse with proof of the boundary; the second is profiling `shared_state/0`. These are research tasks, not ready changes.

The short bitmap run achieved 24.43 exec/s; its `target_us` was 15.24 ms versus 0.32 ms for ETS and 0.093 ms for OTP public. Mutation histories differ, so this is not causal proof, but the source-level hit path needs a separate identical-input profile before the next bitmap optimization. This stage did not change the bitmap/ETS implementation.

## 9. EFZ and external erlang_fuzzer

| Property | EFZ | External `erlang_fuzzer` | Effect/transferability |
|---|---|---|---|
| Mutation | Erlang random/staged | libFuzzer | Different input histories; replacement can change corpus evolution |
| Execution | guardian/root per testcase | in-process loop | EFZ costs more but isolates the BEAM process tree |
| Process model | persistent worker, new guardian/coordinator/root | persistent driver | Adopting a persistent root changes crash/timeout isolation |
| Coverage | EFZ probes or OTP lines | native coverage features | Different semantics; counts are not equivalent |
| Corpus/feedback | EFZ novelty and retention | libFuzzer policy | Direct acceptance comparisons are invalid |
| Cleanup | kill, DOWN, trace barriers, shared checks | process reset/reuse | EFZ pays for quiescence and diagnostics; do not remove without a contract |
| IPC | multiple messages and monitors | direct call | Expected overhead difference |
| Persistence | new execution tree | reused in-process target | Reuse may accelerate execution under a different safety model |
| Crash/timeout | EFZ classification in a controlled tree | libFuzzer/NIF runtime | Different guarantees and failure types |

The 197× gap cannot primarily be attributed to one component. The most apparent 2–3 sources are the per-testcase guardian/trace lifecycle, a controlled process tree with IPC/cleanup, and an entirely different in-process mutation/feedback/corpus model. Measurements confirm the first as a large cost within EFZ, but **do not measure** its share of the difference from `erlang_fuzzer` under an identical input history.

## 10. Persistent execution design note

The worker is already persistent, but guardian/coordinator/root are not. A persistent root would reduce spawn/monitor and perhaps trace setup, but a timeout/crash can leave old descendants, mailbox messages, native coverage writes and shared state. A safe pool requires a per-execution capability, admission gate, coverage-context generation, proven quiescence, retirement of contaminated processes, restart on crash/timeout and deterministic barrier tests. The cost of these mechanisms must be measured. This is a separate design spike, not part of this patch.

## 11. OTP API decision and next steps

Measured `get_coverage` accounts for 0.081%, the entire measured coverage pipeline 0.398%, and even the full inclusive feedback 2.1% of an iteration. Therefore, **optimizing the OTP coverage API is not currently the main potential source of EFZ acceleration**. Compact binary and opaque check-and-advance options should be deferred. The next step is a paired, repeatable trace-lifecycle benchmark on a controlled host with a `+S` sweep, then a narrow safety-preserving prototype to reduce trace setup/destroy. The second candidate is optimizing shared-state checks after a separate profile. No decision is made to default to `otp_native_public`: OTP line coverage is not equivalent to EFZ structural probes, and the current 30-second runs do not prove policy/quality equivalence. ETS remains the default.

## 12. Checks and limitations

`rebar3 compile`, 3 focused EUnit tests, CT (3), xref and Dialyzer passed. Full EUnit under the default 16 schedulers: 257 PASS, 2 timeouts in existing staged tests (`efz:await(10000/60000)`); under `ERL_FLAGS='+S 1:1'`, full EUnit: 259 PASS, staged module: 8 PASS. The timeouts are tied to those tests' wall-clock budgets on a loaded host; test waits were not changed. Profiled and ordinary short no-op campaigns produced identical input IDs and retention reasons in the new test. `cleanup.term` for none and OTP runs shows `efz_fuzzer`, `efz_corpus`, `efz_stats` as `undefined` after stopping; no long-term leak check was performed. `profile.term` data are capped at 20k samples/stage; times have microsecond precision and include disturbance from profiling itself; use `--profile` only for diagnostics. The external-fuzzer comparison does not control identical inputs, target invocation or safety policy.
