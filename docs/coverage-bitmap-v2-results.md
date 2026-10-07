# Bitmap coverage v2: implementation and measured result

Date: 2026-10-02. This is a follow-up to the [v1 audit](coverage-bitmap-audit.md), not a replacement for its baseline. Bitmap remains explicit opt-in; `ets` remains the default.

## Changes and boundaries

* [`efz_worker:init/1`, `execute_checked/4`](../src/efz_worker.erl) allocate one execution map per bitmap campaign and pass it to each guardian. The final campaign report includes `bitmap_storage`: one allocated map, arm count, and normal reuse count. The worker runs iterations synchronously and does not arm a map until `efz_executor:run/4` has received the guardian's final `DOWN`.
* [`efz_guardian:finish/2`](../src/efz_guardian.erl) seals a compact successful bitmap observation only after the existing controlled-descendant cleanup has reached `confirmed`: admission stopped, all known descendants and coordinator down, process and global trace barriers delivered, runtime sampler stopped. A failed or unconfirmed cleanup marks the runner dirty. A guardian death is also converted to a dirty runner by [`efz_executor:guardian_failed/2`](../src/efz_executor.erl). No map from such an execution is rearmed; the campaign stops. A late writer may still mutate its **retired** allocation after guardian death, but cannot write into the next execution map. This contract covers admitted local descendants, not arbitrary remote or uncontrolled processes.
* [`efz_cov_bitmap:allocate/1`, `open/2`, `seal/1`](../src/efz_cov_bitmap.erl) use a reusable unsigned `atomics` word array, an active state, and a generation number. `open/2` full-clears 1,024 words for the default 65,536-bit map and advances the generation. A sealed token from an earlier generation is rejected even after a later execution is sealed. `Active=0` alone is **not** accepted as evidence of writer quiescence; the guardian lifecycle supplies that evidence. The prior `open/1`, `snapshot_bits/1`, `reset/1` and immutable snapshot path remain for low-level differential tests and fallback.
* [`efz_cov_bitmap:has_new/2`](../src/efz_cov_bitmap.erl) scans words with `Current AND NOT Global`, exiting on the first new word. [`efz_feedback:bitmap_sealed_success/5`](../src/efz_feedback.erl) leaves global untouched when no new bit exists; on novelty it decodes only the **new** bits for the existing exact `new_probes` decision and then performs a separate wordwise global merge. Crash, exit, timeout and infrastructure outcomes still do not merge. The feedback module accesses bitmap operations through [`efz_coverage`](../src/efz_coverage.erl).
* The ordinary campaign success path no longer materializes a full bitmap snapshot or all observed probe IDs. First-hit messages remain in the guardian's integrity accounting; a wordwise bit count confirms that their number matches the sealed map. [`efz_cov_integrity:observation_count/3`](../src/efz_cov_integrity.erl) preserves the observation classification/count. The old exact list is still produced for failures, low-level executor calls and campaigns with runtime oracles enabled. Final global reporting still decodes exact IDs. Instrumentation, harness API, mutation engine, crash classification, and corpus acceptance were not changed.
* [`efz_config:valid_field/2`](../src/efz_config.erl) rejects capacities above 2^26 bits (8 MiB payload) before campaign startup; capacity must remain positive and divisible by 64. The default is 65,536 **bits** (8 KiB payload). A default v2 allocation uses about 8,232 bytes for words plus 56 bytes for active/generation atomics, plus schema, reverse IDs, binaries, Erlang terms and allocator overhead.

## Isolation and reuse state machine

`worker-owned map (inactive) → guardian arm/full clear → controlled writers → guardian confirmed cleanup → seal → worker comparison → optional commit → corpus decision → next arm`.

The sealed map remains unchanged while feedback reads it because the worker does not start another execution until that feedback/corpus step finishes. If cleanup is unconfirmed or the guardian dies, the runner becomes dirty and the old map is retired with the worker/VM; a subsequent execution in that runner is refused. A new runner/campaign allocates a new map. The generation prevents accidental reads through stale sealed tokens. A single active check does not close the check-to-CAS race and is not used as a reclamation proof. Controlled writer termination and trace draining remain the actual seal boundary.

## Verification

Baseline before changes: 241 EUnit PASS. After v2: 243 EUnit PASS, 3 CT PASS, xref PASS, Dialyzer PASS. Commands:

```sh
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
```

[`efz_bitmap_audit_tests`](../test/efz_bitmap_audit_tests.erl) add 10,000 A/B re-arms on one map, stable atomics allocation size, stale-generation rejection, a barrier-controlled retired-map late writer, and ETS/v2 feedback comparison across success, repeated coverage, crash and timeout. [`efz_isolation_tests`](../test/efz_isolation_tests.erl) add a fresh-VM bitmap guardian-death case: cleanup is unconfirmed, the runner is dirty and refuses the next execution. [`efz_bitmap_contract_tests`](../test/efz_bitmap_contract_tests.erl) assert campaign map allocation/reuse counts and invalid capacity rejection. The existing full differential tests continue to compare observed IDs, novelty, global coverage and corpus decisions. These tests do not force a real cleanup deadline overrun in a live VM; guardian death exercises the unconfirmed/retirement path deterministically.

## Benchmark protocol and results

Commands (raw files are retained alongside this report):

```sh
ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-v2-benchmark-final-code
ERL_FLAGS='+S 4:4' escript bench/bitmap_audit_bench.escript _build/bitmap-v2-baseline-full-cycle.term
ERL_FLAGS='+S 4:4' escript bench/bitmap_v2_cycle_bench.escript docs/performance/bitmap-v2-cycle-2026-10-02.term
ERL_FLAGS='+S 4:4' escript bench/bitmap_v2_components.escript docs/performance/bitmap-v2-components-2026-10-02.term
```

Environment: OTP 27.0, ERTS 15.0, Linux x86_64, Intel Core i7-1260P, `+S 4:4`. The paired campaign and full-cycle drivers use two warmup pairs and 10 alternating pairs. The component driver uses two warmups and ten samples of 100, 1,000 or 10,000 calls. The parser campaign runs 50 seeded random-mutator executions against `efz_example_target`/`efz_example_parser`; corpus size 4 and final coverage size 5 matched in every sample. These are short local measurements; CPU frequency/scheduler noise and a single harness limit generalization. V1 measurements were taken before the code changes in this same checkout and preserved as [v1 campaign/micro raw data](performance/bitmap-v2-v1-baseline-2026-10-02.term) and [v1 full cycles](performance/bitmap-v2-v1-full-cycle-2026-10-02.term). V2 campaign/micro [run 1](performance/bitmap-v2-2026-10-02-samples.term), [run 2](performance/bitmap-v2-2026-10-02-final-samples.term), and [final-code run 3](performance/bitmap-v2-2026-10-02-final-code-samples.term), three-way [full cycles](performance/bitmap-v2-cycle-2026-10-02.term), and [component data](performance/bitmap-v2-components-2026-10-02.term) are separate.

Medians, microseconds unless marked exec/s:

| Workload | ETS | bitmap-v1 | bitmap-v2 |
|---|---:|---:|---:|
| Parser campaign, exec/s | 362 / 264 | 325 | 255 |
| Full cycle, 1 hit | 4 | 411 | 195 |
| Full cycle, 100 hits | 106 | 432 | 250 |
| Full cycle, 1,000 hits | 2,832 | 985 | 773 |
| Full cycle, 10,000 hits | 9,685 | 7,143 | 6,939 |
| Full cycle, 10,000 repeated hits | 5,805 | 10,479 | 8,731 |
| Repeated hit stage, 5,000 hits | 927 / 1,887 | 1,546 | 2,928 |
| Full clear / arm | <1 (fresh ETS table) | 21 (clear-only benchmark) | 15.01 (clear plus arm, 100 calls/sample) |
| Novelty, 256 local/128 global | 82 (exact new IDs) | 27 (new bitmap) | 0.197 (boolean early exit) |
| Merge, 256 local/128 global | 57 | 28 | 43.72 |

For parser and repeated hits, slash-separated ETS values are the v1 baseline and final-code v2 paired run; they are **not** interchangeable denominators. V1 median wall time was 153,702 µs bitmap vs 138,236 µs ETS; final-code v2 was 195,798 vs 189,237 µs. Median paired bitmap/ETS exec/s ratios were **0.881** v1 and **0.974** final v2 (10 pairs each). The two other v2 paired ratios were **0.938** and **0.984**; the original audit reported 0.893 from its earlier independent run. The v2 runs show substantial wall-time variation and no reliable parser win. The three-way full-cycle rows are from one paired run and are directly comparable as algorithms, but that run uses the v2 source's small repeated-hit change for both bitmap paths; the untouched historical v1 full-cycle medians are 419, 431, 1,852, 8,844 and 8,517 µs respectively. The novelty row intentionally reports different return contracts: ETS returns exact IDs, v1 materializes a new bitmap, v2 returns only a boolean; v2 decodes exact new IDs only after `true`. Reset rows have different operations and sub-microsecond ETS timing; use component measurements for reset cost rather than a speedup ratio.

V2 component medians (µs/call, min–max in raw data): full clear/arm **15.01**, sealed count sparse **25.83**, sealed count dense **53.39**, no-novelty sparse **24.00**, no-novelty dense **23.47**, novelty first word **0.084**, novelty last map word **23.27**, and 256-slot merge **43.72**. The 5,000 repeated-hit stage remains slower than ETS in all v2 runs: 1,486 vs 998 µs, 1,361 vs 890 µs, and 2,928 vs 1,887 µs.

In isolated 10,000-call component samples, process-dictionary lookup took **0.007 µs/call**, integrity registry lookup **0.210**, exact slot ETS lookup **0.100**, atomic read **0.021**, and complete repeated `efz_cov_rt:hit/1` **0.431**; these separately timed costs are not strictly additive. This setup has no guardian registry, so the integrity measurement exercises the missing-registry branch rather than a registered production writer. The repeated-hit path still pays both ETS lookups and guards even though its bit is already set. Those lookups and the full-map count/no-novelty scans are the remaining measured bottlenecks for sparse executions. The default full clear is simpler and cheaper than the combined sparse count/check cost; dirty words were not added because they would burden each hit and need a separate concurrent bookkeeping design and end-to-end win.

## Decision and remaining work

Correctness and feedback compatibility: **PASS** for the tested controlled-process contract. Concurrency/isolation: **PASS** for admitted local descendants, confirmed cleanup and dirty-runner retirement; uncontrolled remote processes remain outside EFZ's existing contract. Memory: **PARTIAL**: a normal campaign allocates one map and 10,000 reuse cycles keep its atomics sizes constant, but no long-running RSS study was performed. Performance: **FAIL** for the default-switch gate: v2 improves the paired parser ratio, yet the paired median remains below 1 in all three runs with large variation, and repeated hits are slower. Maintainability: **PARTIAL**: v1 and compact paths coexist deliberately for differential comparison; the compact path has lifecycle coupling documented above.

Keep `coverage_backend => ets` as default. Bitmap-v2 is available only by explicit `coverage_backend => bitmap` for automatic presence. Roll back by removing that option or setting `coverage_backend => ets`. Before reconsidering the default, repeat paired parser and additional representative harness campaigns, run a long campaign RSS/resource test, and profile whether hit lookup or sparse full-map scans dominate those workloads. Do not adopt dirty-word tracking or OTP-native coverage without its own measured correctness/performance case.
