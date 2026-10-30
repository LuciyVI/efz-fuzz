# Bitmap coverage backend: implementation report

Historical bitmap-v1 baseline. The current campaign path reuses a sealed map;
see the [bitmap-v2 follow-up](coverage-bitmap-v2-results.md). Measurements and
the no-reuse statements below describe v1 at the time of this report.

Date: 2026-10-02. Checkout: `8b5cb05b5b57231b9133be13c883f25863e05d11` plus existing uncommitted changes. This work did not overwrite unrelated dirty files or change the default backend. The [architecture](coverage-bitmap-architecture.md) and [plan](plans/coverage-bitmap-implementation-plan.md) define the intended contract.

## Implemented

| Boundary | Files and API |
| --- | --- |
| Mapping/storage | [`efz_cov_bitmap.erl`](../src/efz_cov_bitmap.erl): `prepare/2`, `open/1`, `hit/2`, `snapshot_bits/1`, `reset/1`, `close/1`, `release/1`, `unseen_bits/2`, `merge_bits/2`, `decode/2`. |
| Dispatch | [`efz_coverage.erl`](../src/efz_coverage.erl): internal `open/3`, `prepare_schema/2`, `new_global/1`, `snapshot_bits/1`, bitwise comparison/merge and diagnostic decode. Existing ETS API remains. |
| Selection/lifecycle | [`efz_config.erl`](../src/efz_config.erl) validates bitmap only for automatic presence and capacity before campaign; [`efz_worker.erl`](../src/efz_worker.erl) owns schema/global and removes internal bits from persisted results; [`efz_guardian.erl`](../src/efz_guardian.erl) collects bits after its controlled writer cleanup; [`efz_executor.erl`](../src/efz_executor.erl) validates schema/build pins; [`efz_feedback.erl`](../src/efz_feedback.erl) applies the existing success-only commit policy. [`efz_instrument_pt.erl`](../src/efz_instrument_pt.erl) excludes the new internal module from target instrumentation. |
| Tests/measurements | [`efz_bitmap_contract_tests.erl`](../test/efz_bitmap_contract_tests.erl), bitmap cases in [`efz_isolation_tests.erl`](../test/efz_isolation_tests.erl), paired [`bitmap_bench.escript`](../bench/bitmap_bench.escript), [raw samples](performance/bitmap-2026-10-02-samples.txt). |

The instrumentation still emits `efz_cov_rt:hit({Module,BuildId,ProbeId})`; harnesses and mutation operators do not touch the backend. Worker prepares a protected `FullId → Slot` ETS table from validated manifests, sorting full IDs by UTF-8 module name, all 32 BuildId bytes, and ProbeId. It rejects duplicates and `N > coverage_bitmap_bits`. A versioned SHA-256 fingerprint includes the metric, schema/instrumentation versions, capacity and canonical identities. Unknown hits and incompatible fingerprints fail explicitly. The default **65,536 bits** require **8 KiB of payload**, plus atomics, mapping, reverse tuple, context and allocator overhead. There is no modulo, hashing or cross-build bitmap import.

Each controlled execution gets a unique unsigned `atomics` word array and active flag. An admitted process receives the context explicitly through the existing guardian gate. Slot `s` uses atomics index `s div 64 + 1` and mask `1 bsl (s rem 64)`; `compare_exchange/4` retries stale reads, including bit 63. Guardian already stops admission, terminates controlled descendants and waits for `DOWN`/trace barriers before snapshot. A single active-flag check cannot close the check-to-CAS race; therefore production never reuses an old mutable map. Confirmed results receive an immutable 8 KiB snapshot; unconfirmed cleanup is an infrastructure failure and cannot commit. `reset/1` allocates a new map. `clear_quiescent/1` is only a measured primitive for callers that have separately proved all writers stopped. The worker owns the immutable global snapshot and serial compare/commit. Only a valid `{ok,_}` result changes it; crash, exit and timeout retain their existing classification/artifact behavior without a global merge. Public observations and reports retain exact IDs; diagnostic decode is outside the hit path.

## Validation

Before implementation: `ERL_FLAGS='+S 4:4' rebar3 compile`, full `eunit` (**226 passed**), `ct` (**3 passed**), `xref`, and `dialyzer` all passed. The old `bench/run.escript all _build/bitmap-baseline reference` remained in its long `hooks` stage for more than three minutes and was interrupted; it has **no complete baseline result**. The historical `ERL_FLAGS='+S 4:4' escript scripts/coverage_bench.escript` was run after implementation and passed, but is an instrumentation hook microbenchmark, not an end-to-end bitmap comparison. An early parallel post-change Rebar3 run failed 20 fresh-VM EUnit cases with `undef` while multiple commands were compiling into the same build tree, and Dialyzer reported an explicit-exception spec warning. After serial execution and a `no_return()` spec, results were:

| Command | Result |
| --- | --- |
| `ERL_FLAGS='+S 4:4' rebar3 compile` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 eunit` | PASS, 238 tests |
| `ERL_FLAGS='+S 4:4' rebar3 ct` | PASS, 3 tests |
| `ERL_FLAGS='+S 4:4' rebar3 xref` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 dialyzer` | PASS |

Contract tests cover empty and repeated observations, slot 0/63/64/last, overflow, same local ID in two modules, incompatible builds/snapshots, one/multiple/no new bits, A→B→A, global isolation, success/crash/timeout feedback, deterministic stale-read CAS retry, shared writers and late contexts. Controlled descendant and timeout tests use messages/barriers, not sleeps alone. Seeded ETS→bitmap→ETS campaigns compare corpus and exact coverage decisions; low-level executor tests compare equal event histories. These do not prove isolation of arbitrary raw `spawn` or remote processes, which the existing EFZ guardian does not own.

## Benchmark

Command: `ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-benchmark`. Raw per-sample time, reductions and minor GC data: [bitmap-2026-10-02-samples.txt](performance/bitmap-2026-10-02-samples.txt). The driver warms twice, takes 10 alternating paired samples per stage, and stores a binary term under `_build/bitmap-benchmark/bitmap-benchmark.term`. Environment: OTP 27.0, ERTS 15.0, Rebar3 3.25.0, Linux x86_64, Intel i7-1260P, `+S 4:4`; 65,536-bit bitmap, 1,024 synthetic manifest probes. Script SHA-256 `975240e42d32a96228d7c177f33053492904c2c9a3aaca1a71d766168e95266b`; bitmap module SHA-256 `e1e5d44bc248c031b8724bb99c1d8bd34109cb1a3a048989e8e2b31398b1fa99`; parser fixture SHA-256 `c834f09eb2bbeabf54c2948ad849ab0f9294e2e455f35ead54d75f589be35747`.

| Stage (median microseconds) | ETS | Bitmap |
| --- | ---: | ---: |
| 5,000 repeated hits | 825 | 1,401 |
| 64 sparse hits | 18 | 23 |
| 1,024 distinct hits | 650 | 775 |
| 64-hit snapshot | 15 | 37 |
| 1,024-hit snapshot | 284 | 41 |
| Decode 1,024 IDs | 324 | 85 |
| Quiescent full clear | 1* | 18 |
| Compare 256 bits/IDs | 84 | 29 |
| Merge 256 bits/IDs | 58 | 28 |
| Ten sparse full cycles | 124 | 6,826 |
| Five dense full cycles | 23,418 | 11,310 |
| 1/2/4/8 writers in one word | 3,925 / 7,758 / 16,061 / 28,523 | 4,499 / 7,825 / 16,324 / 29,044 |
| 50-execution parser campaign wall time | 116,580 | 129,445 |

`*` ETS comparison is fresh table creation, not clear; 0–1 µs is below useful timer resolution. Parser workload uses `efz_example_target`, seeded random mutator, fixed 50 executions, same corpus size 4 and reported coverage size 5 in every sample. Its bitmap/ETS exec/s ratio from median wall times is about **0.90**; the median of 10 paired exec/s ratios is **0.887**, with a percentile bootstrap 95% interval **[0.825, 0.985]** (10,000 resamples, seed `20261002`). Parser wall-time p95 (nearest rank of 10 samples) is **145,333 µs ETS** and **144,728 µs bitmap**. Sparse full cycle is substantially worse; dense bitmap compare/snapshot is better. No general speedup follows. `atomics:info(memory)` reports 8,232 bytes for words and 48 for active flag; mapping ETS reports 20,084 VM words and reverse tuple external size is 58,633 bytes. ETS 1,024-hit execution table reports 22,071 VM words. These figures are partial component sizes, not a total campaign RSS comparison. The campaign benchmark does not isolate external scheduler/thermal noise, and no second production harness was run. Therefore the plan's opt-in performance gate fails on this measured parser workload, and the default-switch gate is **NOT MET**. Bitmap remains experimental opt-in; no reset or hot-path optimization was added after measuring.

## Selection, rollback and remaining work

In an API campaign config, use `#{coverage => automatic, coverage_feedback => presence, coverage_backend => bitmap, coverage_bitmap_bits => 65536, ...}`; pass instrumented artifacts as usual. For rollback, set `coverage_backend => ets` or remove that key. `ets_member` and ETS `hit_count` remain available. CLI campaign backend selection is not exposed; no harness API change is needed. Recompile/reload requires a fresh campaign and revalidated manifests. Corpus input bytes may be recalibrated; stored coverage bits require the exact fingerprint and are not imported between builds.

Still open: complete the historical P0 benchmark without interruption; repeat performance on representative production harnesses with paired confidence intervals, p95 and complete memory/RSS; decide whether sparse map cost warrants a different storage layout. Production default remains ETS. OTP-native coverage, edge coverage, buckets, NIF and OTP patches are outside this implementation.
