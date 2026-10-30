# Preparing and running EFZ

**English** · [Русский](i18n/ru/quickstart.md) · [Español](i18n/es/quickstart.md) · [简体中文](i18n/zh-CN/quickstart.md) · [All languages](i18n/README.md)

State verified on September 15, 2026 with OTP 27.0 / ERTS 15.0,
Rebar3 3.25.0, Linux x86_64. The main coverage-guided loop already works:
mutation → target → new probes → retain → reuse the input as a parent.
This is confirmed by the [real staged-engine integration test](../test/efz_feedback_loop_tests.erl).
The current scope is synchronous `Module:run(binary())` and controlled
descendants; an arbitrary OTP application is not yet a supported target.

## Build and prepare

`erl`, `erlc`, `escript` from Erlang/OTP **27 or newer**, and `rebar3`, must be in
`PATH`. The build sets this minimum; other OTP versions were not verified by this
run. There are no external Rebar dependencies. The script does not install system
packages.

From the `efz/` checkout root:

```sh
escript scripts/prepare.escript
```

The [script](../scripts/prepare.escript) checks the tools and OTP, runs
`rebar3 compile` in the default profile, compiles the existing
[efz_staged_parser](../examples/staged/efz_staged_parser.erl) through
`efz_instrument:compile/2`, checks the BEAM/manifest and `run/1`, and copies the raw
seeds. It finishes by printing the complete launch command with absolute,
shell-quoted paths. The existing `scripts/fuzz.escript` executes the campaign;
there is no new fuzzing engine.

Repeated preparation preserves identical seed files, the corpus and findings.
If a seed with the same name has different content, the script returns an error
and preserves the user's file. The instrumented target is rebuilt. Run preparation
and fuzzing sequentially: rebuilding during a campaign violates the pinned
identity. Invalid arguments, build failures and filesystem errors produce a
nonzero exit code.

```sh
escript scripts/prepare.escript --help
# Custom data directory; relative paths are resolved from the current cwd:
escript scripts/prepare.escript --dir /tmp/my-efz-run
```

The script can be invoked by absolute path from any directory. Default output is
`efz/_build/quickstart/`. For long runs, set `--dir` outside `_build` so that manual
cleanup of the build directory does not delete the corpus/crashes. The script
does not delete them itself.

## Test corpus

The source files are in [examples/staged/corpus](../examples/staged/corpus/),
and working copies are in `_build/quickstart/seeds/`. All five inputs complete
calibration successfully. The source corpus contains no ready-made crashing
input.

| File | Exact bytes (hex) | Purpose |
|---|---|---|
| `00-empty.seed` | empty, 0 bytes | Empty-input clause and mutations from an empty seed |
| `01-zero.seed` | `00` | Numeric boundary/arithmetic paths, producing `80` and `01` |
| `02-near-token.seed` | `55 4f 4b 45 4e` (`UOKEN`) | One bit flip in the first byte produces `TOKEN`, a new successful clause |
| `03-near-crash.seed` | `43 4f 4f 4d 21` (`COOM!`) | One bit flip or arithmetic −1 in the first byte produces `BOOM!` |
| `04-binary.seed` | `00 ff 80 41 0d 0a` | NUL, non-UTF-8 and CR/LF pass through unchanged |

The text seeds have no trailing newline. The last two bytes of the binary seed
are deliberate CR/LF. README and dictionary files are not placed in the seed
directory: the CLI reads every regular file as an input. `tokens.hex` remains
separate and is used by the dictionary-based [staged example](../examples/staged/run.escript);
the general CLI does not yet have a dictionary option, so the standard default
stages are used here.

## Start fuzzing

Run all commands below from `efz/`, after preparation:

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_staged_parser \
  --seeds _build/quickstart/seeds \
  --out _build/quickstart/findings \
  --artifacts _build/quickstart/instrumented \
  --corpus-dir _build/quickstart/corpus \
  --mutation staged \
  --coverage-policy strict \
  --timeout 1000 \
  --max-input-bytes 4096 \
  --max-iterations 1000
```

This is a bounded campaign: 1000 mutation executions plus calibration.
Four BEAM schedulers in `ERL_FLAGS` do not mean four EFZ workers: there is one
worker. `BOOM!` deliberately raises `error(artificial_staged_exception)` in the
tutorial parser; this is a demonstration bug, not a discovered Erlang/OTP
vulnerability. Target crashes alone do not produce a nonzero exit code.
An infrastructure error produces exit 1, invalid CLI/configuration produces
exit 2. Stopping at the execution budget reports `completed`.

| Path | Contents |
|---|---|
| `_build/quickstart/instrumented/` | BEAM and `.efz-manifest` for the selected parser |
| `_build/quickstart/seeds/` | Five initial raw inputs |
| `_build/quickstart/corpus/` | Initial seeds and successful discoveries, SHA-256 content identity |
| `_build/quickstart/findings/report.term` | Binary ETF report: stats, active corpus, recipes, crash groups |
| `_build/quickstart/findings/crashes/` | Bounded representatives: `.input`, `.term`, `.recipe`, `.replay`; durable counters |

Reuse the saved corpus in a new VM:

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_staged_parser \
  --artifacts _build/quickstart/instrumented \
  --corpus-dir _build/quickstart/corpus \
  --out _build/quickstart/restored-findings \
  --mutation staged --coverage-policy strict \
  --timeout 1000 --max-input-bytes 4096 --max-iterations 1000
```

Restored inputs go through calibration again. This is a new campaign, not an
exact continuation of the RNG/cursor/global coverage. An incompatible build is
rejected; `--corpus-build-policy recalibrate` permits an intentional switch to a
new build. See [durable corpus](corpus.md). An existing `report.term` is overwritten
when the same `--out` is reused; different output directories preserve both
reports.

Replay the first saved representative:

```sh
EFZ_CRASH_INPUT=$(find _build/quickstart/findings/crashes -name artifact.input -type f -print -quit)
test -n "$EFZ_CRASH_INPUT" && \
  ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
    --input "$EFZ_CRASH_INPUT" --target efz_staged_parser \
    --artifacts _build/quickstart/instrumented --max-input-bytes 4096

test -n "$EFZ_CRASH_INPUT" && \
  ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
    --recipe "${EFZ_CRASH_INPUT%.input}.recipe" --target efz_staged_parser \
    --artifacts _build/quickstart/instrumented --max-input-bytes 4096
```

Both variants check the saved build/harness identity; the successful verdict is
`reproduced`, exit 0. The raw `.input` remains the authoritative artifact.
For your own target, use the [general CLI and instrumentation rules](cli.md).

## Remaining work for broader use

EFZ already works as a coverage-guided fuzzer for synchronous binary targets.
The following tasks expand its scope and the reliability of long campaigns;
they do not imply that the main feedback loop is missing.

| Priority | Work | Current limitation and readiness criterion |
|---|---|---|
| P1 | Disposable Erlang VM backend | The guardian cleans up controlled descendants, but not an arbitrary OTP application, NIFs, ports or external state. The parent runner must classify VM halt/native crashes with the input preserved; timeout/cancellation must destroy the entire VM owned by the run. See the [execution contract](execution-isolation.md). |
| P1 | Repeated calibration and feature stability | Each initial/restored seed is currently executed once (`efz_worker:handle_info/2`). Repeated exact coverage/outcome observations, instability diagnostics and A→dirty→A/fresh-VM checks are needed. Recipe determinism does not guarantee target determinism. The [proposed model](calibration-readiness.md) is not implemented yet. |
| P1 | Expand and verify instrumentation on OTP | These are currently source clause/outcome probes. Comprehensions, `maybe` and nonliteral record defaults are rejected by the strict transform or receive limitations. Semantic-equivalence tests, real parser harnesses and CI on the stated OTP versions are needed; partial probes must not be presented as full branch/edge coverage. See the [supported syntax](coverage.md). |
| P1 | Operating long campaigns | Exact checkpoint/resume is absent; the durable corpus preserves only reusable inputs. Separate contracts for checkpointing, crash-store recovery/migration and a total disk quota are needed. The representatives limit applies to each signature; a stale writer lock currently requires operator investigation. [Crash storage](replay.md). |
| P2 | Corpus and crash reduction | Content deduplication already exists; coverage-preserving corpus minimization and crash-input reduction do not yet exist. Validation: a reduced input preserves its signature on the pinned build; a minimized corpus preserves the union of probes. |
| P2–P3 | CLI mutation configuration and further scheduling | Dictionary/stages/RNG are available through Erlang configuration; the general CLI does not yet expose them. Next come convenient config validation, favored-input queues and independent VM workers. `efz_config` currently permits only `workers => 1`; an in-VM parallel pool would violate the current isolation model. |

The minimum next stage for integration with stateful Erlang/OTP is a disposable
VM backend and a regression suite for its lifecycle. For current synchronous
parsers, repeated calibration and minimization are more useful first steps.
Distributed execution and a UI do not replace these correctness checks.

## Validation of this preparation

A clean quickstart store produced: `completed`, 5 calibrations, 1000 executions,
3 discoveries, 8 active inputs, 2 crash occurrences with one signature and
0 infrastructure failures. First crash: `COOM! → BOOM!`, parent ID 4,
`stage = arithmetic`, `operations = [{add,0,8,big,-1}]`.
Counters from an arbitrary repeat run can differ: the CLI does not fix the RNG,
and the saved corpus changes the initial state.

Raw/recipe replay and restore were checked in separate Erlang VMs. A new campaign
without `--seeds` loaded 8 inputs, performed 8 calibrations and 100 mutation
executions without infrastructure failures. Checks also covered repeated
preparation without changing findings/corpus, invocation from another working
directory, spaces/apostrophes in paths, an unknown option, a missing argument,
a seed conflict and unavailable output. Local results: `_build/quickstart-checks/`.

The full set of checks—`rebar3 compile`, `rebar3 eunit` (**186 passed**),
`rebar3 ct` (**3 passed**), `rebar3 xref`, `rebar3 dialyzer`—all exited 0.
Additional setup/CLI smoke checks were run; they are not included in the EUnit
test count.
