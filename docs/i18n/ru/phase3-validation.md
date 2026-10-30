# Валидация Phase 3: staged mutation и точный replay

[English](../../phase3-validation.md) · **Русский** · [Español](../es/phase3-validation.md) · [简体中文](../zh-CN/phase3-validation.md) · [Все языки](../README.md)

Phase 3 завершена для проверенного локального контракта: OTP 27.0, один worker,
один instrumented target execution process, фиксированные selected builds и
точное source-level clause/outcome coverage. Staged mutation — opt-in.
Эта phase добавляет byte mutation и replay, не меняя coverage implementation и
не возобновляя её performance study. Измерения ниже — observations, а не
acceptance constants.

## Baseline и provenance

До изменений изучен репозиторий, включая configuration, mutator/corpus/worker,
crash storage, executor, prepared validation и документы Phase 2/2.1.
Применимого `AGENTS.md` не было. Working tree уже содержал modified tracked files
и обширную untracked реализацию/evidence Phase 1–2.1. Эти изменения сохранены.
Не менялись reset, clean, staging, commit, push, remote или Git identity.

Baseline прошёл `rebar3 compile`, `rebar3 eunit` (38 tests), `rebar3 ct`
(3 cases), `rebar3 dialyzer`, `rebar3 xref` и `git diff --check`. Baseline failures
для переноса не было. Baseline logs находятся в `_build/phase3-baseline`;
полные command outputs также сохранены в durable validation record ниже.
Final results — 62 EUnit tests и те же 3 Common Test cases.

Среда: Ubuntu 24.04.4 LTS, Linux 6.8.0-nyx+, x86_64-pc-linux-gnu,
Intel Core i7-1260P, OTP 27.0 / ERTS 15.0, Rebar3 3.25.0. Project и example
compiler options — `[debug_info,warnings_as_errors]`; instrumentation facade
добавляет существующие strict parse-transform и column-location options.
Другие OTP versions не заявлены как tested. Dependencies не добавлялись.

Durable evidence, подходящее для `file:consult/1`:

* [performance/phase3-mutations.term](../../performance/phase3-mutations.term): все
  пять raw samples на mutation workload и campaign mode; normalized
  configurations, input/donor hashes, environment, compiler settings,
  artifact/build descriptor, current source SHA-256 identities, snapshots
  process/VM memory и reductions.
* [performance/phase3-validation.term](../../performance/phase3-validation.term):
  baseline и final check outputs, hashes 41 relevant source/config/test/script
  files, Phase 3 before/after file identities, acceptance/example reports,
  полный manifest, exact recipe и fresh-VM replay output. Runtime references
  в reports — diagnostic strings; bounded acceptance trace в этой durable copy
  опущен. Ни один recipe от этих references не зависит.
* [examples/staged-crash.recipe](../../examples/staged-crash.recipe) и
  [examples/staged-crash.input](../../examples/staged-crash.input): EFZR recipe
  размером 629 bytes и шесть авторитетных raw bytes проверенного примера.

Source hashes unprofiled benchmark сверены с итоговыми runtime, planner и
benchmark sources при экспорте evidence. Последнее изменение после measurement —
test assertion сравнения logging levels, затем ещё один успешный full EUnit run
и только documentation/evidence. Compiler, coverage hook, context ownership,
executor, feedback и manifest validator идентичны baseline. Transform получил
лишь четыре internal-module denylist entries; probe-generation algorithm и
version неизменны.

Final measurement directory — `_build/phase3-performance-verified`.
Ранние runs `_build/phase3-performance` и `_build/phase3-performance-final`
сохранены, но исключены из reported comparison: они предшествовали final source
provenance либо пересекались с другой local example activity. Verified run
завершился exit status 0, не использовал profiler и не пересекался с другой
Erlang task, запущенной assistant. Посторонняя host activity не контролировалась.

## Публичная совместимость и реализация

Campaign default остаётся `mutation_mode => random` с существующими random
mutator behaviour и legacy selector. Prepared validation и исходный ETS coverage
backend — defaults. `coverage_backend => ets_member` остаётся явным и работает
для campaigns и replay. Старый automatic example неизменён. Legacy mutator
exceptions/nonbinary returns теперь останавливают кампанию как infrastructure
failures, не считаясь target bugs.

`mutation_mode => staged` включает новый map `mutation`. Он отклоняет
пользовательский legacy callback и mutation options, случайно переданные в
random mode. Отсутствующий staged `max_iterations` имеет default 1,000, максимум
1,000,000; явный infinity отклоняется. Calibration считается отдельно.
Другие bounds, вся operator semantics и ordering — в [mutations.md](mutations.md).

Native operators: contiguous 1/2/4-bit flips; aligned 1/2/4-byte inversion;
8/16/32-bit arithmetic с явным wrapping и выбором endian; versioned integer
boundary patterns; literal overwrite/insertion; непустые deletion и block
duplication; dictionary overwrite/insertion; content-identified splicing;
bounded stacks этих concrete operations (havoc).

Pure application, operation choice, per-content stage state, donor/seed selection
и execution разделены. Deterministic stages — lazy integer cursors. Corpus rounds
и stage lanes явны и ограничены; рост корпуса не может откладывать старые entries
бесконечно. Skipped operations продвигают cursors или RNG state, finite
attempt/idle limits предотвращают retry loops без execution progress.
Dictionaries/configuration фиксированы внутри кампании. `exsplus` использует
explicit state-threading APIs; logging/target randomness не расходуют это state.

Retention добавляет versioned recipe к existing corpus/crash metadata. Default
rejection handling не хранит full recipe бесконечно; optional trace ограничен.
Recipes содержат actual primary/donor/token bytes и ordered operations, а не
только RNG state. EFZR import path проверяет bounded data-only format до ETF
decoding. Byte regeneration не требует ни target, ни plan. Execution replay
требует artifacts/target, выбранных caller, и compatible builds, готовит новый
validation plan и вызывает existing executor. См. [replay.md](replay.md).

## Конкретное coverage и replay evidence

Обычный `examples/staged/efz_staged_parser.erl` содержит после selected compilation
семь function-clause probes без EFZ API calls в source. Все observations ниже
используют build:

```text
4c53c8d203bf5fca774d78fee2122a75419b86ba8f807cc3ffbb5d96339e0a5e
```

Deterministic integration test использует настоящие production stages
`[dictionary_insert,boundary,arithmetic]`, seed `{17,23,41}`, primary seed `<<0>>`
и budget 200 executions. Старый scripted test mutator не используется.
Calibration сначала наблюдает probe 5 и не является mutation discovery.

| Сохранённые bytes | Parent | Realized operation | Новый probe / source | Decision |
|---|---:|---|---|---|
| `<<"TOKEN",0>>` | Entry 1, `<<0>>` | `{dictionary_insert,0,<<"TOKEN">>}` | 1, `run/1`, line 4, column 1 | `new_coverage` |
| `<<128>>` | Entry 1, `<<0>>` | `{set_integer,0,8,big,128}` | 3, `run/1`, line 6, column 1 | `new_coverage` |

Integration report завершился с 1 calibration, 200 mutation executions,
4 discoveries, 191 equivalent-coverage rejections, 5 crash observations,
одной fingerprint group и нулём infrastructure failures/timeouts. Тесты также
проверяют discovery после первого artificial crash и восстанавливают exact bytes
retained entries из recipes. Probe numbers этого документа — manifest observations;
ни fixture IDs, ни retention exceptions не захардкожены в fuzzer core.

Full example дополнительно включает havoc/splice. Он завершил 200 executions
с 5 discoveries, 188 rejections, 7 crash observations, одной fingerprint group
и нулём infrastructure failures/timeouts. Counters различают 243 visits,
233 mutation attempts, 320 constituent-operation attempts, 72 skipped operations,
43 visits без candidate и 200 generated/executed candidates. Totals operation
skip-reason также включают final canceled stacks, поэтому не равны
skipped-operation count.

Сохранённые artificial crash bytes — `<<"BOOM!",0>>` (hex `424f4f4d2100`), SHA-256:

```text
1732ef36d864988423a5275aec30b90b55e3405cc798c709e318c867797ad64b
```

Fresh-VM regeneration и `cmp` воспроизвели все шесть bytes. Отдельная fresh VM
скомпилировала explicit target, загрузила expected builds сохранённого recipe,
исполнила raw input и вернула
`{crash,error,artificial_staged_exception,Stack}` с `coverage_status => ok` и
exact probe 2. Stack указывает на target line 5. Это подтверждает и byte
reconstruction, и actual deterministic example outcome; это не обещание для
time-sensitive targets.

Probe 2 переживает target termination в crash result. Failure decision имеет
`retention_reason => target_failure, new_probes => []`, а successful-corpus
coverage исключает probe 2. Такова existing policy: crash observations не
подавляют будущую successful novelty. Crash groups — fingerprints, а не proven
independent bugs.

Legacy automatic example также завершился неизменённым в random mode:
500 executions, 1 calibration, 5 discoveries, 493 rejections, 2 crash observations,
одна fingerprint group, ноль infrastructure failures/timeouts. Это observations
этого run; его default unseeded corpus selection не обязан совпадать с прежними
reports.

## Ограниченная стоимость mutation

Воспроизведение из корня репозитория:

```sh
rebar3 compile
ERL_FLAGS='+S 4:4' escript bench/mutations.escript _build/phase3-performance-reproduce
```

Verified run использовал `+S 4:4` (четыре online schedulers). Driver прогревает
каждый case полной batch из 5,000 candidates и сверяет каждую realized operation
sequence с её output. Каждая из пяти timed batches начинает новый planner с той
же normalized configuration и сверяет count, visit count и consumed CRC32 stream
с warmup. Configuration/dictionary normalization и fixture construction вне
mutation-only timing. Candidate hashing, operation planning/application,
provenance construction и CRC consumption внутри. Full EFZR encoding и target
execution вне этих microbenchmarks. Machine-specific performance thresholds в
тестах отсутствуют.

У каждого workload два статических разных inputs: повторяющиеся bytes `0,1,2,3`
указанного размера и donor с инвертированным первым byte. Input limit 4,096;
прочие defaults включают block 128, depth 8, delta 8, tokens `TOKEN`/`BOOM!` и
seed `{17,23,41}`. Все samples действительно сгенерировали 5,000 candidates.
Short/medium/near limit используют bitflip/arithmetic/havoc; dictionary — оба
dictionary stages; splicing и havoc — соответствующий единственный stage.
Эти mutation-only runs не имеют target/probe observations или manifest scans.

| Mutation workload | Input bytes | Медиана µs / 5,000 | Min–max µs | Candidates/s |
|---|---:|---:|---:|---:|
| Short | 4 | 37,396 | 36,364–39,283 | 133,704 |
| Medium | 1,024 | 32,538 | 30,792–34,778 | 153,667 |
| Near configured maximum | 4,095 | 55,712 | 55,276–57,220 | 89,747 |
| Dictionary insertion/overwrite | 1,024 | 17,950 | 16,884–22,325 | 278,552 |
| Splicing | 1,024 | 25,986 | 25,224–27,787 | 192,411 |
| Havoc | 1,024 | 51,818 | 48,236–51,889 | 96,492 |

Более короткий mixed workload в этом sample не быстрее medium: отличаются
applicable operations, retries и intermediate resizing. Это workload results,
а не утверждения о scaling только по размеру. Raw durations сохранены в `.term`
evidence.

## Ограниченное сквозное сравнение

Оба modes используют тот же ordinary example с семью probes, initial seed `<<0>>`,
timeout 100 ms, original ETS hook, prepared validation и **500 mutation target
executions**, с одной calibration. Driver отбрасывает pilot 100 executions на
mode и чередует mode order пять rounds. Compilation (единственное наблюдение
8,921 µs) и final printing вне campaign mutation timing. Compilation — одно
startup observation, а не повторяемая performance estimate.

Legacy random использует `random_seed => {17,23,41}` и
`selection_seed => {101,109,113}`. Staged использует тот mutation seed, пять stages
примера, max input 64, block/token 16, havoc depth 4 и два inline tokens.
Configurations намеренно не заставляют legacy mode принять новые limits.

| Mode | Raw mutation times µs | Медиана µs | Min–max µs | Executions/s | Discoveries | Successful probes | Crashes / groups |
|---|---|---:|---:|---:|---:|---:|---:|
| Existing random | 9169, 9916, 7503, 7786, 7257 | 7,786 | 7,257–9,916 | 64,218 | 4 | 5 / 7 | 0 / 0 |
| Staged | 14965, 17455, 15749, 16198, 15339 | 15,749 | 14,965–17,455 | 31,748 | 5 | 6 / 7 | 14 / 1 |

Counts стабильны во всех пяти samples каждого mode. Staged дополнительно достиг
dictionary branch; crash probe остался вне successful coverage. В обоих ноль
infrastructure failures/timeouts. Calibration medians — 55 µs random и 56 µs
staged. Full `start`/`await`/`stop` API medians, включая preparation/report
delivery/cleanup, — 8,883 и 17,127 µs соответственно. Full API raw samples и
calibration durations записаны отдельно.

Staged mutation заняла **2.02 раза** mutation-phase wall time random на этом
небольшом fixture (около 49.4% его execution throughput). Это включает другой
candidate stream, более богатую mutation/provenance work, больше scheduling
visits и 14 crash observations с artifact writes. Это не same-input
executor/backend comparison. Extra example discovery не доказывает universal
superiority; нет performance target или coverage gain guarantee. Никакие
Phase 2.1 hook или complete-executor performance numbers не переосмысляются
по этому experiment.

## Наблюдения памяти и cleanup

Mutation benchmark записывает process memory и total VM memory до каждой batch,
после timed batch и после явного garbage collection; reads вне timed interval.
Он также записывает reductions; это не allocated bytes. Post-GC samples удерживают
driver, inputs/configurations и предыдущие sample summaries, а completed planner
state/candidates уже не удерживаются. Одна process memory не включает все
referenced off-heap binaries.

| Workload | Post-batch process bytes (range) | Post-GC process bytes (range) | Медиана reductions / batch |
|---|---:|---:|---:|
| Short | 29,552–42,416 | 8,816 | 3,935,059 |
| Medium | 47,184–68,056 | 13,704 | 5,853,867 |
| Near limit | 47,184–62,992 | 13,704–21,608 | 16,006,728 |
| Dictionary | 101,368–142,760 | 21,608 | 3,815,738 |
| Splicing | 89,720–123,048 | 21,608–34,400 | 5,981,997 |
| Havoc | 76,096–110,048 | 34,400 | 8,022,823 |

Observed post-GC VM totals по workloads: 51,106,240–51,261,888 bytes. Они не обязаны
возвращаться к идентичному значению. Это snapshots, а не absolute peak memory или
полное исследование campaign retained-memory. Из VM totals не выводится leak
claim. Existing lifecycle tests отдельно доказывают release execution
tables/processes после normal completion, timeout, cancellation, caller death
и application shutdown. Finished campaign всё ещё владеет plan, corpus, retained
recipes, decisions и optional trace до `efz:stop/0`; execution observations
отдельно выделяются и очищаются, как в Phase 2.1.

Planner копирует minimal corpus view и хеширует content при scheduling;
splicing сканирует и сортирует различные donor contents. Поэтому large corpora
и большие embedded donors могут стоить больше времени и retained recipe storage.
Никакая unmeasured optimization или buffer reuse не вводилась, чтобы скрыть
эти costs.

## Команды регрессии и результаты

Все команды ниже завершились exit status 0 в этом working tree:

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

* Compile: pass, warnings считаются errors.
* EUnit: **62 passed**, включая 15 mutation tests, 3 recipe tests и 6 grouped
  Phase 3 acceptance tests. Existing transform semantics, exact canonical
  backend differential, prepared-plan negatives, error/throw/exit,
  synchronized kill и timeout survival, context separation, deadline boundary,
  caller death, cancellation/shutdown и repeated resource-lifetime checks
  проходят.
* Common Test: **3 passed**.
* Dialyzer: pass, проанализировано 26 project modules, проверено 278 PLT files.
* Xref и whitespace check: pass. Formatter/linter не настроен.
* Inline-dictionary campaign/save/regenerate/execute snippet из README также
  выполнен в fresh VM и прошёл. File-dictionary script выше покрывает другой
  public configuration path.

Existing negative tests намеренно логируют malformed-plan process errors и
unsupported-AST diagnostics; они проверяют infrastructure/error classification
и проходят. Это не новые failing checks. Final EUnit rerun следовал за добавлением
logging-level test; другие final checks применимы, поскольку relevant runtime
source после успешного run не менялся. Ни один baseline failure не скрывался
изменением expected coverage/outcome sets.

Для независимого исполнения durable saved crash bytes в fresh VM:

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

Ordinary example и regeneration commands без `ERL_FLAGS` выше использовали ambient
runtime settings, а не подразумеваемую configuration четырёх schedulers.
Performance run явно фиксирует четыре schedulers. Fresh-VM EUnit replay tests
явно используют два schedulers; все throughput measurements profiler-free.

## Файлы, изменённые в этой phase, и ограничения

Новые runtime modules: `efz_mutation`, `efz_mutation_plan`, `efz_dictionary`,
`efz_recipe`. Интеграция через `efz_config`, `efz_corpus`, `efz_worker`,
`efz_crash`; internal denylist transform расширен. Новые tests:
`efz_mutation_tests`, `efz_recipe_tests`, `efz_phase3_tests`. Добавлены staged
ordinary parser, dictionary/example runner, byte-regeneration CLI и bounded
mutation benchmark. Обновлены README/architecture и добавлены mutation/replay/
validation docs и compact evidence. Existing unrelated source, configuration и
evidence Phase 2.1 сохранены.

Оставшиеся ограничения намеренны: только byte-oriented mutation, один production
worker, in-memory stage state, нет full campaign checkpoint, adaptive schedule,
automatic token extraction, minimization или grammar/stateful fuzzing. Budgets
input, dictionary, stack и campaign ограничивают работу, но высокие configured
maxima всё ещё дороги. Recipes — bounded data artifacts, а не authenticated files.
Для кампании нужны fixed selected builds; regeneration сама по себе не доказывает
outcome reproduction, replay не разрешает arbitrary hot replacement.
Arbitrary child processes, shared VM state и native/OS effects остаются вне
target-process coverage/cleanup contract. Никакой required validation result
не заблокирован и не недоступен в этой среде.
