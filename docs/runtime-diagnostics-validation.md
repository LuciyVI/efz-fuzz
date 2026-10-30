# P0 validation — 2026-09-16

**English** · [Русский](i18n/ru/runtime-diagnostics-validation.md) · [Español](i18n/es/runtime-diagnostics-validation.md) · [简体中文](i18n/zh-CN/runtime-diagnostics-validation.md) · [All languages](i18n/README.md)

## Checkout and environment

- Initial commit: `205e18ba172d74bd6c652a68abfc73e02e4a1f86`.
- Ubuntu 24.04.4 LTS, x86_64, kernel `6.8.0-nyx+`.
- Erlang/OTP 27.0, ERTS 15.0, Rebar3 3.25.0.
- Rebar3/bench used `ERL_FLAGS='+S 4:4'`; external hazardous lifecycle fixtures
  used `erl +S 2:2` under `timeout 10s`.
- No applicable AGENTS.md was found in the checkout or parent directories.
- The checkout initially contained coverage/hit-count, corpus, CLI and docs
  changes: [complete initial status](runtime-validation/preexisting-status.txt).
  The initial diff was saved in `/tmp/efz-p0-baseline/preexisting.diff`.
  No reset/clean, branch updates, commit/push were performed.
- Existing harness/target files were not edited. New targets are only in
  `fixtures/runtime/`. 11 files with unrelated changes, untouched by P0,
  matched the saved initial state byte for byte.
- [Files changed specifically by this task](runtime-validation/changed-files.txt).

Guardian ownership, start gates, monitors, trace barriers, execution-scoped
coverage/integrity, dirty-runner retirement, crash groups, raw/recipe replay and
single-run calibration already existed before implementation. Repeated
verification, the sampler and runtime store/replay did not exist. The existing
feedback loop was checked against the actual checkout; the new repetitions do
not invoke feedback/retention/planner.

## Commands and results

Each command was run from the checkout root:

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 dialyzer
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 eunit --module=efz_runtime_tests
```

| Check | Initial checkout | After implementation |
|---|---:|---:|
| compile | PASS | PASS |
| EUnit | 199 passed | 214 passed |
| Common Test | 3 passed | 3 passed |
| Dialyzer | PASS, no warnings | PASS, no warnings |
| xref | PASS | PASS |
| New P0 EUnit cases | — | 15 passed, including multiple scenarios within cases |

Complete logs: [baseline EUnit](runtime-validation/baseline-eunit.log),
[final EUnit](runtime-validation/eunit.log), [CT](runtime-validation/ct.log),
[compile](runtime-validation/compile.log), [Dialyzer](runtime-validation/dialyzer.log),
[xref](runtime-validation/xref.log). Baseline compile/ct/dialyzer/xref are also saved
in this directory. The initial regression detected a changed CLI message,
“could not be loaded”; the message was corrected and the final suite passed.

Validated:

| Area | Actual check |
|---|---|
| Stability | Normalized outcome/coverage frequencies, stable/variable probes, valid empty, invalid snapshot exclusion, insufficient samples |
| Return | Fresh references are stable by default; explicit comparator returns not_comparable; bounded large-term rejection and scalar unstable_return |
| Executor | Real instrumented target and unchanged binary harness API |
| Verification crash | First run succeeds, second deterministically crashes; origin=verification, one crash occurrence; global coverage equals the original run |
| Mutation state | Complete sequence of random mutation bytes and staged recipes/counters matches off/on |
| Resources | Temporary memory; 100 mailbox messages; 1000 bounded ETS rows; peak survives cleanup |
| Ownership | 4 controlled children + root; cap 2 yields known=5, observed=2, partial=true; infrastructure excluded |
| Child lifecycle | Abnormal child does not change successful root; ordinary child cleanup does not create an abnormal finding |
| Timeout | Real busy/waiting targets; age/evidence; a max_samples=2 ring preserves the latest observations |
| Missing data | Dead PID, disappeared ETS, missing samples, sampler failure |
| Stalled sampler | Sampler forcibly suspended in a separate VM; timeout=150 ms, confirmed cleanup, total duration <1000 ms |
| Infrastructure | Dirty before verification: 0 repeats; dirty on first repetition: later repetition skipped; guardian failure preserves dirty-runner status |
| Limits | Invalid nested keys/types/ranges; sample-slot cap; requested=16 with extra budget=1 yields completed=2, skipped=14 |
| Storage | Representatives/groups/payload caps, suppressed/dropped counters, stale index, corruption, interrupted directory, write-to-file path failure |
| Replay | Runtime round-trip, one-run unstable inconclusive, harness mismatch, build mismatch, fresh CLI VM; legacy artifacts in the previous suite |
| Regression | All previous manual/automatic coverage, random/staged, exact recipes, durable corpus, feedback and isolation tests |

The source of alternating responses in the `vary` fixture is a **test-only
synchronized process**, not a random scheduler. It does not imply support for
external interactions in production harnesses. Dirty/guardian/stalled-sampler
fixtures are isolated by an OS-process watchdog; there are no atom bombs or
unbounded memory/process allocations. Tests do not simulate actual power loss
or disk exhaustion; interrupted/corrupt storage was checked by creating an
incomplete/corrupted state.

## Actual CLI round-trip

Prepare a bounded artificial timeout fixture:

```sh
rebar3 compile
mkdir -p _build/runtime-demo-final/harness _build/runtime-demo-final/seeds
ERL_FLAGS='+S 4:4' erlc +debug_info -o _build/runtime-demo-final/harness \
  fixtures/runtime/efz_runtime_harness.erl
ERL_FLAGS='+S 4:4' erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok,_}=efz_instrument:compile("fixtures/runtime/efz_runtime_sites.erl",
    #{modules=>[efz_runtime_sites],source_root=>".",outdir=>"_build/runtime-demo-final/targets"}),
  ok=file:write_file("_build/runtime-demo-final/seeds/waiting",<<"waiting">>),halt().'

ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_runtime_harness --code-path _build/runtime-demo-final/harness \
  --artifacts _build/runtime-demo-final/targets --seeds _build/runtime-demo-final/seeds \
  --out _build/runtime-demo-final/out --max-iterations 0 --timeout 100 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 10 --sample-interval 5

EFZ_RUNTIME_FINDING=$(dirname "$(rg --files _build/runtime-demo-final/out/runtime-findings | rg '/artifact.input$' | head -n 1)")
ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
  --runtime-finding "$EFZ_RUNTIME_FINDING" --target efz_runtime_harness \
  --code-path _build/runtime-demo-final/harness --artifacts _build/runtime-demo-final/targets --runs 3
```

Observed: campaign `completed`, 1 calibration + 2 verification executions,
3 timeout occurrences (three real execution failures), one crash group.
Runtime replay in another VM: **observed timeout_waiting, 3/3**, compatibility
verified. Logs: [campaign](runtime-validation/cli-fuzz.log),
[replay](runtime-validation/cli-replay.log). Use a new `--out` when changing the
fixture/build locally; the old store is not migrated.

The **existing, unchanged** `efz_example_target` was also checked:

```sh
mkdir -p _build/runtime-existing/seeds
ERL_FLAGS='+S 4:4' erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok,_}=efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
    #{modules=>[efz_example_parser],source_root=>".",outdir=>"_build/runtime-existing/targets"}),
  ok=file:write_file("_build/runtime-existing/seeds/seed",<<0>>),halt().'
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_example_target --artifacts _build/runtime-existing/targets \
  --seeds _build/runtime-existing/seeds --out _build/runtime-existing/out \
  --mutation random --max-iterations 10 --timeout 100 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 20 --sample-interval 20
```

Observed: `completed`, 10 mutation executions, 6 verification executions,
0 infrastructure failures. This is a short smoke campaign, not a long-running
fuzzing audit; the number of discoveries/repeats may differ without a fixed RNG
seed in the CLI. [Actual log](runtime-validation/existing-harness.log).

## Benchmark — actual measurements

Driver: `bench/efz_runtime_bench.erl`, launcher `scripts/runtime_bench.escript`.
One worker, prepared automatic coverage, presence feedback, unchanged instrumented
fixture and binary harness. Each mode uses a separate VM with `+S 4:4`, a
100-mutation warmup, five campaigns of 1000 random mutations + 1 seed, and fixed
mutation/selection seeds. Stability/full perform 4 additional executions each
(seed and discovery); this was measured, not assumed. After the fast campaigns,
`mailbox_ets` (~160 ms) is executed separately.

The baseline was built separately in `/tmp/efz-p0-baseline/checkout` from
`git archive HEAD`, the saved original diff and the original untracked
`src/efz_cov_count.erl`. Thus the comparison includes the user's previous changes,
not just clean HEAD. The main modes were measured sequentially, without running
the test suite/another benchmark in parallel. The host was not dedicated;
CPU frequency/load were not fixed.

```sh
# Each mode: warmup + five runs. The ordinary EFZ build must be ready.
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript baseline /tmp/efz-p0-bench/release/baseline /tmp/efz-p0-baseline/checkout/_build/default/lib/efz/ebin
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript off /tmp/efz-p0-bench/release/off
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript stability /tmp/efz-p0-bench/release/stability
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript resources /tmp/efz-p0-bench/release/resources
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript full /tmp/efz-p0-bench/release/full
ERL_FLAGS='+S 4:4' escript scripts/runtime_bench_report.escript /tmp/efz-p0-bench/release summary.csv
```

| Mode | Median mutation exec/s | Min–max | Mutations / verification | Median-run wall, ms | Post-execution diagnostics, ms | Verification elapsed, ms |
|---|---:|---:|---:|---:|---:|---:|
| baseline | 279.5 | 236.1–372.7 | 1000 / 0 | 3577.3 | 0.00 | 0.00 |
| off | 217.6 | 182.7–227.4 | 1000 / 0 | 4596.3 | 0.00 | 0.00 |
| stability | 219.6 | 212.1–224.0 | 1000 / 4 | 4553.4 | 52.37 | 4.35 |
| resources | 205.4 | 179.1–225.5 | 1000 / 0 | 4868.1 | 38.26 | 0.00 |
| full | 194.9 | 176.8–216.9 | 1000 / 4 | 5131.5 | 52.60 | 3.97 |

`runtime_diagnostic_us` is worker wall time after the initial executor:
comparisons, summary/storage and verification are **included**.
`verification_elapsed_us` must not be added to it again. Sampler work time is
a different metric in a separate process. These rows correspond to the run with
median throughput, not independently selected medians of different counters.

The fast campaigns produced no runtime samples: resources=0/1001 sampled/missed,
full=0/1005; stability disables the sampler. Zeros for baseline/off mean that
measurements were disabled, not that consumption was absent. Therefore, fast-loop
slowdown **does not measure the cost of one sampling hook that actually ran**.

| Long-input mode | Wall, ms | Samples | Sampler work, ms | ETS diagnostic buffer at finish, bytes |
|---|---:|---:|---:|---:|
| baseline | 166.52 | 0 | 0.000 | 0 |
| off | 164.70 | 0 | 0.000 | 0 |
| stability | 166.50 | 0 | 0.000 | 2648 |
| resources | 167.44 | 7 | 1.004 | 7008 |
| full | 166.11 | 7 | 0.534 | 7008 |

The maximum completed ETS buffer in fast campaigns was 2648 bytes with P0 enabled.
This is **not total diagnostics memory**: sampler/guardian heap and retained report
maps are excluded. Resident slots, children, report bytes and disk metadata are
bounded by separate caps. Arbitrary targets with expensive process_info/ETS
require separate profiling.

The [CSV summary](runtime-validation/bench/summary.csv) and raw `.term` files/logs
for all five modes are saved in `docs/runtime-validation/bench/`. The same report
script can recompute the summary from the raw files.

### Checking the unexpected P0=off result

The main sequential batch showed off at **−22.2%** in median wall throughput.
This result cannot be declared an absence of regression. An additional control
was run in reverse order (off first, then baseline), using the same driver/fixture,
warmup and five campaigns; `/usr/bin/time` also measured CPU for the whole escript
process, including compilation/warmup/the long fixture, so those CPU seconds
**are not the CPU cost of one mutation**:

```sh
/usr/bin/time -f 'wall_s=%e user_s=%U system_s=%S' \
  env ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript off /tmp/efz-p0-bench/reverse/off
/usr/bin/time -f 'wall_s=%e user_s=%U system_s=%S' \
  env ERL_FLAGS='+S 4:4' escript scripts/runtime_bench.escript baseline /tmp/efz-p0-bench/reverse/baseline \
  /tmp/efz-p0-baseline/checkout/_build/default/lib/efz/ebin
```

| Reverse-order control | Median mutation exec/s | Min–max | Whole-process wall, s | User CPU, s | System CPU, s |
|---|---:|---:|---:|---:|---:|
| off | 253.0 | 248.0–258.6 | 20.78 | 57.28 | 4.30 |
| baseline | 251.6 | 223.5–259.1 | 21.59 | 59.80 | 4.66 |

Here off is **+0.54%** relative to baseline and does not show increased CPU time.
More CPU seconds than wall seconds is normal for a VM with multiple scheduler
threads. Both opposing results are preserved: `bench/reverse/{off,baseline}/`
contains raw `.term`, stdout and time logs. This shows that the measurement is
sensitive to conditions/order, but does not establish a particular external cause.
There is no proof of a statistically significant absence of regression on a
dedicated host.

## Outcome and remaining boundaries

- **PASS for functional checks in this environment:** production executor/guardian
  path, repeated calibration, resources/children/timeouts, separate
  findings/report/replay, limits and the listed regressions; 214 EUnit + 3 CT,
  compile/Dialyzer/xref.
- **PARTIAL performance acceptance:** all five modes were actually measured;
  off has no consistent degradation in the reverse-order control, but substantial
  variation prevents an overall PASS for the absence of a material regression.
  A separate control on a dedicated stabilized host is needed before making that
  claim.
- Samples do not guarantee detection of fast peaks. ETS enumeration is partial
  when capped; the memory metric does not include the full off-heap footprint.
  Sampler/report heap was not measured as a separate peak: the report gives
  actual ETS buffer bytes and limitations.
- The initiator of a child exit is usually `unknown`: DOWN does not prove who
  sent the exit signal. Cleanup records its own kill_requested, and an ambiguous
  race is not turned into a claim about an exact cause or process leak.
- Resource growth within a run is a diagnostic suspicion. There is no proof of
  arbitrary leaks, memory safety, semantic correctness, race/deadlock/livelock,
  native failures or external side effects. A stateful reproducer may require
  input history/a fresh VM. These extensions are deliberately not implemented.
- Full power-loss/ENOSPC fault injection, other OTP/OS versions and long
  production campaigns were **NOT RUN**. None of the listed final
  compile/test/benchmark checks had commands blocked by missing dependencies
  or permissions.

This report describes local checks that actually ran; it is not a claim of
production readiness or an overall full PASS for all operational properties.
