# EFZ (Erlang fuzzer)

**English** · [Русский](docs/i18n/ru/README.md) · [Español](docs/i18n/es/README.md) · [简体中文](docs/i18n/zh-CN/README.md) · [All languages](docs/i18n/README.md)

EFZ is an Erlang fuzzer with corpus management, random and pluggable staged
binary mutations, exact candidate recipes, controlled target execution, crash
artifacts and automatic source-code instrumentation. EFZ does not depend on
other fuzzing engines.

Optional semantic/Gleam layer: [connecting Erlang libraries](docs/gleam-layer/connecting-erlang-libraries.md) ·
[final P5 validation](docs/gleam-layer/p5-validation.md) ·
[automatic connector generation from `-spec`](docs/gleam-layer/connector-generation.md).

Continuous mode: [staged and Gleam campaigns without an execution limit](docs/continuous.md).

Optional local Erlamsa provider: [configuration and replay](docs/erlamsa-integration.md) ·
[validation](docs/erlamsa-validation.md) · [measurements](docs/erlamsa-benchmark.md).
Mutation providers and semantic adapters are independent settings. Native builds
need neither Erlamsa nor Gleam. See the [local Python SDK](packages/pyefz/README.md).
The optional persistent provider worker has a separate [lifecycle guide](docs/erlamsa-performance.md).
Live [feature stability](docs/feature-stability.md) audits repeated coverage traces;
it is opt-in and does not change the default mutation path.

TUI: [terminal campaign dashboard](docs/tui.md) — `python3 scripts/tui.py --demo --out _build/tui-demo-1`.

Documentation: [architecture and UML](docs/architecture.md) ·
[map of all directories and files](docs/repository-map.md).

The [audit of the original presence backend and comparison with AFL++](docs/coverage-tracking-audit.md)
is pinned to commit `205e18b`. Experimental
[hit-count feedback](docs/hit-count-experiment.md) is now also available:
`coverage_feedback => hit_count` or CLI `--coverage-feedback hit_count`.
The default remains `presence`. Automatic presence supports opt-in
`coverage_backend => bitmap`: one bit per exact structural probe, without
hashing or edge coverage.

Quick start with a ready-made test corpus:

```sh
# From efz/: check OTP/Rebar3, build, instrument and prepare initial corpus files.
escript scripts/prepare.escript
# Run the command printed by the script.
```

[Verified fuzzing command, replay and remaining development stages](docs/quickstart.md).
Preparation uses the existing staged parser; `BOOM!` is a demonstration crash.

Phase 2 collects **source-code coverage of function clauses and branch outcomes
within one execution**. Ordinary targets under test need no EFZ calls. Compilation
instruments modules from an explicit allowlist; BEAM files and source manifests
are placed in a separate directory. One campaign worker calibrates initial inputs
and then retains successful mutations that reach previously unseen coverage
points. Exceptions, exits and timeouts preserve coverage and appear in results;
infrastructure failures stop the campaign.

The additional `hit_count` mode retains successful inputs that reach a new hit-count
bucket for an existing exact coverage point. Probe novelty and count novelty are
tracked separately (`new_probe` / `new_hit_count`); the same mutation, execution,
corpus and replay mechanisms are used. See the [experiment results](docs/hit-count-experiment.md)
before choosing a mode.

Execution model: a synchronous binary-input harness and controlled child processes
created through `efz_target:spawn/1` or `spawn_link/1`. An independent guardian
manages their lifecycle and coverage, waits for cleanup before returning a result,
and retires contaminated VMs. See [execution isolation and shared-state rules](docs/execution-isolation.md).
Arbitrary asynchronous OTP applications will require a separate disposable VM
backend.

Verified environment: Erlang/OTP **27.0**, ERTS 15.0, x86_64 Linux, Rebar3 3.25.0.
The minimum configured version is OTP 27; other versions were not verified here.

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
```

Run your own `my_harness:run(Input) when is_binary(Input)` through the general CLI:

```sh
escript scripts/fuzz.escript \
  --target my_harness \
  --code-path ./harness-ebin \
  --seeds ./corpus \
  --out ./findings \
  --artifacts ./instrumented \
  --mutation staged \
  --timeout 1000 \
  --max-input-bytes 4096 \
  --max-iterations 1000

escript scripts/fuzz.escript --help
```

Compile an ordinary harness into `harness-ebin`; it calls your parser or other
code under test. Build selected target modules with `efz_instrument:compile/2`
into `instrumented` (BEAM and `.efz-manifest` pairs; an example follows). Repeat
`--code-path` for dependency BEAM directories. The harness itself may be among
the instrumented modules if it exports `run/1`.

The runner reads regular files in the initial corpus as raw binary data in
filename order. Empty files are allowed; an empty directory is not. Before
execution, artifacts, the `run/1` export and output-directory availability are
checked. Findings go into `findings/crashes/`, and `findings/report.term` contains
the campaign report, including the active corpus. Reusing an output directory
replaces this report. Exit codes: `0` for normal campaign completion, including
target crashes; `2` for invalid arguments or configuration; `1` for execution
infrastructure or report-storage failure. The CLI defaults to staged mutations
and 1000 mutation executions. Erlang API defaults are unchanged except for the
shared input-size limit. `--max-input-bytes` applies to staged and random modes
(default 4096, inclusive, range 0..1048576).

Campaign configuration maps reject unknown top-level keys, including `function`
and `arity`. The standard callback is `run/1`; `max_input_bytes => N` is a
campaign-level setting. The old nested `mutation.max_input_bytes` setting is
rejected with an explicit migration message. Oversized inputs are rejected
without truncation. See [input limits and storage failures](docs/input-and-storage.md)
and [CLI configuration and campaign schema](docs/cli.md).

To use a corpus that persists across runs, set `--corpus-dir ./findings/corpus`
(Erlang API: `corpus_dir => "./findings/corpus"`). Initial inputs and successful
new-coverage discoveries are saved by SHA-256 before admission to the corpus
is acknowledged. Use the same directory on the next run; `--seeds` may then be
omitted. Seeds supplied alongside restored inputs are deduplicated by content.
Each restored input is recalibrated and may become a mutation parent.

Reusable inputs are restored, not the exact campaign state: planner cursors,
RNG state, global coverage and old integer queue IDs are not restored. By default,
a target or build mismatch produces an error. Explicit
`--corpus-build-policy recalibrate` permits inputs from another build with
diagnostics and fresh coverage collection. A corrupt persisted entry causes a
restore error; incomplete intermediate writes are excluded with diagnostics.
See [durable corpus format, durability guarantees and tests](docs/corpus.md).

Run the bounded example from the repository root:

```sh
escript examples/automatic/run.escript
```

The example compiles only `efz_example_parser`, uses the separate
`efz_example_target` adapter, calibrates `<<0>>` and performs 500 mutations using
the standard random mutator with a fixed RNG seed. The report is written to
`_build/example-report.term`, the instrumented build to
`_build/instrumented-example`, and artificial-crash artifacts to
`_build/example-crashes`. The parser is ordinary Erlang source; the deliberate
`artificial_example_exception` demonstrates a target failure.

For an interactive run after compilation, open a fresh `rebar3 shell`:

```erlang
{ok, Artifact} = efz_instrument:compile(
    "examples/simple_parser/efz_example_parser.erl",
    #{modules => [efz_example_parser], source_root => ".",
      outdir => "_build/instrumented-shell"}).
{ok, _} = efz:start(#{target => efz_example_target, artifacts => [Artifact],
                     seeds => [<<0>>], max_iterations => 500,
                     timeout => 100, workers => 1, random_seed => {17,23,41}}).
Report = efz:await(30000).
efz:stats().
efz:stop().
```

Targets still implement `run/1`; adapters may call one or more selected modules
in the same process. `efz_executor:run/3` preserves the phase-1 tuple API in an
explicit manual compatibility mode; `run/4` adds execution-scoped coverage
metadata. Automatic campaigns require validated artifacts; they do not fall
back to manual feedback. Do not preload an ordinary target or replace target
code during a campaign; use a fresh VM when switching builds.

```sh
# Deterministic coverage, semantics, identity and lifecycle checks:
rebar3 eunit --module=efz_phase2_tests
# Real coverage loop: <<>> -> A -> AB -> ABC, preserved parent IDs,
# exact input delivery to the harness and recipe reconstruction in a fresh VM:
rebar3 eunit --module=efz_feedback_loop_tests
# Repeatable local performance measurement after warmup:
escript scripts/coverage_bench.escript
# Clean ordinary build without deleting existing results:
EFZ_CLEAN_BUILD=$(mktemp -d /tmp/efz-clean.XXXXXX)
REBAR_BASE_DIR="$EFZ_CLEAN_BUILD" rebar3 compile
```

The implementation is described in [coverage API, supported syntax, manifests, measurements and limitations](docs/coverage.md),
[bitmap architecture](docs/coverage-bitmap-architecture.md),
[implementation and measurement report](docs/coverage-bitmap-implementation-report.md),
[coverage integrity, pinned identities and zero-coverage policy](docs/coverage-integrity.md),
[EFZ architecture and UML diagrams](docs/architecture.md),
[architecture decision record](docs/adr/0002-automatic-coverage.md) and
[validation results](docs/phase2-validation.md).

In the default isolated mode, coverage and cleanup include the root and
controlled child processes. The opt-in persistent target mode has a separate
[epoch and coverage-window contract](docs/persistent-target.md). An Erlang
process alone is not a VM- or OS-level sandbox. Distributed campaigns and
arbitrary VM snapshots are outside these execution modes.

Exact coverage identities are validated once per campaign. The default `ets`
backend uses `insert_new` and independently reports the first observation to the
guardian; `coverage_backend => ets_member` checks for an entry before insertion.
Optional `coverage_backend => bitmap` with `coverage_bitmap_bits => 65536` uses
a campaign schema and an execution-scoped atomic bitmap for automatic probe
presence. Set `coverage_backend => ets` to return to the reference implementation.
Bitmap reuse, isolation and performance validation results are in the
[bitmap v2 report](docs/coverage-bitmap-v2-results.md).
Experimental `coverage_backend => otp_native_public` uses public OTP 27+
executable-line coverage APIs and separately compiled target artifacts. Its
coverage semantics differ; ETS remains the default. See the
[short measurements and limitations](docs/otp-native-public-results.md).
ETS and bitmap preserve execution-scoped observations and recovery after crashes
or timeouts. Measured tradeoffs and source artifacts appear in the
[performance report](docs/phase2.1-performance.md). Set `random_seed` and optional
`selection_seed` for reproducible mutations and corpus selection.

The identity of the harness and selected instrumented modules is pinned for the
campaign. Hot replacement or execution-context corruption causes an infrastructure
error even if the target caught the coverage-hook exception. A valid input with
no observed coverage points receives `valid_empty_coverage`. The
`coverage_diagnostics` field lists unused artifacts; `--coverage-policy strict`
(API: `coverage_policy => strict`) fails the campaign if no coverage point was
observed during the entire campaign. The default policy is `diagnostic`.
Zero-hit calibration warns but lets mutations find the first point. Historical
performance figures predate these integrity checks.

```sh
# Rebuild the large sparse fixture deterministically:
escript bench/generate_sparse.escript
# All throughput measurement levels without a profiler (several minutes):
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/performance
escript bench/report.escript _build/performance
# Measure memory separately from throughput:
ERL_FLAGS='+S 4:4' escript bench/run.escript memory _build/performance-memory prepared
# Differential backend/validator and lifecycle checks:
rebar3 eunit --module=efz_backend_tests
```

Phase 3 adds **pluggable staged mutations**. Existing configurations preserve
the previous random-mutation and coverage defaults. The staged planner uses
explicit `exsplus` state, lazy per-content stage cursors, bounded havoc, binary
dictionaries and content-identified splice donors. Recipes record concrete
operations and bytes; reconstruction requires neither RNG state nor a running
campaign.

```sh
rebar3 compile
# Ordinary parser, dictionary file, real mutation operators, crash persistence and replay:
ERL_FLAGS='+S 4:4' escript examples/staged/run.escript
# Reconstruct exact bytes in a fresh VM without executing the target:
escript scripts/replay.escript _build/staged-example.recipe _build/regenerated.input
cmp _build/staged-example.input _build/regenerated.input
# Execute raw bytes in another VM, checking the saved build and harness:
escript scripts/replay.escript --input _build/staged-example.input \
  --target efz_staged_parser --artifacts _build/staged-targets
# The same execution from a concrete mutation recipe:
escript scripts/replay.escript --recipe _build/staged-example.recipe \
  --target efz_staged_parser --artifacts _build/staged-targets
```

In a fresh Erlang shell with EFZ on the code path:

```erlang
{ok, A} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".",
      outdir => "_build/staged-shell"}).
{ok, _} = efz:start(#{target => efz_staged_parser, artifacts => [A],
    seeds => [<<0>>], mutation_mode => staged, max_iterations => 200,
    max_input_bytes => 64,
    mutation => #{seed => {17,23,41}, dictionary => [<<"TOKEN">>, <<"BOOM!">>],
        stages => [dictionary_insert,boundary,arithmetic,havoc,splice],
        max_block_bytes => 16, max_token_bytes => 16,
        max_tokens => 16, max_dictionary_bytes => 256,
        attempts_per_visit => 8, havoc_depth => 4, random_retries => 4,
        max_idle_visits => 256}}).
StagedReport = efz:await(30000).
ok = efz:stop().
[Crash | _] = maps:get(crashes, StagedReport).
Recipe = maps:get(mutation, maps:get(metadata, Crash)).
ok = efz_recipe:save("_build/saved.recipe", Recipe).
ok = file:write_file("_build/saved.input", maps:get(input, Crash)).
{ok, Regenerated} = efz_recipe:regenerate(Recipe).
{ok, Expected} = efz_replay:load(maps:get(path, Crash) ++ ".replay").
{ok, Replay} = efz_recipe:execute_file("_build/saved.input",
    efz_staged_parser, [A], maps:get(target_builds, Recipe),
    #{timeout => 100, expected_harness => maps:get(harness, Expected)}).
maps:get(outcome, Replay).
```

To use an **EFZ hexadecimal dictionary**, replace `dictionary => [...]` with
`dictionary_file => "examples/staged/tokens.hex"`. Format: one token with an
even number of hexadecimal characters per line; blank lines and comment lines
starting with `#` are allowed. Empty tokens are rejected, duplicates removed,
and tokens sorted. The normalized dictionary is pinned for the campaign.
If the mutation RNG seed is not supplied, it is created once and recorded in
`StagedReport.mutation`.

Raw `.input` files remain the authoritative source of bytes. Executing them
requires an explicitly selected compatible local target; a recipe file cannot
choose executable code. Replay uses the saved `.replay` identity record and
reports `reproduced` (code 0) or `not-reproduced` (code 3). Build or harness mismatch
is rejected (code 2); infrastructure failures return code 1. Reports count
occurrences of each normalized signature. The default
`crash_policy => #{reason => category, max_frames => 5, max_representatives => 3}`
preserves the first three distinct representative inputs **both on disk and in
the report**; `reason` also accepts `exact` and `ignore`. The on-disk `summary`
counts all recorded occurrences and preserves the cap across VM restarts.
Selected artifacts preserve exact raw bytes and the complete `Reason`; other
inputs are counted without separate artifact files. `storage` distinguishes
`saved`, `duplicate` and `limit_reached`; only the first two provide a path to an
artifact with the exact input. Old groups without `summary` remain replayable;
use a new output directory for representative-capped storage. Interrupted or
corrupt storage reports an error instead of resetting counters or bypassing
the cap. See [operator semantics, stage order and all limits](docs/mutations.md),
[recipe format and replay API](docs/replay.md), and
[phase-3 validation and measured costs](docs/phase3-validation.md).

```sh
# Bounded mutation-only runs and campaigns with comparable budgets, without profiling:
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance
```

## Running with Cowboy

The `efz_cowboy_target:run/1` wrapper passes query string bytes without a leading
`?` to `cowboy_req:parse_qs/1`. Coverage is collected automatically from
`cowboy_req` and `cow_qs` (Cowlib). No HTTP listener is started: this tests
synchronous query string parsing in the target process.

Verified combination: OTP 27.0, Rebar3 3.25.0, Cowboy 2.19.0 and Cowlib 2.20.0.
The build also requires Git, GNU Make and access to Cowboy's public dependencies.
Run all commands below in one terminal from the **efz/** root; Cowboy sources
must be in the sibling **../cowboy/** directory.

Build EFZ and a separate copy of Cowboy. A copy in `/tmp` is needed for the
current `erl:fuzz` path: the colon causes the `erlang.mk` error
`target pattern contains no '%'`. The original checkout is preserved.

```sh
rebar3 compile
COWBOY_BUILD=$(mktemp -d /tmp/efz-cowboy.XXXXXX)
cp -a ../cowboy "$COWBOY_BUILD/cowboy"
make -C "$COWBOY_BUILD/cowboy"
```

If dependency downloads stop with `Proxy CONNECT aborted` and direct GitHub
access is available, repeat the build without proxy variables:

```sh
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy make -C "$COWBOY_BUILD/cowboy"
```

After a successful build, check the wrapper and run 500 mutation executions:

```sh
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" check
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" 500
```

`check` runs 14 additional EUnit checks against the selected Cowboy version.
The campaign's last argument sets the number of executions: 1–100000, default
500. The example uses staged mutations, RNG seed `{17,23,41}`, a small dictionary,
initial corpus `[<<>>]` and a 1024-byte input limit. EFZ coverage defaults are
preserved: prepared validation and ETS. Each escript invocation starts a fresh VM.

Status and statistics are printed at the end. The full report is saved to
`_build/cowboy-report.term`, instrumented BEAM files and manifests to
`_build/cowboy-targets/`, and unexpected-crash artifacts to
`_build/cowboy-crashes/`. Expected parsing rejection is returned as
`{invalid, Reason}` and is not counted as a target crash.

The runner warns about two list comprehensions in `cowboy_req` preserved without
internal coverage probes; they are not on the `parse_qs/1` path. See the
[Cowboy wrapper README](examples/cowboy/README.md) for scope, error semantics and
limitations.

## Automatic runtime diagnostics (opt-in)

P0 adds repeated calibration and verification, bounded sampling of
execution-owned processes and ETS, child-exit observations and timeout evidence.
Existing `run/1` harnesses need no changes. Enable it with
`runtime_oracles => #{enabled => true}` or the CLI flags
`--runtime-diagnostics --runtime-runs 3 --verification-budget 1000 --sample-interval 20`.
Execution outcomes, coverage retention and the controlled-descendant model remain
unchanged. Findings are written to `OUT/runtime-findings/`; replay uses
`replay.escript --runtime-finding DIRECTORY --target MODULE --artifacts DIR`.
See [policy, categories, limits and examples](docs/runtime-diagnostics.md) and
[validation and performance results](docs/runtime-diagnostics-validation.md).

## External worker VM (Linux, opt-in)

`--supervised` runs the unchanged campaign loop in a launcher-owned BEAM OS
process. Every executor call first publishes its exact input in the external
journal and waits for a digest-bound RUN permission. A native VM crash, hard
timeout, or dirty runner retires that VM; the controller waits for confirmed OS
cleanup, starts a new generation, restores the durable corpus, recalibrates it,
and continues within campaign-wide budgets. Existing `run(binary())` harnesses
and legacy mode are unchanged. Build first with `rebar3 compile` (this compiles
the small Linux lifecycle helper), then add `--supervised` to the normal command.

The exact guarantees, journal format, replay command, recovery limits and tested
native-crash evidence are in [P1-01 External supervisor](docs/p1-01-external-supervisor.md).

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --supervised --target my_harness --code-path harness-ebin \
  --artifacts instrumented --seeds corpus --corpus-dir out/corpus \
  --out out --timeout 1000 --max-iterations 10000
```

Supervised mode is deliberately unavailable on non-Linux systems rather than
silently weakening worker cleanup and parent-death guarantees.

The opt-in [persistent target VM](docs/persistent-target.md) retains target state
within an epoch and supports sequence journal, replay and same-sequence audits.
