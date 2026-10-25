# Technical audit of the EFZ bitmap coverage backend

**English** · [Русский](i18n/ru/coverage-bitmap-audit.md) · [Español](i18n/es/coverage-bitmap-audit.md) · [简体中文](i18n/zh-CN/coverage-bitmap-audit.md) · [All languages](i18n/README.md)

This is the original bitmap-v1 audit. Fixes and new measurements are described in
the [bitmap-v2 report](coverage-bitmap-v2-results.md); the original results below are preserved.

Date: 2026-10-02. Scope: the current working copy at `8b5cb05b5b57231b9133be13c883f25863e05d11`, with existing uncommitted changes. Backend code was not fixed. The [architecture](coverage-bitmap-architecture.md), [plan](plans/coverage-bitmap-implementation-plan.md), [implementation report](coverage-bitmap-implementation-report.md), source and tests were read. New tests and a separate audit benchmark are listed below.

## 1. Conclusion

For the supported `automatic` + `presence` mode, bitmap losslessly represents **the same structural points** as ETS: the key is the full `{Module,BuildId,ProbeId}`, slots are unique, and ETS/bitmap results matched on identical event histories and a seeded campaign. With multiple admitted processes, a CAS loop preserves different bits in the same word. Production allocates a new map for every execution; a late writer cannot write into the next map. This is evidence within EFZ's *controlled descendants* model, not a guarantee of isolation for arbitrary remote/external processes.

**Acceleration was not confirmed.** In the repeated paired run of a real example-parser campaign, bitmap delivered lower exec/s: median bitmap/ETS ratio `0.893`, bootstrap 95% interval `[0.851,0.949]`. A sparse full storage/feedback cycle is particularly costly. The `ets` default must not change; `bitmap` is acceptable only as an experimental opt-in for profiling and differential tests. No correctness P0 blockers were found on the checked path; bitmap-specific dirty-cleanup failure injection has not yet been performed.

## 2. Actual architecture and testcase path

| Step | Function and data | State, owner and concurrency |
| --- | --- | --- |
| Campaign preparation | [`efz_config:prepare_coverage/1`](../src/efz_config.erl#L85) preflights manifests/capacity; [`efz_worker:init/1`](../src/efz_worker.erl#L7) calls `efz_coverage:prepare_schema/2`, creates feedback/global. | The worker owns protected ETS `FullId→Slot`, the reverse tuple and immutable global binary. There is one worker (`workers=1`), so commit is serial. |
| Input/iteration | [`efz_worker:execute_checked/4`](../src/efz_worker.erl#L93) passes binary input, backend/schema and a pinned plan to [`efz_executor:run/4`](../src/efz_executor.erl#L11). | Worker mutable state, corpus and mutation selection; the backend does not select input. |
| Execution context | [`efz_guardian:start/6`](../src/efz_guardian.erl#L33) opens `{efz_context,1,Ref,{bitmap,Schema,Words,Active},Owner}` through `efz_coverage:open/3`. | The guardian owns a separate unsigned atomics array and active flag per execution. |
| Process attachment | [`efz_guardian:admit/2`](../src/efz_guardian.erl#L53) and [`efz_target:spawn_owned/2`](../src/efz_target.erl#L9) start root/children through a gate; [`efz_cov_bitmap:attach/1`](../src/efz_cov_bitmap.erl#L84) explicitly stores context in the process dictionary. | Multiple controlled writers share one map. Ordinary `spawn` does not inherit context; tracing detects it and marks the runner dirty. |
| Instrumented target/hit | [`efz_instrument_pt:body/5`, `probe/4`](../src/efz_instrument_pt.erl#L112) inserts `efz_cov_rt:hit({M,B,Id})`; [`efz_cov_rt:hit/1`](../src/efz_cov_rt.erl#L6) checks PID/context and passes the full key to `efz_coverage:hit/2` → `efz_cov_bitmap:hit/2`. | The hot path changes one 64-bit word using CAS; the first hit sends a guardian event. Concurrent writers are possible. |
| Completion | [`efz_guardian:cleanup/2`, `loop/1`](../src/efz_guardian.erl#L72) closes admission, kills remaining controlled writers, waits for `DOWN` and trace barriers; a deadline produces unconfirmed/dirty. | One root's `DOWN` is not sufficient. Stability relies on the whole registered group terminating and trace drain. |
| Observation | [`efz_guardian:finish/2`](../src/efz_guardian.erl#L172) calls [`efz_executor:coverage/3`](../src/efz_executor.erl#L123) for an exact ID list/validation; for a confirmed successful result, it separately takes immutable `snapshot_bits/1`, then closes the map. | Two snapshots are acceptable only after quiescence. Public `Result.coverage` remains a list; `coverage_bits` is an internal result field. |
| Novelty/global | [`efz_feedback:evaluate/3`, `bitmap_success/5`](../src/efz_feedback.erl#L21) checks status/outcome, calculates `Local & ~Global`, decodes new IDs and builds `Global | Local`. | Global is an immutable 8 KiB binary in the worker; comparison and commit run sequentially. Crash/timeout do not merge. |
| Corpus/failures | [`efz_worker:execute_result/6`, `retain/2`, `record_failure/4`](../src/efz_worker.erl#L101) uses the existing `retention_reason`; successful new coverage adds input through `efz_corpus:add/2`, failures are saved separately. | As with ETS, global is updated in feedback **before** writing the corpus. A write error stops the campaign; this is the existing order, not new bitmap behavior. |
| Reset/release | The next `efz_guardian:start/6` creates a new map; [`efz_cov_bitmap:close/1`, `reset/1`](../src/efz_cov_bitmap.erl#L151) do not zero global. [`efz_worker:terminate/2`](../src/efz_worker.erl#L345) deletes schema ETS. | The old mutable map is not reused in production. Atomics are reclaimed by GC once context references disappear. |

Legacy follows the same executor/guardian/feedback/worker policy stages. Differences: [`efz_cov_ets:open/2`, `hit/2`, `snapshot/1`](../src/efz_cov_ets.erl#L7) use a fresh public ETS table with `insert_new`, while [`efz_coverage:unseen/2`, `merge/2`](../src/efz_coverage.erl#L40) operate on exact Erlang sets/lists. Bitmap changes storage and comparison, preserving public identities and worker decisions.

## 3. Identity, slots and instrumentation

[`efz_instrument_pt:parse_transform/2`, `probe/4`](../src/efz_instrument_pt.erl#L7) start local `ProbeId` at 1 and insert a call with `{Module,BuildId,ProbeId}`; BuildId depends on canonical forms, OTP/compiler and identity options (lines 37–55). [`efz_cov_manifest:identities/1`, `validate/1`](../src/efz_cov_manifest.erl#L4) retain this full identity and reject nonpositive/duplicate local IDs. Placement for function/case/if/receive/try/fun is shown in [`body/5`, `expr/3`](../src/efz_instrument_pt.erl#L107) and checked by [`efz_phase2_tests:manifest/1`](../test/efz_phase2_tests.erl#L70); bitmap did not change this traversal. [`efz_phase2_tests:determinism/1`](../test/efz_phase2_tests.erl#L195) checks identical BuildIds for equivalent builds and a difference when a macro changes.

[`efz_cov_bitmap:validate_manifests/1`, `prepare/2`](../src/efz_cov_bitmap.erl#L23) validate manifests, reject repeated selected modules and duplicate IDs, sort *full* identities and assign sequential slots `0..N−1`. Protected ETS stores `FullId→Slot`; a tuple stores `Slot→FullId`. There is no `ProbeId rem MapSize`, hash mask or truncation. Different modules with the same local ID receive different slots. Two builds of one module **are not allowed simultaneously** in one campaign; the fingerprint contains the full ID sequence and capacity. An identical canonical build produces the same slots; a new BuildId/schema requires a new campaign and rejects old bitmap snapshots (`unseen_bits/2`, `merge_bits/2`, lines 177–191). Corpus **input bytes** can be rerun and recalibrated after rebuilding; old coverage bits are not imported automatically.

Capacity: `N > Bits` returns `{bitmap_capacity_exceeded,#{required_bits,configured_bits}}` before the campaign ([`check_capacity/2`](../src/efz_cov_bitmap.erl#L14), [`efz_config:prepare_coverage/1`](../src/efz_config.erl#L90)). `MapSize` cannot appear as a slot in a validated schema; an unknown ID, negative/huge ID or foreign BuildId yields an explicit `unexpected_probe_or_build` in [`hit/2`](../src/efz_cov_bitmap.erl#L93). A corrupted manifest is rejected. Specific tests: [`mapping_and_capacity_test/0`, `boundary_test/0`, `default_last_slot_test_/0`](../test/efz_bitmap_contract_tests.erl#L4), [`invalid_identity_test/0`](../test/efz_bitmap_audit_tests.erl#L7) and [`wide_differential/0`](../test/efz_bitmap_audit_tests.erl#L39).

## 4. Representation, hot path and concurrency

Default `coverage_bitmap_bits=65536`: 65,536 **bits**, 8,192 payload bytes, 1,024 64-bit words. [`efz_cov_bitmap:open/1`](../src/efz_cov_bitmap.erl#L74) allocates `atomics:new(Bits div 64,[{signed,false}])` and a separate active flag. Slot `s` is addressed as `Word=s div 64+1` (atomics is 1-based), `Mask=1 bsl (s rem 64)`. Thus slots `0,1,63,64,65,65535` correspond to `word/bit` `1/0,1/1,1/63,2/0,2/1,1024/63`. Slot `65536` is not allocated. The high bit is unsigned; [`cas_word/4`](../src/efz_cov_bitmap.erl#L119) retries CAS after a stale read, preserving adjacent bits. Deterministic [`cas_stale_read_test/0`](../test/efz_bitmap_contract_tests.erl#L95) delays several writers after reading the same `Old=0`, then checks bits 0, 1 and 63; [`shared_writers_and_late_context_test/0`](../test/efz_bitmap_contract_tests.erl#L107) checks shared context. There is no simple unsafe `get→OR→put`.

One probe hit: [`efz_cov_rt:hit/1`](../src/efz_cov_rt.erl#L6) performs a PID-registry membership lookup through [`efz_cov_integrity:expected/0`](../src/efz_cov_integrity.erl#L70), checks the process dictionary, then [`efz_coverage:hit/2`](../src/efz_coverage.erl#L20) calls [`efz_cov_bitmap:hit/2`](../src/efz_cov_bitmap.erl#L93). The latter reads the active flag twice, performs an exact ETS lookup, calculates word/mask and invokes a CAS loop; on the first 0→1, it sends the guardian a message. No configuration is read, no bitmap binary/list/set/map is created per hit, and no diagnostics/source decoding occurs. However, `ets:lookup` in the integrity registry and slot table returns Erlang terms; **the hot path is not allocation-free**. For repeated hits, the benchmark shows greater time than `ets:insert_new`.

A production snapshot is stable only after [`efz_guardian:loop/1`](../src/efz_guardian.erl#L72) has empty alive/barriers and a stopped coordinator, then [`finish/2`](../src/efz_guardian.erl#L172). `snapshot_bits/1` itself reads words sequentially and is not an atomic snapshot with live writers ([`efz_cov_bitmap:snapshot_bits/1`](../src/efz_cov_bitmap.erl#L139)). `Active=0` also does not close the race between check and CAS. Production avoids writing into the next iteration by using a new map; dirty cleanup makes the runner nonreusable. [`efz_isolation_tests`](../test/efz_isolation_tests.erl#L17) check controlled descendants and timeout, [`shared_writers_and_late_context_test/0`](../test/efz_bitmap_contract_tests.erl#L107) checks a late hit into the old context after close/reset. Both new and old mailbox messages carry `Ref`; the guardian accepts only its own `Ref` ([`loop_event/2`](../src/efz_guardian.erl#L138)); after completion, the owner does not transfer messages to another map.

`reset/1` allocates a fresh array; there are no dirty-word lists or epochs. Full clear is implemented as [`clear_quiescent/1`](../src/efz_cov_bitmap.erl#L163) only for benchmarking. Its `Active=0` check **does not prove** that a writer did not pass the earlier check and is not waiting on CAS: [`closed_clear_stale_cas_test/0`](../test/efz_bitmap_audit_tests.erl#L28) reproduces a write after clear. This is not a production leak because production does not reuse the array. The name/API needs an explicit join precondition or removal from the accessible interface.

## 5. Novelty, global and fuzzing feedback

[`efz_cov_bitmap:wordwise/4`](../src/efz_cov_bitmap.erl#L193) calculates `Local band bnot Global` and `Local bor Global` in 64-bit words without conversion to sets. [`efz_feedback:bitmap_success/5`](../src/efz_feedback.erl#L42) decodes **new** bits for `new_probes` and `retention_reason`, then obtains the new global. Comparison does not mutate the previous global. There is no *early exit* on the first new word: the function always builds the full difference binary; the current API requires an exact list of all new probes. Even without novelty, it performs a full scan, creates a new binary and decodes across all manifest IDs. This is a measurable fixed cost described below.

For the history `{} → {1,2} → {1,2} → {1,2,3} → {3} → {64,65} → {65}`, novelty results must be `new, none, new, none, new, none`; the implemented bitwise operator produces exactly that sequence, while [`wide_differential/0`](../test/efz_bitmap_audit_tests.erl#L39) compares another prescribed history using the same rule, including an empty result, 63/64/65/65535, repeated hits, two modules, crash and timeout. [`efz_feedback:evaluate/3`](../src/efz_feedback.erl#L13) allows merge only for `coverage_status=ok` and `{ok,_}`; crash/exit/timeout produce `target_failure` and leave global unchanged. Calibration of a successful seed updates global without adding the corpus entry again. [`efz_worker:retain/2`](../src/efz_worker.erl#L245) decides corpus retention after feedback, while [`record_failure/4`](../src/efz_worker.erl#L256) classifies/saves failures separately. The ETS branch has the same boundaries (`efz_feedback:evaluate/3`, lines 30–39). External `Result.coverage` remains an exact ID list; `coverage_bits` is removed from report/failure context by [`public_result/1`](../src/efz_worker.erl#L352).

## 6. Checks and benchmark

Commands ran **sequentially** so Rebar3 commands did not compile the same `_build` concurrently:

| Command | Result |
| --- | --- |
| `ERL_FLAGS='+S 4:4' rebar3 eunit` | PASS, **241** tests after audit tests (see `_build/bitmap-audit-eunit-final.log`) |
| `ERL_FLAGS='+S 4:4' rebar3 ct` | PASS, 3 tests |
| `ERL_FLAGS='+S 4:4' rebar3 xref` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 dialyzer` | PASS |
| `ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_bitmap_audit_tests` | PASS, 3 audit tests |
| `ERL_FLAGS='+S 4:4' escript bench/bitmap_bench.escript _build/bitmap-audit-benchmark` | PASS; [raw samples](performance/bitmap-audit-2026-10-02-existing-bench.txt) |
| `ERL_FLAGS='+S 4:4' escript bench/bitmap_audit_bench.escript docs/performance/bitmap-audit-2026-10-02-samples.term` | PASS; [raw samples](performance/bitmap-audit-2026-10-02-samples.term) |

OTP 27.0 / ERTS 15.0, Linux x86_64, i7-1260P, `+S 4:4`, Rebar3 3.25.0. Both benchmarks warmed up for 2 pairs, then alternated ETS/bitmap order in 10 paired repeats. Synthetic manifest: 1,024 probes, capacity 65,536 bits; parser campaign: seeded `efz_example_target`, 50 executions, corpus size 4, coverage size 5 in every sample. Figures below are median microseconds, with min/max in the raw artifacts. The built-in benchmark separately collects reductions and minor GC; the paired audit script does the same. Script SHA-256: `bench/bitmap_bench.escript` `975240e42d32a96228d7c177f33053492904c2c9a3aaca1a71d766168e95266b`, `bench/bitmap_audit_bench.escript` `fdde7eea1345717f69e41863458b5f68f9970c06e41a35db19fb0c3511def29e`. Measurements used one machine and do not prove results for other harnesses/OTP versions.

| Existing benchmark stage | ETS | Bitmap |
| --- | ---: | ---: |
| 5,000 repeated hits | 824 | 1 413 |
| 64 sparse hits | 18 | 23 |
| 1,024 distinct hits | 629 | 768 |
| Snapshot 64 / 1,024 | 13 / 293 | 39 / 38 |
| Decode 1,024 IDs | 312 | 88 |
| Compare / merge 256 | 84 / 58 | 30 / 28 |
| Full clear after close | 0* | 19 |
| 10 sparse full cycles | 135 | 7 451 |
| 5 dense full cycles | 34 379 | 13 013 |
| 1 / 2 / 4 / 8 writers, one word | 4 367 / 8 345 / 12 169 / 26 675 | 4 377 / 8 656 / 11 904 / 32 422 |
| Parser campaign, 50 executions wall time | 116 842 | 125 835 |

`*` The ETS stage creates a new table rather than clearing it; 0 µs is below useful timer resolution. Median wall times for 50 executions correspond to about **428 exec/s ETS** and **397 exec/s bitmap**. Median paired exec/s ratio `0.893`; bootstrap percentile 95% `[0.851,0.949]`, 10,000 resamples, seed `20261002`. This measures the example parser, not a production harness. Full cycles in the separate audit script include fresh context, hits, exact public observation, bitmap snapshot, novelty and merge:

| Hits/execution | ETS median (min–max), µs | Bitmap median (min–max), µs |
| --- | ---: | ---: |
| 1 | 4 (3–4) | 402 (347–452) |
| 100 | 97 (92–227) | 400 (286–546) |
| 1 000 | 3 054 (2 115–3 948) | 1 546 (725–2 125) |
| 10 000, cycle over 1 024 IDs | 8 509 (6 471–9 730) | 7 374 (6 338–9 449) |
| 10 000 hits of one ID | 6 045 (4 951–6 885) | 7 796 (7 309–8 219) |

Audit cycle intentionally excludes actual guardian process cleanup, mutation and corpus IO; parser campaign includes them. With sparse coverage, fixed costs of opening the map, two snapshots/decodes and full map/manifest scans dominate; `hit/1` is not the only bottleneck. With many repeated hits, hit-path cost is visible: bitmap is 1.7× slower than ETS in the 5,000-hit microbenchmark. Bitmap performs better on dense unique workloads because wordwise compare/merge is cheap. The cost profile depends on density; these data cannot justify OTP-native/JIT coverage research before fixed execution cost is addressed and a production harness measured.

Actual memory components from `efz_cov_bitmap:memory/1` with 1,024 probes: atomics words **8,232 B**, active **48 B**, mapping ETS **20,084 VM words** (8 B each on this VM ≈160,672 B), reverse tuple `external_size` **58,633 B**. Global binary and one immutable snapshot are each **8,192 B**; manifests/plan/context/allocator are additional. The ETS execution table after 1,024 hits is **22,071 VM words**. `external_size` is not RSS, and component sizes cannot simply be treated as total campaign memory. RSS and memory retention after many campaigns are **NOT TESTED** here.

## 7. Issues found and assessment

| Category | Status | Evidence and limitation |
| --- | --- | --- |
| Correctness | **PASS** | Collision-free mapping, bounds, the high bit and different builds are checked by code and tests; no silent coverage loss was found within the checked scope. |
| Concurrency safety | **PARTIAL** | **Medium:** production CAS preserves adjacent bits, but exported [`clear_quiescent/1`](../src/efz_cov_bitmap.erl#L163) checks only `Active=0`; the audit test reproduced a stale writer after close/clear. Do not use the helper for reuse without join. |
| Execution isolation | **PARTIAL** | **Medium:** fresh map/Ref and controlled descendant timeout were checked, but bitmap-specific unconfirmed cleanup/guardian death were not run in a fresh VM. [`efz_guardian:finish/2`](../src/efz_guardian.erl#L172) shares the ETS lifecycle, but a bitmap variant of [`efz_isolation_tests:fresh_vm/2`](../test/efz_isolation_tests.erl#L27) is needed with forced cleanup deadline/guardian kill and verification of no commit/reuse. |
| Semantic compatibility | **PASS** | Identical event histories and seeded campaigns yield the same observed/new/global/corpus/crash/timeout decisions in tests. |
| Performance | **FAIL** | **High:** parser-campaign exec/s ratio `0.893`; 1-hit full cycle `402` versus `4` µs. Source: [`efz_guardian:finish/2`](../src/efz_guardian.erl#L172) performs exact decode and a second bitmap snapshot; [`efz_cov_bitmap:wordwise/4`, `decode/2`](../src/efz_cov_bitmap.erl#L193) scan the full map/schema; [`efz_feedback:bitmap_success/5`](../src/efz_feedback.erl#L42) does so even without novelty. Profile/simplify fixed work before making it default. |
| Memory efficiency | **PARTIAL** | **Medium:** payload is 8 KiB, but mapping ETS is ~160 KiB in VM words and reverse external size ~58 KiB already at 1,024 probes; [`prepare/2`, `memory/1`](../src/efz_cov_bitmap.erl#L23). Full RSS/retention were not measured. Measure peak/RSS across repeated campaigns before rollout. |
| Maintainability | **PARTIAL** | **Medium:** [`snapshot_bits/1`](../src/efz_cov_bitmap.erl#L139) can be called with live writers; its own `Active=1` guard does not make the result stable. The production guardian meets the required condition, but the API must explicitly require quiescence or expose snapshots only through the lifecycle owner. |
| Observability/debuggability | **PARTIAL** | **Low:** [`efz_worker:finish/2`](../src/efz_worker.erl#L306) publishes exact IDs, but there are no separate phase timings for mapping/open, snapshot/decode, compare/merge or full RSS. Reproduce the parser benchmark and add cost counters before optimizing. |

An additional robustness gap (**medium**): [`efz_config:valid_field/2`](../src/efz_config.erl#L69) accepts arbitrarily large positive `coverage_bitmap_bits`, while [`efz_cov_bitmap:check_capacity/2`](../src/efz_cov_bitmap.erl#L14) checks only the number of probes `<= Bits`. A value such as `1 bsl 60` passes that check, but [`efz_cov_bitmap:new_global/1`, `open/1`](../src/efz_cov_bitmap.erl#L74) will try to allocate huge binary/atomics objects at worker/execution startup. This is an explicit resource failure, not a silent collision; limit configuration to a supported maximum or test allocation and release before campaign startup with a clear error.

## 8. Improvement priorities

**P0 correctness blockers:** none found for the checked automatic/presence scenarios. Before widening opt-in use, bitmap-specific fault injection for unconfirmed cleanup is needed. If event histories diverge or dirty cleanup produces no infrastructure result, immediately roll back to `coverage_backend => ets`.

**P1 performance/architecture:** (1) add phase timings to [`efz_guardian:finish/2`](../src/efz_guardian.erl#L172) and [`efz_feedback:bitmap_success/5`](../src/efz_feedback.erl#L42), profile the sparse parser and a production harness; (2) if the fixed scan is confirmed, obtain the exact ID list and bytes in one stable pass and avoid full `NewBits` decode when zero novelty is proven, preserving `new_probes` and commit order; (3) then separately evaluate the two ETS lookups/active checks/CAS on repeated hits. Do not add dirty words/epochs before measurement and a new concurrency gate.

**P2 robustness/observability:** (1) clarify the contract or remove benchmark-only `clear_quiescent/1`; (2) make the stable-snapshot boundary explicit in the API; (3) check the capacity upper bound before allocation and handle allocation errors; (4) perform bitmap-specific dirty-cleanup fault injection; (5) publish peak RSS, active maps/schema ETS count during repeated campaigns. These tasks do not change instrumentation or the harness API.

## 9. Answers to the main questions

- **Are the old EFZ semantics preserved?** Yes, in tested automatic/presence mode, including success-only global merge and corpus/failure policy.
- **Is there silent coverage loss?** None was found: full identity is checked by exact lookup, overflow/unknown BuildId produce errors, and CAS preserves adjacent bits.
- **Are multiple processes safe?** Yes for controlled descendants and the production fresh-map lifecycle; `clear_quiescent/1` alone is insufficient for reuse.
- **Are iterations isolated?** Yes in the checked controlled-timeout scenarios: A and B have different atomics arrays; a late hit from A cannot reach B. Bitmap-specific unconfirmed-cleanup fault injection remains open.
- **Is bitmap faster?** Not in the measured parser campaign and sparse cycles; dense unique stages sometimes benefit.
- **A new bottleneck?** For sparse input, fixed per-execution snapshot/decode/full-map work; for very frequent repeated hits, also Erlang `hit/1` itself with checks and ETS lookup. No single bottleneck for all harnesses has been established.
- **Ready to be default?** No. Keep it experimental opt-in; ETS remains default/reference/rollback.
