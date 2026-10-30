# Контракт автоматического покрытия

[English](../../coverage.md) · **Русский** · [Español](../es/coverage.md) · [简体中文](../zh-CN/coverage.md) · [Все языки](../README.md)

## Поддерживаемая среда и метрика

Фактически проверены: OTP 27.0 / ERTS 15.0, `x86_64-pc-linux-gnu`, Rebar3 3.25.0.
MD5 compiler module включён в build identities. Другие OTP releases и
architectures требуют validation; одна minimum-OTP setting не является evidence.

Метрика default ETS и opt-in bitmap — **execution-scoped source-level
clause/outcome probe coverage**.
Каждое observation — точное `{Module, BuildId, ProbeId}`. Default
`coverage_feedback => presence` сохраняет exact set semantics. Экспериментальное
`coverage_feedback => hit_count` добавляет exact-identity counters и count
buckets; см. [контракт и измерения](hit-count-experiment.md). Ни в одном mode
нет hashed bitmap, выведенного CFG edge или previous-probe transition state.
Opt-in bitmap backend хранит эти exact structural probes в collision-free slots.

[Архитектура bitmap storage](coverage-bitmap-architecture.md) сохраняет эти
structural probes и exact identities. Для automatic presence campaigns задайте
`coverage_backend => bitmap` и при желании `coverage_bitmap_bits => 65536`
(bits, не bytes). `ets` остаётся default и fallback. Bitmap с manual coverage
или hit-count feedback отклоняется до кампании. Tests и measured tradeoffs см.
в [отчёте реализации v1](coverage-bitmap-implementation-report.md) и
[измерениях v2](coverage-bitmap-v2-results.md). Экспериментальный
`coverage_backend => otp_native_public` использует OTP 27+ `line_coverage` и
документированные reset/read APIs. Его feature — executable line, поэтому count
и corpus history нельзя считать эквивалентными EFZ structural probes. Он требует
отдельно скомпилированных native target artifacts и выделенной VM без посторонних
callers этих modules. См. [реализацию и короткие результаты](otp-native-public-results.md).
Прямое чтение DWARF остаётся нереализованным.

## Синтаксис и семантика

| Конструкция | Instrumentation |
|---|---|
| Function clauses, включая guarded/binary-pattern clauses | Body entry |
| `case`, `if` | Entry выбранного clause body |
| `receive` | Entry выбранной clause; entry `after` body |
| `try` | Body entry, выбранные `of` и catch clauses, непустой `after` body |
| Anonymous/named `fun` | Entry выбранной fun clause |
| Nested expressions | Обход calls и callee expressions, tuples, lists, map keys/values/updates, record values/updates/access, binary values/sizes, blocks, matches (RHS), operators, old `catch` |
| Patterns и guards | Структурно сохраняются; probes не вставляются |
| `andalso`, `orelse` | Operator/evaluation rules сохранены; nested clause bodies обходятся, operator-outcome probes нет |
| Local/remote fun references | References сохранены; dynamic expression components обходятся |
| List/binary/map comprehensions | Entire expression сохраняется; diagnostic и manifest limitation; strict mode отклоняет |
| `maybe`, включая `else` | Entire expression сохраняется; diagnostic и limitation; strict mode отклоняет |
| Nonliteral record defaults | Сохранены без internal probes; diagnostic и limitation; strict mode отклоняет |
| Unknown executable forms | Сохранить с видимой diagnostic/limitation либо отклонить в strict mode |

`strict => true` — default. `strict => false` явно принимает incomplete
instrumentation и выводит diagnostics в stderr, а также записывает их в manifest.
Internal coverage внутри skipped expressions не заявляется, даже если они
содержат поддерживаемые `case` или fun syntax. Feature selection остаётся у
compiler и source attributes `-feature`. Fixtures OTP 27 comprehension и `maybe`
сравниваются в ordinary и instrumented compilations.

Headers/macros обрабатываются EPP до transformation. Include file boundaries
сохраняются в manifest mappings. Annotations используют `erl_anno` APIs и
сохраняют columns, когда compiler их предоставляет. Probe IDs различают clauses
на одной строке. Transform генерирует abstract forms, никогда не source,
отредактированный regex.

Probes добавляются в начало original bodies без новых variables, wrappers или
code после existing tail calls. Original expressions не вычисляются повторно
и не перемещаются через exception boundaries. Receive timeout expressions
остаются на месте; selective matching и clause ordering неизменны. Тесты
сравнивают controlled mailbox contents, side effects, returns, exception
class/reason и relevant target stack frames. Transformed-AST test проверяет,
что recursive tail call остаётся последним; run на 20,000 шагов также завершается.

Это functional preservation для проверенных constructs, а не equivalence timing,
reductions, memory consumption, scheduling или inspection всех dictionary keys.
Targets не должны менять EFZ-owned context state или ETS rows. ETS public,
чтобы execution process мог вставлять data; это не security boundary внутри VM.

## Compilation и selection APIs

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

Сначала соберите EFZ (`rebar3 compile`) и поместите его ebin в code path compiler
VM. Facade обеспечивает загрузку transform. Compilation не запускает EFZ или
кампанию. Она использует `compile:noenv_file/2` с переданными options; ambient
`ERL_COMPILER_OPTIONS` намеренно исключён. Явно воспроизведите include, macro,
feature и code-path settings своего проекта. Relative paths относятся к working
directory вызывающей VM. Temporary code-path change восстанавливается при
возврате; facade calls должны сериализоваться внутри VM. Concurrent compilers
должны использовать разные output directories.

Другие parse transforms (включая source attributes `-compile`), output-mode
options и alternate output directories отклоняются вместо тихого запуска более
позднего transform за manifest. Record/type/spec attributes в остальном
сохраняются. Output directory не может быть source directory, активным code-path
directory или содержать ordinary BEAM artifacts. Files пишутся facade после
compilation, никогда не transform workers. Это source build path, а не
instrumenter произвольных prebuilt BEAM или Rebar3 plugin.

EFZ runtime/internal modules и modules из установленного OTP tree отклоняются.
Dependencies инструментируются лишь при явной компиляции и включении в allowlist.
Пример инструментирует ровно `efz_example_parser`; его adapter и все EFZ/OTP
modules остаются ordinary. Нельзя предполагать, что top-level Rebar3 profile
инструментирует dependency projects.

Artifact descriptor содержит `module`, `beam`, `manifest`, `build_id` и compiler
`warnings`. Preflight требует BEAM и sidecar files, проверяет schema и unique
probe entries, безопасно декодирует sidecar, сравнивает его exact term со
встроенным manifest, затем проверяет `efz_manifest` attribute загруженного модуля
и BEAM code checksum. Уже загруженный ordinary или different-build module
отклоняется. Automatic purge нет. Для смены builds используйте fresh VM либо
намеренно контролируемый unload без active users. На каждой iteration
compilation/loading/purging не выполняются. Harness и selected loaded identities
фиксируются при campaign preparation и проверяются executor. Hot replacement
во время case делает observation invalid, даже если original build
восстановлен. См. [контракт целостности](coverage-integrity.md).

## Manifest schema и воспроизводимость

Schema 1 / instrumentation version 1 встраивает этот map как `-efz_manifest(...)`:

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

Sidecar `my_parser.efz-manifest` — Erlang external-term encoding того же map.
`efz_cov_manifest:from_beam/1` извлекает авторитетный embedded map;
`identities/1` разворачивает identities. Разрешайте `{M,B,Id}` совпадением module,
build и `probe_id`, затем читайте source и structural location. Manifest
проверяет одну entry на ID и одну entry на structural path.

Build ID — SHA-256 instrumentation version, OTP release, compiler-module identity,
normalized preprocessed forms и relevant compiler options. Probe IDs —
deterministic integers, назначенные local ordered AST traversal; они никогда
не интерпретируются без module и build. Structural paths различают nested bodies
и same-line clauses. Нет timestamps, random compile IDs, global allocation
counters или малых hash namespaces.

Контракт: идентичные preprocessed source, relevant options и supported toolchain
дают идентичные probe identities. Сами output directory, code paths,
include-search paths, debug-info и warning presentation settings не меняют IDs;
expanded header/macro contents меняют. File attributes/annotation paths под
явным общим `source_root` нормализуются относительно него. Relocation этого root
с идентичным relative layout проверена. External headers с absolute names и
path-sensitive literals, например absolute `?FILE` expansions, всё ещё могут
менять IDs; они не переписываются так, будто runtime values идентичны.
Изменения line/column structure также могут менять build. Это identity stability,
а не обещание byte-identical BEAM metadata между directories.

Embedded build включает каждый probe; observations вне pinned manifests
отклоняются, feedback независимо проверяет complete build map. Новый build
требует новой кампании/calibration. Saved coverage никогда молча не переносится
между incompatible namespaces. Double instrumentation отклоняется.

## Execution APIs и ownership

```erlang
Result = efz_executor:run(my_target_adapter, Input, 100, #{
    coverage => automatic, manifests => Manifests
}).
% #{execution_ref := Ref, outcome := Outcome, target_outcome := TargetOutcome,
%   elapsed_us := Us, coverage := ExactIdentities, coverage_status := ok,
%   builds := #{my_parser => BuildId}}
```

`Outcome` — `{ok, Value}`, `{crash, Class, Reason, Stack}`, `{exit, Reason}` или
`{timeout, Milliseconds}`. Errors и throws сохраняют class/reason/stack; exit
exceptions сохраняют exit tuple Phase 1. Externally killed targets дают
`{exit, killed}`. Coverage читается после каждого outcome.
`{infrastructure, Reason}` и `coverage_status => {error, Reason}` отделены от
target bugs; `target_outcome` сохраняет observed target result, когда он есть.
Low-level `run/4` ожидает уже preflighted manifests. Campaign startup делает
preflight автоматически и требует `artifacts`; empty/manual fallback в automatic
mode не разрешён.

`efz_cov:open/0` создаёт `{efz_context,1,ExecutionRef,Table,Owner}` с unnamed public
ETS set. `attach/1` явно устанавливает его в executing process под
`'$efz_execution_context'`. `snapshot/1` и `close/1` принадлежат owner; executor
guardian выполняет их после наблюдения завершения root и всех controlled
descendants. Contexts имеют независимые references и tables. `efz_cov_rt:hit/1`
также обращается к независимому guardian-owned PID/context registry. Missing
dictionary context неактивен лишь вне executor-owned participant.
Lost/malformed context, invalid tables и caught hook exceptions дают sticky
infrastructure errors. `coverage_observation` отличает `valid_empty_coverage`
от сломанного observation; campaign `coverage_diagnostics` сообщает unused
artifacts. Optional `coverage_policy => strict` считает ошибкой completed campaign
без probes.

Coverage scope — **root плюс controlled descendants одного execution**.
`efz_target:spawn/1` и `spawn_link/1` допускают children через независимый guardian
до подключения shared coverage context и старта child code. Guardian собирает
snapshot после process DOWN и trace-delivery barriers. Plain local spawns
обнаруживаются, но отклоняются как dirty executions без притворства о полном
coverage. Background/remote OTP services остаются вне scope. См.
[execution lifecycle и dirty-VM policy](execution-isolation.md).

Manual compatibility явная: `coverage => manual`, `efz_cov:hit(Id)` записывает
`{manual,Id}`. `efz_executor:run/3` использует этот mode и возвращает старый outcome
tuple. Manual и automatic namespaces нельзя смешивать в кампании. Legacy
conveniences `reset_local/0`/`snapshot/0` process-local; ordinary callers должны
предпочитать explicit `open/attach/snapshot/close` и не сбрасывать executor-owned
context.

## Feedback и artifacts

Только один worker. Initial seeds используют тот же execution path и
инициализируют successful global set до mutations. `calibrations` отделён от
mutation `executions` и `discoveries`.

Novelty successful input — `Observed - Global`. New successful observations
объединяются; new binaries с непустой novelty входят в корпус. Repeats
отклоняются без false discoveries. Crashes/exits/timeouts сохраняются независимо,
**их coverage не объединяется с successful global set**. Это позволяет позднему
non-crashing input сохранить probes, ранее замеченные лишь в crash.

Каждый retention имеет input SHA-256, corpus identity, parent identity,
execution reference, newly seen identities, retention reason, phase и build map.
Final report `efz:await/1` включает decisions, corpus, crash records, stats и
successful coverage. Идентичные rejected executions суммируются counter.
Crash occurrences — atomic directories по пути
`crash_dir/SIGNATURE/OCCURRENCE/artifact.input`, `.term`, `.replay` и optional
`.recipe`, с group manifest. Raw `.term` сохраняет result metadata, включая
crash/timeout coverage. См. [crash/replay/report](replay.md). Эти term files —
local diagnostics, а не safe import format.

## Воспроизводимая validation и overhead

`rebar3 eunit --module=efz_phase2_tests` покрывает semantic comparisons, все
required probe kinds, unsupported syntax diagnostics, cross-module calls,
separate contexts, same-input repeatability, target kills, timeouts, owner death,
cancellation, backend failure, identity/relocation, preflight и feedback.
Termination tests ждут сообщение, отправленное после завершения ожидаемого entry
hook. Они не выводят факт исполнения probe из sleep. Deadline-boundary tests
принимают документированные completed-or-timeout outcomes и проверяют изоляцию
следующего execution. Plain/instrumented comparisons выгружают один module
лишь после завершения прежних target processes; self-qualified calls не
переименовываются.

`rebar3 ct` содержит три integration cases: deterministic automatic campaign,
artificial-crash coverage и synchronized timeout coverage. Scripted mutator
с пятью inputs находится только в `test/`; это не production mutator и не
заявление random fuzzing success. `examples/automatic/run.escript` также
запускает original random mutator Phase 1 на 500 iterations. См.
[записанную валидацию](phase2-validation.md).

После `rebar3 compile` выполните `escript scripts/coverage_bench.escript`.
Он загружает тот же fixture ordinary и instrumented в controlled sequence,
прогревает каждый path, затем измеряет семь samples по 200,000 tail-loop
iterations. Active measurements повторно используют один execution context,
показывая probe costs; это не end-to-end fuzz executions/second. Output включает
times, reductions, process memory snapshots, compilation times, exact ETS size
и число observed probes. Performance threshold не применяется. Benchmark
измеряет EFZ hooks, а не OTP cover.
OTP 27 / ERTS 15.0; x86_64-pc-linux-gnu. Fixture `efz_bench_fixture`, 200000 loop
iterations на sample, 7 repeats, 30,000 warmup iterations на mode.

| Mode | Медиана us | Relative | Samples us | Reductions (последний sample) |
|---|---:|---:|---|---:|
| ordinary | 518 | 1.00x | [619,517,517,517,530,518,518] | 200013 |
| instrumented_inactive | 5315 | 10.26x | [5315,4438,4260,4203,5532,5467,5581] | 1000017 |
| instrumented_active | 67209 | 129.75x | [71060,66993,67233,67125,67095,67232,67209] | 1401177 |

Active table: 419 words (8 bytes/word), 6 unique observed probes из 6 manifest
probes. Table удалена после measurement. Compilation: ordinary 3387 us;
instrumented 62202 us (single measurements, включает cold setup). Нет correctness
threshold. Process-memory snapshots находятся в `_build/coverage-benchmark.term`.

Измерения сделаны локально 2026-09-08. Крошечный ordinary loop сильно оптимизирован
и работает меньше миллисекунды, поэтому ratios нельзя экстраполировать на
настоящий parser. Active collection в этом run примерно в 12.6 раза медленнее
inactive instrumented path. ETS insert/copy path — измеримая cost; reductions
также выросли с 200,013 до 1,401,177. Last-sample process memory:
8,816 -> 8,816 bytes (ordinary), 13,704 -> 13,704 (inactive),
21,696 -> 55,176 (active); это snapshots, а не peak-memory estimates. Exact table
size оставался шесть entries несмотря на repeated hits; при completion table
удалена.

Следующий optimization candidate — execution-local already-recorded cache,
который пишет каждый first hit сразу в owner-held ETS до caching. Это могло бы
уменьшить duplicate inserts, сохранив coverage при abrupt target termination;
до внедрения нужны lifecycle и backend-failure tests. Текущая implementation
намеренно сохраняет каждый hit синхронным с external storage.

Current limits: один worker, одно execution с controlled descendants, source
compilation на tested toolchain, explicit selected modules и skipped syntax
выше. Other parse transforms, prebuilt-only binaries, arbitrary
background-process attribution, stateful OTP campaigns, full CFG/branch/state
coverage и isolation от всех shared VM или operating-system effects не
реализованы.

## Runtime choices и reporting Phase 2.1

Default backend `ets` теперь использует `ets:insert_new` и уведомляет guardian
при first insertion, позволяя обнаружить published observations, потерянные
из table. Opt-in path `ets_member` сначала проверяет `ets:member` и вставляет
только при отсутствии. **Нет process-local seen cache**, compact/hash ID,
sampling или delayed publication. Каждый hit всё ещё обращается к external
table; удаление backend после first hit не может превратить subsequent cached
hits в false success. First observations стоят lookup плюс insertion и могут
быть медленнее. Ни один backend не меняет instrumentation, manifests, build IDs
или source mappings.

Campaigns теперь по умолчанию один раз готовят exact allowed-probe set. Worker
владеет unnamed **protected** ETS table `efz_coverage_plan` с теми же identities,
которые прежний validator перестраивал на каждой iteration, плюс schema/mode/build
marker и selected loaded-module identities. Guardian проверяет marker и каждую
observed identity после root/descendant termination. Он получает лишь execution
options и plan handle, а не worker corpus/decision state и full source manifests.
Это shared immutable allowlist, а не reused coverage buffer. Observation tables
всё ещё fresh, public, execution-owned. Plans живут между executions и удаляются
с campaign worker; plan или observation reuse между кампаниями не реализован.
Invalid/deleted plans дают infrastructure failures, включая otherwise empty
snapshot.

```erlang
% Default campaign settings in Phase 2.1:
#{coverage_backend => ets, coverage_validation => prepared}.
% Per-execution manifest validation, retained for comparison:
#{coverage_backend => ets, coverage_validation => per_execution}.
% Optional duplicate-write suppression (compatible with either validator):
#{coverage_backend => ets_member, coverage_validation => prepared}.
```

Для low-level repeated `run/4` calls явно подготовьте plan после artifact preflight:

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

`prepare/2` проверяет manifest schema/instrumentation version, probe uniqueness,
непустой automatic selection и duplicate modules. Он не загружает и не изучает
artifacts: сначала вызовите `preflight/1`. Plan —
`{efz_cov_plan,1,Table,BuildMap}`; marker связывает coverage mode и builds.
Он backend-independent: оба ETS hooks публикуют те же exact identities.
Campaign configuration проверяет backend до старта worker.

Caller, владеющий plan, должен сохранять его живым до завершения executions.
На low-level API это read-only capability, которую можно передавать другим
execution callers и повторно использовать для тех же selection/builds.
Foreign callers не могут писать protected table. Он не привязан к одному
execution reference; привязано лишь observation storage. Освободите его из owner
после завершения всех users, либо owner termination автоматически удалит его.
Disposed table, changed build map, wrong mode или incompatible descriptor не
могут validate empty snapshot. Malformed descriptor versions не проходят
validation как infrastructure errors; это не target crashes. Valid plan другого
owner разрешён.

Campaign completion сохраняет worker и plan для reporting до `efz:stop/0` или
application shutdown. Новая кампания строит новый plan. Plans — не hot-reload
cache: selected code должен оставаться неизменным всю их жизнь. Preflight
отклоняет already loaded ordinary или different build; observation validation
отклоняет identities вне pinned set. Replacement кода после preflight на code,
не выдающий probes, не обнаруживается set validation. One-time preparation не
обещает correctness при arbitrary hot loading.

`run/4` только с `manifests` сохраняет per-execution validation для compatibility.
`efz_cov:open/0` сохраняет reference backend; `open(ets_member)` выбирает
альтернативу. Existing contexts сохраняют schema 1; в alternative context
storage slot содержит `{ets_member, Table}`. Context contents остаются EFZ-owned.

Reports различают четыре понятия, не меняя merge policy:

* `Result.coverage`: exact observations этого execution, включая observations
  до exceptions, external kills и timeouts.
* Campaign `coverage`: union successful calibration/execution observations.
* Saved crash `result.coverage`: observations crash; могут включать probes,
  отсутствующие в campaign `coverage`.
* Decision `new_probes`: novelty, подходящая для successful-corpus retention.
  Она намеренно `[]` для `retention_reason => target_failure`, даже когда crash
  наблюдал прежде unseen probe. Никакие crash-only observations не объединяются
  с successful coverage set.

Дополнительный report map `timing` содержит `calibration_started_at`
(monotonic microseconds), `calibration_us` и `mutation_us`. Последний исключает
calibration и final report construction/pretty-printing, но включает selection,
mutation, execution, validation, feedback, stats и crash artifact I/O. Это не
только target running time. Benchmark startup и cleanup сообщаются отдельно.

Optional `selection_seed` инициализирует selection RNG corpus process.
Существующий `random_seed` продолжает инициализировать mutator RNG worker.
Без `selection_seed` прежнее selection behavior неизменно; одно задание
`random_seed` не определяет кампанию полностью. Reproducible comparisons задают
оба либо replay-ят saved candidate stream. Benchmark replay code находится в
`bench/`, а не production mutator.

См. [profiling, измерения, tradeoffs и воспроизведение Phase 2.1](phase2.1-performance.md).
Таблица benchmark Phase 2 выше историческая, а не performance constant.

## Диагностические повторы

Opt-in [runtime diagnostics](runtime-diagnostics.md) сравнивает exact execution
probe sets, включая build identity. Verification coverage никогда не объединяется
с campaign global feedback; variable probes не маскируются. Invalid или unstarted
observations — не empty coverage. Valid empty series имеет repeatability и
stable-probe ratio 100% с явным marker.
