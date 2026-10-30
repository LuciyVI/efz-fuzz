# Bitmap coverage backend implementation plan

**English** · [Русский](../i18n/ru/plans/coverage-bitmap-implementation-plan.md) · [Español](../i18n/es/plans/coverage-bitmap-implementation-plan.md) · [简体中文](../i18n/zh-CN/plans/coverage-bitmap-implementation-plan.md) · [All languages](../i18n/README.md)

Status: P1–P7 were implemented and verified on October 2, 2026; P0 performance baseline and P8 rollout are incomplete. Detailed results are in the [report](../coverage-bitmap-implementation-report.md). The basis is the [architecture document](../coverage-bitmap-architecture.md), checked against current source. First version: `automatic` + `presence`, one EFZ worker, an ordinary OTP build, existing structural probes. `ets` remains default and reference; `ets_member` and ETS `hit_count` continue to work. OTP/ERTS patches, DWARF, NIF, edge coverage, hit-count buckets for bitmap, harness changes and mutation-engine changes are excluded.

## Verified starting point and architecture corrections

| Contract | Evidence in code |
| --- | --- |
| `efz_instrument:compile_target/2` enables `efz_instrument_pt`; `probe/4` inserts `efz_cov_rt:hit({Module,BuildId,ProbeId})` into a clause/outcome body. `ProbeId` starts at 1 within each module build. | [`efz_instrument.erl`](../../src/efz_instrument.erl), [`efz_instrument_pt.erl`](../../src/efz_instrument_pt.erl) |
| The current hit entry checks PID/context and sends the first-hit event; ETS stores exact identities. `efz_cov` provides the public compatibility API, `efz_coverage` already dispatches, and `efz_cov_ets` implements storage and current set operations. | [`efz_cov_rt:hit/1`](../../src/efz_cov_rt.erl), [`efz_cov.erl`](../../src/efz_cov.erl), [`efz_coverage.erl`](../../src/efz_coverage.erl), [`efz_cov_ets.erl`](../../src/efz_cov_ets.erl) |
| The guardian creates a new context/table per execution; root and `efz_target:spawn[_link]/1` are admitted through a gate and attached explicitly. Multiple writers write one execution table. After timeout/completion, the guardian stops admission, kills survivors, waits for `DOWN`/trace barriers and takes a snapshot. Unsuccessful cleanup marks the runner dirty. | [`efz_guardian:start/6`, `admit/2`, `cleanup/2`, `finish/2`](../../src/efz_guardian.erl), [`efz_target.erl`](../../src/efz_target.erl), [`efz_cov_integrity.erl`](../../src/efz_cov_integrity.erl) |
| `efz_feedback:evaluate/3` compares `Observed − Global` and merges **only** `coverage_status=ok`, `outcome={ok,_}`. Calibration updates global without adding the seed again. Crash/exit/timeout do not update global. The worker retains corpus inputs by `retention_reason`; crash artifacts use a separate path. | [`efz_feedback.erl`](../../src/efz_feedback.erl), [`efz_worker:execute_result/6`, `retain/2`, `record_failure/4`](../../src/efz_worker.erl), [`efz_corpus.erl`](../../src/efz_corpus.erl) |
| `rebar.config` requires OTP 27 minimum and `warnings_as_errors`; locally verified OTP 27.0 / ERTS 15.0, x86_64, Rebar3 3.25.0. `atomics` exports `compare_exchange/4`, but no OR; an unsigned array accepts and returns `1 bsl 63` and `2^64−1`. CAS returns `ok` on success and the previous value on mismatch. This is a local API check, not performance proof. | [`rebar.config`](../../rebar.config); commands below |
| Tests: `rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests`, `rebar3 ct`, full `rebar3 eunit`, xref/dialyzer. Integration: `efz_coverage_SUITE`, `efz_feedback_loop_tests`, `efz_isolation_tests`, `efz_backend_tests`. Bench: `scripts/coverage_bench.escript`, `bench/run.escript` (`hooks`, `executor`, `campaign`, `memory`, `startup`), `bench/profile.escript`. | [`test/`](../../test), [`bench/run.escript`](../../bench/run.escript), [`bench/efz_perf.erl`](../../bench/efz_perf.erl), [`scripts/coverage_bench.escript`](../../scripts/coverage_bench.escript) |

Check in this session: `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests` — **18/18 PASS**. This is the existing ETS baseline, not bitmap validation. The source tree was already dirty; logical and timing baselines need an exact commit/diff and separate result directories.

Reproduce the primitive check on this OTP without changing files:

```sh
erl -noshell -eval 'A=atomics:new(1,[{signed,false}]), M=1 bsl 63, ok=atomics:compare_exchange(A,1,0,M), M=atomics:get(A,1), ok=atomics:compare_exchange(A,1,M,16#ffffffffffffffff), 16#ffffffffffffffff=atomics:get(A,1), io:format("~p~n",[atomics:module_info(exports)]), halt().'
```

Corrections were made in the original architecture: configuration rejects bitmap + `hit_count` for the first version; signedness and CAS on the verified OTP 27.0 were specified. Another important implementation detail: current `efz_coverage:unseen/2` and `merge/2` work with Erlang sets/lists, and `Result.coverage` is an exact-identity list. Bitwise comparison therefore needs an **internal** snapshot alongside the existing public list; replacing `hit/2` alone is insufficient. The current guardian can form a Hits list even with dirty cleanup, but marks `coverage_status` as an error; bitmap likewise must not treat that list as stable/eligible for commit.

## Final decisions for the first version

### A. Schema and slot

The sole key is `{Module, BuildId, ProbeId}` from validated manifests. At campaign preparation, [`efz_cov_manifest:prepare/2`](../../src/efz_cov_manifest.erl) remains the allowlist/build-pin source; bitmap preparation builds a separate **immutable schema descriptor** tied to that plan. Sort by UTF-8 module name, all 32 BuildId bytes, then positive ProbeId; verify uniqueness; assign sequential slots `0..N−1`. The worker owns protected ETS `FullId → Slot`, while a reverse array/tuple `Slot → FullId` is needed only for snapshot/report. Retain full identity in lookup: equal `ProbeId` values across modules/builds receive distinct slots. Build map and SHA-256 of a versioned canonical sequence form the schema fingerprint. Schema/build mismatch is an infrastructure error before comparison; do not ignore new/unknown probes.

Calculate the fingerprint from an explicit format version, metric `clause_outcome_probe`, manifest/instrumentation versions, capacity and canonical identity sequence; do not rely on unspecified ETF map order. Configuration `coverage_bitmap_bits`: default **65536 bits**, an integer multiple of 64; `N > capacity` is a clear preparation error with `required_bits` and `configured_bits`. There is no automatic growth during a campaign. Users can choose a larger map **before** startup. Unused slots stay zero. No `rem MapSize`, truncation or BuildId mixing. Saved corpus input bytes may be recalibrated on a new build; coverage bitmaps do not transfer automatically between builds. The first version adds no format for persisting a global bitmap to disk.

### B. Mutable map and bit 63

The execution map is `atomics:new(Capacity div 64,[{signed,false}])`, with unsigned 64-bit words. For `Slot ∈ [0,Capacity)`, calculate `Word = Slot div 64 + 1` (the atomics API is 1-based) and `Mask = 1 bsl (Slot rem 64)`. For slot 63, mask is `2^63`, valid in an unsigned array; slot 64 uses word 2, mask 1. Check bounds and schema lookup first, then a CAS loop: `Old=atomics:get`; if `(Old band Mask) /= 0`, finish; otherwise `compare_exchange(Ref,Word,Old,Old bor Mask)`; `ok` means first hit, a returned current value means retry. On `badarg`, notify the guardian of backend failure. Send `efz_cov_observed` **after** successful 0→1 CAS, exactly once per bit. Never replace CAS with `get` + `put`. Reading and merging must account for unsigned masks and the final word; `Slot >= N`/a bit beyond the schema is not a probe.

### C. Isolation, snapshot, reset

The guardian owns **a separate map per execution** and retains current `{efz_context,1,Ref,Storage,Owner}` as the outer wire shape; `Storage` becomes an opaque tagged handle. Pass context only through existing `efz_guardian:admit/2` and `efz_coverage:attach/1`. Do not rely on process-dictionary inheritance. Keep the PID registry and checks in `efz_cov_rt:hit/1`. After timeout, the guardian closes admission and terminates all controlled writers, including descendants, waits for `DOWN` and trace barriers, then takes a snapshot. First-hit/error events must also be drained/checked against the snapshot.

A flag/epoch can reject a late hit quickly, but checking `active` before CAS **does not close** the window between check and write. Safety comes from a unique execution map, no reuse before proven quiescence and rejection of valid snapshot/commit on unconfirmed cleanup. After close, a late hit should yield a diagnosable infrastructure error; even if a race allows CAS into the **old** map, it cannot write into the next iteration. With unconfirmed cleanup, do not clear/reuse the old map; retire the runner, and do not treat the event as successful coverage. The first implementation releases the map after a confirmed snapshot; a new iteration allocates a new map: this is the safe production reset. Implement/measure **full clear** (`atomics:put(...,0)` across all words) only for a proven-quiescent map in a test/benchmark; enable reuse in production only if lifecycle proves exclusive ownership. Dirty-word tracking and epochs come only after P8.

### D. Global and feedback

The worker remains the sole policy owner. [`efz_feedback:evaluate/3`](../../src/efz_feedback.erl) checks status and outcome **before** bitmap compare/merge. For a successful presence result, `Local & ~Global` produces exact new identities for existing `new_probes`/`retention_reason`; after the decision, global becomes `Global | Local`. The first version's global is an immutable binary with fingerprint in worker state: a new value is built **per iteration**, not per hit, and installed only after a successful decision. Crash/exit/timeout and infrastructure results leave global unchanged. Do not give the backend a function that independently decides corpus retention. `efz_worker:retain/2` and `record_failure/4` stay active. Future multi-worker operation would require compare-and-commit serialization; currently `workers=1`.

### E. API, metadata, compatibility

Preserve `efz_cov_rt:hit/1`, `efz_cov:open/0,/1,/2`, `attach/1`, `detach/0`, `snapshot/1`, `close/1`, the manual API, `efz_executor:run/4`, `Result.coverage` (sorted exact IDs), `efz_feedback:evaluate/3` and the public campaign report. Extend **internal** `efz_coverage:open/3` with a validated-schema parameter, leaving `open/2` for ETS; add `prepare_schema/2`, `snapshot_bits/1`, `new_global/1`, `unseen_bits/2`, `merge_bits/2`, `decode_new/2` (exact names may be adjusted in P1, semantics may not). New `-opaque bitmap_schema()` / `bitmap_context()` / `bitmap_snapshot()` must hide the atomics handle and schema fingerprint; check descriptor version at every boundary. For a successful bitmap result, pass internal immutable `coverage_bits` with fingerprint to the worker, while decoding ordinary `coverage` at execution completion for validation/reporting. The extra low-level `run/4` field is not part of the persisted format: the worker removes it before crash/runtime artifacts, failure context and campaign reports; crash/timeout results do not carry it. Do not confuse this field with existing `coverage_observation` (a classification map). Fingerprint comparison is mandatory for `unseen_bits/merge_bits`. Diagnostics translate set bits through reverse mapping into probe IDs and manifest source positions; existing reports/crash artifacts receive the same ID list.

Reject bitmap + `hit_count` and bitmap + `manual` at `efz_config:prepare/1` and low-level `open/3` before target execution. `ets`/`ets_member` continue to support both current modes. Backend selection neither changes the instrumentation manifest nor transfers old global coverage into a new campaign.

## Stages and acceptance conditions

Run commands from the `efz` root; fix `ERL_FLAGS='+S 4:4'` for tests/benchmarks. For each stage, commit only its files after validation; fallback means removing/disabling the added path, restoring `coverage_backend => ets` and not migrating persisted coverage. New filenames below are proposals; existing modules are listed by actual functions.

| Stage | Concrete work and API | Depends on | Check / observable result / acceptance | Rollback |
| --- | --- | --- | --- | --- |
| **P0 Baseline** | Record commit/diff, OTP and `erl:system_info`, manifests, exact history and seeded-fixture decisions. Add baseline fixture/event recording in `test/efz_backend_tests.erl` and new `test/efz_bitmap_contract_tests.erl` without a bitmap branch. Store raw benchmarks in `_build/bitmap-baseline/`, not historical-log docs. Do not change APIs. | None | `rebar3 compile`; `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests`; `ERL_FLAGS='+S 4:4' rebar3 ct`; `ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference`. Exact IDs, global/decisions, commands and raw samples are recorded without acceleration claims. | Remove only new baseline fixtures/artifacts; production code untouched. |
| **P1 Backend boundary** | Refine dispatch in `src/efz_coverage.erl` and legacy adapter `src/efz_cov_ets.erl`; preserve delegation of `open/2`, `attach/1`, `hit/2`, `snapshot/1`, `close/1`, `unseen/2`, `merge/2`. Add internal types/`open/3` with explicit rejection of `bitmap` without schema. Do not change `efz_cov_rt:hit/1`/`efz_cov` behavior. | P0 | Focused EUnit + `rebar3 xref`; legacy context shape, events, error/status and corpus decisions match P0 byte-for-byte/structurally. | Restore current dispatch. |
| **P2 Mapping** | `src/efz_cov_manifest.erl`: preserve `prepare/2`/`validate_prepared/3`; add schema preparation from validated manifests/plan. If needed use `src/efz_cov_bitmap.erl` for immutable mapping; `src/efz_config.erl` capacity validation comes later, initially use an internal argument. Implement `FullId→Slot`, reverse map, fingerprint, overflow/unknown/mismatch errors. | P1 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests`; bijection, same local ID across modules, BuildId, 0/last/overflow. No collisions. | Remove mapping module/branch without changing the ETS plan. |
| **P3 Storage** | `src/efz_cov_bitmap.erl`, `src/efz_coverage.erl`: unsigned atomics map, bounded slot lookup, CAS hit, first-hit event, `snapshot_bits/1`, full clear after quiescence. Internal opaque handle; `efz_cov_rt:hit/1` stays unchanged. | P2; successful bounded CAS spike below | Focused EUnit, synchronized two writers on one word, slots 0/63/64/last, repeated hit, unsigned high bit, malformed handle. All bits/events exact; unsupported OTP stops preparation. | Remove bitmap dispatch; ETS untouched. |
| **P4 Lifecycle** | `src/efz_guardian.erl:start/6,admit/2,cleanup/2,finish/2`, `src/efz_executor.erl:coverage/3`, `src/efz_worker.erl:executor_reference_options/1`, `src/efz_cov_integrity.erl`: pass schema to `open/3` also for `coverage_validation=per_execution`, await quiescence before snapshot, validate first-hit evidence, prohibit reuse after dirty cleanup, diagnose late hits. Do not change `efz_target` API. | P3 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_backend_tests,efz_isolation_tests,efz_bitmap_contract_tests`; barriers for hit-vs-timeout, child admission, cleanup failure, A→B→A. Only confirmed results have stable snapshots; dirty never commits. | Disable bitmap selection; guardian ETS branch unchanged. |
| **P5 Comparison** | `src/efz_coverage.erl`: bitmap `new_global/1`, `unseen_bits/2`, `merge_bits/2`, `global_snapshot/1`, fingerprint checks; `src/efz_feedback.erl:new/3,evaluate/3`: new internal initializer with schema, preserve `new/1,/2`; presence branch compares/merges only successful immutable snapshots; `src/efz_worker.erl:init/1,execute_checked/4,execute_result/6,record_failure/4`: create schema/global, use internal bits and remove them from persisted/report/failure-context metadata. External `Result.coverage`, `new_probes`, retention_reason unchanged. | P4 | One synthetic event history through ETS/bitmap, `efz_feedback_loop_tests`; global unchanged after crash/timeout, matching calibration/mutation decisions, mismatched snapshot error, no internal bits payload in crash/replay files. | Return presence to ETS-set path; do not touch corpus API. |
| **P6 Config/integration** | `src/efz_config.erl:valid_field/2,prepare_coverage/1`, `src/efz_worker.erl:init/1,executor_reference_options/1`, `src/efz_guardian.erl:start/6`, `docs/cli.md`: accept **API** config `bitmap` and `coverage_bitmap_bits`, reject manual/hit_count pairs and over-capacity before execution. Campaign CLI currently has no backend flag; adding one is not required. Default `ets`. `efz_recipe:execute/5` and `efz_replay_cli` retain reference ETS input replay, checking the same exact identities. Harness/mutator unchanged. | P5 | `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_config_tests,efz_backend_tests,efz_cli_tests,efz_phase3_tests`; `ERL_FLAGS='+S 4:4' rebar3 ct`. API selects bitmap, CLI/replay with ETS preserve previous results, invalid pairs yield stable errors. | Restore config allowlist `ets,ets_member`; replay path unchanged. |
| **P7 Differential acceptance** | `test/efz_bitmap_contract_tests.erl`, `test/efz_backend_tests.erl`, `test/efz_coverage_SUITE.erl`, `test/efz_feedback_loop_tests.erl`: one prescribed event history for storage/feedback; then identical fixtures/seeded campaigns on both backends. Compare exact coverage, statuses, novelty, corpus IDs/content, crash/timeout evidence. | P6 | `ERL_FLAGS='+S 4:4' rebar3 eunit`; `ERL_FLAGS='+S 4:4' rebar3 ct`; `rebar3 xref`; `rebar3 dialyzer`. Zero contract differences; compare a nondeterministic real harness by invariants/repeats, not character-for-character trace. | Switch default to ETS, disable experimental bitmap branch. |
| **P8 Benchmark/rollout** | Extend `bench/efz_perf.erl`/`bench/run.escript` with bitmap variant and separate `hit/clear/snapshot/compare/merge/full-cycle` workloads; `bench/profile.escript` for attribution. Measure using the protocol below. Explore dirty words/epochs in a separate decision only after proven benefit. Update `README.md`, `docs/coverage.md`, architecture status. | P7 | Raw samples, environment, parser/sparse/dense/repeat/multiwriter; correctness gate remains mandatory. Default changes by a separate decision after performance gates; otherwise bitmap stays opt-in. | Restore `coverage_backend => ets` default; retain bitmap opt-in or remove it for a correctness defect. |

Commands for each gate (new `efz_bitmap_contract_tests` and the bitmap variant appear at the relevant stage):

```sh
# P0
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference
# P1
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_coverage_layer_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' rebar3 xref
# P2, P3 and spike correctness
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests
# P4
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests,efz_isolation_tests,efz_integrity_tests
# P5
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_contract_tests,efz_backend_tests,efz_feedback_loop_tests
# P6
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_config_tests,efz_backend_tests,efz_cli_tests,efz_phase3_tests
# P7
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
# P8 (after adding the bitmap variant to bench/run.escript)
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-compare reference
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-compare-bitmap bitmap
```

For P8, additionally run a new stage separating reset/snapshot/compare/merge, with specified seed and writer count; record the stage name and parameters in the benchmark README before the first comparison. Do not run nonexistent bitmap tests/variants in P0.

### Bounded spike before P3

In a separate test file/script under `bench/`, compare unsigned `atomics` CAS-loop with an alternative using a serialized ETS/counter owner **only** for correctness and shared-word contention cost. Check values 0, `2^63`, `2^64−1`, `compare_exchange` success/failure, 1-based bounds; start 1/2/4/8 writers behind a barrier on adjacent bits, run 10 repeats and verify final words. The winner preserves every bit and has measurable cost; with equal correctness, retain CAS as the simpler path. If unsigned CAS fails on supported OTP, P3 is blocked until another BEAM primitive is chosen; do not switch to `get+put`. The spike does not change the production API.

## Test matrix

`B` is bitmap, `E` is ETS reference. For storage/feedback tests, feed **the same sequence of exact hit identities and iteration completions** to both backends. For integration, fix binary inputs, seeds and manifest/builds; some real harnesses may be nondeterministic, so compare allowed outcome/coverage invariants and repetitions rather than requiring identical scheduling order.

| Scenario | Method / expected result |
| --- | --- |
| Empty coverage | Confirmed attached execution: `[]`, `valid_empty_coverage`, `New=[]`; broken/unstarted are separate and not accepted as empty. E=B. |
| Repeated hit | One slot stays 1, one first-hit event, snapshot contains one ID. E=B. |
| Two distinct bits in one word | Two writers concurrently read initial 0 through a test barrier before CAS; after both writes are released, both bits exist. Repeat with CAS retry. |
| Slots 0, 63, 64, last | Check addressing `(0→word1,bit0)`, `(63→word1,bit63)`, `(64→word2,bit0)`, `(capacity−1→last)`; unsigned high bit does not become negative. |
| Capacity overflow | `N=capacity+1` is rejected at preparation with required/configured; a hit at slot `capacity` is rejected, not wrapped. |
| Matching local ID | `{M1,B1,1}` and `{M2,B2,1}` get distinct slots; another BuildId for the same module is not merged. |
| Schema/build mismatch | Substitute BuildId/fingerprint, plan or loaded code: error before merge; do not use a saved bitmap from another build. |
| No novelty; one/multiple new bits | History `[A]→[A]→[A,B]→[B,C,D]`; new lists `A, [], B, C/D`; decisions and ID order match E/B. |
| Global accumulation | After successful `A`, `B`, global=`{A,B}`; repeats do not change it; calibration updates global without adding the corpus entry again. |
| A→B→A | Three executions with independent maps; third local=`{A}`, global=`{A,B}`. Full clear of an old map only after quiescence, never clear global. |
| Crash/timeout | Barrier guarantees hit before crash/timeout; result contains ID, successful global/corpus remain unchanged, crash artifacts and counters match previous behavior. |
| Late hit and failed cleanup | Delay a writer after active check, begin timeout/close, then release it. It does not write into map B of the next iteration; without proven termination, A has no valid snapshot and the runner is dirty. Check ordering with barriers, not stress alone. |
| Concurrent same-word hits | N controlled children receive one context, barrier before first CAS, concurrently set adjacent and identical bits; final popcount exact, complete first-hit evidence. Add 10⁴-cycle stress. |
| Backend switching | Separate ETS→B→ETS campaigns with the same schema/inputs yield identical decisions; no default global transfer. |
| Corpus decision | Seeded integration and replayed candidate stream: `retention_reason`, `new_probes`, additions/deduplication, crash/timeout classification match E/B. Bitmap `hit_count` yields a config error without running the target. |

## Benchmark protocol and performance gates

1. P0 first: `ERL_FLAGS='+S 4:4' rebar3 compile`, then `ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/bitmap-baseline reference` and `ERL_FLAGS='+S 4:4' escript scripts/coverage_bench.escript`. The latter is a historical hook microbenchmark, not full campaign cost. Save raw `.term`, source/fixture SHA-256, `git rev-parse HEAD`, `git diff --stat`, OTP/ERTS, `system_architecture`, wordsize, `schedulers_online`, JIT/flags and hardware. Do not compare to old published numbers without matching environments.
2. After P7, use identical manifests and seeded event streams: sparse/dense sets, 1/8/64/1024+ distinct probes, varying hits per execution, 90%+ repeated hits, 1/2/4/8 controlled writers with/without contention. Measure mapping preparation separately from steady state; memory includes atomics, ETS mapping, reverse map, context, manifest/plan, global state and process heap.
3. Measure separately `hit` (first/repeated), full clear/reset, quiescence+snapshot, decode, comparison, merge, full `reset→execute→collect→compare→commit` and end-to-end mutation exec/s on parser/loop/sparse and a real harness. Separate calibration, startup and steady mutation time. Normalize by checking corpus/outcomes; do not silently exclude errors/timeouts from the denominator.
4. Use identical scheduler settings, warmup, at least 10 paired repeats alternating E/B order, separate VMs where needed for state cleanup. Publish all samples, median, min/max, paired ratios and bootstrap 95% intervals; reductions, GC counts, allocated/process memory and `atomics:info(memory)`/ETS memory where available. `bench/profile.escript` explains costs, not throughput results. Record neighboring processes/thermal drift as limitations.
5. **Correctness gate:** all P7 tests and the matrix pass, zero lost bits, zero mixed schemas, zero changed corpus decisions. **Opt-in performance gate:** no sustained median end-to-end exec/s degradation above 5% on each preselected representative workload; otherwise remain experimental and profile. **Default-switch gate:** beyond correctness, the lower bound of the paired 95% interval for bitmap/ETS exec/s is above 1.0 on the preselected primary workload and at least 0.95 on every other representative workload; full memory footprint and p95 latency are published and within campaign limits written down in advance. These thresholds are decision rules, not expected results. With unstable measurements, ETS stays default. Any correctness regression immediately restores ETS.
6. Initial reset is full clear of all words only after quiescence. Put dirty words/epochs in a new opt-in experiment if timing breakdown shows clear materially affects the full cycle; repeat the concurrency/lifecycle matrix and benchmark after changing it.

## Definition of done and rollout

Actual stage status: P0 **partial** (226 baseline EUnit and 3 CT passed, historical `bench/run.escript all` interrupted after more than three minutes without a result); P1–P7 **implemented** and sequential checks passed; P8 **partial** (paired micro/campaign benchmark completed through separate `bench/bitmap_bench.escript`, parser performance gate not reached, default unchanged). A separate benchmark driver instead of a bitmap variant in `bench/run.escript` is a deliberate narrow deviation; the old driver benchmark is still needed to compare historical workloads. See the [report](../coverage-bitmap-implementation-report.md).

- [x] Exact instrumentation identities and source mapping unchanged; bitmap selectable only for automatic/presence.
- [x] Injective mapping, versioned fingerprint and capacity errors checked; incompatible builds not mixed.
- [x] CAS for bit63/word boundaries and controlled concurrent writers tested; first-hit integrity preserved in checked scenarios.
- [x] Snapshot only after confirmed quiescence; late hits/dirty cleanup cannot yield valid commit or reuse for controlled descendants.
- [x] `Result.coverage`, feedback, global, corpus and crash/timeout decisions match ETS in the implemented matrix.
- [x] `rebar3 compile`, full `rebar3 eunit`, `rebar3 ct`, `rebar3 xref`, `rebar3 dialyzer` pass on supported OTP.
- [ ] Full P8 protocol: raw samples published, but historical baseline, production harness, full RSS/p95 and confidence intervals remain.
- [x] ETS remains default until a separate performance-gate decision; rollback by one config selector without migrating stored coverage.

Recommended rollout: internal low-level test → opt-in `coverage_backend => bitmap` for an automatic presence campaign → differential CI on both backends → real-harness measurements → separate default decision. On any discrepancy, immediately return to `ets`, save failing event history and map/schema metadata for reproduction. Corpus inputs may be reused with new recalibration; saved coverage bits only with an exactly matching fingerprint, otherwise do not import them.

## First tasks for the implementation agent

1. **P0:** record reproducible event history and an ETS baseline in `test/efz_backend_tests.erl`/a new contract test, save raw benchmark and environment; do not change the production path.
2. **P1:** establish the internal `efz_coverage` dispatch/type contract with unchanged ETS behavior and focused EUnit.
3. **P2:** implement schema mapping + fingerprint + capacity errors with bijection/boundary tests; do not wire up the hit path yet.
4. **Spike/P3:** check unsigned CAS on OTP 27 and implement atomic bit set with a controlled concurrent test, then integrate the execution map.

Each task has a separately verifiable result; the next starts after the previous gate passes.
