# Phase 2.1 performance and closeout record

Closed locally on 2026-09-09. The default is **prepared validation with the
original exact ETS hook**. Membership remains opt-in. Preparation improves the
measured complete parser and sparse executions/campaigns; membership helps
repeated-hit workloads but penalizes first observations and has no reliable
advantage in sparse campaigns. No probes, timeouts, identities, or retention
rules were changed to obtain these results.

## Environment, baseline, and provenance

The repository is `efz/` under the supplied workspace. No applicable `AGENTS.md`
or formatter/linter configuration was found. The worktree was already dirty,
with most Phase 1/2 source untracked. Comparison with the preserved Phase 2
snapshot `/tmp/efz-phase21-baseline` identifies this phase's changes; Git status
alone cannot distinguish them. No clean/reset, staging, commit, identity, remote,
or push operation was performed.

At Phase 2.1 entry, compilation, 24 EUnit tests, three Common Test cases,
Dialyzer and xref passed. The interrupted implementation subsequently passed
36 EUnit tests and the same remaining gates. Closeout added two focused tests
and fixed one artifact-loading defect; the final gate passes **38 EUnit tests**.
There were no environmental blockers. Historical Phase 2 results remain in
[phase2-validation.md](phase2-validation.md); they are observations, not test
constants.

The unprofiled final throughput and all memory VMs recorded:

* OTP 27.0, ERTS 15.0; Rebar3 3.25.0; JIT, 8-byte words.
* Ubuntu 24.04.4 LTS, Linux, `x86_64-pc-linux-gnu`; Intel Core i7-1260P.
* `ERL_FLAGS='+S 4:4'`: four schedulers, four online, four dirty CPU schedulers.
* Fixture compilation with `compile:noenv_file/2`, `debug_info`,
  `warnings_as_errors`; strict instrumentation, explicit module allowlists,
  `source_root => "."`, separate instrumented directories. No profiling during
  throughput measurements; no custom NIF, port-based runner, or external engine.

The original tight-loop benchmark was actually rerun at Phase 2.1 entry:
seven warmed samples of 200,000 iterations gave medians **766 / 2,218 / 33,407 us**
for ordinary / inactive / active. This differs from the earlier reported
518 / 5,315 / 67,209 us. It does not independently reproduce those exact numbers.
Its raw samples are archived; scheduler settings were not captured in that
benchmark artifact, so it is not combined with the four-scheduler comparison.
The original example also completed with 500 mutations, one calibration, four
discoveries, 494 rejections and two crashes, one unique.

The authoritative full-run artifacts are:

| Group | Content and completion evidence | Applicability |
|---|---|---|
| `_build/performance-final/{environment,hooks,executor,campaign}.term` and `.txt`, `summary.txt` | 36 hook, 12 executor, 24 campaign rows; five samples each. Complete command exited 0; progress log ends after saving all six campaign cases. Audit recomputes every median/min/max and compares canonical campaign objects before compacting. | Current hooks, executor, feedback and mutation timing. Historical startup samples are superseded below. |
| `_build/performance-final/*-candidates.term` | Complete prerecorded loop/parser/sparse candidate sequences | Same input order across variants; also included in durable evidence |
| `_build/performance-memory-{reference,member,prepared,prepared_member}/` | Four separate VMs, each saved a complete environment and memory result; loop command completed with exit 0 | Original memory observations, before closeout preflight fix |
| `_build/performance-final/profile-sparse-prepared.txt` | Complete eprof table and `Total: 6331`; profile command exited 0 | Focused diagnostic only; preparation/loading outside profile |
| `_build/performance-final/automatic-example.{term,txt}` | Completed report, nonzero discoveries/crashes, zero infrastructure failures; command sequence exited 0 | Previous working example. Its command did **not** set `ERL_FLAGS`; scheduler count was not recorded and is not assumed to be four. |
| `_build/phase21-closeout-startup/` | Five warmed zero-mutation campaign samples per fixture/variant, exit 0 | Current preflight startup/calibration costs |
| `_build/phase21-closeout-memory-*/` | Four new separate VMs; complete bounded memory checks, exit 0 | Current memory observations after preflight fix |
| `_build/phase21-closeout-fixed/` | Final gate logs, refreshed example, artifact audit | Current source validation; refreshed example explicitly uses `+S 4:4` |

No benchmark process from the interrupted session remained when work resumed.
Existence or modification time of a file was not used as completion proof.

[Durable evidence](performance/phase2.1-samples.term) contains all raw timing
samples and spread, startup samples, both sets of memory records (including
`/proc/self/status`), compact environment data, full build/source/input identities,
artifact SHA-256s, profile tables, validation logs, example/termination results,
and prerecorded candidates. Runtime references/pids are explicitly replaced by
`runtime_reference_omitted`/`runtime_pid_omitted` in this consultable copy.
Repeated campaign check objects are replaced by digests **after exact comparison**;
original full checks remain in the ignored raw campaign files. Digests are an
archive aid, not the differential test oracle.

Provenance is explicit about its limit: the old harness recorded fixture hashes,
compiler options, build IDs and runtime metadata, but not a full source-tree hash
at measurement time. The closeout archive records source hashes retrospectively,
recompiles all 22 current application BEAMs using their recorded compiler options,
and compares code MD5 and abstract forms. It also rebuilds the three fixture
identities and verifies the saved BEAM/sidecar terms and source hashes in all
artifact groups. The prior successful execution records and unchanged hot-path
source establish continuity; this is not a claim of an originally signed Git
revision or contemporaneous whole-tree snapshot.

The audit exposed a Phase 2 preflight defect: equivalent ETF maps can serialize
in different key orders in another VM. Byte comparison rejected valid saved
sidecars. `efz_instrument` now safely decodes the sidecar and compares exact terms
to the validated embedded manifest. Invalid encodings and changed manifests
still fail. A deterministic reversed-key encoding test and fresh-VM preflight
regression cover this. This change runs during artifact loading, not a probe,
execution or mutation interval. Only startup/calibration, memory observations
and the example were refreshed; no throughput/profile rerun was necessary.

## Variants and public defaults

Names are defined by `backend/1`, `prepared/1` and campaign options in
`bench/efz_perf.erl`:

| Variant | Validation strategy | Coverage storage/hook |
|---|---|---|
| `reference` | `per_execution`: reconstruct allowed exact set from manifests | `ets`: original insert on every hit |
| `member` | `per_execution` | `ets_member`: membership lookup, insert only if absent |
| `prepared` | `prepared`: one protected allowlist, compact executor options | Original `ets` |
| `prepared_member` | `prepared` | `ets_member` |

`efz_config:defaults/0`, and therefore `efz:start/1` and the ordinary automatic
example, select `prepared` + `ets`. Existing campaign configurations without
these options receive the new validation default with unchanged feedback policy.
Select the optional hook by adding:

```erlang
coverage_backend => ets_member
```

For the complete reference configuration, use:

```erlang
coverage_backend => ets, coverage_validation => per_execution
```

The default `efz_cov:open/0` remains original ETS. Low-level `run/4` with only
`manifests` still validates per execution; it does not implicitly create a shared
plan. `run/3` retains the manual compatibility API. Both hook backends preserve
schema 1 contexts and exact `{Module, BuildId, ProbeId}` observations.

Two focused alternatives were evaluated: membership before insertion, and
preparing validation/avoiding copying full worker state into each coordinator.
No atomics backend, compact/hash IDs, process-local seen cache, asynchronous
publication or final target flush was introduced. Membership still checks the
external table on every hit; a deleted table cannot hide behind a cache.

## Prepared-validation boundary

Public campaign preflight validates selected artifacts, embedded manifest schema
and instrumentation version, sidecar equivalence, descriptor build ID and loaded
module identity. The target adapter need not itself be instrumented; explicitly
selected modules must be. The configuration rejects invalid backend/validation
choices and multiple workers.

`efz_cov_manifest:prepare(Mode, Manifests)` separately validates manifest format,
unique probe IDs/structural paths, nonempty automatic selection and duplicate
modules. It creates `{efz_cov_plan,1,Table,BuildMap}`. The unnamed **protected** ETS
set contains every exact allowed identity and a `'$efz_plan'` mode/build marker.
Preparation itself does not load artifacts; low-level users must preflight first.
The plan works with either hook backend because their observation formats agree.

The campaign worker owns its plan. It passes only coverage/backend/plan options
to each coordinator, removing both repeated set construction and full
manifest/worker-state copying. A low-level caller may intentionally share a plan
with other callers while its owner lives: this is an immutable read capability,
not a campaign ID or execution context. Foreign processes cannot write it.
The owner releases it after all users stop, or owner termination deletes it.
Completion keeps the campaign worker, plan, corpus and report alive until
`efz:stop/0` or application shutdown. Separate campaigns create separate plans.

Every execution still creates its own reference, target process and public ETS
observation set owned by a coordinator. Attach checks context ownership; every
active hit accesses that table. After target termination, validation checks the
plan marker even for an empty snapshot and tests **every observed identity**
against the prepared allowlist. Feedback also compares the pinned build map.
Disposed/mismatched plans and broken active tables become infrastructure results,
not discovered target bugs or valid empty feedback. Malformed descriptor versions
can produce a `coordinator_down` infrastructure result rather than the more
specific `invalid_coverage_plan`; neither is success. Valid observations survive
an expired plan, with error status, when its descriptor shape remains valid.

The new lifetime test covers protected foreign writes, shared read use, repeated
use, wrong schema/mode/build descriptors, plan-owner death during a synchronized
execution, and rejection after disposal with **zero observations**. Existing tests
cover changed builds, invalid manifests, deleted active observation tables and
caught runtime-hook errors.

Selected builds must remain unchanged for the campaign/plan lifetime. Preflight
rejects already loaded ordinary/different builds; observation validation rejects
unexpected new-build probes. Neither proves safety under later arbitrary code
replacement, particularly replacement that emits no hooks. Hot-code management
and a reload-safe cache are outside the supported API contract.

## Methodology and workloads

Five measured samples per case, after a discarded pilot or full warmup batch.
Variant order reverses on alternating rounds. Executor pilots choose batches
near 180 ms (128–20,000 executions); counts can differ and are normalized below.
Campaigns share 2,048 mutations per sample, plus one separately timed seed
calibration. The cap makes the slow reference practical: fast campaign batches
are still tens of milliseconds, not sub-millisecond timing. No machine-specific
thresholds or confidence intervals are claimed; spread means observed min–max.

| Fixture | Manifest probes | Executor observations | Input/work and checked result |
|---|---:|---:|---|
| `efz_bench_fixture` | 6 | 6 | `run(1024) = 2304`; tail-loop microbenchmark uses 20,000,000 iterations and verifies checksum 45,000,000 |
| `efz_perf_parser` | 20 | 10 | 32 copies of `<<0,0,7,1,35,2,2,97,98,3,2>>`; 352 bytes, result `{ok,128,1888}` |
| `efz_perf_sparse` | 2,051 | 2 | `<<0,7>>`, result 22; generated 2,048 explicit choice clauses plus fallback and entry probes |

Build IDs, unchanged after closeout:

```text
loop    943bea4cf9695048788654bbe520185c78611ad26733a1066989d28e4b0fd80d
parser  c966463003a8d5244d58710e533634f4003faeece71c7a9d61fdfa2559df2351
sparse  bf27f5190ec9b6744e8d20179a0c9110ae265238ac22fe4d70b2add7645f5534
```

Ordinary and instrumented fixtures are loaded in a controlled sequence without
active target calls; values are compared. No renamed-module approximation is
used. Complete-executor samples time `run/4` through coordinator termination and
cleanup, including context allocation, process/monitor startup, target work,
snapshot, validation and deletion. Each execution's outcome/status/canonical
probe set is checked against the reference. Plan setup is outside that timer and
recorded separately (sparse: 603 us prepared, 431 us prepared-member, single
observations; not a stable setup benchmark).

Campaign mutation clocks include corpus selection, actual mutation, executor,
feedback, retention, stats and crash artifact writes. They exclude fixture
compilation, calibration and final report construction/printing. API-start and
stop/cleanup timing are separately recorded. Both mutation RNG `{17,23,41}` and
corpus selection RNG `{101,109,113}` are set. The latter is an optional new
configuration; default unseeded corpus selection remains unchanged.

Replay cycles through saved candidate lists; it is benchmark-only, not a new
production mutator. Real mode uses the existing `efz_mutator_random`. Exact
sanitized coverage, corpus inputs, decisions/new probes, crash outcomes and stats
agree across all four variants and all five repetitions for each workload/mode.
Loop campaigns calibrate all six probes and retain no additional inputs. Parser
replay/real retain 5/10 total corpus inputs and observe 15/19 successful probes;
sparse replay/real retain 9/538 inputs and observe 10/540 successful probes. Thus
campaigns include different retention/metadata workloads, not just repeated writes.

## A. Hook costs

Repeated observations below use 2,000,000 direct hook calls, real full identities
from the 2,051-probe sparse manifest, and a pre-published set. Times are **ms per
batch**, median [min–max]; inactive still executes the same calling loop.

| Distinct probes | Inactive | ETS reference | Membership | Reference/member time ratio |
|---:|---:|---:|---:|---:|
| 1 | 15.208 [14.648–17.336] | 182.385 [179.183–185.007] | 118.594 [114.060–123.957] | 1.54x |
| 8 | 9.673 [8.811–10.222] | 176.121 [174.143–179.749] | 111.413 [110.601–115.619] | 1.58x |
| 64 | 8.670 [8.553–8.829] | 177.991 [176.712–180.876] | 112.828 [112.526–113.132] | 1.58x |
| 1,024 | 8.595 [8.534–8.792] | 189.348 [186.503–194.945] | 125.183 [124.630–128.117] | 1.51x |

Calling-loop/list traversal contributes to these times, explaining why the
inactive cost varies with distinct-count batching. All 500,000-call results are
also preserved. This measures the real `hit/1` path without attributing all its
cost to the process-dictionary lookup.

First observations use fresh, preallocated contexts; timing includes attach and
first publications, excludes allocation/snapshot/deletion. Every expected set is
checked afterwards. These deliberately use many live contexts to isolate writes;
production remains one worker with one live execution.

| Hook calls | Probes/context | Contexts | ETS ms [range] | Member ms [range] | Member added time |
|---:|---:|---:|---:|---:|---:|
| 131,072 | 64 | 2,048 | 15.168 [14.983–16.831] | 20.565 [20.091–22.281] | 35.6% |
| 524,288 | 64 | 8,192 | 87.746 [87.056–92.194] | 112.473 [110.292–121.294] | 28.2% |
| 131,072 | 1,024 | 128 | 20.230 [19.191–20.427] | 25.031 [24.558–25.196] | 23.7% |
| 524,288 | 1,024 | 512 | 91.261 [90.249–91.978] | 113.625 [111.488–115.044] | 24.5% |

The existing loop fixture at 20,000,000 iterations:

| Mode | Median ms [min–max] | Relative to ordinary |
|---|---:|---:|
| Ordinary | 35.087 [32.072–35.191] | 1.00x time |
| Instrumented inactive | 227.358 [220.167–229.080] | 6.48x time |
| Instrumented ETS | 4,046.383 [3,962.962–4,088.383] | 115.32x time |
| Instrumented membership | 2,593.771 [2,503.256–2,614.029] | 73.93x time |

All six probes occur; there are 40,000,002 hook calls. Membership is 1.56x faster
than ETS in this synthetic loop, while substantial instrumentation overhead
remains. Preparation is not involved in these hook measurements. No hook ratio
is presented as campaign throughput.

## B. Complete executor

Times are **us/execution**, median [min–max]. `N` is each variant's measured batch
size in reference/member/prepared/prepared-member order. The same fixture input
and exact result/probe set are used within each row.

| Fixture; N | Reference | Member | Prepared (default) | Prepared-member |
|---|---:|---:|---:|---:|
| Loop; 808/1,260/860/1,335 | 230.853 [221.092–235.197] | 149.522 [142.960–157.459] | 221.483 [213.171–231.353] | 142.897 [138.843–144.178] |
| Parser; 4,105/4,974/4,975/6,386 | 50.392 [48.179–50.662] | 40.454 [37.910–41.297] | 37.471 [37.168–39.381] | 27.998 [27.633–29.012] |
| Sparse; 132/129/17,311/20,000 | 1,331.235 [1,241.583–1,623.515] | 1,624.434 [1,409.581–1,770.605] | 7.405 [7.234–7.943] | 7.582 [7.034–7.607] |

Preparation gives 1.04x / 1.34x / 179.76x reference/default median ratios.
The small loop change has overlapping ranges; its advantage alone is weak.
The large sparse change removes work proportional to a 2,051-probe manifest
from every two-hit execution. It is not a general Erlang speedup. Membership's
sparse reference-path median is **22% slower**, with broad overlapping ranges;
with preparation it is 2.4% slower, again inconclusive as a fine distinction.

## C. Complete campaigns

Each sample has **2,048 mutations and one separate calibration**. Values are
mutation **ms/batch**, median [min–max]. Manifest and successful probe counts are
specified in the methodology; different modes must not be averaged together.

| Fixture / mode | Reference | Member | Prepared (default) | Prepared-member |
|---|---:|---:|---:|---:|
| Loop / replay | 140.439 [130.715–150.496] | 114.871 [104.974–124.499] | 124.164 [121.846–134.971] | 94.616 [87.827–102.950] |
| Loop / real | 157.566 [149.826–177.073] | 120.003 [112.035–142.344] | 139.574 [128.366–141.977] | 106.589 [99.934–111.639] |
| Parser / replay | 162.143 [147.937–163.049] | 138.111 [133.298–174.021] | 111.907 [109.947–115.914] | 99.370 [85.961–111.084] |
| Parser / real | 122.444 [115.189–129.781] | 111.796 [107.400–115.664] | 95.287 [91.475–99.000] | 85.973 [81.385–91.675] |
| Sparse / replay | 2,842.573 [2,738.130–2,892.657] | 2,910.044 [2,882.867–3,023.839] | 33.266 [31.554–33.738] | 34.619 [31.641–40.462] |
| Sparse / real | 3,939.023 [3,409.309–4,382.920] | 3,750.131 [3,152.201–4,191.928] | 49.230 [46.300–78.594] | 47.972 [39.963–75.125] |

| Fixture / mode | Reference mutations/s | Default mutations/s | Default speed ratio |
|---|---:|---:|---:|
| Loop / replay | 14,583 | 16,494 | 1.13x |
| Loop / real | 12,998 | 14,673 | 1.13x |
| Parser / replay | 12,631 | 18,301 | 1.45x |
| Parser / real | 16,726 | 21,493 | 1.29x |
| Sparse / replay | 720 | 61,564 | 85.45x |
| Sparse / real | 520 | 41,601 | 80.01x |

Adding membership to the prepared default improves loop campaign medians by
1.31x and parser by 1.13x replay / 1.11x real. Sparse replay is 4.1% slower; sparse
real is 2.6% faster with overlapping ranges and large outliers. This supports an
opt-in repeated-hit optimization, not a universal backend switch. There is no
unexplained aggregate speedup. The reference remains useful for differential
checks, including its original per-execution set construction/copying costs.

Current **startup** observations come from zero-mutation campaigns after the
sidecar fix, one full warmup and five alternating samples. Compilation of all
three ordinary/instrumented fixtures took 1,174,788 us in that VM (one cold build
observation); the original final-run build took 575,889 us. These include compiler
startup and loading and are not a compiler-speed comparison. Median startup
before calibration / calibration / stop time, in us:

| Fixture | Reference | Member | Prepared | Prepared-member |
|---|---:|---:|---:|---:|
| Loop | 220 / 148 / 650 | 210 / 132 / 640 | 215 / 125 / 640 | 232 / 115 / 653 |
| Parser | 349 / 178 / 646 | 366 / 162 / 651 | 344 / 156 / 655 | 357 / 139 / 643 |
| Sparse | 19,318 / 3,392 / 1,378 | 20,327 / 4,129 / 1,629 | 22,710 / 156 / 1,765 | 21,215 / 152 / 2,685 |

These short startup samples are diagnostic, not the main throughput comparison.
Sparse startup ranges are 18,864–20,533 / 19,100–22,979 / 20,341–24,678 /
19,610–27,023 us. All startup/calibration/API-start/cleanup raw samples and ranges
are archived. `api_start_us` overlaps worker initialization/calibration; it must
not be added to `startup_us + calibration_us`. Historical campaign startup values
remain in the archive but are superseded as current measurements by this run.

## Memory and cleanup

Memory sampling is separate from throughput. Each variant runs in a fresh VM:
compile/load fixtures, snapshot after GC, optionally allocate a 2,051-ID plan,
attach a context and make 80,000 hits over eight distinct IDs, snapshot live state,
close context/release plan and GC, then run a bounded 5,000-mutation sparse replay
campaign with a sampler and stop everything. The sampler records VM/ETS/process
peaks at nominal 2 ms intervals; reading memory itself costs time, and actual
sampling spacing is longer. These are **sampled peaks**, not absolute peaks or
unprofiled throughput.

The original saved observations (decimal MB for VM totals):

| Variant | Before | With plan | Live context | After context/plan cleanup | After campaign cleanup | Sampled VM peak / samples |
|---|---:|---:|---:|---:|---:|---:|
| Reference | 57.143 | 56.191 | 61.645 | 56.205 | 54.809 | 81.542 / 2,315 |
| Member | 57.124 | 56.169 | 56.202 | 56.165 | 54.775 | 87.575 / 2,367 |
| Prepared | 59.509 | 58.720 | 64.187 | 58.448 | 57.104 | 77.915 / 34 |
| Prepared-member | 59.335 | 58.680 | 64.137 | 56.810 | 56.963 | 76.673 / 34 |

After the closeout preflight fix, the same bounded protocol produced:

| Variant | Before | With plan | Live context | After context/plan cleanup | After campaign cleanup | Sampled VM peak / samples |
|---|---:|---:|---:|---:|---:|---:|
| Reference | 56.129 | 56.154 | 61.597 | 56.135 | 54.749 | 84.452 / 4,534 |
| Member | 57.339 | 57.356 | 57.389 | 57.387 | 55.924 | 91.795 / 4,429 |
| Prepared | 58.326 | 58.640 | 64.107 | 58.371 | 57.007 | 84.378 / 76 |
| Prepared-member | 56.274 | 56.579 | 62.062 | 54.741 | 54.926 | 79.588 / 71 |

All refreshed checks also return to **41 processes, zero observation tables and
zero plan tables** after each cleanup. Live observation storage is again 3,656
bytes; plan allocation increases total ETS by 300,072–300,096 bytes. Refreshed ETS
sampled peaks are 517,624 / 517,912 / 820,288 / 818,016 bytes; process peaks remain
52. Final ETS totals are 515,976 / 515,872 / 515,968 / 516,264 bytes. These values
are observations, not thresholds or requirements for later machines.

For example, refreshed prepared `VmRSS` is 125,952 kB with the plan and 125,476 kB
after campaign cleanup; `VmHWM` stays at its earlier 240,416 kB high-water mark.
Prepared-member RSS actually rises from 133,776 to 137,428 kB while all its EFZ
owned tables are released. This illustrates why RSS or VM total alone cannot
establish a leak or prove its absence. The refreshed runs include the changed
startup allocation; different sampled maxima are not attributed to a backend
speed or memory improvement.

All original variants had one observation table while live, **3,656 bytes for
eight probes**, then zero. Prepared variants additionally held one plan; the
observed total ETS increase at allocation was 300,072 bytes for 2,051 identities
and its marker. It is an exact term-keyed set, not a packed bitmap. Whole-VM live
memory includes heap/allocator and compiler warmup effects; subtracting those
VM columns would not isolate plan cost. The legacy six-hit loop table was
3,352 bytes, consistent with a different observed set.

Original sampled total ETS peaks were 517,424 / 517,624 / 817,464 / 817,752 bytes.
All four original VMs returned to 41 processes and zero coverage/plan tables
at both cleanup boundaries; sampled process-count peaks were 52. Final total
ETS values remained about 18 KB above the early snapshots due to other VM/app
state. This is not evidence of an EFZ execution-table leak.

Large VM-total fluctuations already occur between `before` and `with_plan`,
even when no plan is allocated. Treat these as cold-start/warmup and GC/allocator
observations. Prepared campaigns are much shorter and received far fewer samples;
smaller sampled maxima do not prove lower absolute peaks. `/proc/self/status`
records RSS and lifetime `VmHWM` separately in the archive. Neither is the same
quantity as `erlang:memory(total)` or ETS table words.

Resource-release evidence is stronger than similar VM totals: tests wait for
monitored target/coordinator termination and verify exact table inventories,
repeat 50 deadline/next-execution pairs per variant, kill continuously publishing
targets, and exercise caller death, plan-owner death, cancellation, application
shutdown and restart. Completed campaigns intentionally retain corpus, successful
coverage, decisions, unique crash reports and the plan until stopped. Those
objects are not execution-local leaks. This bounded evidence supports resource
cleanup under the documented lifecycle; it is not an unlimited-soak or arbitrary
VM-state leak guarantee.

## Profiling findings and decision

The original loop eprof run attributes 47.97% of sampled function time to
100,002 ETS inserts, 30.38% to `efz_cov_rt:hit/1`, and 21.52% to the loop. The
parser profile attributes 26.52% to inserts and 17.76% to hooks. This motivated
membership-before-insert; first-hit measurements expose its extra lookup cost.
The parser profile input is 32 copies of `<<0,0,7,1,35,3,2>>`, seven observed
probes, and differs from the ten-probe throughput input. Do not compare their
elapsed times directly.

The original sparse profile, 100 complete executions with two observations and
a 2,051-probe manifest, makes 205,100 allowed-set insertions and 3,591,131 traced
calls. Set bucket update/add/rehash and hashing dominate; `spawn_opt` also costs
7.51%, consistent with copying the full options/manifests into each coordinator.
Code inspection confirms that campaigns passed the full growing worker state as
options. Preparation removes repeated allowlist construction and passes compact
execution options instead. The measurements do not separately apportion these
two improvements. There was no per-hit full-manifest scan to remove.

The saved follow-up `sparse prepared` profile completed: **6,331 traced calls**,
100 executions, 200 hook hits/inserts and 200 prepared membership checks. It no
longer reconstructs the manifest set. Largest attributed costs are `spawn_opt`
14.71%, ETS snapshot `match_object` 13.68%, coordinator 13.42%, `run/4` 12.71%,
ETS info 7.87% and wait handling 7.74%. Profiling total 1,550 us is an attributed
function-time diagnostic, **not** the unprofiled executor batch duration.

Context allocation/deletion, process/monitor setup and snapshots remain visible
fixed costs. Full identities are still constructed and stored, and global novelty
and retained metadata still consume work. This phase does not claim each is a
bottleneck on every workload. Future work may measure remaining snapshot/setup
costs or lighter exact identity representation; none was pursued at closeout.
Correct termination semantics were kept, including no target flush requirement.

The simplest supported decision is therefore unchanged: **prepared validation
by default; original ETS hook by default; membership optional**. Large sparse
benefits are validation/copying improvements. Membership alone does not deliver a
reliable sparse executor/campaign benefit.

## Correctness and actual command results

The final sequence, after the sidecar fix, exited 0:

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
```

| Check | Actual result |
|---|---|
| Compile | Pass, configured warnings-as-errors |
| EUnit | 38 passed: original semantic/lifecycle tests plus 13 backend groups and fresh-VM sidecar test |
| Common Test | All 3 integration cases passed |
| Dialyzer | Pass, 22 project files; 278-file PLT checked; no warnings |
| xref | Pass, configured undefined/deprecated checks |
| Artifact audit | All 360 original timing samples internally consistent; exact canonical comparisons agree; fixture identities and current BEAM/source code verified |
| Automatic example, `+S 4:4` | Completed 500 mutations, 1 calibration, 4 discoveries, 494 rejections, 2 crashes / 1 unique, 0 timeouts or infrastructure failures |
| `git diff --check` | Pass |

Expected negative-test output includes strict-mode syntax diagnostics and
coordinator errors for deliberately incompatible plan versions. These tests
assert infrastructure outcomes and cleanup; they are not unexplained regressions.
The first closeout gate (37 tests) passed before the cross-VM defect was found.
The artifact audit initially rejected the noncanonical sidecar bytes; that
failure was the evidence for the narrow fix, not a baseline test failure.

Exact differential tests cover return values, nested clauses, cross-module
calls, repeated hits, error/throw/exit, synchronized external kill and timeout,
completion/deadline boundaries, isolated contexts, broken storage, missing/build-
mismatched instrumentation and deterministic corpus/crash decisions. Existing
plain/instrumented semantics and tail-position tests remain unchanged and pass.
No expectations were weakened to accommodate a backend.

Concrete current evidence: after seed `<<0>>`, the real-mutator example retained
`<<>>` as corpus entry 3, parent 2, `new_coverage`, probe 2. Its source mapping is
`efz_example_parser:classify/1`, `examples/simple_parser/efz_example_parser.erl:7`,
build `5f11a3a9df248ba517a1ae78cfad9462d6c6453bc0565bfe27089fa4a8239b6a`.
The deterministic five-candidate test separately proves repetition rejection and
retention after an artificial crash; these IDs/inputs are not in the fuzzer core.

The saved artificial crash from `<<255,0>>` contains execution probe 7 with
`coverage_status => ok`, while its decision has `target_failure` and
`new_probes => []`. Successful campaign coverage is probes `{2,3,4,5,8,9}`.
These fields have different meanings: execution observations include crash hits;
corpus novelty and global successful coverage exclude crash-only observations.
The campaign continued and retained `<<0,0>>` after its first artificial crash.
No reporting-policy change was needed.

Final termination snapshots preserve exact fixture probes `{30,66}` for error,
`{30,65}` for throw, `{30,67}` for exit and `{58}` for external kill/timeout,
under build `19b2e8635273c78d98eb79d7bb4c2b11d1b94e4da9608e217d5636864fd80096`.
All have `coverage_status => ok`. Differential tests compare complete module/
build/probe tuples across variants. Kill/timeout tests wait for an explicit
post-publication message; timeout returns only after target termination.

## Reproduction

Run from the `efz/` repository root. Use a **new output directory** for another
measurement; keep the archived outputs. The following commands use distinct
`reproduce-*` directories and the current retained reference path:

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref

ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/reproduce-performance
escript bench/report.escript _build/reproduce-performance

for EFZ_VARIANT in reference member prepared prepared_member; do
  ERL_FLAGS='+S 4:4' escript bench/run.escript memory \
    "_build/reproduce-memory-$EFZ_VARIANT" "$EFZ_VARIANT" || exit
done

ERL_FLAGS='+S 4:4' escript bench/run.escript startup _build/reproduce-startup
ERL_FLAGS='+S 4:4' escript bench/profile.escript sparse
ERL_FLAGS='+S 4:4' escript bench/profile.escript sparse prepared
ERL_FLAGS='+S 4:4' escript bench/profile.escript parser
ERL_FLAGS='+S 4:4' escript bench/profile.escript loop
ERL_FLAGS='+S 4:4' escript examples/automatic/run.escript
```

`all` runs hooks, executor and real/replay campaigns. Individual stages and an
optional variant argument select a bounded subset. `startup` is explicitly
zero-mutation; it is not a throughput benchmark. Profiling commands run separately
from final timing. `escript scripts/coverage_bench.escript` reproduces the older
small seven-sample loop harness, whose ordinary batches are sub-millisecond.

The closeout-specific archive command reads the named original and refreshed
artifact groups, checks them, and writes a new consultable evidence file:

```sh
ERL_FLAGS='+S 4:4' escript bench/archive.escript \
  _build/performance-final _build/phase21-closeout-evidence.term
```

It requires those saved group directories; it is an auditor for this record,
not a portable benchmark stage. The repository deliverable includes the
result under `docs/performance/` so future readers do not need ignored `_build`
files to inspect samples/metadata. No build directory is added to Git.

## Changed files and remaining limits

Relative to the saved Phase 2 state, runtime/integration changes are
`efz_cov`, `efz_cov_rt`, `efz_cov_manifest`, `efz_executor`, `efz_worker`,
`efz_config`, `efz_corpus`, `efz_fuzzer`, plus the closeout fix in `efz_instrument`.
Tests add `test/efz_backend_tests.erl` and the sidecar regression in
`test/efz_phase2_tests.erl`. Benchmark/replay/profile/archive tools are under
`bench/`; ordinary parser/sparse fixtures are under `fixtures/performance/`.
Documentation changes are README, architecture, coverage, this report and its
small durable evidence file. Rebar configuration, the transform, mutations,
feedback rules and ordinary example source were preserved during Phase 2.1.

Acceptance is complete for the tested local contract; no required result remains
blocked. Limits remain OTP 27.0 only, one production worker, coverage scoped to
the explicitly attached target process, fixed selected builds per campaign,
source-level clause/outcome probes and documented skipped syntax. Timing and
allocation change under instrumentation. Arbitrary spawned work, hot reload,
stateful OTP applications and complete VM/OS isolation are unsupported. Five
samples on one non-dedicated machine do not establish universal speedups or
absolute memory peaks. Preparation uses memory proportional to the selected
manifest; membership retains its first-hit cost and workload dependence.
