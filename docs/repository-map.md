# EFZ repository map: directories and files

**English** · [Русский](i18n/ru/repository-map.md) · [Español](i18n/es/repository-map.md) · [简体中文](i18n/zh-CN/repository-map.md) · [All languages](i18n/README.md)

Each file's purpose was checked against the working tree on **September 15, 2026**.
The root in this document is the `efz/` directory; adjacent checkouts, such as `../cowboy/`,
are not part of EFZ. The description covers **186 project files**, including this
document, and **21 subdirectories**. It includes source files not yet added to Git,
tests, examples, documentation, and saved validation evidence.

For every file below, the map lists its purpose and implemented function or, for
data, its contents and consumer. Git internals and changing build outputs
are described separately by category: test directory names, logs, and BEAM files
are regenerated and are not included in the 186 project files.

Component relationships, state ownership, and UML are covered in the
[architecture description](architecture.md). This map answers “where things
are,” while the architecture explains “how they work together.”

## Navigation

- [Directory tree and root files](#root)
- [src — runtime and instrumentation build](#src)
- [scripts — user commands](#scripts)
- [test — automated checks](#test)
- [fixtures — test targets and data](#fixtures)
- [examples — demonstration integrations](#examples)
- [bench — performance measurements](#bench)
- [docs — documentation, UML, and archives](#docs)
- [Generated and internal files](#generated)
- [Finding the right place to change functionality](#changes)

<a id="root"></a>
## Directory tree and root files

```text
efz/
├── src/                      runtime, contracts, and instrumentation
├── c_src/                    Linux lifecycle helper for the external worker
├── priv/                     bounded external supervisor/controller
├── scripts/                  preparation, CLI campaign/replay, and coverage benchmark
├── test/                     EUnit and Common Test
├── fixtures/                 artificial test targets
│   ├── include/              include file for compilation checks
│   ├── external/             separate BEAM and P1-01 native-crash fixtures
│   ├── hit_count/            targets for count feedback tests and benchmarks
│   └── performance/          parser and sparse target for benchmarks
├── examples/                 standalone usage examples
│   ├── automatic/            random campaign with automatic coverage
│   ├── simple_parser/        ordinary parser and minimal harness
│   ├── staged/               staged campaign, dictionary, and crash replay
│   │   └── corpus/           five raw seeds for the quickstart
│   └── cowboy/               integration with external Cowboy/Cowlib
├── bench/                    measurement, profiling, and report drivers
├── docs/                     architecture and subsystem contracts
│   ├── adr/                  architecture decisions
│   ├── diagrams/             Mermaid UML sources and rendered SVGs
│   ├── examples/             saved crash input + recipe pair
│   ├── performance/          recorded measurement results
│   ├── coverage-audit-2026-09-15/  diagnostic targets and probe-set audit evidence
│   └── audit-2026-09-12/     historical diagnostics and their results
├── _build/                   generated builds, test data, and logs
└── .git/                     internal Git state
```

| File | Responsibility | Contents and usage |
|---|---|---|
| [.gitignore](../.gitignore) | Git exclusions | Excludes `_build`, BEAM, PLT, logs, crash dumps, Erlang cookies, and editor files. These are file-tracking rules, not fuzz campaign configuration. |
| [LICENSE](../LICENSE) | Project license | Apache License 2.0 text; matches the license identifier in `efz.app.src`. |
| [README.md](../README.md) | Main documentation entry point | Build, launcher, harness, instrumentation, staged mutation, replay, and links to detailed contracts. |
| [rebar.config](../rebar.config) | Rebar3 build and checks | Requires OTP 27 or newer, `debug_info`, warnings as errors, EUnit, Xref, and Dialyzer. `src_dirs` includes `src` and `examples/simple_parser`; the Linux pre-hook builds `c_src/efz_vm_launcher`. There are no external Erlang dependencies. |
| [rebar.lock](../rebar.lock) | Dependency locking | Currently contains `[]`: there are no pinned external Rebar dependencies. Rebar3 manages this file. |

<a id="src"></a>
## src — runtime and instrumentation build

The [src/](../src/) directory contains **35 files** in the main application. A module file
does not necessarily mean a separate process: `gen_server` modules are marked explicitly below;
mutator, feedback, recipe, and filesystem helpers are called as ordinary functions.

### Startup, configuration, and campaign control

| File | Responsibility | Implemented functionality and runtime role |
|---|---|---|
| [efz.app.src](../src/efz.app.src) | OTP application descriptor | Application name and version, `efz_app` callback, registered services, and dependencies `kernel`, `stdlib`, `crypto`. Rebar3 generates `efz.app` from it. |
| [efz.erl](../src/efz.erl) | Public Erlang API | `start/1` starts the application and campaign; `await/1` waits for the report, `stats/0` reads statistics, and `stop/0` stops the campaign and application. |
| [efz_app.erl](../src/efz_app.erl) | OTP application lifecycle | The `start/2` callback creates `efz_sup`; `stop/1` finishes the application callback. Contains no mutation loop. |
| [efz_sup.erl](../src/efz_sup.erl) | Root supervisor | Starts with an empty child list; `efz:start/1` adds a temporary `efz_fuzzer`. The `one_for_all` strategy with zero restart intensity does not recover campaign state. |
| [efz_cli.erl](../src/efz_cli.erl) | Universal launcher | `main/1` parses options, reads bounded raw seeds, checks paths and artifacts, calls `efz:start/1`, saves `report.term`, and returns an exit code. Has no fuzzing engine of its own. |
| [efz_external.erl](../src/efz_external.erl) | Supervised CLI boundary | Before target lookup, starts a file-only controller through `spawn_executable`, passes an explicit argv, and handles the parent-death ACK. Returns a clear error on non-Linux systems. |
| [efz_external_worker.erl](../src/efz_external_worker.erl) | Worker entrypoint and mandatory barrier | Runs only in the child BEAM: checks identity, starts the ordinary CLI/campaign, and implements a bounded HELLO/READY/PREPARE/RUN/RESULT protocol. The legacy executor calls the closure directly. |
| [efz_config.erl](../src/efz_config.erl) | Strict campaign schema | `prepare/1` checks known keys, `run/1`, workers, limits, mutation configuration, and coverage artifacts; restores the durable corpus and produces normalized configuration. `function` and `arity` are unsupported. |
| [efz_fuzzer.erl](../src/efz_fuzzer.erl) | Campaign coordinator, `gen_server` | Creates linked corpus, stats, and worker supervisor processes; monitors the worker, handles `await`, assembles the final report, and stops services. The executor runs individual inputs. |
| [efz_worker_sup.erl](../src/efz_worker_sup.erl) | Worker supervision | Creates one temporary `efz_worker` under `one_for_one`. The name does not imply an implemented parallel pool: the campaign schema permits only `workers => 1`. |
| [efz_worker.erl](../src/efz_worker.erl) | Main fuzz loop, `gen_server` | Calibration of all seeds → scheduling → mutation → executor → feedback → corpus/crash storage. Owns global coverage, staged cursors/RNG, crash groups/counters and bounded representatives, mutation trace, and decisions; handles infrastructure failures. |
| [efz_stats.erl](../src/efz_stats.erl) | Counters, `gen_server` | `inc/1`, `failure/1`, and `get/0` handle executions, calibrations, discoveries, rejections, crash occurrences/groups, timeouts, and infrastructure failures; the first infrastructure cause is stored separately. Mutation-specific counts belong to the planner/worker. |

### Harness, input, and execution

| File | Responsibility | Implemented functionality and runtime role |
|---|---|---|
| [efz_target.erl](../src/efz_target.erl) | Harness contract | Behaviour with the `run(binary()) -> term()` callback. The user module implements the callback; configuration checks the export. Also provides `spawn/1`, `spawn_link/1` for controlled descendants, and `dirty/1` to declare external effects. |
| [efz_input.erl](../src/efz_input.erl) | Shared input-size bound | `check/3` checks the binary and inclusive limit; `read_file/3` bounds file reads. Default 4096, permitted limit 0..1048576; bytes are not truncated. Used by ingestion, corpus, executor, mutations, replay, and crash storage. |
| [efz_executor.erl](../src/efz_executor.erl) | Single-input execution | `run/4` first crosses the external barrier when the supervised broker is registered, then creates the existing guardian. Returns after the final cleanup result and guardian DOWN; losing the guardian marks the VM dirty. `run/3` is a compatibility wrapper. |
| [efz_guardian.erl](../src/efz_guardian.erl) | Lifecycle ownership | Owns the root/controlled descendants, start gates, monitors, observation ETS, and trace barriers. Cleans up independently of caller/coordinator, checks shared-state violations, and prevents dirty VM reuse. |

### Coverage: compilation, runtime hooks, and feedback

| File | Responsibility | Implemented functionality and runtime role |
|---|---|---|
| [efz_instrument.erl](../src/efz_instrument.erl) | Building and loading instrumented artifacts | `compile/2` compiles selected sources into a separate outdir; `discover/1`, `load/1`, and `preflight/1` find and verify BEAM/sidecar, build identity, and loaded code. Runs before the campaign, not on every mutation. |
| [efz_instrument_pt.erl](../src/efz_instrument_pt.erl) | Compiler `parse_transform` | Traverses Erlang AST, inserts clause/outcome probes, and creates the build ID and source manifest. Checks the allowlist, repeated instrumentation, and unsupported syntax; strict mode rejects incomplete coverage. |
| [efz_cov_manifest.erl](../src/efz_cov_manifest.erl) | Manifest and permitted coverage space | Validates schema and probe identities, extracts the embedded manifest, and matches observed probes to builds. `prepare/2` creates a reusable validation plan with protected ETS; `release/1` releases it. |
| [efz_cov_integrity.erl](../src/efz_cov_integrity.erl) | Coverage observation integrity | Pins loaded harness/build identities, maintains an independent protected PID/context registry and context/code-load traces, and classifies valid empty versus broken observation. |
| [efz_cov_rt.erl](../src/efz_cov_rt.erl) | Runtime hook for inserted probes | `hit/1` checks context against the PID registry. Presence uses an ETS set; opt-in hit-count uses an atomic ETS counter per exact identity. Context/table errors and the first hit notify the guardian. |
| [efz_cov_count.erl](../src/efz_cov_count.erl) | Experimental count features | Validates the counter snapshot and checks its keys against exact coverage; classifies counts into eight buckets. Owns no process/table and does not replace the presence backend. |
| [efz_cov.erl](../src/efz_cov.erl) | Execution coverage context | `open`, `attach`, `snapshot`, `detach`, and `close` manage a single execution's table. Also contains set merge and manual compatibility helpers `hit/1`, `reset_local/0`, `snapshot/0`, `interesting/2`; `efz_feedback` makes the runtime decision. |
| [efz_feedback.erl](../src/efz_feedback.erl) | Coverage novelty | `evaluate/3` checks builds/status and computes `Observed − Global`. Opt-in hit-count also compares exact bucket features, distinguishing `new_probe`/`new_hit_count`. Target failures do not extend global state. |

### Corpus and persistent storage

| File | Responsibility | Implemented functionality and runtime role |
|---|---|---|
| [efz_corpus.erl](../src/efz_corpus.erl) | Active corpus, `gen_server` | Owns binary entries, integer IDs, and metadata. `add/2` deduplicates discoveries and, with storage enabled, persists them before acknowledging insertion; `select/0` chooses a random parent, `mutation_entries/0` passes entries to the staged scheduler. |
| [efz_corpus_store.erl](../src/efz_corpus_store.erl) | Durable reusable corpus | `save/4` stores the exact input and checksummed metadata under the SHA-256 content hash. `restore/3,4` validates schema, integrity, input limit, and build policy; returns inputs for fresh calibration. Does not restore old cursors, RNG, coverage, or integer IDs. |
| [efz_crash.erl](../src/efz_crash.erl) | Crash identity and artifacts | `identify/3` separates random occurrence ID, content hash, and normalized signature v2; `remember/3` maintains counts and bounded representatives. `save/4` stores raw input/Reason/recipe/expectation for selected representatives; every committed occurrence is counted in the durable summary. A faulty recipe does not prevent saving the selected raw input. Returns structured errors with identities and the primary cause. |
| [efz_crash_store.erl](../src/efz_crash_store.erl) | Bounded disk crash store | First N distinct inputs per signature, immutable artifacts, and an EFZG summary with durable count. An exclusive directory lock prevents concurrent writers from different VMs; the cap survives restart. Corrupt/unindexed/interrupted state produces an explicit error. |
| [efz_fs.erl](../src/efz_fs.erl) | Shared filesystem primitives | Bounded reads, directory creation, write/sync/close, `atomic_file/2`, and `atomic_group/3`. Temporary staging + rename publishes data; the group manifest validates integrity. Errors contain operation/path/reason; secondary cleanup does not replace the primary failure. |

### Mutation and replay

| File | Responsibility | Implemented functionality and runtime role |
|---|---|---|
| [efz_mutator.erl](../src/efz_mutator.erl) | Mutator callback contract | Behaviour `mutate(binary(), map()) -> binary()` for the random/callback path. The worker calls the staged engine through a separate planner API. |
| [efz_mutator_random.erl](../src/efz_mutator_random.erl) | Built-in random mutator | Size-bounded flip, overwrite, insert, and delete; supports seeded RNG. This is the active default Erlang API, not dead code. When the input is full, selects a permitted operation without producing oversized bytes. |
| [efz_mutation_plan.erl](../src/efz_mutation_plan.erl) | Lazy staged scheduler | `prepare/2`, `new/1`, and `next/2` maintain parent/stage cursors, RNG, donors, skips, and progress guard; generate one candidate at a time. Picks up the growing corpus and distinguishes true exhaustion from idle stop; does not materialize the entire mutation space. |
| [efz_mutation.erl](../src/efz_mutation.erl) | Deterministic byte operations | Applies specific flip/integer/block/dictionary/splice operations, validates offsets and limits, and returns bytes, skip, or error. Used by both planner and recipe replay; makes no random decisions of its own. |
| [efz_dictionary.erl](../src/efz_dictionary.erl) | Dictionary ingestion | `normalize/2` validates, sorts, and deduplicates binary tokens and computes identity; `load/2` performs bounded reads of a hex file with comments. This is EFZ's own format, not a parser for Erlang expressions or AFL dictionaries. |
| [efz_recipe.erl](../src/efz_recipe.erl) | Exact mutation provenance and replay | `make/4` records primary/donor bytes and hashes, parent, operations, limits, and builds. Encode/decode/load/save handle the EFZR envelope; regenerate reconstructs bytes, execute/execute_file runs them through the executor with explicit target/builds and a mandatory expected harness identity. |
| [efz_replay.erl](../src/efz_replay.erl) | Verified execution replay | EFZX expectation codec, portable harness identity, input hash, complete build-set and harness validation; raw/recipe runs through the existing executor, and the signature determines reproduced/not-reproduced. |
| [efz_replay_cli.erl](../src/efz_replay_cli.erl) | Replay CLI | Parses `--input/--recipe`, explicit target/artifacts/code paths/expectation; prints the verdict and distinguishes exit codes 0/3/2/1. Retains the old byte-regeneration-only mode. |

<a id="scripts"></a>
## scripts — user commands

The [scripts/](../scripts/) directory contains **4 escripts**. Launcher and replay locate
the compiled EFZ relative to their own paths; the coverage benchmark is intended
to run from the repository root. `prepare.escript` performs the build itself; other
scripts require it to have been completed beforehand.

| File | Responsibility | Behavior when run |
|---|---|---|
| [fuzz.escript](../scripts/fuzz.escript) | Universal fuzzing command | Finds the application ebin, loads `efz_cli`, passes arguments to `main/1`, and terminates the VM with its exit code. Prints a clear error when no build exists. |
| [prepare.escript](../scripts/prepare.escript) | Build and first-run preparation | Checks OTP/Rebar3, builds EFZ, instruments the staged parser, and copies the raw corpus without overwriting differing seeds; prints a command for the common CLI. Does not start the campaign itself. |
| [replay.escript](../scripts/replay.escript) | Thin replay CLI wrapper | Adds compiled EFZ ebin relative to the script and calls `efz_replay_cli:main/1`; the target is not selected by a recipe or diagnostic artifact. |
| [coverage_bench.escript](../scripts/coverage_bench.escript) | Original coverage microbenchmark | Compares the ordinary target, instrumented inactive hooks, and active ETS hooks on `efz_bench_fixture`; saves samples, memory, and compilation timing in `_build/coverage-benchmark.*`. It is not a launcher. |

<a id="test"></a>
## test — automated checks

The [test/](../test/) directory contains **21 files**. `*_tests.erl` run through
`rebar3 eunit`; `efz_coverage_SUITE.erl` runs through `rebar3 ct`. Helpers with `run/1`
within tests act as test harnesses; exporting them does not make them runtime services.

| File | Functionality tested | Key distinction / scenario |
|---|---|---|
| [efz_config_tests.erl](../test/efz_config_tests.erl) | Strict schema and target contract | Unknown keys, invalid values, missing `run/1`, empty corpus, and the ability to start from persistent inputs. |
| [efz_cli_tests.erl](../test/efz_cli_tests.erl) | Launcher in fresh Erlang VMs | External harness, raw seeds, staged/random, durable corpus, help, invalid modules/paths/artifacts/options, input bounds, crashes, timeouts, and infrastructure failure exit codes. |
| [efz_crash_tests.erl](../test/efz_crash_tests.erl) | Occurrences, signatures, and verified replay | Distinct inputs sharing a signature, Reason policy, relocation, 1000 occurrences with a bounded report, raw/recipe in fresh VMs, build/harness mismatch, corrupt/unreadable artifacts, primary coordinator/worker failure, and stats. |
| [efz_crash_retention_tests.erl](../test/efz_crash_retention_tests.erl) | Disk retention and late guardian failure | Checks disk cap/duplicates/raw Reason, two campaigns in different VMs, retained-input replay, corrupt summary, failed commit, concurrent/interrupted writer. A test-only AST gate after the actual guardian reply proves primary failure preservation in report/stats and prevents reuse. |
| [efz_integrity_tests.erl](../test/efz_integrity_tests.erl) | Coverage integrity | 22 regression scenarios: zero-hit/disconnected/unused, strict policy, dictionary/ETS corruption, caught hooks, child, reload/restore, harness pin, prepared plan, and direct ERTS loading. |
| [efz_isolation_tests.erl](../test/efz_isolation_tests.erl) | Guardian and controlled descendants | Root/child/nested lifecycle, timeout/trap_exit, caller/coordinator death, registrations/ETS, fresh-VM dirty policies, guardian loss, and prevention of reuse. |
| [efz_executor_tests.erl](../test/efz_executor_tests.erl) | Basic execution contract | Short `run/3` checks: return, error, exit, and timeout. This is a compatibility path; other suites test automatic coverage in greater detail. |
| [efz_phase2_tests.erl](../test/efz_phase2_tests.erl) | Automatic instrumentation and executor | Compares ordinary/instrumented semantics, probe kinds, manifests/build IDs, includes/options, tail calls, strict syntax, contexts, crash/kill/timeout coverage, and campaign cancellation. |
| [efz_backend_tests.erl](../test/efz_backend_tests.erl) | Coverage variant equivalence | Compares `ets`/`ets_member` and prepared/per-execution validation: exact probes, outcomes, novelty, validation-plan lifetime, backend failures, caller death, and cleanup. |
| [efz_hit_count_tests.erl](../test/efz_hit_count_tests.erl) | Count feedback integration | All buckets, multiplicity/namespace, multi-probe delta, controlled children, crash/timeout/corrupt counters, mutation independence, real staged parent reuse, durable restore, and crash replay in fresh VMs. |
| [efz_coverage_SUITE.erl](../test/efz_coverage_SUITE.erl) | Common Test integration | Three scenarios: automatic campaign, coverage on crash, and coverage on timeout. The campaign uses a scripted fixture; proof of real multistep parent reuse is in a separate feedback-loop test. |
| [efz_mutator_tests.erl](../test/efz_mutator_tests.erl) | Basic random mutator | Checks the returned binary for nonempty and empty primary inputs. `efz_limits_tests` checks the shared campaign limit. |
| [efz_mutation_tests.erl](../test/efz_mutation_tests.erl) | Byte operators and staged planner | Operation models, dictionary, limits, enumeration, fairness, finite exhaustion, RNG, growing corpus, donors, and progress guard. Includes a regression with 256 seeds and an unavailable first dictionary lane. |
| [efz_phase3_tests.erl](../test/efz_phase3_tests.erl) | Staged runtime and crash replay | Real operator discoveries, recipe persistence, continuation after a crash, trace independence, fresh-VM replay, and build mismatch. A campaign regression proves execution after skipping a dictionary lane and distinguishable stop reasons. |
| [efz_feedback_loop_tests.erl](../test/efz_feedback_loop_tests.erl) | Closing the feedback loop | Real dictionary mutations `<<>> → A → AB → ABC`; checks corpus IDs/parent, exact harness delivery by execution ref, primary hash/bytes, and replay in a fresh VM. No scripted mutator is used. |
| [efz_recipe_tests.erl](../test/efz_recipe_tests.erl) | EFZR and deterministic reconstruction | All operations, recipe corruption, schema/hash/limit checks, fresh-VM regeneration, and size bounding when invoking the replay script. |
| [efz_corpus_store_tests.erl](../test/efz_corpus_store_tests.erl) | Durable store and integrity | Roundtrip, duplicates, metadata shape/hash/schema, missing/truncated files, build policy, and interrupted write. Verifies that persistence failure does not add an unconfirmed entry to the active queue. |
| [efz_durable_tests.erl](../test/efz_durable_tests.erl) | Corpus reuse after VM restart | Several separate VMs: discovery `A` is persisted, then restored, calibrated, and becomes the parent of `AB` with a new queue ID. Also checks duplicates, build mismatch, and input limit. |
| [efz_limits_tests.erl](../test/efz_limits_tests.erl) | Shared input limit and storage failures | Bounds 0/max/max+1, random/staged/restore/replay/executor/crash; rejection of a callback with oversized result; filesystem errors, rollback, corrupt groups, and interrupted staging. Checks the exact input and primary reason in the report when writing fails. |
| [efz_smoke_tests.erl](../test/efz_smoke_tests.erl) | Minimal campaign lifecycle | Ten random executions in explicit manual mode and correct shutdown. Does not prove automatic coverage or actual corpus expansion. |
| [efz_scripted_mutator.erl](../test/efz_scripted_mutator.erl) | Fixed-sequence fixture | The callback returns predetermined bytes by iteration for Phase 2/backend/CT acceptance. Used only by tests; it is not a production mutator or proof of staged scheduling. |
| [efz_external_tests.erl](../test/efz_external_tests.erl) | Legacy compatibility gate | Proves that the absence of an external broker does not change the executor return path, quarantine, or readiness. |
| [external_supervisor_test.py](../test/external_supervisor_test.py) | Native P1-01 acceptance | Real secondary BEAM VMs and NIF: durable gate, SIGSEGV/SIGABRT recovery/replay, hard timeout, dirty recycle, protocol corruption, storage faults, restart budget, and parent-death cleanup. |
| [external_bench.py](../test/external_bench.py) | Legacy/supervised comparison | Three alternating runs of the same safe target; measures mutation/total throughput and durable preparation time separately without disabling fsync. |

<a id="fixtures"></a>
## fixtures — test targets and data

The [fixtures/](../fixtures/) directory contains **23 files including subdirectories**.
These are artificial targets that tests/bench compile with the ordinary compiler or
through `efz_instrument`. They are not included in the application's main `src_dirs`.

| File | Responsibility | Functionality and consumer |
|---|---|---|
| [efz_fixture.erl](../fixtures/efz_fixture.erl) | Broad Erlang syntax coverage for instrumentation | Clauses/guards, case/if, fun, try/catch/after, receive, binaries, records, macros, and tail recursion. Observer synchronization permits kill/timeout tests after an actual probe. Low-level tests pass Erlang terms. |
| [efz_fixture_helper.erl](../fixtures/efz_fixture_helper.erl) | Cross-module target call | `classify/1` distinguishes zero/other; called from `efz_fixture` to check instrumentation of multiple selected modules. |
| [efz_skipped.erl](../fixtures/efz_skipped.erl) | Supported-syntax limitations | List/binary/map comprehensions and the `maybe` expression check strict-mode rejection and semantic preservation with limitations under `strict => false`. |
| [efz_record_default.erl](../fixtures/efz_record_default.erl) | Expression in a record default | The default value depends on the process dictionary through `case`; Phase 2 checks diagnostics for the unsupported expression location and plain/instrumented equivalence in non-strict mode. |
| [efz_bench_fixture.erl](../fixtures/efz_bench_fixture.erl) | Frequently repeated probes | Numeric tail-recursive loop with a small branch on `N band 3`. Coverage/performance benchmarks measure repeated-hit overhead. |
| [efz_cli_harness.erl](../fixtures/efz_cli_harness.erl) | Minimal external harness | `run/1` accepts a binary and calls `efz_cli_parser:parse/1`; CLI tests compile the harness separately from the instrumented parser. |
| [efz_cli_parser.erl](../fixtures/efz_cli_parser.erl) | CLI test target | Distinguishes binaries starting with byte 128 from other inputs; flipping the first bit produces reachable new coverage. Exports `parse/1`, so also checks the missing `run/1` error. |
| [efz_lineage_parser.erl](../fixtures/efz_lineage_parser.erl) | Parent-reuse regression target | Ordinary `parse/1` with separate clauses for `A`, `AB`, `ABC`, and fallback. Hooks are added by the compiler; used by feedback-loop and durable tests. |
| [efz_durable_harness.erl](../fixtures/efz_durable_harness.erl) | Harness for multiple VMs | Stable `run(binary())` calls the lineage parser; proves restore and mutation parent reuse independently of the preceding VM's test process. |
| [efz_integrity_target.erl](../fixtures/efz_integrity_target.erl) | Instrumented integrity-test target | Real A/B clauses and an alternate build; unmatched binaries do not enter the probe body. |
| [efz_integrity_harness.erl](../fixtures/efz_integrity_harness.erl) | Ordinary integrity-test harness | Binary cases for disconnected/zero-hit, context corruption, caught hook, child context, synchronized hot reload, and a separate alternate harness build. |
| [efz_isolation_target.erl](../fixtures/efz_isolation_target.erl) | Execution-isolation target | Binary scenarios with actual linked/unlinked/nested children, timeout, registrations/ETS, and VM-global mutations. Compiled with automatic instrumentation for the isolation suite. |
| [efz_limits_target.erl](../fixtures/efz_limits_target.erl) | Exact delivery and artificial crash | Sends the received binary to a registered observer, returns it, or raises an error for `CRASH`. Used for limits and preservation of triggering input on IO failure. |
| [efz_crash_target.erl](../fixtures/efz_crash_target.erl) | Instrumented parser crash fixture | Returns ok for `OK`, waits on `WAIT`, otherwise crashes with a data-dependent Reason. A compile macro creates an incompatible build; source relocation checks signature normalization. |
| [efz_crash_harness.erl](../fixtures/efz_crash_harness.erl) | Ordinary external binary harness | Calls the actual parser. A compile macro changes harness identity; test-only environment settings select normal return, another error, or infrastructure failure in a fresh replay VM. |

### fixtures/external

`efz_external_target` and `efz_external_startup` define SAFE, dirty, timeout,
ordinary-exit, and startup paths. `efz_native_fixture` is a test-only NIF with controlled
SIGSEGV, SIGABRT, and hanging behavior; loaded only in the child acceptance VM.

### fixtures/include

The [fixtures/include/](../fixtures/include/) directory tests include-path
resolution and preprocessing when building an instrumented target.

| File | Purpose and functionality |
|---|---|
| [efz_fixture.hrl](../fixtures/include/efz_fixture.hrl) | `INCLUDED` macro with `case` and record `item`. The macro uses `MAGIC`, supplied by a compiler option; tests source-location preservation and expanded-code behavior. |

### fixtures/hit_count

Five ordinary targets/helpers for call-multiplicity checks and controlled
feedback comparison. The test/benchmark selects the instrumentation scope explicitly.

| File | Purpose |
|---|---|
| [efz_count_sites.erl](../fixtures/hit_count/efz_count_sites.erl) | Three functions x/a/b; the compiler adds one probe to each. Separates hit multiplicity from dispatch/loop-control probes. |
| [efz_count_harness.erl](../fixtures/hit_count/efz_count_harness.erl) | Uninstrumented binary adapter for L-counts, probe pairs, controlled children, crash/timeout, and test counter corruption. |
| [efz_count_repeat.erl](../fixtures/hit_count/efz_count_repeat.erl) | Prefix of identical bytes; separate deep clause at 16 repetitions. |
| [efz_count_records.erl](../fixtures/hit_count/efz_count_records.erl) | Parser of complete short records; deep clause at eight records. |
| [efz_count_machine.erl](../fixtures/hit_count/efz_count_machine.erl) | State machine with repeated tick/ack and commit after eight transitions. |

### fixtures/performance

The [fixtures/performance/](../fixtures/performance/) directory contains reproducible
benchmark workloads that require no third-party applications.

| File | Purpose and functionality |
|---|---|
| [efz_perf_parser.erl](../fixtures/performance/efz_perf_parser.erl) | Artificial binary record parser: numeric fields, flags, variable-length payload, truncated/invalid records, and an artificial error. Provides a mixed workload for executor/campaign benchmarks. |
| [efz_perf_sparse.erl](../fixtures/performance/efz_perf_sparse.erl) | Generated source retained in the project: 2048 `choose/1` clauses plus fallback. A large manifest with few reached probes measures sparse coverage/validation cost; the generator is in `bench`. |

<a id="examples"></a>
## examples — demonstration integrations

The [examples/](../examples/) directory contains **15 files**. Its campaigns select
specific targets/seeds/options for demonstration; the common user-facing launcher
is `scripts/fuzz.escript`.

### examples/simple_parser

The [examples/simple_parser/](../examples/simple_parser/) directory is a minimal pair:
ordinary target + harness. This is the only example included in Rebar3 `src_dirs`,
so both modules are available after an ordinary EFZ build.

| File | Purpose and functionality |
|---|---|
| [efz_example_parser.erl](../examples/simple_parser/efz_example_parser.erl) | Classifies empty input, binary prefixes, and text; deliberately crashes on prefix `255`. Contains no EFZ calls. `run/1` preserves compatibility; the main entry point is `classify/1`. |
| [efz_example_target.erl](../examples/simple_parser/efz_example_target.erl) | `efz_target` behaviour harness: `run/1` passes input to `efz_example_parser:classify/1`. Used by shell examples, smoke tests, and automatic coverage acceptance. |

### examples/automatic

The [examples/automatic/](../examples/automatic/) directory demonstrates automatic coverage
with the existing random mutation path.

| File | Purpose and functionality |
|---|---|
| [run.escript](../examples/automatic/run.escript) | Instruments the simple parser, runs 500 random executions from `<<0>>`, saves `_build/example-report.term` and crashes, and stops EFZ. Run from the root after building. |

### examples/staged

The [examples/staged/](../examples/staged/) directory demonstrates staged operators,
dictionary discoveries, and reproduction of an actual crash.

| File | Purpose and functionality |
|---|---|
| [efz_staged_parser.erl](../examples/staged/efz_staged_parser.erl) | Distinguishes `TOKEN`, boundary/arithmetic values, and empty input; prefix `BOOM!` raises an artificial error. Ordinary target without manual coverage hooks. |
| [run.escript](../examples/staged/run.escript) | Instruments the parser, runs 200 staged executions, extracts a crash recipe, checks exact regeneration and another crash through the executor; saves report/input/recipe/replay expectation under `_build`. |
| [tokens.hex](../examples/staged/tokens.hex) | Two hex lines for binary tokens `TOKEN` and `BOOM!`, plus a comment. Read by the standard `efz_dictionary`; these are mutation-stage data. |

### examples/staged/corpus

Five raw seed files for `scripts/prepare.escript` and the common launcher.
Documentation stays outside this directory so the CLI does not treat it as a seed.

| File | Purpose and exact contents |
|---|---|
| [00-empty.seed](../examples/staged/corpus/00-empty.seed) | Empty binary, 0 bytes; checks the empty-input path. |
| [01-zero.seed](../examples/staged/corpus/01-zero.seed) | One zero byte, the initial parent for boundary/arithmetic discoveries. |
| [02-near-token.seed](../examples/staged/corpus/02-near-token.seed) | `UOKEN` without newline; mutating the first byte reveals the `TOKEN` clause. |
| [03-near-crash.seed](../examples/staged/corpus/03-near-crash.seed) | `COOM!` without newline; bitflip/arithmetic on the first byte produces the artificial crash `BOOM!`. |
| [04-binary.seed](../examples/staged/corpus/04-binary.seed) | Hex `00 ff 80 41 0d 0a`; binary ingestion with NUL, non-UTF-8, and CR/LF. |

### examples/cowboy

The [examples/cowboy/](../examples/cowboy/) directory adapts an external
Cowboy/Cowlib checkout. Does not add these libraries as EFZ dependencies or start an HTTP
listener: the target synchronously parses a query string.

| File | Purpose and functionality |
|---|---|
| [README.md](../examples/cowboy/README.md) | External Cowboy preparation, checking, and launch commands; describes the `parse_qs` scope, instrumentation limitations, and historical results for a specific build. |
| [efz_cowboy_target.erl](../examples/cowboy/efz_cowboy_target.erl) | Passes raw query bytes to `cowboy_req:parse_qs/1` through a minimal Req map. Converts expected `request_error` for `qs`/`limit_reached` into returns; unexpected exceptions remain crashes. |
| [efz_cowboy_checks.erl](../examples/cowboy/efz_cowboy_checks.erl) | Additional EUnit checks for percent decoding, binary bytes, repetitions, and key counts; compares coverage backends and confirms discovery from an actual dictionary mutation. Invoked by the example runner in `check` mode. |
| [run.escript](../examples/cowboy/run.escript) | Checks external BEAMs, compiles the harness, instruments `cowboy_req` and `cow_qs`, and runs checks or a staged campaign. Uses explicit non-strict instrumentation for Cowboy and prints limitations. |

<a id="bench"></a>
## bench — performance measurements

The [bench/](../bench/) directory contains **13 files** of measurement support
infrastructure. They do not run during normal EFZ startup. Results are saved in
`_build`; recorded historical samples are in `docs/performance`.

| File | Responsibility | Implemented functionality |
|---|---|---|
| [run.escript](../bench/run.escript) | Benchmark launcher | Compiles local `efz_perf*` helpers, selects workload `hooks/executor/campaign/memory/startup` or `all` and backend/validation variants. Supports the `EFZ_PERF_EBIN` path. |
| [efz_perf.erl](../bench/efz_perf.erl) | Main measurement driver | Builds fixtures, checks semantics, measures hooks/executor/campaign/startup/memory, and saves environment and samples. `canonical/1` normalizes results for comparing variants. |
| [efz_perf_loop_target.erl](../bench/efz_perf_loop_target.erl) | Binary adapter for a numeric loop | Converts the input's first byte into a repetition count for `efz_bench_fixture`, and checks the checksum against a formula. Required by the campaign benchmark's binary contract. |
| [efz_perf_replay.erl](../bench/efz_perf_replay.erl) | Fixed stream of benchmark candidates | `install/1` places tuple inputs in `persistent_term`, `mutate/2` selects by iteration, and `clear/0` cleans up. Isolates mutation cost in measurements; not EFZR replay or a production scheduler. |
| [generate_sparse.escript](../bench/generate_sparse.escript) | Sparse fixture generator | Reproducibly writes `fixtures/performance/efz_perf_sparse.erl` with 2048 numeric clauses. Changes the source file; not required before every fuzzing run. |
| [profile.escript](../bench/profile.escript) | `eprof` profiling | Compiles the loop/parser/sparse target, preloads the execution path, and profiles hooks or executor; supports prepared validation. Profiling results are not treated as throughput samples. |
| [report.escript](../bench/report.escript) | Reading benchmark results | Reads local binary `.term` rows for hooks/executor/campaign and prints medians, raw samples, per-operation cost, and throughput. Does not rerun the workload. |
| [archive.escript](../bench/archive.escript) | Phase 2.1 evidence archive | Checks sample counts, canonical comparisons, source/BEAM/build hashes, memory/profiles; produces a compact text Erlang term for documentation. Intended for the specific historical artifact layout. |
| [mutations.escript](../bench/mutations.escript) | Staged mutation benchmark | Measures short/medium/maximum-size inputs, dictionary, splice, and havoc; verifies operation application. Compares finite random/staged campaigns and records memory, reductions, environment, and hashes. |
| [hit_count.escript](../bench/hit_count.escript) | New experiment launcher | Runs storage/executor/campaign/random/large-loop measurements and exports samples to JSON. |
| [efz_hit_count_micro.erl](../bench/efz_hit_count_micro.erl) | Storage microbenchmark | ETS set/counter, dense counters/atomics with exact mapping; 100–100000 probes, hit/snapshot/reset/memory/lifecycle, concurrent writers. |
| [efz_hit_count_experiment.erl](../bench/efz_hit_count_experiment.erl) | Controlled end-to-end comparison | Real staged/random campaigns with equal budgets/RNG, first deep input, corpus/count-only growth, fixed-input executor overhead, and saturation. |
| [efz_count_bench_harness.erl](../bench/efz_count_bench_harness.erl) | Observing the deep outcome | Calls the selected instrumented target and sends the `deep` time to the observer. Does not select mutations or collect coverage itself. |

<a id="docs"></a>
## docs — documentation, UML, and archives

The [docs/](./) directory contains **70 files including subdirectories**. Contracts
describe how to use the current subsystems. Audit/validation/performance records
capture state and results as of their recording date; their old failures, counts, and
commands are not claims about the current checkout.

### Main documents

| File | Purpose and contents |
|---|---|
| [architecture.md](architecture.md) | Current architecture: modules, processes, state owners, startup, feedback, execution, coverage, corpus, mutation, failures, and OTP integration boundaries. Includes four UML SVGs. |
| [repository-map.md](repository-map.md) | This file-by-file map: purposes of all project directories/files, runtime/test/example boundaries, generated artifacts, and locations for functionality changes. |
| [cli.md](cli.md) | Universal launcher, minimal external harness, compilation artifacts, parameters, and campaign map schema. |
| [execution-isolation.md](execution-isolation.md) | Supported binary harness contract, guardian protocol, controlled spawn API, dirty VM policy, shared-state boundaries, and the future disposable-VM backend. |
| [coverage-integrity.md](coverage-integrity.md) | Harness/build pins, independent observation evidence, context states, code replacement, campaign diagnostic/strict policy, and supported boundaries. |
| [coverage.md](coverage.md) | Automatic source coverage contract: supported syntax, granularity, manifest/build identities, compilation and execution APIs, backend/validation variants, and limitations. |
| [coverage-tracking-audit.md](coverage-tracking-audit.md) | Audit of exact probe-set representation, runtime lifetime/global feedback, comparison with pinned AFL++ bitmap/counters, 15 sections, and actual experiment results. |
| [hit-count-experiment.md](hit-count-experiment.md) | Opt-in count feedback contract, selection of ETS counters after benchmarking, paired fuzzing results, overhead, corpus growth, compatibility, and reproduction commands. |
| [quickstart.md](quickstart.md) | Build and test corpus preparation, exact fuzz/replay/restore commands, current limitations, and priorities before broader use. |
| [mutations.md](mutations.md) | Staged engine: defaults, dictionary format, lazy enumeration, progress/exhaustion, byte operators, havoc, provenance, and accounting. |
| [replay.md](replay.md) | Crash occurrence/signature/group contract, bounded report, Reason policies, EFZR/EFZX schemas, raw authority, verified replay CLI/APIs, compatibility, and regression evidence. |
| [corpus.md](corpus.md) | Durable corpus records v1/v2: content-addressed layout, atomic publication, probe/count provenance, restore, duplicate/build policies, and corrupt/partial diagnostics. Reusable corpus, not exact resume. |
| [input-and-storage.md](input-and-storage.md) | Shared `max_input_bytes`, replay/crash boundaries, atomic artifact groups, structured IO failures, and preservation of triggering input in runtime context. |
| [calibration-readiness.md](calibration-readiness.md) | September 9 audit of prerequisites for repeated calibration/feature stability. Analyzes snapshot completeness, termination, cross-case state, and includes diagnostic scripts; the proposed model does not mean feature stability is implemented. |
| [phase2-validation.md](phase2-validation.md) | Historical completion of automatic instrumentation: commands, retention/continuation, coverage after termination, baseline, and Phase 2 limitations. |
| [phase2.1-performance.md](phase2.1-performance.md) | Performance-work methodology and results: ETS variants, prepared validation, executor/campaign costs, memory, profiles, and default selection. |
| [phase3-validation.md](phase3-validation.md) | Historical staged mutation and replay validation: discoveries, crashes, measured costs, memory, commands, and Phase 3 boundaries. |
| [technical-audit-2026-09-12.md](technical-audit-2026-09-12.md) | Full September 12 audit: component inventory, actual call paths, integration matrix, experiments, bugs, maturity, and plan. Scheduler/CLI/persistence/IO gaps found then must be compared with current code and new regression tests. |
| [p1-01-external-supervisor.md](p1-01-external-supervisor.md) | P1-01 contract and evidence | Process boundary, protocol/state machine, durable pre-execution journal, timeout/dirty/native recovery, replay, Linux limits, regression, and benchmark evidence. |

### docs/coverage-audit-2026-09-15

Reproducible diagnostic fixtures and coverage-tracking audit evidence.
These are not production instrumentation or a new fuzzing engine.

| File | Purpose and contents |
|---|---|
| [efz_cov_audit_sites.erl](coverage-audit-2026-09-15/efz_cov_audit_sites.erl) | Four ordinary functions a/b/c/x for automatic instrumentation. A target-local diagnostic count in x confirms actual invocation counts without participating in coverage. |
| [efz_cov_audit_harness.erl](coverage-audit-2026-09-15/efz_cov_audit_harness.erl) | Uninstrumented binary dispatcher: A/B/AB/ABC, LOOP1…1000, crash/timeout/context erase, and controlled/native children. Prevents extra dispatch/loop probes from distorting count-semantics comparison. |
| [run.escript](coverage-audit-2026-09-15/run.escript) | Compiles fixtures, runs both actual ETS backends and feedback/corpus/planner, and checks rows/cleanup/novelty; native child is checked in a separate VM. Raw records are saved in `_build`. |
| [results.txt](coverage-audit-2026-09-15/results.txt) | Saved actual snapshots/novelty/corpus sizes, invocation multiplicity, child results, and production staged-campaign lineage. |
| [validation.json](coverage-audit-2026-09-15/validation.json) | EFZ/AFL++ revisions, commands and exit codes, EUnit/CT counts, and SHA-256 of unchanged production sources. |

### docs/adr

The [docs/adr/](adr/) directory stores architecture decisions: which approach was
chosen and why. Each baseline refers to the time the decision was made.

| File | Purpose and contents |
|---|---|
| [0002-automatic-coverage.md](adr/0002-automatic-coverage.md) | ADR choosing source clause/outcome probes and execution-owned ETS. Compares parse transforms, OTP coverage, and low-level rewriting; records the isolation/feedback contract and alternatives. |

### docs/diagrams

The [docs/diagrams/](diagrams/) directory contains **10 UML files**. `.mmd` files are
editable Mermaid sources; `.svg` files are saved images for viewing
without a Mermaid renderer. These SVGs are included in the architecture document.

| File | Purpose and contents |
|---|---|
| [README.md](diagrams/README.md) | Explains Erlang UML stereotypes, arrow meanings, and local rendering commands for all four diagrams. |
| [mermaid-config.json](diagrams/mermaid-config.json) | Shared Mermaid theme, fonts, and security/layout settings; HTML labels are disabled for portable SVGs. Unrelated to campaign configuration. |
| [modules.mmd](diagrams/modules.mmd) | Structural UML source: main runtime modules and staged-path dependencies. |
| [modules.svg](diagrams/modules.svg) | Rendered module-dependency image generated from `modules.mmd`. |
| [processes.mmd](diagrams/processes.mmd) | Structural UML source: supervisor children, links, monitors, worker/guardian/coordinator/target/descendants, and ETS owners. |
| [processes.svg](diagrams/processes.svg) | Rendered process and resource image from `processes.mmd`. |
| [feedback-loop.mmd](diagrams/feedback-loop.mmd) | Sequence UML source: fetching corpus entries, lazy mutation, execution, feedback, and retention that makes a discovery available to future mutations. |
| [feedback-loop.svg](diagrams/feedback-loop.svg) | Rendered complete staged feedback-loop image. |
| [executor.mmd](diagrams/executor.mmd) | Sequence UML source for one input: caller/guardian/coordinator/root/descendants, gates, hooks, DOWN/barriers, timeout, and dirty-runner cleanup. |
| [executor.svg](diagrams/executor.svg) | Rendered execution protocol and alternative outcomes. |

### docs/examples

The [docs/examples/](examples/) directory stores a small actual artifact pair for
replay documentation. These files are data, not target sources.

| File | Purpose and contents |
|---|---|
| [staged-crash.input](examples/staged-crash.input) | Exact binary from the staged example: six bytes `<<"BOOM!", 0>>`. Can be compared against recipe reconstruction; this is input for an intentionally crashing artificial parser. |
| [staged-crash.recipe](examples/staged-crash.recipe) | EFZR v1 recipe for the same input: primary, operations, hashes, limits, and build provenance from the historical run. Byte regeneration requires no target; execution requires an explicit compatible build. |

### docs/performance

The [docs/performance/](performance/) directory stores **text Erlang terms**
with historical measurements and JSON samples from the new count experiment.
Despite the `.term` extension, these terms are not binary ETF:
the contents are intended for inspection or `file:consult/1`.

| File | Purpose and contents |
|---|---|
| [phase2.1-samples.term](performance/phase2.1-samples.term) | Archive of environment, sample rows, canonical campaign checks, memory, profiling, and source/BEAM hashes for the Phase 2.1 report. |
| [phase3-mutations.term](performance/phase3-mutations.term) | Mutation-workload and random/staged campaign measurements, environment, compiler/build identities, memory/reductions, and source hashes. Basis for Phase 3 performance tables. |
| [phase3-validation.term](performance/phase3-validation.term) | Phase 3 acceptance evidence archive: source hashes, campaign/check results, and a link to the measurement environment. Captures that run, not an automatically updated test report. |
| [hit-count-samples.json](performance/hit-count-samples.json) | Raw storage/executor samples, configs/builds, and paired campaign results, random control, large loops, environment, and validation for the new prototype. |

### docs/audit-2026-09-12

The [docs/audit-2026-09-12/](audit-2026-09-12/) directory contains **30 files**
of diagnostics and evidence from the old audit. Scripts retain the old API/layout and
assertions for the defects found: for example, the nested mutation limit, premature
`mutation_exhausted`, and flat crash files. They **are not the current regression
suite**; after fixes, some assertions/paths are naturally incompatible.
Current regressions are in `test/`.

| File | Purpose and recorded contents |
|---|---|
| [audit_target.erl](audit-2026-09-12/audit_target.erl) | Artificial parser with `A`, `AB`, `ABC` paths, error on `CRASH`, and fallback; source for audit automatic instrumentation. |
| [audit_harness.erl](audit-2026-09-12/audit_harness.erl) | Actual binary harness: sends the exact delivered bytes to the observer and calls `audit_target:parse/1`. |
| [audit_faults.erl](audit-2026-09-12/audit_faults.erl) | Diagnostic targets for `persistent_term`, spawned/linked children, timeout, coordinator kill, context corruption, and exception classes. Creates controlled fault scenarios. |
| [run.escript](audit-2026-09-12/run.escript) | Historical driver: builds targets, runs a lineage campaign and fault diagnostics, and writes reports and snapshots to the specified working directory. Requires adapting the old configuration to the current API. |
| [edge-cases.escript](audit-2026-09-12/edge-cases.escript) | Reproducer for premature exhaustion with 256 seeds, silently ignored configuration keys, and crash storage failure. Assertions describe the old defects; the corrected scheduler should not satisfy them. |
| [fresh-replay.escript](audit-2026-09-12/fresh-replay.escript) | Historical check of `CRASH` reconstruction and execution in a new VM. Searches old flat `crashes/*.recipe`, while current artifacts are stored in groups. |
| [before-sha256.json](audit-2026-09-12/before-sha256.json) | File hash baseline before the audit, used to prove sources were unchanged during investigation. |
| [status-before.txt](audit-2026-09-12/status-before.txt) | Pre-audit `git status` snapshot: tracked modifications and untracked implementation. Not a description of today's Git status. |
| [verification.json](audit-2026-09-12/verification.json) | Integrity check of original files and final audit report structure/links. |
| [e2e-report.term](audit-2026-09-12/e2e-report.term) | Full **binary ETF** audit campaign report: corpus, coverage, recipes/trace, decisions, and crash evidence. Unlike `docs/performance/*.term`, this is not text for `file:consult/1`. |
| [e2e.txt](audit-2026-09-12/e2e.txt) | Readable lineage extract: corpus IDs, ancestry, delivery/regeneration counts, and crash path. The lack of durable restore refers to the old implementation. |
| [child.txt](audit-2026-09-12/child.txt) | Ordinary spawned-child snapshot: root finished, child alive, no automatic context in child. |
| [linked_child.txt](audit-2026-09-12/linked_child.txt) | Linked-child snapshot after normal root return; shows that a link alone does not guarantee child termination. |
| [child_timeout.txt](audit-2026-09-12/child_timeout.txt) | Snapshot after root timeout: a separate unlinked child remains alive and does not automatically receive coverage context. |
| [coordinator_kill.txt](audit-2026-09-12/coordinator_kill.txt) | Forced coordinator death: infrastructure outcome while the target is still alive. Evidence of the fault-isolation boundary. |
| [cross_case_state.txt](audit-2026-09-12/cross_case_state.txt) | Two executions of the same logical scenario before/after a `persistent_term` write; global state changes target outcome and coverage. |
| [caught_malformed_context.txt](audit-2026-09-12/caught_malformed_context.txt) | Target catches an exception after replacing process-dictionary context; snapshot shows lost malformed-context diagnostics. |
| [hot_reload.txt](audit-2026-09-12/hot_reload.txt) | Result of replacing instrumented code with an ordinary build after preflight: successful return with empty coverage. Evidence of dependence on stable loaded code. |
| [disconnected_artifacts.txt](audit-2026-09-12/disconnected_artifacts.txt) | Campaign with artifacts that do not provide the required target path: executions/crashes without discoveries or coverage. Valid artifacts alone do not prove instrumented code is reached. |
| [exception_classes.txt](audit-2026-09-12/exception_classes.txt) | Compares classes/reasons such as function_clause, badarg, throw, and exit with actual executor outcomes and stack traces. |
| [duplicate_initial_seeds.txt](audit-2026-09-12/duplicate_initial_seeds.txt) | Historical in-memory run of two identical initial seeds with different integer IDs and two calibrations. Not a durable content-dedup test. |
| [random-example-summary.txt](audit-2026-09-12/random-example-summary.txt) | Random-example summary: execution/discovery/crash counts and parent links in the grown corpus. |
| [edge-cases.log](audit-2026-09-12/edge-cases.log) | Reproducer output: in that checkout, 256 idle visits produced 0 candidates/executions; also records old configuration/storage diagnostics. |
| [fresh-replay.log](audit-2026-09-12/fresh-replay.log) | Confirmation of that historical fresh-VM replay: `CRASH`, 5 bytes, coverage present. |
| [staged-example.log](audit-2026-09-12/staged-example.log) | Counts and replay result for the standalone staged example at audit time. |
| [cowboy-check.log](audit-2026-09-12/cowboy-check.log) | Recorded **launch failure**: external `cowboy_req.beam` was missing. Not a successful Cowboy test result. |
| [eunit.log](audit-2026-09-12/eunit.log) | `rebar3 eunit` output from the historical checkout; test list and results of that run. |
| [ct.log](audit-2026-09-12/ct.log) | Common Test output: three automatic coverage scenarios passed at audit time. |
| [xref.log](audit-2026-09-12/xref.log) | Cross-reference analysis output from the old checkout. |
| [dialyzer.log](audit-2026-09-12/dialyzer.log) | Dialyzer output and the PLT/project file counts used then. |

<a id="generated"></a>
## Generated and internal files

### _build

`_build/` is excluded from Git. It contains Rebar3 outputs, instrumented targets,
crash/corpus artifacts, and local validation evidence. Unlike source
files, its contents depend on commands run. For example, fresh-VM tests create
directories with random suffixes; some tests remove them on completion.

| Directory / path family | Purpose and contents |
|---|---|
| `_build/default/lib/efz/` | Ordinary-profile build: `ebin/*.beam`, `ebin/efz.app`, compiler cache, and source links. The launcher uses this ebin. |
| `_build/test/lib/efz/` | Test-profile build and compiled test modules; does not replace the universal CLI's default ebin. |
| `_build/test/logs/` | Common Test runs: HTML reports, suite logs, summaries, and CSS/JS for local viewing. |
| `_build/plt/`, `_build/default/*plt`, `*.dialyzer_warnings` | Dialyzer base and project PLTs and diagnostic analysis output. A type-analysis cache, not a fuzz corpus. |
| `_build/*targets/`, `*-target/`, `instrumented-example/` | BEAM/manifest pairs created by the compilation facade for tests, examples, and benchmarks. Nested `target/` and `instrumented/` serve the same purpose. |
| `_build/*crashes/`, nested `crashes/` | Crash artifacts for the corresponding run. Old experiments may contain flat files; current `efz_crash` publishes the groups described below. |
| `_build/feedback-loop-test/` | `report.term`, `lineage.txt`, retained-entry recipes, and fresh replay evidence for the actual `A → AB → ABC` chain; `target/` stores its instrumented parser. Additional `checks/` and negative-parent logs are local regression checks. |
| `_build/durable-e2e-*/` | Separate VM phases: descriptor, plain/instrumented/v2 targets, persistent `corpus/`, phase reports/logs, and `lineage.txt`. `durable-e2e-latest.txt` identifies the latest directory. |
| `_build/cli-test-*/`, `cli-acceptance/`, `cli-checks/` | Temporary fixtures/launcher copies, fresh-VM results, and local CLI evidence. Test cleanup usually removes `*-test-*`. |
| `_build/quickstart/`, `quickstart-checks/` | Prepared seeds, instrumented parser, reusable corpus/findings, and validation logs for the preparation script, common CLI, restore, and replay. |
| `_build/coverage-audit-2026-09-15/` | Compiled diagnostic target, complete experiment records, validation logs, and downloaded pinned AFL++ reference sources. |
| `_build/limits-test-*/`, `limits-checks/`, `limits-storage-failure.term` | Inputs/targets and fault-injection artifacts for limit tests, command logs, and report preserving triggering input on storage failure. |
| `_build/scheduler-checks/`, `scheduler-progress.term` | Local evidence for the staged progress/exhaustion fix, including a campaign with 256 seeds. |
| `_build/isolation-test/`, `isolation-checks/` | Instrumented lifecycle fixture, fresh-VM dirty-policy logs, and guardian regression-suite validation results. |
| `_build/architecture-checks/` | Local Markdown/UML validation, preview PNG, and validation report. UML sources and published SVGs are in `docs/diagrams`. |
| `_build/performance*/`, `perf-*/`, `phase21-*/`, `phase3-performance*/` | Performance experiment variants: compiled fixtures, raw samples, memory/profile output, and comparisons. Saved conclusions are published in `docs/performance`. |
| `_build/phase2-*/`, `phase3-*/`, `backend-test-*/`, `fixture-check/`, `relocated/` | Acceptance working directories: rebuilt/relocated code, manifest corruption, strict syntax, replay, and termination diagnostics. Find the specific producer by searching the path in tests/bench. |
| `_build/*report.term`, `*.term`, `*.txt`, `*.log`, `*.json` | Reports and local evidence. The `.term` extension alone does not specify encoding: a producer writes either binary ETF or a text Erlang term. |
| `_build/*.input`, `*.recipe`, `*.hex` | Replay bytes and recipes, corrupt negative fixtures, and dictionary test files. Their meaning is determined by the producing test/script, not the extension alone. |

### Runtime artifact formats

These paths are set by the campaign/CLI. They can be outside `_build/` and persist
between runs if the user selects a permanent directory.

| Path / file | Responsibility | Producer / reader |
|---|---|---|
| `ARTIFACTS/Module.beam` | Loadable instrumented Erlang code with embedded manifest | `efz_instrument:compile/2`; loading/preflight through `efz_instrument`. |
| `ARTIFACTS/Module.efz-manifest` | Sidecar metadata: build, probes, and source locations; must match the BEAM | Compilation facade and preflight/manifest validation. |
| `OUT/report.term` | Final binary ETF campaign report, including stats/corpus/decisions/crashes | `efz_cli` through the atomic file helper. Not a campaign checkpoint by itself. |
| `CORPUS/<sha256>/input` | Exact binary reusable corpus entry | `efz_corpus_store`; SHA-256 content identity is independent of the old queue ID. |
| `CORPUS/<sha256>/metadata` | EFZC v1 metadata envelope: content/parent/build/discovery and available mutation recipe | `efz_corpus_store:save/4` and restore; integrity/compatibility are checked. |
| `CRASHES/<signature>/<occurrence>/artifact.input` | Exact triggering input for the selected immutable representative | `efz_crash` through `efz_fs:atomic_group/3`; execution replay reads the bytes. |
| `CRASHES/<signature>/<occurrence>/artifact.term` | Binary ETF schema v2: full raw Reason/stack, result/metadata, identities, and campaign input limit | Crash storage; used to analyze cause and provenance. |
| `CRASHES/<signature>/<occurrence>/artifact.replay` | EFZX v1: expected builds/harness, input hash, signature, policy, and limit | Created by `efz_crash`, safely loaded and checked by `efz_replay` before execution. |
| `CRASHES/<signature>/<occurrence>/artifact.recipe` | EFZR recipe when staged provenance is available; may be absent on the random path | `efz_crash` checks input correspondence; a malformed recipe produces an error and raw-only publication; `efz_recipe` reconstructs bytes. |
| `CRASHES/<signature>/<occurrence>/manifest` | Group schema and file identities for validating the complete published group | `efz_fs:validate_group/1` validates the whole group; raw replay deliberately does not depend on diagnostics or the optional recipe. |
| `CRASHES/<signature>/summary` | EFZG v1 durable occurrence count and bounded representative ID/hash pairs | `efz_crash_store`: bounded safe ETF decode, group validation, atomic replacement + fsync. Count persists across VMs; scheduler state does not. |
| `CRASHES/<signature>/.lock/` | Exclusive writer lock | The store creates it before changes and removes it with directory sync after writing. A competing writer or remaining lock gives `writer_active_or_interrupted`; no automatic guessing of a dead owner. |
| `.tmp-*` in a storage directory | Incomplete staging write before atomic rename; not a committed corpus/crash entry | Store/filesystem helpers. Ordinary failures trigger cleanup; interruption of the VM may leave remnants, reported by corpus restore diagnostics. |

### .git and crash dumps

`.git/` is managed by Git and does not participate in fuzzing. None of its files
are EFZ sources or campaign configuration.

| File / directory | Purpose |
|---|---|
| `.git/HEAD`, `refs/`, `objects/`, `index` | Current reference, branch/tag refs, history objects, and staging index. |
| `.git/config`, `description`, `info/` | Local settings and internal repository description. |
| `.git/logs/`, `ORIG_HEAD`, `FETCH_HEAD`, `AUTO_MERGE`, `COMMIT_EDITMSG` | Reflogs and temporary Git-operation state. Their presence/values change independently of EFZ. |
| `.git/hooks/`, `branches/`, `worktrees/`, `gk/` | Hooks, Git/worktree internal directories, and local Git-client data; not EFZ runtime. |
| Root `erl_crash.dump` | ERTS dump created when the VM crashes. Not a target crash `.input` or recipe; present in this checkout and excluded from Git. |
| `rebar3.crashdump`, `.rebar3/`, `.eunit/`, `_checkouts/`, and other `.gitignore` exclusions | Possible generated/tool files listed in ignore rules. A rule alone does not mean such a file or directory currently exists. |

<a id="changes"></a>
## Finding the right place to change functionality

| Task | Main code | Where to verify behavior |
|---|---|---|
| Add CLI option / campaign field | `efz_cli`, `efz_config` | `efz_cli_tests`, `efz_config_tests`; then `docs/cli.md`. |
| Change harness invocation / timeout | `efz_target`, `efz_executor`, `efz_guardian`, `efz_worker` | Executor, Phase 2/backend tests, and execution UML. |
| Change covered syntax / probe identities | `efz_instrument_pt`, `efz_instrument`, `efz_cov_manifest` | Phase 2 tests, `fixtures/efz_fixture`, strict fixtures, and coverage contract. |
| Change hooks or snapshot validation | `efz_cov_rt`, `efz_cov`, `efz_cov_manifest` | Backend differential tests and Phase 2 termination/isolation scenarios. |
| Change novelty / retention | `efz_feedback`, `efz_worker`, `efz_corpus` | `efz_feedback_loop_tests`: the discovered input must actually become a parent. |
| Change scheduling / progress guard | `efz_mutation_plan` | Mutation/Phase 3 regressions with 256 seeds, growing corpus, and the full feedback-loop test. |
| Add byte operator | `efz_mutation_plan`, `efz_mutation`, `efz_recipe` | Mutation model tests, recipe roundtrip/fresh-VM tests, and staged runtime. |
| Change durable schema / restore | `efz_corpus_store`, `efz_corpus`, `efz_config` | Store corruption/duplicate tests and durable fresh-VM integration. |
| Change input bound / IO contract | `efz_input`, `efz_fs`, `efz_crash`, and calling boundaries | `efz_limits_tests`, CLI ingestion, and recipe tests. |
| Change architecture description | `docs/architecture.md`, `docs/diagrams/*.mmd` | Check call paths against sources, regenerate SVGs, and update this map when adding files. |

When adding or moving a file, update the corresponding table and file
count. Preserve archived diagnostics as evidence of their time; current
correctness is confirmed by active tests and a new run, not an old log.

## Runtime diagnostics additions

| Path | Purpose |
|---|---|
| `src/efz_runtime_config.erl` | Shared nested policy validator and limits |
| `src/efz_stability.erl` | Bounded return comparison, repeatability metrics and replay repetition |
| `src/efz_runtime.erl` | Guardian-owned sampler, child/timeout observations |
| `src/efz_runtime_store.erl` | Bounded independent runtime artifacts and checksummed index |
| `src/efz_runtime_replay.erl` | Explicit-target compatible runtime rechecks |
| `fixtures/runtime/`, `test/efz_runtime_tests.erl` | Instrumented resources/lifecycle/verification regressions |
| `bench/efz_runtime_bench.erl` | Same-driver baseline/off/stability/resources/full measurement |
| `docs/runtime-diagnostics.md`, `docs/runtime-diagnostics-validation.md` | Contract and actual validation |

## P1-01 external supervisor additions

| Path | Purpose |
|---|---|
| `c_src/efz_vm_launcher.c`, `c_src/Makefile` | Linux pidfd/PDEATHSIG/session/subreaper lifecycle and authoritative wait status |
| `priv/efz_external.py` | Bounded protocol, durable journal, state machine, restart policy and external replay |
| `src/efz_external.erl`, `src/efz_external_worker.erl` | Pre-load CLI delegation and worker-side execution gate |
| `fixtures/external/` | Safe/native-crash/hang/dirty/startup fixtures loaded only by integration workers |
| `test/efz_external_tests.erl`, `test/external_supervisor_test.py` | Legacy gate and real OS-process acceptance |
| `test/external_bench.py` | Same-target legacy/supervised durability-cost measurement |
| `docs/p1-01-external-supervisor.md` | Contract, commands, evidence and limitations |
