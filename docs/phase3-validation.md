# Phase 3 validation: staged mutation and exact replay

Phase 3 is complete for the tested local contract: OTP 27.0, one worker, one
instrumented target execution process, fixed selected builds and exact source-level
clause/outcome coverage. Staged mutation is opt-in. This phase adds byte mutation
and replay without changing the coverage implementation or restarting its
performance study. Measurements below are observations, not acceptance constants.

## Baseline and provenance

The repository was inspected before modification, including configuration,
mutator/corpus/worker, crash storage, executor, prepared validation and Phase 2/2.1
documents. No applicable `AGENTS.md` was present. The working tree already contained
modified tracked files and extensive untracked Phase 1–2.1 implementation and
evidence. Those changes were preserved. There was no reset, clean, staging,
commit, push, remote or Git identity change.

The baseline passed `rebar3 compile`, `rebar3 eunit` (38 tests), `rebar3 ct`
(3 cases), `rebar3 dialyzer`, `rebar3 xref` and `git diff --check`. There were no
baseline failures to carry forward. Baseline logs are in `_build/phase3-baseline`;
full command outputs are also retained in the durable validation record below.
The final results are 62 EUnit tests and the same 3 Common Test cases.

Environment: Ubuntu 24.04.4 LTS, Linux 6.8.0-nyx+, x86_64-pc-linux-gnu,
Intel Core i7-1260P, OTP 27.0 / ERTS 15.0, Rebar3 3.25.0. Project and example
compiler options are `[debug_info,warnings_as_errors]`; the instrumentation facade
adds its existing strict parse-transform and column-location options. Other OTP
versions are not claimed tested. No dependency was added.

Durable evidence, suitable for `file:consult/1`:

* [performance/phase3-mutations.term](performance/phase3-mutations.term): all five
  raw samples per mutation workload and campaign mode; normalized configurations,
  input/donor hashes, environment, compiler settings, artifact/build descriptor,
  current source SHA-256 identities, process/VM memory snapshots and reductions.
* [performance/phase3-validation.term](performance/phase3-validation.term): baseline
  and final check outputs, hashes of 41 relevant source/config/test/script files,
  Phase 3 before/after file identities, acceptance/example reports, full manifest,
  exact recipe, and fresh-VM replay output. Runtime references in reports are
  diagnostic strings; the bounded acceptance trace is omitted from this durable
  copy. No recipe depends on those references.
* [examples/staged-crash.recipe](examples/staged-crash.recipe) and
  [examples/staged-crash.input](examples/staged-crash.input): a 629-byte EFZR recipe
  and the six authoritative raw bytes from the verified example.

The unprofiled benchmark's source hashes were checked against the final runtime,
planner and benchmark sources when exporting evidence. The last change after
measurement was a test assertion comparing logging levels, followed by another
passing full EUnit run, and documentation/evidence only. The compiler, coverage
hook, context ownership, executor, feedback and manifest validator remain identical
to the baseline. The transform only gained four internal-module denylist entries;
its probe-generation algorithm and version remain unchanged.

The final measurement directory is `_build/phase3-performance-verified`.
Earlier `_build/phase3-performance` and `_build/phase3-performance-final` runs are
preserved but excluded from the reported comparison: they preceded the final
source provenance or overlapped other local example activity. The verified run
completed with exit status 0, had no profiler enabled, and did not overlap another
assistant-launched Erlang task. Unrelated host activity was not controlled.

## Public compatibility and implementation

The campaign default remains `mutation_mode => random`, with the existing random
mutator behaviour and legacy selector. Prepared validation and the original ETS
coverage backend remain defaults. `coverage_backend => ets_member` stays explicit
and works for campaigns and replay. The old automatic example is unchanged.
Legacy mutator exceptions/nonbinary returns now stop as infrastructure failures,
without being counted as target bugs.

`mutation_mode => staged` enables the new `mutation` map. It rejects a custom
legacy callback and rejects mutation options accidentally supplied in random mode.
Omitted staged `max_iterations` defaults to 1,000, with a maximum of 1,000,000;
explicit infinity rejects. Calibration is counted separately. Other bounds, all
operator semantics and ordering are in [mutations.md](mutations.md).

The native operators are contiguous 1/2/4-bit flips; aligned 1/2/4-byte inversion;
8/16/32-bit arithmetic with explicit wrapping and endian selection; versioned
integer boundary patterns; literal overwrite/insertion; nonempty deletion and
block duplication; dictionary overwrite/insertion; content-identified splicing;
and bounded stacks of those concrete operations (havoc).

Pure application, operation choice, per-content stage state, donor/seed selection,
and execution are separate. Deterministic stages are lazy integer cursors. Corpus
rounds and stage lanes are explicit and bounded; growing the corpus cannot defer
older entries indefinitely. Skipped operations advance cursors or RNG state, and
finite attempt/idle limits prevent retry loops without execution progress.
Dictionaries/configuration stay fixed within a campaign. `exsplus` uses explicit
state-threading APIs; logging/target randomness does not consume that state.

Retention attaches a versioned recipe to existing corpus/crash metadata. Default
rejection handling stores no full recipe indefinitely; optional trace is bounded.
Recipes contain actual primary/donor/token bytes and ordered operations, not just
RNG state. The EFZR import path validates a bounded data-only format before ETF
decoding. Byte regeneration needs neither a target nor a plan. Execution replay
requires caller-selected artifacts/target and compatible builds, prepares a fresh
validation plan and invokes the existing executor. See [replay.md](replay.md).

## Concrete coverage and replay evidence

The ordinary `examples/staged/efz_staged_parser.erl` contains seven function-clause
probes after selected compilation, with no EFZ API calls in its source. All
observations below use build:

```text
4c53c8d203bf5fca774d78fee2122a75419b86ba8f807cc3ffbb5d96339e0a5e
```

The deterministic integration test uses the real production stages
`[dictionary_insert,boundary,arithmetic]`, seed `{17,23,41}`, primary seed `<<0>>`,
and a 200-execution budget. It does not use the old scripted test mutator.
Calibration initially observes probe 5 and is not a mutation discovery.

| Retained bytes | Parent | Realized operation | New probe / source | Decision |
|---|---:|---|---|---|
| `<<"TOKEN",0>>` | Entry 1, `<<0>>` | `{dictionary_insert,0,<<"TOKEN">>}` | 1, `run/1`, line 4, column 1 | `new_coverage` |
| `<<128>>` | Entry 1, `<<0>>` | `{set_integer,0,8,big,128}` | 3, `run/1`, line 6, column 1 | `new_coverage` |

The integration report completed with 1 calibration, 200 mutation executions,
4 discoveries, 191 equivalent-coverage rejections, 5 crash observations, one
fingerprint group and zero infrastructure failures/timeouts. Tests also assert
that a discovery occurs after the first artificial crash and regenerate the exact
bytes of retained entries from their recipes. Probe numbers in this document are
manifest observations; neither fixture IDs nor retention exceptions are hard-coded
in the fuzzer core.

The full example additionally enables havoc/splice. It completed 200 executions
with 5 discoveries, 188 rejections, 7 crash observations, one fingerprint group and
zero infrastructure failures/timeouts. Its counters distinguish 243 visits,
233 mutation attempts, 320 constituent-operation attempts, 72 skipped operations,
43 visits without a candidate, and 200 generated/executed candidates. Operation
skip-reason totals also include final canceled stacks, so they do not equal the
skipped-operation count.

The saved artificial crash bytes are `<<"BOOM!",0>>` (hex `424f4f4d2100`), with
SHA-256:

```text
1732ef36d864988423a5275aec30b90b55e3405cc798c709e318c867797ad64b
```

Fresh-VM regeneration and `cmp` reproduced all six bytes. A separate fresh VM
compiled the explicit target, loaded the saved recipe's expected builds, executed
the raw input, and returned `{crash,error,artificial_staged_exception,Stack}`,
with `coverage_status => ok` and exact probe 2. Its stack points to target line 5.
This confirms both byte reconstruction and the actual deterministic example
outcome; it is not a promise about time-sensitive targets.

Probe 2 survives target termination in the crash result. The failure decision has
`retention_reason => target_failure, new_probes => []`, and successful-corpus
coverage excludes probe 2. That is the existing policy: crash observations do not
suppress future successful novelty. Crash groups are fingerprints, not proven
independent bugs.

The legacy automatic example also completed unchanged in random mode: 500
executions, 1 calibration, 5 discoveries, 493 rejections, 2 crash observations,
one fingerprint group, zero infrastructure failures/timeouts. These are this run's
observations; its default unseeded corpus selection need not match earlier reports.

## Bounded mutation cost

Reproduction, from the repository root:

```sh
rebar3 compile
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance-reproduce
```

The verified run used `+S 4:4` (four online schedulers). The driver warms each
case with one full 5,000-candidate batch and validates every realized operation
sequence against its output. Each of five timed batches starts a fresh planner
with the same normalized configuration and validates count, visit count and
consumed CRC32 stream against warmup. Configuration/dictionary normalization and
fixture construction are outside mutation-only timing. Candidate hashing,
operation planning/application, provenance construction and CRC consumption are
inside. Full EFZR encoding and target execution are outside these microbenchmarks.
No machine-specific performance threshold appears in tests.

Each workload has two static distinct inputs: repeated bytes `0,1,2,3` at the
listed size and a donor with its first byte inverted. The input limit is 4,096;
other defaults include block 128, depth 8, delta 8, tokens `TOKEN`/`BOOM!` and seed
`{17,23,41}`. All samples actually generated 5,000 candidates. Short/medium/near
limit use bitflip/arithmetic/havoc; dictionary uses both dictionary stages;
splicing and havoc use their respective single stage. These mutation-only runs
have no target/probe observations or manifest scans.

| Mutation workload | Input bytes | Median µs / 5,000 | Min–max µs | Candidates/s |
|---|---:|---:|---:|---:|
| Short | 4 | 37,396 | 36,364–39,283 | 133,704 |
| Medium | 1,024 | 32,538 | 30,792–34,778 | 153,667 |
| Near configured maximum | 4,095 | 55,712 | 55,276–57,220 | 89,747 |
| Dictionary insertion/overwrite | 1,024 | 17,950 | 16,884–22,325 | 278,552 |
| Splicing | 1,024 | 25,986 | 25,224–27,787 | 192,411 |
| Havoc | 1,024 | 51,818 | 48,236–51,889 | 96,492 |

The shorter mixed workload is not faster than medium in this sample: applicable
operations, retries and intermediate resizing differ. These are workload results,
not size-only scaling claims. Raw durations are retained in the `.term` evidence.

## Bounded end-to-end comparison

Both modes use the same seven-probe ordinary example, initial seed `<<0>>`,
100 ms timeout, original ETS hook, prepared validation and **500 mutation target
executions**, with one calibration. The driver discards a 100-execution pilot for
each mode and alternates mode order over five rounds. Compilation (one observed
8,921 µs) and final printing are outside campaign mutation timing. Compilation is
one startup observation, not a repeated performance estimate.

Legacy random uses `random_seed => {17,23,41}` and
`selection_seed => {101,109,113}`. Staged uses that mutation seed, the example's
five stages, max input 64, block/token 16, havoc depth 4, and the two inline tokens.
The configurations intentionally do not force legacy mode to adopt new limits.

| Mode | Raw mutation times µs | Median µs | Min–max µs | Executions/s | Discoveries | Successful probes | Crashes / groups |
|---|---|---:|---:|---:|---:|---:|---:|
| Existing random | 9169, 9916, 7503, 7786, 7257 | 7,786 | 7,257–9,916 | 64,218 | 4 | 5 / 7 | 0 / 0 |
| Staged | 14965, 17455, 15749, 16198, 15339 | 15,749 | 14,965–17,455 | 31,748 | 5 | 6 / 7 | 14 / 1 |

Counts were stable across the five samples for each mode. Staged additionally
reached the dictionary branch; its crash probe remained outside successful
coverage. Both had zero infrastructure failures/timeouts. Calibration medians were
55 µs random and 56 µs staged. Full `start`/`await`/`stop` API medians, including
preparation/report delivery/cleanup, were 8,883 and 17,127 µs respectively. Full API
raw samples and calibration durations are recorded separately.

Staged mutation took **2.02 times** the mutation-phase wall time of random in this
small fixture (about 49.4% of its execution throughput). This includes a different
candidate stream, richer mutation/provenance work, more scheduling visits and 14
crash observations with artifact writes. It is not a same-input executor/backend
comparison. The extra example discovery is not evidence of universal superiority;
there is no performance target or coverage gain guarantee. No Phase 2.1 hook or
complete-executor performance number is reinterpreted from this experiment.

## Memory and cleanup observations

The mutation benchmark records process memory and total VM memory before each
batch, after the timed batch and after explicit garbage collection, with reads
outside the timed interval. It also records reductions; these are not allocated
bytes. Post-GC samples retain the driver, inputs/configurations and preceding
sample summaries, while the completed planner state/candidates are no longer
retained. Process memory alone does not include all referenced off-heap binaries.

| Workload | Post-batch process bytes (range) | Post-GC process bytes (range) | Median reductions / batch |
|---|---:|---:|---:|
| Short | 29,552–42,416 | 8,816 | 3,935,059 |
| Medium | 47,184–68,056 | 13,704 | 5,853,867 |
| Near limit | 47,184–62,992 | 13,704–21,608 | 16,006,728 |
| Dictionary | 101,368–142,760 | 21,608 | 3,815,738 |
| Splicing | 89,720–123,048 | 21,608–34,400 | 5,981,997 |
| Havoc | 76,096–110,048 | 34,400 | 8,022,823 |

Observed post-GC VM totals ranged from 51,106,240 to 51,261,888 bytes across these
workloads. They need not return to an identical value. These snapshots are neither
absolute peak memory nor a complete campaign retained-memory study. No leak claim
is inferred from VM totals. The existing lifecycle tests separately prove release
of execution tables/processes after normal completion, timeout, cancellation,
caller death and application shutdown. A finished campaign still owns its plan,
corpus, retained recipes, decisions and optional trace until `efz:stop/0`; execution
observations remain separately allocated and cleaned as in Phase 2.1.

The planner copies the minimal corpus view and hashes content during scheduling;
splicing scans and sorts distinct donor contents. Large corpora and large embedded
donors can therefore cost more time and retained recipe storage. No unmeasured
optimization or buffer reuse was introduced to hide these costs.

## Regression commands and results

All commands below completed with exit status 0 in this working tree:

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
git diff --check
ERL_FLAGS='+S 4:4' escript examples/staged/run.escript
escript scripts/replay.escript _build/staged-example.recipe _build/staged-regenerated.input
cmp _build/staged-example.input _build/staged-regenerated.input
escript examples/automatic/run.escript
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance-verified
escript scripts/replay.escript docs/examples/staged-crash.recipe _build/from-docs.input
cmp docs/examples/staged-crash.input _build/from-docs.input
```

* Compile: pass with warnings treated as errors.
* EUnit: **62 passed**, including 15 mutation tests, 3 recipe tests and 6 grouped
  Phase 3 acceptance tests. Existing transform semantics, exact canonical backend
  differential, prepared-plan negatives, error/throw/exit, synchronized kill and
  timeout survival, context separation, deadline boundary, caller death,
  cancellation/shutdown and repeated resource-lifetime checks all pass.
* Common Test: **3 passed**.
* Dialyzer: pass, 26 analyzed project modules and 278 PLT files checked.
* Xref and whitespace check: pass. No formatter/linter is configured.
* The README's inline-dictionary campaign/save/regenerate/execute snippet was
  also run in a fresh VM and passed. The file-dictionary script above covers the
  other public configuration path.

Existing negative tests intentionally log malformed-plan process errors and
unsupported-AST diagnostics; they assert infrastructure/error classification and
pass. These messages are not new failing checks. The final EUnit rerun followed
the logging-level test addition; other final checks remain applicable because no
relevant runtime source changed after their passing run. No baseline failure was
masked by altering expected coverage/outcome sets.

To independently execute the durable saved crash bytes in a fresh VM:

```sh
erl +S 4:4 -noshell -pa _build/default/lib/efz/ebin -eval '
{ok, A} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".", outdir => "_build/replay-target"}),
{ok, R} = efz_recipe:load("docs/examples/staged-crash.recipe"),
{ok, Result} = efz_recipe:execute_file("docs/examples/staged-crash.input",
    efz_staged_parser, [A], maps:get(target_builds,R), #{timeout => 100}),
{crash,error,artificial_staged_exception,_} = maps:get(outcome,Result),
ok = maps:get(coverage_status,Result),
io:format("~tp~n",[Result]),halt(0).'
```

The ordinary example and regeneration commands without `ERL_FLAGS` above used
ambient runtime settings, not an inferred four-scheduler configuration. The
performance run explicitly records four schedulers. Fresh-VM EUnit replay tests
explicitly use two schedulers; all throughput measurements are profiler-free.

## Files changed in this phase and limits

New runtime modules: `efz_mutation`, `efz_mutation_plan`, `efz_dictionary`,
`efz_recipe`. Integrated through `efz_config`, `efz_corpus`, `efz_worker`,
`efz_crash`; the transform's internal denylist was extended. New tests are
`efz_mutation_tests`, `efz_recipe_tests`, `efz_phase3_tests`. Added the staged
ordinary parser, dictionary/example runner, byte-regeneration CLI and bounded
mutation benchmark. Updated README/architecture and added mutation/replay/
validation documentation and compact evidence. Existing unrelated source,
configuration and Phase 2.1 evidence remain preserved.

Remaining limits are intentional: byte-oriented mutation only, one production
worker, in-memory stage state, no full campaign checkpoint, no adaptive schedule,
automatic token extraction, minimization or grammar/stateful fuzzing. Input,
dictionary, stack and campaign budgets constrain work, but high configured maxima
can still be costly. Recipes are bounded data artifacts, not authenticated files.
Fixed selected builds are required for a campaign; regeneration alone does not
prove outcome reproduction, and replay does not enable arbitrary hot replacement.
Arbitrary child processes, shared VM state and native/OS effects remain outside
the target-process coverage/cleanup contract. No required validation result is
blocked or unavailable in this environment.
