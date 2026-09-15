# EFZ (Erlang Fuzzer)

EFZ is an Erlang-native fuzzer with corpus management, random and opt-in staged
binary mutation, exact candidate recipes, monitored target execution, crash
artifacts, and automatic source instrumentation. It has no dependency on another
fuzzing engine.

Документация: [архитектура и UML](docs/architecture.md) ·
[карта всех директорий и файлов](docs/repository-map.md).

Быстрый старт с готовым тестовым корпусом:

```sh
# Из efz/: проверка OTP/Rebar3, сборка, instrumentation и подготовка raw seeds.
escript scripts/prepare.escript
# Выполните команду, которую напечатает скрипт.
```

[Проверенная команда фаззинга, replay и оставшиеся этапы разработки](docs/quickstart.md).
Подготовка использует существующий staged parser; `BOOM!` — его демонстрационный crash.

Phase 2 collects **execution-scoped source-level clause/outcome probe coverage**.
An ordinary target needs no EFZ calls. Compilation instruments an explicit module
allowlist and produces BEAM files plus source manifests in a separate directory.
A single campaign worker calibrates seeds, then retains successful mutations
that reach previously unseen probes. Exceptions, exits, and timeouts retain
coverage and become result data; infrastructure failures stop the campaign.

Execution model: synchronous binary harness with controlled descendants created
through `efz_target:spawn/1` / `spawn_link/1`. An independent guardian owns their
lifecycle and coverage, waits for cleanup before returning, and retires dirty VMs.
See [execution isolation and shared-state policy](docs/execution-isolation.md).
Arbitrary asynchronous OTP applications require a future disposable-VM backend.

Tested environment: Erlang/OTP **27.0**, ERTS 15.0, x86_64 Linux, Rebar3 3.25.0.
The configured minimum is OTP 27; other versions have not been validated here.

```sh
rebar3 compile
rebar3 eunit
rebar3 ct
rebar3 dialyzer
rebar3 xref
```

Launch your own `my_harness:run(Input) when is_binary(Input)` with the universal CLI:

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

Compile the ordinary harness into `harness-ebin`; it calls your parser or other
target code. Build selected target modules with `efz_instrument:compile/2` into
`instrumented` (BEAM + `.efz-manifest` pairs; see the example below).
Repeat `--code-path` for dependency BEAM directories. The harness may instead be
one of the instrumented modules if it exports `run/1`.

The launcher reads regular seed files as raw binaries in filename order; empty
files are valid seeds, but an empty directory is rejected. It checks artifacts,
the `run/1` export and output access before execution. Findings go to
`findings/crashes/`; `findings/report.term` contains the campaign report, including
the active corpus. Reusing an output directory replaces that report. Exit codes:
`0` for a normal campaign stop (including target crashes), `2` for invalid
arguments/configuration, `1` for runtime infrastructure or report-storage failure.
CLI defaults are staged mutation and 1,000 mutation executions; the Erlang API's
defaults remain unchanged apart from the common input bound. `--max-input-bytes`
applies to both staged and random modes (default 4096, inclusive, 0..1048576).

Campaign maps reject unknown top-level keys, including `function` and `arity`.
The canonical callback is `run/1`; set `max_input_bytes => N` at campaign level.
The old nested `mutation.max_input_bytes` is rejected with an explicit migration
error. Oversized inputs are rejected, never truncated. See
[input limits and storage failures](docs/input-and-storage.md).
See [CLI setup and the campaign schema](docs/cli.md).

Enable reusable durable corpus with `--corpus-dir ./findings/corpus` (Erlang API:
`corpus_dir => "./findings/corpus"`). Initial seeds and successful new-coverage
discoveries are stored by SHA-256 before they are acknowledged as retained.
Use the same directory in a later invocation; `--seeds` may then be omitted.
Seeds supplied alongside saved inputs are deduplicated by content. Every restored
input is calibrated again and can become a mutation parent.

This restores reusable inputs, not an exact campaign: scheduler cursors, RNG
state, global coverage and old integer queue IDs are not restored. Target/build
mismatches fail by default. Explicit `--corpus-build-policy recalibrate` allows
inputs from another build with diagnostics and fresh coverage collection.
Committed entry corruption fails restore; incomplete staging entries are excluded
with diagnostics. See [durable corpus format, durability and tests](docs/corpus.md).

Run the bounded example from the repository root:

```sh
escript examples/automatic/run.escript
```

This compiles only `efz_example_parser`, uses the separate `efz_example_target`
adapter, calibrates `<<0>>`, and runs 500 mutations with the production random
mutator and a fixed random seed. It writes `_build/example-report.term`, an
instrumented build under `_build/instrumented-example`, and artificial crash
artifacts under `_build/example-crashes`. The parser is ordinary Erlang source;
its deliberately raised `artificial_example_exception` is a demonstration bug.

For an interactive run, start a fresh `rebar3 shell` after compilation:

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

Targets still implement `run/1`; adapters can call one or several selected
modules in the same process. `efz_executor:run/3` retains the Phase 1 tuple API
in explicit manual compatibility mode; `run/4` adds scoped coverage metadata.
Automatic campaigns require validated artifacts and never fall back to manual
feedback. Do not load the ordinary target first or hot-reload targets during a
campaign; use a fresh VM to switch builds.

```sh
# Deterministic feedback acceptance, semantics, identities, and lifecycle checks:
rebar3 eunit --module=efz_phase2_tests
# Real staged feedback loop: <<>> -> A -> AB -> ABC, retained parent IDs,
# exact harness delivery, and recipe regeneration/execution in a fresh VM:
rebar3 eunit --module=efz_feedback_loop_tests
# Repeated, warmed local performance measurement:
escript scripts/coverage_bench.escript
# Clean ordinary compilation without deleting existing builds:
EFZ_CLEAN_BUILD=$(mktemp -d /tmp/efz-clean.XXXXXX)
REBAR_BASE_DIR="$EFZ_CLEAN_BUILD" rebar3 compile
```

[Coverage APIs, syntax support, manifests, measurements, and limits](docs/coverage.md),
[Coverage integrity, pinned identities and zero-hit policy](docs/coverage-integrity.md),
[Архитектура EFZ и UML-диаграммы](docs/architecture.md),
[decision record](docs/adr/0002-automatic-coverage.md), and
[validation evidence](docs/phase2-validation.md) describe the implementation.

Coverage and cleanup cover the root and controlled descendants. Arbitrarily spawned
children, stateful OTP applications, shared VM state, native failures, distributed
campaigns, grammar-aware mutation, and corpus minimization are outside this phase.
An Erlang process is not a VM or operating-system sandbox.

Exact coverage validation is prepared once per campaign. The default `ets` hook
uses `insert_new` and independently reports first observations to the guardian;
`coverage_backend => ets_member` checks membership before insertion. Both preserve execution-scoped observations
and crash/timeout recovery. See the [performance report](docs/phase2.1-performance.md)
for measured tradeoffs and raw artifacts. Set both `random_seed` and the optional
`selection_seed` when reproducible mutation and corpus selection are needed.

Harness and selected instrumented module identities are pinned for the campaign.
Hot replacement or damaged execution context produces an infrastructure failure,
including when the target catches the hook exception. A healthy zero-hit input is
reported as `valid_empty_coverage`. `coverage_diagnostics` lists unused artifacts;
`--coverage-policy strict` (API: `coverage_policy => strict`) fails a campaign that
finishes without any observed probe. The default is `diagnostic`. Zero-hit
calibration warns and still allows mutation to discover its first probe.
Historical performance numbers predate these integrity checks.

```sh
# Rebuild the larger ordinary sparse fixture (its output is deterministic):
escript bench/generate_sparse.escript
# All throughput layers, without a profiler (can take several minutes):
ERL_FLAGS='+S 4:4' escript bench/run.escript all _build/performance
escript bench/report.escript _build/performance
# Memory sampling is separate from throughput:
ERL_FLAGS='+S 4:4' escript bench/run.escript memory _build/performance-memory prepared
# Exact backend/validator differential and lifecycle checks:
rebar3 eunit --module=efz_backend_tests
```

Phase 3 adds **opt-in staged mutation**. Existing configurations retain their
random stream and coverage defaults. The staged planner uses explicit `exsplus`
state, lazy per-content stage cursors, bounded havoc, binary dictionaries and
content-identified splice donors. Recipes record concrete operations and bytes;
regeneration does not need RNG state or a live campaign.

```sh
rebar3 compile
# Ordinary parser, file dictionary, real staged operators, saved crash and replay:
ERL_FLAGS='+S 4:4' escript examples/staged/run.escript
# Regenerate exact bytes in a fresh VM, without executing a target:
escript scripts/replay.escript _build/staged-example.recipe _build/regenerated.input
cmp _build/staged-example.input _build/regenerated.input
# Execute raw bytes in another VM, verifying saved build and harness identity:
escript scripts/replay.escript --input _build/staged-example.input \
  --target efz_staged_parser --artifacts _build/staged-targets
# The same execution from its concrete mutation recipe:
escript scripts/replay.escript --recipe _build/staged-example.recipe \
  --target efz_staged_parser --artifacts _build/staged-targets
```

In a fresh Erlang shell with EFZ on its code path:

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

Replace `dictionary => [...]` with
`dictionary_file => "examples/staged/tokens.hex"` to use the **EFZ hex dictionary**
format: one even-length hex token per line, blank lines and `#` comment lines
allowed. Empty tokens reject; duplicates are removed and tokens sorted. The
normalized dictionary is fixed for the campaign. If the mutation seed is omitted,
one is generated once and recorded in `StagedReport.mutation`.

Raw `.input` files remain authoritative. Executing them requires an explicitly
selected compatible local target; recipe files cannot choose executable code.
Execution replay uses the saved `.replay` identity record and prints `reproduced`
(exit 0) or `not-reproduced` (exit 3). Build/harness mismatches reject (exit 2);
infrastructure failures return exit 1. Reports count occurrences per normalized
signature. `crash_policy => #{reason => category, max_frames => 5, max_representatives => 3}`
keeps the first three distinct input representatives **on disk and in the report**
by default; `reason` also accepts `exact` or `ignore`. Disk `summary` counts all
committed occurrences and preserves the cap across VM restarts. Selected artifacts
retain exact raw bytes and full Reason; additional inputs are counted without
individual artifact files. `storage` distinguishes `saved`, `duplicate` and
`limit_reached`; only the first two provide an exact-input artifact path.
Legacy groups without `summary` remain replayable; use a fresh output directory
for bounded storage. Interrupted/corrupt stores fail explicitly instead of
resetting their counters or bypassing the cap.
See [operator semantics, stage order and all limits](docs/mutations.md),
[recipe format and replay APIs](docs/replay.md), and
[Phase 3 validation and measured costs](docs/phase3-validation.md).

```sh
# Bounded mutation-only batches and comparable-budget campaigns; no profiling:
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance
```

## Запуск с Cowboy

Обёртка `efz_cowboy_target:run/1` передаёт байты query string без начального `?`
в `cowboy_req:parse_qs/1`. Покрытие автоматически собирается из `cowboy_req`
и `cow_qs` (Cowlib). HTTP listener не запускается: проверяется синхронный разбор
query string в процессе target.

Проверенная связка: OTP 27.0, Rebar3 3.25.0, Cowboy 2.19.0 и Cowlib 2.20.0.
Для сборки также нужны Git, GNU Make и доступ к публичным зависимостям Cowboy.
Все команды ниже выполняются в одном терминале из корня **efz/**;
исходники Cowboy должны находиться рядом, в **../cowboy/**.

Соберите EFZ и отдельную копию Cowboy. Копия в `/tmp` нужна для текущего пути
`erl:fuzz`: двоеточие вызывает у `erlang.mk` ошибку
`target pattern contains no '%'`. Исходный checkout сохраняется.

```sh
rebar3 compile
COWBOY_BUILD=$(mktemp -d /tmp/efz-cowboy.XXXXXX)
cp -a ../cowboy "$COWBOY_BUILD/cowboy"
make -C "$COWBOY_BUILD/cowboy"
```

Если скачивание зависимостей остановилось на `Proxy CONNECT aborted` и доступен
прямой доступ к GitHub, повторите сборку без переменных прокси:

```sh
env -u HTTPS_PROXY -u HTTP_PROXY -u ALL_PROXY \
    -u https_proxy -u http_proxy -u all_proxy make -C "$COWBOY_BUILD/cowboy"
```

После успешной сборки проверьте обёртку и запустите 500 мутационных исполнений:

```sh
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" check
escript examples/cowboy/run.escript "$COWBOY_BUILD/cowboy" 500
```

`check` запускает 14 дополнительных EUnit-проверок на указанной версии Cowboy.
Последний аргумент кампании задаёт число исполнений: 1–100000, по умолчанию 500.
Пример использует staged mutations, seed `{17,23,41}`, небольшой словарь,
начальный корпус `[<<>>]` и предел входа 1024 байта. Defaults покрытия EFZ
сохраняются: prepared validation + ETS. Каждый вызов escript — свежая VM.

В конце выводятся статус и статистика. Полный отчёт сохраняется в
`_build/cowboy-report.term`, инструментированные BEAM и manifests — в
`_build/cowboy-targets/`, артефакты неожиданных падений — в
`_build/cowboy-crashes/`. Штатный отказ разбора возвращается как `{invalid, Reason}`
и не считается падением target.

Runner предупреждает о двух list comprehensions в `cowboy_req`, сохранённых
без внутренних probes; они не входят в путь `parse_qs/1`. Подробнее об области
проверки, семантике ошибок и ограничениях — в
[README обёртки Cowboy](examples/cowboy/README.md).
