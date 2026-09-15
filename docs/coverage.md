# Automatic coverage contract

## Supported environment and metric

Actually tested: OTP 27.0 / ERTS 15.0, `x86_64-pc-linux-gnu`, Rebar3 3.25.0.
The compiler module's MD5 is included in build identities. Other OTP releases and
architectures require validation; the minimum-OTP setting alone is not evidence.

The metric is **execution-scoped source-level clause/outcome probe coverage**.
Each observation is an exact `{Module, BuildId, ProbeId}`. There is no hashed
bitmap, hit-count bucketing, inferred CFG edge, or previous-probe transition state.

## Syntax and semantics

| Construct | Instrumentation |
|---|---|
| Function clauses, including guarded/binary-pattern clauses | Body entry |
| `case`, `if` | Selected clause body entry |
| `receive` | Selected clause entry; `after` body entry |
| `try` | Body entry, selected `of` and catch clauses, nonempty `after` body |
| Anonymous/named `fun` | Selected fun clause entry |
| Nested expressions | Traverse calls and callee expressions, tuples, lists, map keys/values/updates, record values/updates/access, binary values/sizes, blocks, matches (RHS), operators, old `catch` |
| Patterns and guards | Preserved structurally; no probes inserted |
| `andalso`, `orelse` | Preserve operator/evaluation rules; nested clause bodies traversed, no operator-outcome probes |
| Local/remote fun references | Preserve references; traverse dynamic expression components |
| List/binary/map comprehensions | Entire expression preserved; diagnostic and manifest limitation; strict mode rejects |
| `maybe`, including `else` | Entire expression preserved; diagnostic and limitation; strict mode rejects |
| Nonliteral record defaults | Preserved without internal probes; diagnostic and limitation; strict mode rejects |
| Unknown executable forms | Preserve with visible diagnostic/limitation, or reject in strict mode |

`strict => true` is the default. `strict => false` explicitly accepts incomplete
instrumentation and prints diagnostics to stderr as well as recording them in the
manifest. There is no claim of internal coverage inside skipped expressions,
even if they contain supported `case` or fun syntax. Feature selection remains
under the compiler and source `-feature` attributes. OTP 27 comprehension and
`maybe` fixtures are compared in ordinary and instrumented compilations.

Headers/macros are processed by EPP before transformation. Include file boundaries
are retained in manifest mappings. Annotations use `erl_anno` APIs and preserve
columns where the compiler provides them. Probe IDs distinguish clauses on the
same line. The transform generates abstract forms, never regex-edited source.

Probes are prepended inside original bodies without introducing variables,
wrappers, or code after existing tail calls. Original expressions are not
re-evaluated or moved across exception boundaries. Receive timeout expressions
remain in place; selective matching and clause ordering are unchanged. Tests
compare controlled mailbox contents, side effects, returns, exception class/
reason and relevant target stack frames. A transformed-AST test verifies that the
recursive tail call remains last; a 20,000-step run also completes.

This is functional preservation for tested constructs, not equivalence of timing,
reductions, memory consumption, scheduling, or inspection of all dictionary keys.
Targets must not alter EFZ-owned context state or ETS rows. ETS is public so the
execution process can insert data; it is not a security boundary inside the VM.

## Compilation and selection APIs

```erlang
{ok, Artifact} = efz_instrument:compile("src/my_parser.erl", #{
    modules => [my_parser],             % Explicit allowlist; never all dependencies
    source_root => ".",                % Common root of source and local headers
    outdir => "_build/efz-targets",      % Separate from the ordinary build
    erl_opts => [debug_info, warnings_as_errors,
                 {i, "include"}, {d, 'MY_FEATURE'}, {d, 'LIMIT', 256}],
    code_paths => ["_build/default/lib/my_dependency/ebin"],
    strict => true
}).
{ok, Manifests} = efz_instrument:preflight([Artifact]).
```

Compile EFZ first (`rebar3 compile`) and put its ebin on the compiler VM's code
path. The facade ensures its transform is loaded. Compilation does not start EFZ
or any campaign. It uses `compile:noenv_file/2` with supplied options; ambient
`ERL_COMPILER_OPTIONS` is intentionally excluded. Reproduce your actual project's
include, macro, feature, and code-path settings explicitly. Relative paths are
relative to the calling VM's working directory. A temporary code-path change is
restored on return; facade calls must be serialized within a VM. Concurrent
compilers must use distinct output directories.

Other parse transforms (including source `-compile` attributes), output-mode
options and alternate output directories are rejected, rather than silently
running a later transform behind the manifest. Record/type/spec attributes are
otherwise preserved. The output directory cannot be the source directory, an
active code-path directory, or contain ordinary BEAM artifacts. Files are written
by the facade after compilation, never by transform workers. This is a source
build path, not an arbitrary prebuilt-BEAM instrumenter or a Rebar3 plugin.

EFZ runtime/internal modules and modules resolved from the installed OTP tree
are rejected. Dependencies are instrumented only if explicitly compiled and
allowlisted. The example instruments exactly `efz_example_parser`; its adapter
and all EFZ/OTP modules remain ordinary. A top-level Rebar3 profile is not assumed
to instrument dependency projects.

An artifact descriptor contains `module`, `beam`, `manifest`, `build_id`, and
compiler `warnings`. Preflight requires BEAM and sidecar files, validates schema
and unique probe entries, safely decodes the sidecar and compares its exact term to the embedded manifest, then
checks the loaded module's `efz_manifest` attribute and BEAM code checksum. An already loaded ordinary
or different-build module is rejected. No automatic purge occurs. Use a fresh VM
or a deliberately controlled unload with no active users to switch builds.
No compilation/loading/purging occurs per iteration. Harness and selected loaded
identities are pinned at campaign preparation and checked by the executor.
Hot replacement during a case invalidates its observation, even if the original
build is restored. See [the integrity contract](coverage-integrity.md).

## Manifest schema and reproducibility

Schema 1 / instrumentation version 1 embeds this map as `-efz_manifest(...)`:

```erlang
#{schema_version => 1, instrumentation_version => 1,
  metric => clause_outcome_probe, module => my_parser, build_id => <<...>>,
  toolchain => #{otp => "27", compiler => <<...>>},
  probes => [#{probe_id => 1, function => parse, arity => 1,
               kind => function_clause,
               structural_location => [{function,parse,1},1],
               source_file => "src/my_parser.erl", line => 12, column => 1}],
  limitations => []}.
```

The sidecar `my_parser.efz-manifest` is the Erlang external-term encoding of that
same map. `efz_cov_manifest:from_beam/1` extracts the authoritative embedded map;
`identities/1` expands its identities. Resolve `{M,B,Id}` by matching module,
build, and `probe_id`, then read the source and structural location. A manifest
validates one entry per ID and one entry per structural path.

Build ID is SHA-256 over instrumentation version, OTP release, compiler-module
identity, normalized preprocessed forms, and relevant compiler options. Probe IDs
are deterministic integers allocated by a local ordered AST traversal; they are
never interpreted without module and build. Structural paths distinguish nested
bodies and same-line clauses. There are no timestamps, random compile IDs, global
allocation counters, or small hash namespaces.

Contract: identical preprocessed source, relevant options and supported toolchain
produce identical probe identities. Output directory, code paths, include-search
paths alone, debug-info and warning presentation settings do not change IDs;
expanded header/macro contents do. File attributes/annotation paths under the
explicit common `source_root` are normalized relative to it. Relocating that root
with identical relative layout is tested. External headers with absolute names
and path-sensitive literals such as absolute `?FILE` expansions can still change
IDs; they are not rewritten as if their runtime values were identical. Changes
in line/column structure may also change the build. This is identity stability,
not a claim of byte-identical BEAM metadata across directories.

The embedded build includes every probe; observations outside pinned manifests
are rejected, and feedback independently checks the complete build map. A new
build requires a new campaign/calibration. Saved coverage is never silently
carried across incompatible namespaces. Double instrumentation is rejected.

## Execution APIs and ownership

```erlang
Result = efz_executor:run(my_target_adapter, Input, 100, #{
    coverage => automatic, manifests => Manifests
}).
% #{execution_ref := Ref, outcome := Outcome, target_outcome := TargetOutcome,
%   elapsed_us := Us, coverage := ExactIdentities, coverage_status := ok,
%   builds := #{my_parser => BuildId}}
```

`Outcome` is `{ok, Value}`, `{crash, Class, Reason, Stack}`, `{exit, Reason}`, or
`{timeout, Milliseconds}`. Errors and throws preserve class/reason/stack; exit
exceptions retain the Phase 1 exit tuple. Externally killed targets yield
`{exit, killed}`. Coverage is readable after each of these outcomes.
`{infrastructure, Reason}` and `coverage_status => {error, Reason}` are separate
from target bugs; `target_outcome` retains the observed target result when one
exists. Low-level `run/4` expects already preflighted manifests. Campaign startup
performs preflight automatically and requires `artifacts`; empty/manual fallback
is not allowed in automatic mode.

`efz_cov:open/0` creates `{efz_context,1,ExecutionRef,Table,Owner}` with an unnamed
public ETS set. `attach/1` explicitly installs it in the executing process under
`'$efz_execution_context'`. `snapshot/1` and `close/1` belong to the owner; the
executor guardian performs them after observing termination of root and all controlled descendants. Contexts
have independent references and tables. `efz_cov_rt:hit/1` also consults an
independent guardian-owned PID/context registry. Missing dictionary context is
inactive only outside an executor-owned participant. Lost/malformed context,
invalid tables and caught hook exceptions produce sticky infrastructure errors.
`coverage_observation` distinguishes `valid_empty_coverage` from a broken
observation; campaign `coverage_diagnostics` reports unused artifacts. Optional
`coverage_policy => strict` fails a completed campaign with no probes.

Coverage scope is **root plus controlled descendants in one execution**.
`efz_target:spawn/1` and `spawn_link/1` admit children through an independent guardian
before attaching the shared coverage context and starting child code. The guardian
collects the snapshot after process DOWN and trace-delivery barriers. Plain local
spawns are detected but rejected as dirty executions, without pretending their
coverage was complete. Background/remote OTP services remain outside this scope.
See [execution lifecycle and dirty-VM policy](execution-isolation.md).

Manual compatibility is explicit: `coverage => manual`, `efz_cov:hit(Id)` records
`{manual,Id}`. `efz_executor:run/3` uses that mode and returns the old outcome tuple.
Manual and automatic namespaces cannot be mixed in a campaign. The legacy
`reset_local/0`/`snapshot/0` conveniences are process-local; ordinary callers
should prefer explicit `open/attach/snapshot/close`, and must not reset an
executor-owned context.

## Feedback and artifacts

One worker only. Initial seeds use the same execution path and initialize the
successful global set before mutations begin. `calibrations` is separate from
mutation `executions` and `discoveries`.

Successful input novelty is `Observed - Global`. New successful observations are
merged; new binaries with nonempty novelty enter the corpus. Repeats are rejected
without false discoveries. Crashes/exits/timeouts are saved independently and
**their coverage is not merged into the successful global set**. This permits a
later non-crashing input to retain probes previously seen only in a crash.

Each retention has input SHA-256, corpus identity, parent identity, execution
reference, newly seen identities, retention reason, phase and build map. The
final `efz:await/1` report includes decisions, corpus, crash records, statistics,
and successful coverage. Identical rejected executions are summarized by a
counter. Crash occurrences are atomic directories at
`crash_dir/SIGNATURE/OCCURRENCE/artifact.input`, `.term`, `.replay`, and optional
`.recipe`, with a group manifest. Raw `.term` preserves result metadata,
including crash/timeout coverage. See [crash/replay/report](replay.md). These term
files are local diagnostics, not a safe import format.

## Reproducible validation and overhead

`rebar3 eunit --module=efz_phase2_tests` covers semantic comparisons, all required
probe kinds, unsupported syntax diagnostics, cross-module calls, separate
contexts, same-input repeatability, target kills, timeouts, owner death,
cancellation, backend failure, identity/relocation, preflight and feedback.
Termination tests wait for a message sent after the expected entry hook completed.
They do not infer that a probe ran from a sleep. Deadline-boundary tests accept
the documented completed-or-timeout outcomes and check subsequent execution
isolation. Plain/instrumented comparisons unload the same module only after its
previous target processes have terminated; self-qualified calls are not renamed.

`rebar3 ct` contains three integration cases: deterministic automatic campaign,
artificial-crash coverage, and synchronized timeout coverage. The five-input
scripted mutator lives only under `test/`; it is not the production mutator or a
random fuzzing success claim. `examples/automatic/run.escript` also runs the
original Phase 1 random mutator for 500 iterations. See
[recorded validation](phase2-validation.md).

Run `escript scripts/coverage_bench.escript` after `rebar3 compile`. It loads the
same fixture ordinarily and instrumented in controlled sequence, warms each path,
then measures seven samples of 200,000 tail-loop iterations. Active measurements
reuse one execution context to expose probe costs; they are not end-to-end fuzz
executions/second. Output includes times, reductions, process memory snapshots,
compilation times, exact ETS size, and number of observed probes. No performance
threshold is enforced. The benchmark measures EFZ hooks, not OTP cover.
OTP 27 / ERTS 15.0; x86_64-pc-linux-gnu. Fixture `efz_bench_fixture`, 200000 loop iterations per sample, 7 repeats, 30,000 warmup iterations per mode.

| Mode | Median us | Relative | Samples us | Reductions (last sample) |
|---|---:|---:|---|---:|
| ordinary | 518 | 1.00x | [619,517,517,517,530,518,518] | 200013 |
| instrumented_inactive | 5315 | 10.26x | [5315,4438,4260,4203,5532,5467,5581] | 1000017 |
| instrumented_active | 67209 | 129.75x | [71060,66993,67233,67125,67095,67232,67209] | 1401177 |

Active table: 419 words (8 bytes/word), 6 unique observed probes of 6 manifest probes. Table deleted after measurement. Compilation: ordinary 3387 us; instrumented 62202 us (single measurements, includes cold setup). No correctness threshold. Process-memory snapshots are in `_build/coverage-benchmark.term`.

These measurements were taken locally on 2026-09-08. The tiny ordinary loop is
highly optimized and runs in less than a millisecond, so ratios should not be
extrapolated to a real parser. Active collection was about 12.6 times the inactive
instrumented path on this run. The ETS insert/copy path is a measurable cost;
reductions also rose from 200,013 to 1,401,177. Last-sample process memory was
8,816 -> 8,816 bytes (ordinary), 13,704 -> 13,704 (inactive), and 21,696 -> 55,176
(active); these are snapshots, not peak-memory estimates. Exact table size stayed
at six entries despite repeated hits, and the table was deleted on completion.

A next optimization candidate is an execution-local already-recorded cache that
writes each first hit immediately to owner-held ETS before caching it. That could
reduce duplicate inserts while preserving coverage on abrupt target termination;
it requires lifecycle and backend-failure tests before adoption. The current
implementation deliberately keeps every hit synchronous with external storage.

Current limits remain one worker, one execution with controlled descendants, source compilation under
the tested toolchain, explicit selected modules, and the skipped syntax above.
Other parse transforms, prebuilt-only binaries, arbitrary background-process attribution,
stateful OTP campaigns, full CFG/branch/state coverage, and isolation from all
shared VM or operating-system effects are not implemented.

## Phase 2.1 runtime choices and reporting

The default `ets` backend now uses `ets:insert_new` and notifies the guardian on
first insertion, so published observations lost from the table can be detected.
The opt-in `ets_member` path checks `ets:member` first and inserts only
when absent. There is **no process-local seen cache**, compact/hash ID, sampling,
or delayed publication. Every hit still accesses the external table; deleting a
backend after a first hit cannot turn subsequent cached hits into false success.
First observations cost a lookup plus insertion and may be slower. Neither
backend changes instrumentation, manifests, build IDs, or source mappings.

Campaigns now default to preparing the exact allowed-probe set once. The worker
owns an unnamed **protected** `efz_coverage_plan` ETS table, containing the same
identities the previous validator rebuilt on every iteration plus a schema/mode/
build marker plus the selected loaded-module identities. The guardian validates that marker and every observed identity
after root/descendant termination. It receives only execution options and the plan handle,
not the worker's corpus/decision state and full source manifests. This is a shared
immutable allowlist, not a reused coverage buffer. Observation tables are still
fresh, public, execution-owned tables. Plans survive between executions and are
deleted with their campaign worker; no plan or observation reuse across campaigns
is implemented. Invalid/deleted plans produce infrastructure failures, including
for an otherwise empty snapshot.

```erlang
% Default campaign settings in Phase 2.1:
#{coverage_backend => ets, coverage_validation => prepared}.
% Per-execution manifest validation, retained for comparison:
#{coverage_backend => ets, coverage_validation => per_execution}.
% Optional duplicate-write suppression (compatible with either validator):
#{coverage_backend => ets_member, coverage_validation => prepared}.
```

For low-level repeated `run/4` calls, prepare explicitly after artifact preflight:

```erlang
{ok, Manifests} = efz_instrument:preflight(Artifacts),
{ok, Plan} = efz_cov_manifest:prepare(automatic, Manifests),
try
    efz_executor:run(Target, Input, Timeout,
        #{coverage => automatic, coverage_backend => ets, coverage_plan => Plan})
after
    efz_cov_manifest:release(Plan)
end.
```

`prepare/2` checks manifest schema/instrumentation version, probe uniqueness,
nonempty automatic selection and duplicate modules. It does not load or inspect
artifacts: call `preflight/1` first. The plan is `{efz_cov_plan,1,Table,BuildMap}`;
its marker binds coverage mode and builds. It is backend-independent: both ETS
hooks publish the same exact identities. Campaign configuration validates the
backend before the worker starts.

The caller owning this plan must keep it alive until its executions complete.
At the low-level API, it is a read-only capability that can be passed to other
execution callers and reused for the same selection/builds. Foreign callers
cannot write its protected table. It is not bound to one execution reference;
only observation storage is. Release it from the owner after all users finish,
or owner termination deletes it automatically. A disposed table, changed build
map, wrong mode or incompatible descriptor cannot validate an empty snapshot.
Malformed descriptor versions fail validation as infrastructure
errors; they are not target crashes. A valid plan from another owner is allowed.

Campaign completion retains the worker and plan for reporting until `efz:stop/0`
or application shutdown. A new campaign constructs a new plan. Plans are not a
hot-reload cache: selected code must remain unchanged for their entire lifetime.
Preflight rejects an already loaded ordinary or different build; observation
validation rejects identities outside the pinned set. Replacing code after
preflight with code that emits no probes cannot be detected by set validation.
One-time preparation does not promise correctness under arbitrary hot loading.

`run/4` with only `manifests` retains per-execution validation for compatibility.
`efz_cov:open/0` retains its reference backend; `open(ets_member)` selects the
alternative. Existing contexts retain schema 1; in the alternative context the
storage slot contains `{ets_member, Table}`. Context contents remain EFZ-owned.

Reports distinguish four concepts without changing the merge policy:

* `Result.coverage`: exact observations from that one execution, including
  observations before exceptions, external kills, and timeouts.
* Campaign `coverage`: union of successful calibration/execution observations.
* Saved crash `result.coverage`: the crash's observations; it can include probes
  absent from campaign `coverage`.
* Decision `new_probes`: novelty eligible for successful-corpus retention. It is
  intentionally `[]` for `retention_reason => target_failure`, even when the
  crash observed a previously unseen probe. No crash-only observations are merged
  into the successful coverage set.

The additive report `timing` map contains `calibration_started_at` (monotonic
microseconds), `calibration_us`, and `mutation_us`. The last excludes calibration
and final report construction/pretty-printing, but includes selection, mutation,
execution, validation, feedback, statistics, and crash artifact I/O. It is not
just target running time. Benchmark startup and cleanup are reported separately.

The optional `selection_seed` seeds the corpus process's selection RNG. Existing
`random_seed` continues to seed the worker's mutator RNG. Without `selection_seed`,
the prior selection behavior remains unchanged; setting only `random_seed` does
not fully determine a campaign. Reproducible comparisons specify both or replay
the saved candidate stream. Benchmark replay code lives under `bench/`, not in
the production mutator.

See [Phase 2.1 profiling, measurements, tradeoffs, and reproduction](phase2.1-performance.md).
The Phase 2 benchmark table above is historical; it is not a performance constant.
