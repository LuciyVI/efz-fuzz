# Phase 2 validation record

Date: 2026-09-08. All execution targets and corpora are local artificial fixtures.
Environment: OTP 27.0, ERTS 15.0, x86_64-pc-linux-gnu; Rebar3 3.25.0.

## Baseline and scope

The repository is the `efz/` subdirectory of the supplied workspace. At entry,
README and app metadata were modified, and most Phase 1 code, examples, tests,
and docs were untracked. No AGENTS.md or additional repository instructions were
found. Work was compared against a copy of that initial state; unrelated corpus,
mutator, behaviour, application callback, and root-supervisor source was preserved.
No Git identity, remotes, commits, staging, or pushes were changed.

Before editing code: `rebar3 compile` passed; `rebar3 eunit` passed all 7 tests;
`rebar3 ct` passed with zero cases; `rebar3 dialyzer` passed. There was no configured
formatter/linter plugin. Existing xref checks are exercised in final validation.

The baseline executor could return before timeout termination was confirmed,
and coverage was a shared gen_server set. Initial calibration, crash storage,
and reliable campaign teardown were missing. Those foundations were repaired
in the existing execution/worker/fuzzer path; the original random mutator and
in-memory corpus implementation were retained.

## Commands and final outcomes

| Command | Result |
|---|---|
| `rebar3 compile` | Pass, warnings treated as errors |
| `rebar3 eunit` | 24 tests pass, including 17 grouped Phase 2 cases |
| `rebar3 eunit --module=efz_phase2_tests` | Pass, all 17 focused Phase 2 cases |
| `rebar3 ct` | 3 integration cases pass |
| `rebar3 dialyzer` | Pass; compiler added to PLT extra apps for compilation APIs |
| `rebar3 xref` | Pass, configured undefined/deprecated checks |
| `REBAR_BASE_DIR="$EFZ_CLEAN_BUILD" rebar3 compile` with a new `mktemp` directory | Pass; ordinary parser BEAM has no EFZ manifest |
| `escript examples/automatic/run.escript` | Instrumented build and 500 real-mutator iterations complete |
| `escript scripts/coverage_bench.escript` | Seven measured samples per warmed mode; no threshold |
| `git diff --check` | Pass |

No dependency blocked these commands. Expected negative-test diagnostics include
strict-mode rejection of comprehensions, `maybe`, and nonliteral record defaults,
missing/changed artifacts, and unselected modules. During development, the
relocation test exposed source-root `.` normalization and was fixed. An invalid
record-default test fixture was corrected after the compiler rejected a bound
variable in a record declaration. These were development failures, not baseline
failures; final test outcomes are above.

The clean build was created under `/tmp/efz-clean.cl22wE` without cleaning or
resetting the existing worktree/build. Its ordinary parser was checked with
`efz_cov_manifest:from_beam/1`, which returned `{error,missing_instrumentation}`
as expected. Generated outputs remain ignored under `_build` or in the explicit
temporary build directory.

## Concrete retention and continuation evidence

The deterministic test mutator (only `test/efz_scripted_mutator.erl`) emits:

```erlang
[<<>>, <<>>, <<255>>, <<1,7>>, <<1,7>>]
```

After calibrating the single seed `<<0>>`, `<<>>` is retained as corpus entry 2,
with parent entry 1 and `retention_reason => new_coverage`. It returns `{ok,empty}`
and discovers the `classify/1` empty-input clause at
`examples/simple_parser/efz_example_parser.erl:7:1`. In this recorded build, its
logical identity has probe ID 2 and build SHA-256:

```text
5f11a3a9df248ba517a1ae78cfad9462d6c6453bc0565bfe27089fa4a8239b6a
```

This ID was read from the generated manifest/decision, not hard-coded into core
logic or the acceptance test. The metadata also includes an execution reference
and the input SHA-256. The next identical mutation is rejected. `<<255>>` raises
the labelled artificial exception and is saved as a crash with nonempty coverage.
The campaign continues and retains `<<1,7>>`, then rejects its repetition.

Final deterministic counts: 1 calibration, 5 mutation executions, 2 discoveries,
2 equivalent rejections, 1 crash, and 3 corpus entries. Crash-only coverage is
not merged; a separate assertion proves it can still be novel for a later
successful result. `_build/phase2-acceptance.term` stores the full report.

The production mutator run uses `random_seed => {17,23,41}`, seed `<<0>>`, and
500 iterations. Measured result: 5 discoveries, 2 artificial crashes (1 unique),
493 equivalent rejections, 0 timeouts, 0 infrastructure failures, and 6 corpus
entries. It completes after both crashes. `_build/example-report.term` and
`_build/example-report.txt` contain the report; input and metadata files are under
`_build/example-crashes`. Random-mutator observations are separate from the
scripted acceptance proof.

## Coverage after termination and isolation

The lifecycle fixture sends `{probe_recorded, self()}` only after the automatic
entry probe returns. Tests wait for that message before requesting an external
kill, or before awaiting the deliberately blocked execution's timeout. Final
results assert nonempty coverage mapped to that function entry, `coverage_status
=> ok`, and respectively `{exit,killed}` or `{timeout,1000}`. The process is dead
before final timeout coverage is returned. Error, throw, and exit exception
results also retain their pre-termination coverage. The inspected snapshots
contain two probes each for error/throw/exit, and one probe each for external
kill/timeout, all with `coverage_status => ok`.

Inspectable snapshots are written by EUnit to `_build/phase2-kill.term`,
`_build/phase2-timeout.term`, `_build/phase2-error.term`,
`_build/phase2-throw.term`, and `_build/phase2-exit.term`.

Other checks cover fresh empty contexts, same-input equal probe sets and distinct
references, different-input disjoint entry probes, two simultaneously attached
contexts, selected cross-module calls, repeated deadline-boundary executions,
and unchanged ETS table counts. Caller death, public campaign cancellation, and
application shutdown during a synchronized active target all terminate the target
and context owner. A caught invalid-table hook exception still becomes an
infrastructure result instead of a target crash or successful empty feedback.

## Benchmark observations

See [the complete measured samples](coverage.md#reproducible-validation-and-overhead).
The same ordinary/instrumented fixture ran 200,000 tail-loop iterations per
sample after 30,000 warmup iterations, seven repetitions per mode:

| Mode | Median | Relative to ordinary |
|---|---:|---:|
| Ordinary | 518 us | 1.00x |
| Instrumented, no context | 5,315 us | 10.26x |
| Instrumented, active context | 67,209 us | 129.75x |

The active set held six probes in 419 ETS words (3,352 bytes at 8 bytes/word), then
was deleted. This synthetic loop exposes hook/ETS overhead; it is not a claim
about end-to-end parser throughput. OTP cover was not benchmarked. There are no
machine-specific correctness thresholds.

## Changed files relative to the supplied Phase 1 worktree

* Compilation/runtime additions: `src/efz_instrument.erl`,
  `src/efz_instrument_pt.erl`, `src/efz_cov_rt.erl`,
  `src/efz_cov_manifest.erl`, `src/efz_feedback.erl`.
* Existing integration changes: `src/efz.erl`, `src/efz_config.erl`,
  `src/efz_cov.erl`, `src/efz_executor.erl`, `src/efz_worker.erl`,
  `src/efz_fuzzer.erl`, `src/efz_worker_sup.erl`, `src/efz_stats.erl`,
  `src/efz_crash.erl`, `src/efz.app.src`, `rebar.config`.
* Example: changed `examples/simple_parser/efz_example_parser.erl`; added
  `examples/simple_parser/efz_example_target.erl` and
  `examples/automatic/run.escript`.
* Tests: changed `test/efz_smoke_tests.erl`; added `test/efz_phase2_tests.erl`,
  `test/efz_scripted_mutator.erl`, and `test/efz_coverage_SUITE.erl`.
* Fixtures/benchmark: `fixtures/efz_fixture.erl`,
  `fixtures/efz_fixture_helper.erl`, `fixtures/include/efz_fixture.hrl`,
  `fixtures/efz_skipped.erl`, `fixtures/efz_record_default.erl`,
  `fixtures/efz_bench_fixture.erl`, `scripts/coverage_bench.escript`.
* Documentation: `README.md`, `docs/architecture.md`, `docs/coverage.md`,
  `docs/adr/0002-automatic-coverage.md`, and this validation record.

The remaining limits are explicit: only OTP 27.0 was tested; one worker and one
execution process; no arbitrary child cleanup/attribution; skipped syntax requires
permissive mode; no arbitrary BEAM rewriting or other parse transforms; significant
measured hook overhead; no complete branch/CFG/state coverage or VM/OS sandbox.
