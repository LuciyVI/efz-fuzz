# P0 acceptance fixes — 2026-09-21

## Verdict: ACCEPT

P0-01, P0-02, P0-03, P0-04: PASS. Canonical compile, EUnit twice, CT,
Dialyzer and xref: exit 0. Existing harness files and ownership model unchanged.
No P1/P2 features, commits, reset/clean/pull or deletion of preexisting changes.
HEAD remains `205e18ba172d74bd6c652a68abfc73e02e4a1f86`.
Environment: OTP 27.0 / ERTS 15.0 / rebar3 3.25.0, `ERL_FLAGS='+S 4:4'`.

## Fixes and root causes

### P0-02: validate before expensive work

`efz_stability:bounded_return/1` formerly sorted arbitrary map keys before checking
the budget. It now validates using an unordered iterator, element-by-element tuple
access and budget-aware list recursion. Independent limits: 1024 visited nodes,
1024 binary bytes, 1024 container elements, depth 64. Container sizes and binary
byte_size are checked before traversal/content access. No unvalidated map-to-list,
sorting, reconstruction or serialization. Deterministic ETF/hash runs only after
the whole term passes. Unsupported terms return not_comparable; default comparison
remains disabled.

Tests cover small maps, equivalent map insertion order, references/PIDs/functions,
huge binary keys/values, common-prefix huge keys, oversized maps, aggregate binary
budget and depth. An arity-only call trace bounds validation visits and proves
rejected terms never invoke term_to_binary/2, maps:to_list/1 or lists:sort/1; huge
arguments are not copied into trace messages. No absolute realtime assertion.

### P0-01: separate post-cleanup memory observation

Within-execution growth remains a separate existing observation. A new observation
measures VM-global binary memory before execution and after normal guardian DOWN,
confirmed cleanup and bounded quiescence. It runs outside guardian using monitored,
deadline-limited helpers. Failure gives incomplete/unavailable; target outcome is
unchanged. Failed cleanup remains infrastructure failure and skips this observation.
No target/shared-state mutation, foreign GC or ownership changes.

Evidence stores baseline_memory, sampled peak_memory, post_execution_memory,
residual_delta, units, threshold, scope, completeness, cleanup_status, quiescence,
deadline and explicit attribution limitation. Target-owned post memory is
not_applicable after owners terminate. `vm_memory_growth_suspected` has vm_global
scope in both evidence and artifact/dedup identity; it is never a proven target leak.
Old schema-v1 policy maps are normalized with new defaults at load time.

The new fixture returns a fresh 16 MiB binary through ordinary run(binary()). EFZ
retains that return after root cleanup: a supported residual VM allocation with
known attribution limits. Campaign reproduction is 3/3. Replay discards raw returns
between executions, so old binary collection can offset a new allocation; it reports
the actual M/N, not a forced 3/3 or a leak verdict. The evidence run obtained 1/3.
Temporary 16 MiB allocation has an observed peak but no residual finding (delta 40
bytes in the dedicated run, below the 8 MiB fixture threshold).

A suspended post-observation helper was tested separately: target timeout 60 ms,
guardian cleanup completed at 66 ms, caller returned at 167 ms with incomplete
memory evidence, helper dead, runner reusable. The 100 ms observation deadline
expired **after** cleanup; it did not delay target termination.

### P0-03: explicit unknown timeout

The disabled-hangs branch used to return no category. Enabled runtime diagnostics
now always classify timeout as unknown if hangs are disabled. Existing no-samples,
stale and insufficient-evidence paths also return unknown. Busy/waiting remain
unchanged and classifications are mutually exclusive per execution. Primary
`{timeout, TimeoutMs}` is unchanged.

### P0-04: separate test-infrastructure fix

The original 5s EUnit timeout enclosed two 300-execution limits campaigns, four
independent backend variants (~400 executions), or a 512-execution scheduler test.
The campaigns themselves already had 10s await bounds. This made a correctness
test an unintended aggregate host-throughput gate.

Fresh before-current targeted run reproduced a limits timeout. Fresh clean-HEAD
ordinary runs were also red (its older exhaustion await bound, plus a downstream
smoke failure in the full run), but did not consistently reproduce all three short
timeouts. Therefore a separately labelled, bounded diagnostic contention experiment
ran the original three functions with the same 5s EUnit bound on both the saved
pre-fix tree and clean HEAD: all six cases cancelled. These are diagnostic FAILs,
not canonical PASS results, even though the driver itself exited normally.

Without that competing workload the unchanged assertions completed three times each:
limits 2.61–2.64s, scheduler 2.17–2.26s, backend 1.94–2.04s. Each returned to
processes=41, ETS=19, guardian=undefined, runner=ready. Evidence supports finite
workload / scheduler-sensitive aggregate timeout, not leaked processes, lost
cleanup or an unbounded receive.

Fix: split independent limits cases and backend variants into individual EUnit
cases. Align the outer limits/scheduler test deadline (12s) with the existing 10s
campaign await plus cleanup. Preserve all iterations, variants, assertions and
the full 256-parent scheduler scenario. No skips, reduced workload or catch-all.
The preexisting 75s exhaustion test / 60s campaign bound was preserved.

This fix is separately reviewable in
[test-infrastructure.patch](runtime-fixes-validation/test-infrastructure.patch),
relative to the initial dirty checkout, excluding prior user changes.

## Changed implementation and test files

- `src/efz_stability.erl`: bounded comparator.
- `src/efz_runtime.erl`: before/post observations, VM sample context, timeout_unknown,
  cheaper final ETS existence query.
- `src/efz_runtime_config.erl`: validated residual threshold/quiescence/deadline.
- `src/efz_executor.erl`: before measurement and post-normal-guardian-DOWN integration.
- `src/efz_worker.erl`: vm_global artifact scope for the new category.
- `src/efz_runtime_store.erl`: scoped signature, category validation, old policy defaults.
- `src/efz_runtime_replay.erl`: residual-observation completeness in recheck.
- `fixtures/runtime/efz_runtime_memory_fixture.erl`: new fixture, no existing harness edits.
- `test/efz_runtime_acceptance_tests.erl`: comparator/config/memory/timeout regressions.
- `test/efz_limits_tests.erl`, `test/efz_backend_tests.erl`, `test/efz_phase3_tests.erl`:
  separate test-infrastructure changes.
- `docs/runtime-diagnostics.md`, this report, and `docs/runtime-fixes-validation/`:
  policy documentation and fresh evidence.

## Regression results

All commands below ran from the project checkout, with `ERL_FLAGS='+S 4:4'`.

| Command | Exit | Passed | Failed / skipped | Seconds |
|---|---:|---:|---:|---:|
| rebar3 compile | 0 | — | — | 1 |
| rebar3 eunit, run 1 | 0 | 223 | 0 / 0 | 117 |
| rebar3 eunit, run 2 | 0 | 223 | 0 / 0 | 123 |
| rebar3 ct | 0 | 3 | 0 / 0 | 6 |
| rebar3 dialyzer | 0 | — | — | 8 |
| rebar3 xref | 0 | — | — | 1 |
| rebar3 eunit --module=efz_runtime_acceptance_tests,efz_runtime_tests | 0 | 20 | 0 / 0 | 8 |

An earlier combined targeted run (runtime + all three former timeout modules)
passed 59 tests; the later config validation case is included in both final 223-test
runs and the final 20-test runtime run. Logs:
[run 1](runtime-fixes-validation/final-eunit-1.log),
[run 2](runtime-fixes-validation/final-eunit-2.log),
[command statuses](runtime-fixes-validation/results.txt).

## Targeted acceptance

| ID | Before | After | Evidence |
|---|---|---|---|
| P0-01 | FAIL | PASS | post-cleanup VM measurement; peak-only negative; campaign 3/3; stored/replayed actual M/N; suspended helper deadline |
| P0-02 | FAIL | PASS | budgets before traversal/serialization; trace proves rejection before expensive calls; huge-key warm benchmark |
| P0-03 | FAIL | PASS | disabled sampler, interval longer than timeout, zero/stale/incomplete samples, busy and waiting cases |
| P0-04 | FAIL | PASS | diagnosed original functions on both trees; full canonical EUnit twice, 223/223 |

Additional sanity: existing efz_example_target CLI with P0 enabled exited 0.
Examples and existing runtime harness are byte-identical to the saved pre-fix tree.
25 random and staged mutations match before-fixes/off/on in generated inputs,
staged traces/counters, coverage and corpus contents (volatile metadata excluded).
Existing verification-isolation, verification-only-crash, dirty-runner, guardian
failure and suspended-sampler tests pass.
An artifact saved before these fixes also replayed in a fresh CLI VM: compatibility
verified, child_abnormal_exit observed 3/3, exit 0
([log](runtime-fixes-validation/old-runtime-replay.log)).

## Performance

Three 300-mutation campaigns/mode after 50-mutation warmup, same input/seeds,
single worker, +S 4:4; sequential VMs. Before is the saved **dirty pre-fix tree**,
not clean HEAD (thus unrelated hit-count changes are held constant). Median row by
mutation throughput; calibration=1 for every row.

| Initial batch | Mutations | Verification | Wall s | Mutation/s | Total/s |
|---|---:|---:|---:|---:|---:|
| before fixes, off | 300 | 0 | 1.749 | 171.52 | 172.09 |
| after fixes, off | 300 | 0 | 2.003 | 149.76 | 150.26 |
| resources only | 300 | 0 | 2.005 | 149.60 | 150.10 |
| full | 300 | 4 | 2.065 | 145.28 | 147.70 |

Initial off delta was -12.7%; it was not hidden. Reverse-order control gave
before=202.48, after=206.45 mutation/s (+2.0%). An additional CPU/reductions batch
gave before=206.47, after=205.82 (-0.3%). Median CPU runtime over each three runs:
4358 -> 4333 ms (-0.6%); reductions at the median-throughput runs:
27,963,230 -> 27,965,219 (+0.007%). Substantial off regression was not reproduced
by controls. Host scheduling/frequency was not fixed; these data are not a claim
of a universal throughput guarantee. Initial and control rows are retained in
[bench-summary.log](runtime-fixes-validation/bench-summary.log).

Warm comparator, 100 calls, map with two shared-prefix binary keys (construction
outside timing), all results not_comparable:

| Bytes/key | Before, us | After, us |
|---:|---:|---:|
| 1025 | 46 | 31 |
| 1048577 | 6533 | 74 |
| 16777217 | 183717 | 44 |

This corroborates the structural bound; it is not a realtime limit assertion.
No comparator invocation is added to compare_return=false.

## ETS NOTE and remaining limitations

The final disappearance check now asks only ets:info(Tab,owner), avoiding allocation
of the full table-info list (including unrelated metadata). Enumeration semantics
and owner filtering are unchanged. ets:all still enumerates all VM tables before
the inspection cap: documented O(VM table count) limitation, outside guardian.
100 enumeration calls measured 3210 us with 100 additional tables and 17313 us
with 1000. No ownership redesign or unsupported VM-wide enumeration cap is claimed.

VM-global residual metrics intentionally cannot establish input attribution; replay
M/N may differ due to collection of earlier returns. Quiescence is a bounded wait,
not a claim that the whole VM is idle. No confirmed leak/deadlock/livelock claims.
No remaining MAJOR/BLOCKER or known correctness MINOR from this fix set.

## Additional executed commands and raw evidence

```sh
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_runtime_acceptance_tests,efz_runtime_tests,efz_limits_tests,efz_phase3_tests,efz_backend_tests
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/debt_probe.escript /home/fbogoslavskii/erl:fuzz/efz
ERL_FLAGS='+S 4:4' timeout 50s escript /tmp/efz-p0-fixes/debt_contention.escript /tmp/efz-acceptance-20260921/baseline
ERL_FLAGS='+S 4:4' timeout 50s escript /tmp/efz-p0-fixes/debt_contention.escript /tmp/efz-p0-fixes/before-tree
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /tmp/efz-p0-fixes/before-tree before-off off
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/fbogoslavskii/erl:fuzz/efz off off
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/fbogoslavskii/erl:fuzz/efz resources resources
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/short_bench.escript /home/fbogoslavskii/erl:fuzz/efz full full
ERL_FLAGS='+S 4:4' escript /tmp/efz-p0-fixes/post_bound.escript /home/fbogoslavskii/erl:fuzz/efz
```

The temporary drivers/snapshots remain in `/tmp/efz-p0-fixes/` and
`/tmp/efz-acceptance-20260921/baseline/`. Fresh logs are preserved in
`docs/runtime-fixes-validation/`; no historical acceptance log was counted as PASS.
