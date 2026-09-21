# Карта репозитория EFZ: директории и файлы

Назначение каждого файла сверено с рабочим деревом **15 сентября 2026 года**.
Корень в этом документе — каталог `efz/`; соседние checkout, например `../cowboy/`,
не являются частью EFZ. Описание охватывает **167 файлов проекта**, включая этот
документ, и **19 подкаталогов**. Учитываются исходники, ещё не добавленные в Git,
тесты, примеры, документация и сохранённые доказательства проверок.

Для каждого файла ниже приведены назначение и реализуемая функция либо, для
данных, их содержание и потребитель. Внутренности Git и изменяемые результаты
сборки описаны отдельно по типам: имена тестовых каталогов, логи и BEAM-файлы
генерируются заново и не входят в число 167 файлов проекта.

Связи компонентов, владельцы состояния и UML находятся в
[описании архитектуры](architecture.md). Эта карта отвечает на вопрос «где что
находится», а архитектура — «как это работает вместе».

## Навигация

- [Дерево каталогов и корневые файлы](#root)
- [src — runtime и сборка instrumentation](#src)
- [scripts — пользовательские команды](#scripts)
- [test — автоматические проверки](#test)
- [fixtures — цели и данные для проверок](#fixtures)
- [examples — демонстрационные интеграции](#examples)
- [bench — измерения производительности](#bench)
- [docs — документация, UML и архивы](#docs)
- [Генерируемые и служебные файлы](#generated)
- [Как найти место для изменения функциональности](#changes)

<a id="root"></a>
## Дерево каталогов и корневые файлы

```text
efz/
├── src/                      runtime, контракты и instrumentation
├── scripts/                  подготовка, CLI campaign/replay и coverage benchmark
├── test/                     EUnit и Common Test
├── fixtures/                 искусственные targets для тестов
│   ├── include/              include-файл для проверки компиляции
│   └── performance/          parser и sparse target для benchmarks
├── examples/                 самостоятельные примеры использования
│   ├── automatic/            random campaign с automatic coverage
│   ├── simple_parser/        обычный parser и минимальный harness
│   ├── staged/               staged campaign, dictionary и crash replay
│   │   └── corpus/           пять raw seeds для quickstart
│   └── cowboy/               интеграция с внешним Cowboy/Cowlib
├── bench/                    драйверы измерений, профилирования и отчётов
├── docs/                     архитектура и контракты подсистем
│   ├── adr/                  решения об архитектуре
│   ├── diagrams/             Mermaid-исходники UML и готовые SVG
│   ├── examples/             сохранённая пара crash input + recipe
│   ├── performance/          зафиксированные результаты измерений
│   └── audit-2026-09-12/     исторические диагностики и их результаты
├── _build/                   генерируемые сборки, тестовые данные и логи
└── .git/                     служебное состояние Git
```

| Файл | За что отвечает | Содержимое и использование |
|---|---|---|
| [.gitignore](../.gitignore) | Исключения для Git | Исключает `_build`, BEAM, PLT, логи, crash dumps, Erlang cookie и файлы редакторов. Это правила учёта файлов, а не конфигурация fuzz campaign. |
| [LICENSE](../LICENSE) | Лицензия проекта | Текст Apache License 2.0; соответствует идентификатору лицензии в `efz.app.src`. |
| [README.md](../README.md) | Главная точка входа в документацию | Сборка, launcher, harness, instrumentation, staged mutation, replay и ссылки на подробные контракты. |
| [rebar.config](../rebar.config) | Сборка и проверки Rebar3 | Минимум OTP 27, `debug_info`, warnings as errors, EUnit, Xref и Dialyzer. В `src_dirs` включены `src` и `examples/simple_parser`; внешних Erlang-зависимостей нет. |
| [rebar.lock](../rebar.lock) | Фиксация зависимостей | Сейчас содержит `[]`: закреплённых внешних Rebar-зависимостей нет. Файл обслуживает Rebar3. |

<a id="src"></a>
## src — runtime и сборка instrumentation

Каталог [src/](../src/) содержит **34 файла** основного приложения. Файл модуля
не обязательно означает отдельный процесс: `gen_server` явно отмечены ниже;
mutator, feedback, recipe и filesystem helpers вызываются как обычные функции.

### Запуск, конфигурация и управление campaign

| Файл | За что отвечает | Реализуемая функциональность и участие в runtime |
|---|---|---|
| [efz.app.src](../src/efz.app.src) | OTP application descriptor | Имя и версия приложения, callback `efz_app`, зарегистрированные сервисы, зависимости `kernel`, `stdlib`, `crypto`. Rebar3 формирует из него `efz.app`. |
| [efz.erl](../src/efz.erl) | Публичный Erlang API | `start/1` запускает application и campaign; `await/1` ждёт отчёт, `stats/0` читает статистику, `stop/0` завершает campaign и приложение. |
| [efz_app.erl](../src/efz_app.erl) | Lifecycle OTP application | Callback `start/2` создаёт `efz_sup`; `stop/1` завершает application callback. Не содержит mutation loop. |
| [efz_sup.erl](../src/efz_sup.erl) | Корневой supervisor | Начинает с пустого списка children; `efz:start/1` добавляет временный `efz_fuzzer`. Стратегия `one_for_all` с нулевой интенсивностью рестартов не восстанавливает campaign state. |
| [efz_cli.erl](../src/efz_cli.erl) | Универсальный launcher | `main/1` разбирает опции, читает raw seeds с лимитом, проверяет пути и artifacts, вызывает `efz:start/1`, сохраняет `report.term`, возвращает exit code. Собственного fuzzing engine нет. |
| [efz_config.erl](../src/efz_config.erl) | Строгая campaign schema | `prepare/1` проверяет известные ключи, `run/1`, workers, лимиты, mutation config и coverage artifacts; загружает durable corpus и формирует нормализованную конфигурацию. `function` и `arity` не поддерживаются. |
| [efz_fuzzer.erl](../src/efz_fuzzer.erl) | Campaign coordinator, `gen_server` | Создаёт связанные corpus, stats и worker supervisor; следит за worker, обслуживает `await`, собирает итоговый report и останавливает сервисы. Отдельный input исполняет executor. |
| [efz_worker_sup.erl](../src/efz_worker_sup.erl) | Supervision worker | Создаёт один temporary `efz_worker` под `one_for_one`. Название не означает реализованный параллельный pool: campaign schema допускает только `workers => 1`. |
| [efz_worker.erl](../src/efz_worker.erl) | Основной fuzz loop, `gen_server` | Calibration всех seeds → scheduling → mutation → executor → feedback → corpus/crash storage. Владеет global coverage, staged cursor/RNG, crash groups/counters и bounded representatives, mutation trace и решениями; обрабатывает инфраструктурные ошибки. |
| [efz_stats.erl](../src/efz_stats.erl) | Счётчики, `gen_server` | `inc/1`, `failure/1` и `get/0` обслуживают executions, calibrations, discoveries, rejections, crash occurrences/groups, timeouts и infrastructure failures; первая infrastructure cause сохраняется отдельно. Mutation-specific counts принадлежат planner/worker. |

### Harness, input и исполнение

| Файл | За что отвечает | Реализуемая функциональность и участие в runtime |
|---|---|---|
| [efz_target.erl](../src/efz_target.erl) | Контракт harness | Behaviour с callback `run(binary()) -> term()`. Пользовательский модуль реализует callback, config проверяет экспорт. Также предоставляет `spawn/1`, `spawn_link/1` для controlled descendants и `dirty/1` для декларации внешних эффектов. |
| [efz_input.erl](../src/efz_input.erl) | Общий предел размера input | `check/3` проверяет binary и inclusive limit; `read_file/3` ограничивает чтение файлов. Default 4096, допустимый предел 0..1048576; bytes не обрезаются. Используется ingestion, corpus, executor, mutations, replay и crash storage. |
| [efz_executor.erl](../src/efz_executor.erl) | Исполнение одного input | `run/4` создаёт независимого guardian; coordinator классифицирует root. Возврат после final cleanup result и guardian DOWN; при потере guardian VM помечается dirty. `run/3` — compatibility wrapper. |
| [efz_guardian.erl](../src/efz_guardian.erl) | Lifecycle ownership | Владеет root/controlled descendants, start gates, monitors, observation ETS и trace barriers. Выполняет cleanup независимо от caller/coordinator, проверяет shared-state violations, запрещает reuse dirty VM. |

### Coverage: компиляция, runtime hooks и feedback

| Файл | За что отвечает | Реализуемая функциональность и участие в runtime |
|---|---|---|
| [efz_instrument.erl](../src/efz_instrument.erl) | Сборка и загрузка instrumented artifacts | `compile/2` компилирует выбранные исходники в отдельный outdir; `discover/1`, `load/1`, `preflight/1` находят и проверяют BEAM/sidecar, build identity и загружаемый код. Выполняется до campaign, не на каждой мутации. |
| [efz_instrument_pt.erl](../src/efz_instrument_pt.erl) | Compiler `parse_transform` | Обходит Erlang AST, вставляет clause/outcome probes, создаёт build ID и source manifest. Проверяет allowlist, повторную instrumentation и неподдержанную syntax; strict mode отклоняет неполное покрытие. |
| [efz_cov_manifest.erl](../src/efz_cov_manifest.erl) | Manifest и допустимое пространство coverage | Проверяет schema и probe identities, извлекает embedded manifest, сопоставляет observed probes с builds. `prepare/2` создаёт переиспользуемый validation plan с protected ETS; `release/1` освобождает его. |
| [efz_cov_integrity.erl](../src/efz_cov_integrity.erl) | Целостность coverage observation | Pins loaded harness/build identities, independent protected PID/context registry, context/code-load traces и классификация valid empty / broken observation. |
| [efz_cov_rt.erl](../src/efz_cov_rt.erl) | Runtime hook вставленных probes | `hit/1` сверяет process-dictionary context с PID registry и пишет probe в ETS set; поддерживает `ets` и `ets_member`. Вне executor hook может быть inactive; context/table error и первый insert уведомляют guardian. |
| [efz_cov.erl](../src/efz_cov.erl) | Execution coverage context | `open`, `attach`, `snapshot`, `detach`, `close` управляют таблицей одного исполнения. Также содержит set merge и manual compatibility helpers `hit/1`, `reset_local/0`, `snapshot/0`, `interesting/2`; решение runtime принимает `efz_feedback`. |
| [efz_feedback.erl](../src/efz_feedback.erl) | Новизна покрытия | `evaluate/3` проверяет builds/status и вычисляет `Observed − Global`. Для успешного execution возвращает новое состояние и `new_probes`/`retention_reason`; ошибки target не расширяют global coverage. Состояние хранит worker. |

### Corpus и постоянное хранение

| Файл | За что отвечает | Реализуемая функциональность и участие в runtime |
|---|---|---|
| [efz_corpus.erl](../src/efz_corpus.erl) | Active corpus, `gen_server` | Владеет binary entries, integer IDs и metadata. `add/2` дедуплицирует discoveries и при включённом store сохраняет их до подтверждения вставки; `select/0` выбирает random parent, `mutation_entries/0` передаёт entries staged scheduler. |
| [efz_corpus_store.erl](../src/efz_corpus_store.erl) | Durable reusable corpus | `save/4` сохраняет exact input и checksummed metadata под SHA-256 content hash. `restore/3,4` проверяет schema, целостность, input limit и build policy; возвращает inputs для новой calibration. Старые cursor, RNG, coverage и integer IDs не восстанавливает. |
| [efz_crash.erl](../src/efz_crash.erl) | Crash identity и artifacts | `identify/3` разделяет random occurrence ID, content hash и normalized signature v2; `remember/3` ведёт count и bounded representatives. `save/4` сохраняет raw input/Reason/recipe/expectation выбранных representatives; каждый committed occurrence учитывается в durable summary. Ошибочная recipe не блокирует сохранение выбранного raw input. Возвращает structured errors с identities и primary cause. |
| [efz_crash_store.erl](../src/efz_crash_store.erl) | Bounded disk crash store | Первые N различных inputs на signature, immutable artifacts и EFZG summary с durable count. Exclusive directory lock исключает одновременных writers из разных VM; cap переживает restart. Corrupt/unindexed/interrupted state даёт явную ошибку. |
| [efz_fs.erl](../src/efz_fs.erl) | Общие filesystem primitives | Ограниченное чтение, создание каталогов, запись/sync/close, `atomic_file/2` и `atomic_group/3`. Temporary staging + rename публикуют данные; group manifest проверяет целостность. Ошибки содержат operation/path/reason, secondary cleanup не заменяет primary failure. |

### Mutation и replay

| Файл | За что отвечает | Реализуемая функциональность и участие в runtime |
|---|---|---|
| [efz_mutator.erl](../src/efz_mutator.erl) | Контракт callback mutator | Behaviour `mutate(binary(), map()) -> binary()` для random/callback path. Staged engine вызывается worker через отдельный planner API. |
| [efz_mutator_random.erl](../src/efz_mutator_random.erl) | Встроенный random mutator | Flip, overwrite, insert и delete с ограничением размера; поддерживает seed RNG. Это действующий default Erlang API, а не мёртвый код. При полном input выбирает допустимую операцию, не создавая oversized bytes. |
| [efz_mutation_plan.erl](../src/efz_mutation_plan.erl) | Lazy staged scheduler | `prepare/2`, `new/1`, `next/2` ведут cursors родителей и stages, RNG, donors, skips и progress guard; генерируют по одному candidate. Подхватывает growing corpus и различает true exhaustion и idle stop; не материализует всё пространство mutations. |
| [efz_mutation.erl](../src/efz_mutation.erl) | Детерминированные byte operations | Применяет конкретные flip/integer/block/dictionary/splice операции, проверяет offsets и limits, возвращает bytes, skip или error. Используется и planner, и recipe replay; собственных случайных решений не принимает. |
| [efz_dictionary.erl](../src/efz_dictionary.erl) | Dictionary ingestion | `normalize/2` проверяет, сортирует и дедуплицирует binary tokens, вычисляет identity; `load/2` ограниченно читает hex-файл с комментариями. Это собственный формат EFZ, не parser Erlang expressions или AFL dictionaries. |
| [efz_recipe.erl](../src/efz_recipe.erl) | Exact mutation provenance и replay | `make/4` фиксирует primary/donor bytes и hashes, parent, operations, limits и builds. Encode/decode/load/save обслуживают EFZR envelope; regenerate восстанавливает bytes, execute/execute_file запускают их через executor с явными target/builds и обязательной ожидаемой harness identity. |
| [efz_replay.erl](../src/efz_replay.erl) | Verified execution replay | EFZX expectation codec, portable harness identity, проверка input hash, полного build set и harness; raw/recipe запускаются через существующий executor, signature определяет reproduced/not-reproduced. |
| [efz_replay_cli.erl](../src/efz_replay_cli.erl) | Replay CLI | Парсит `--input/--recipe`, explicit target/artifacts/code paths/expectation; выводит verdict, различает exit codes 0/3/2/1. Сохраняет старый режим только byte regeneration. |

<a id="scripts"></a>
## scripts — пользовательские команды

Каталог [scripts/](../scripts/) содержит **4 escript**. Launcher и replay находят
скомпилированный EFZ относительно собственного пути; coverage benchmark рассчитан
на запуск из корня репозитория. `prepare.escript` сам выполняет сборку; для остальных
скриптов она должна быть выполнена заранее.

| Файл | За что отвечает | Что делает при запуске |
|---|---|---|
| [fuzz.escript](../scripts/fuzz.escript) | Универсальная команда fuzzing | Находит application ebin, загружает `efz_cli`, передаёт аргументы в `main/1` и завершает VM с его exit code. При отсутствии сборки выводит понятную ошибку. |
| [prepare.escript](../scripts/prepare.escript) | Сборка и подготовка первого запуска | Проверяет OTP/Rebar3, собирает EFZ, инструментирует staged parser, копирует raw corpus без перезаписи отличающихся seeds; печатает команду общего CLI. Сам campaign не запускает. |
| [replay.escript](../scripts/replay.escript) | Тонкая оболочка replay CLI | Подключает compiled EFZ ebin относительно script и вызывает `efz_replay_cli:main/1`; target не выбирается из recipe или diagnostic artifact. |
| [coverage_bench.escript](../scripts/coverage_bench.escript) | Исходный coverage microbenchmark | Сравнивает обычный target, instrumented inactive и active ETS hooks на `efz_bench_fixture`; сохраняет samples, memory и compile timing в `_build/coverage-benchmark.*`. Не является launcher. |

<a id="test"></a>
## test — автоматические проверки

Каталог [test/](../test/) содержит **20 файлов**. `*_tests.erl` запускаются через
`rebar3 eunit`, `efz_coverage_SUITE.erl` — через `rebar3 ct`. Helpers с `run/1`
внутри тестов служат тестовыми harness; их экспорт не делает их runtime сервисами.

| Файл | Проверяемая функциональность | Существенное отличие / сценарий |
|---|---|---|
| [efz_config_tests.erl](../test/efz_config_tests.erl) | Строгая schema и target contract | Неизвестные ключи, неверные значения, отсутствующий `run/1`, пустой corpus и возможность старта из persistent inputs. |
| [efz_cli_tests.erl](../test/efz_cli_tests.erl) | Launcher в свежих Erlang VM | External harness, raw seeds, staged/random, durable corpus, help, неверные модули/пути/artifacts/options, input bounds, crash, timeout и exit codes инфраструктурных ошибок. |
| [efz_crash_tests.erl](../test/efz_crash_tests.erl) | Occurrences, signatures и verified replay | Разные inputs одной signature, Reason policy, relocation, 1000 occurrences при bounded report, raw/recipe в новых VM, build/harness mismatch, corrupt/unreadable artifacts, primary coordinator/worker failure и stats. |
| [efz_crash_retention_tests.erl](../test/efz_crash_retention_tests.erl) | Disk retention и поздний сбой guardian | Проверяет disk cap/duplicates/raw Reason, две campaigns в разных VM, replay retained input, corrupt summary, отказ commit, concurrent/interrupted writer. Test-only AST gate после настоящего guardian reply доказывает сохранение первичной ошибки в report/stats и запрет reuse. |
| [efz_integrity_tests.erl](../test/efz_integrity_tests.erl) | Coverage integrity | 22 regression scenarios: zero-hit/disconnected/unused, strict policy, dictionary/ETS corruption, caught hooks, child, reload/restore, harness pin, prepared plan и direct ERTS loading. |
| [efz_isolation_tests.erl](../test/efz_isolation_tests.erl) | Guardian и controlled descendants | Root/child/nested lifecycle, timeout/trap_exit, caller/coordinator death, registrations/ETS, fresh VM dirty policies, guardian loss и запрет reuse. |
| [efz_executor_tests.erl](../test/efz_executor_tests.erl) | Базовый execution contract | Короткие проверки `run/3`: return, error, exit и timeout. Это compatibility path; automatic coverage подробнее проверяется другими suites. |
| [efz_phase2_tests.erl](../test/efz_phase2_tests.erl) | Automatic instrumentation и executor | Сравнивает обычную/instrumented семантику, probe kinds, manifests/build IDs, includes/options, tail calls, strict syntax, контексты, crash/kill/timeout coverage и отмену campaign. |
| [efz_backend_tests.erl](../test/efz_backend_tests.erl) | Эквивалентность coverage вариантов | Сопоставляет `ets`/`ets_member` и prepared/per-execution validation: exact probes, outcomes, novelty, жизнь validation plan, ошибки backend, caller death и cleanup. |
| [efz_coverage_SUITE.erl](../test/efz_coverage_SUITE.erl) | Common Test интеграция | Три сценария: automatic campaign, coverage при crash и timeout. Campaign использует scripted fixture; доказательство реального многошагового parent reuse находится в отдельном feedback-loop тесте. |
| [efz_mutator_tests.erl](../test/efz_mutator_tests.erl) | Базовый random mutator | Проверяет возвращаемый binary для непустого и пустого primary. Общий campaign limit проверяется в `efz_limits_tests`. |
| [efz_mutation_tests.erl](../test/efz_mutation_tests.erl) | Byte operators и staged planner | Модели операций, dictionary, limits, enumeration, fairness, finite exhaustion, RNG, growing corpus, donors и progress guard. Содержит regression с 256 seeds и недоступным первым dictionary lane. |
| [efz_phase3_tests.erl](../test/efz_phase3_tests.erl) | Staged runtime и crash replay | Реальные operator discoveries, сохранение recipes, продолжение после crash, trace independence, fresh VM replay и build mismatch. Campaign regression доказывает executions после пропуска dictionary lane и различимые stop reasons. |
| [efz_feedback_loop_tests.erl](../test/efz_feedback_loop_tests.erl) | Замыкание feedback loop | Реальные dictionary mutations `<<>> → A → AB → ABC`; проверяет corpus IDs/parent, exact harness delivery по execution ref, primary hash/bytes и replay в свежей VM. Scripted mutator не используется. |
| [efz_recipe_tests.erl](../test/efz_recipe_tests.erl) | EFZR и детерминированное восстановление | Все операции, повреждения recipe, schema/hash/limit checks, fresh VM regeneration и ограничение размера при запуске replay script. |
| [efz_corpus_store_tests.erl](../test/efz_corpus_store_tests.erl) | Durable store и целостность | Roundtrip, duplicates, metadata shape/hash/schema, missing/truncated files, build policy и interrupted write. Проверяет, что ошибка persistence не добавляет неподтверждённый entry в active queue. |
| [efz_durable_tests.erl](../test/efz_durable_tests.erl) | Повторное использование corpus после VM restart | Несколько отдельных VM: discovery `A` сохраняется, затем восстанавливается, calibrates и становится parent `AB` с новым queue ID. Также проверяются duplicates, build mismatch и input limit. |
| [efz_limits_tests.erl](../test/efz_limits_tests.erl) | Общий input limit и storage failures | Границы 0/max/max+1, random/staged/restore/replay/executor/crash; отказ callback с oversized result; filesystem errors, rollback, corrupt groups и interrupted staging. Проверяет exact input и primary reason в report при невозможности записи. |
| [efz_smoke_tests.erl](../test/efz_smoke_tests.erl) | Минимальный lifecycle campaign | Десять random executions в explicit manual mode и корректная остановка. Не доказывает automatic coverage или реальное расширение corpus. |
| [efz_scripted_mutator.erl](../test/efz_scripted_mutator.erl) | Fixture фиксированной последовательности | Callback выдаёт заранее заданные bytes по iteration для Phase 2/backend/CT acceptance. Используется только тестами; не является production mutator или доказательством staged scheduling. |

<a id="fixtures"></a>
## fixtures — цели и данные для проверок

Каталог [fixtures/](../fixtures/) содержит **18 файлов с учётом подкаталогов**.
Это искусственные targets, которые tests/bench компилируют обычным compiler либо
через `efz_instrument`. Они не входят в основной `src_dirs` приложения.

| Файл | За что отвечает | Функциональность и потребитель |
|---|---|---|
| [efz_fixture.erl](../fixtures/efz_fixture.erl) | Широкий набор Erlang syntax для instrumentation | Clauses/guards, case/if, fun, try/catch/after, receive, binaries, records, macros и tail recursion. Синхронизация с observer позволяет тестировать kill/timeout после реального probe. Low-level tests передают Erlang terms. |
| [efz_fixture_helper.erl](../fixtures/efz_fixture_helper.erl) | Межмодульный вызов target | `classify/1` различает zero/other; вызывается из `efz_fixture`, чтобы проверить instrumentation нескольких выбранных модулей. |
| [efz_skipped.erl](../fixtures/efz_skipped.erl) | Ограничения поддерживаемой syntax | List/binary/map comprehensions и `maybe` expression проверяют отказ strict mode и сохранение семантики с limitations при `strict => false`. |
| [efz_record_default.erl](../fixtures/efz_record_default.erl) | Expression в record default | Default value зависит от process dictionary через `case`; Phase 2 проверяет диагностику неподдержанного расположения expression и plain/instrumented equivalence в non-strict mode. |
| [efz_bench_fixture.erl](../fixtures/efz_bench_fixture.erl) | Часто повторяемые probes | Числовой tail-recursive loop с небольшой веткой по `N band 3`. Coverage/performance benchmarks измеряют накладные расходы на многократных hits. |
| [efz_cli_harness.erl](../fixtures/efz_cli_harness.erl) | Минимальный внешний harness | `run/1` принимает binary и вызывает `efz_cli_parser:parse/1`; CLI tests компилируют harness отдельно от instrumented parser. |
| [efz_cli_parser.erl](../fixtures/efz_cli_parser.erl) | Target CLI tests | Различает binary с первым byte 128 и остальные inputs; изменение первого бита создаёт достижимое новое покрытие. Экспортирует `parse/1`, поэтому также проверяет ошибку missing `run/1`. |
| [efz_lineage_parser.erl](../fixtures/efz_lineage_parser.erl) | Target parent-reuse regression | Обычный `parse/1` с отдельными clauses для `A`, `AB`, `ABC` и fallback. Hooks добавляет compiler; используется feedback-loop и durable tests. |
| [efz_durable_harness.erl](../fixtures/efz_durable_harness.erl) | Harness для нескольких VM | Стабильный `run(binary())` вызывает lineage parser; позволяет доказать restore и mutation parent reuse независимо от тестового процесса предыдущей VM. |
| [efz_integrity_target.erl](../fixtures/efz_integrity_target.erl) | Instrumented target integrity tests | Реальные clauses A/B и alternate build; unmatched binary не входит в probe body. |
| [efz_integrity_harness.erl](../fixtures/efz_integrity_harness.erl) | Обычный harness integrity tests | Binary cases для disconnected/zero-hit, context corruption, caught hook, child context, synchronization hot reload и отдельная alternate harness build. |
| [efz_isolation_target.erl](../fixtures/efz_isolation_target.erl) | Target execution isolation | Binary scenarios с реальными linked/unlinked/nested children, timeout, registrations/ETS и VM-global mutations. Компилируется automatic instrumentation для isolation suite. |
| [efz_limits_target.erl](../fixtures/efz_limits_target.erl) | Exact delivery и искусственный crash | Отправляет полученный binary зарегистрированному observer, возвращает его либо вызывает error для `CRASH`. Используется для limits и проверки сохранения triggering input при IO failure. |
| [efz_crash_target.erl](../fixtures/efz_crash_target.erl) | Instrumented parser crash fixture | Возвращает ok для `OK`, ждёт на `WAIT`, иначе падает с data-dependent Reason. Compile macro создаёт несовместимый build; source relocation проверяет нормализацию signature. |
| [efz_crash_harness.erl](../fixtures/efz_crash_harness.erl) | Обычный внешний binary harness | Вызывает реальный parser. Compile macro меняет harness identity; test-only env выбирает normal return, другую ошибку либо infrastructure failure в свежей replay VM. |

### fixtures/include

Каталог [fixtures/include/](../fixtures/include/) нужен для проверки разрешения
include paths и preprocessing при сборке instrumented target.

| Файл | Назначение и функциональность |
|---|---|
| [efz_fixture.hrl](../fixtures/include/efz_fixture.hrl) | Макрос `INCLUDED` с `case` и record `item`. Макрос использует `MAGIC`, задаваемый compiler option; проверяется сохранение source locations и поведение expanded code. |

### fixtures/performance

Каталог [fixtures/performance/](../fixtures/performance/) содержит воспроизводимые
нагрузки benchmark, не требующие сторонних приложений.

| Файл | Назначение и функциональность |
|---|---|
| [efz_perf_parser.erl](../fixtures/performance/efz_perf_parser.erl) | Искусственный binary record parser: числовые поля, flags, variable-length payload, truncated/invalid records и искусственный error. Даёт смешанную нагрузку для executor/campaign benchmarks. |
| [efz_perf_sparse.erl](../fixtures/performance/efz_perf_sparse.erl) | Генерируемый, но сохранённый в проекте source: 2048 clauses `choose/1` плюс fallback. Большой manifest при малом числе достигнутых probes измеряет стоимость sparse coverage/validation; генератор расположен в `bench`. |

<a id="examples"></a>
## examples — демонстрационные интеграции

Каталог [examples/](../examples/) содержит **15 файлов**. Его campaigns задают
конкретные targets/seeds/options для демонстрации; общий пользовательский запуск
предоставляет `scripts/fuzz.escript`.

### examples/simple_parser

Каталог [examples/simple_parser/](../examples/simple_parser/) — минимальная пара
обычный target + harness. Это единственный example, включённый в `src_dirs` Rebar3,
поэтому оба модуля доступны после обычной сборки EFZ.

| Файл | Назначение и функциональность |
|---|---|
| [efz_example_parser.erl](../examples/simple_parser/efz_example_parser.erl) | Классифицирует пустой input, binary prefixes и text, намеренно падает на prefix `255`. Не содержит вызовов EFZ. `run/1` сохраняет compatibility, основной entry point — `classify/1`. |
| [efz_example_target.erl](../examples/simple_parser/efz_example_target.erl) | Harness behaviour `efz_target`: `run/1` передаёт input в `efz_example_parser:classify/1`. Используется shell examples, smoke и automatic coverage acceptance. |

### examples/automatic

Каталог [examples/automatic/](../examples/automatic/) показывает automatic coverage
с существующим random mutation path.

| Файл | Назначение и функциональность |
|---|---|
| [run.escript](../examples/automatic/run.escript) | Инструментирует simple parser, запускает 500 random executions от `<<0>>`, сохраняет `_build/example-report.term` и crashes, останавливает EFZ. Запускается из корня после сборки. |

### examples/staged

Каталог [examples/staged/](../examples/staged/) демонстрирует staged operators,
dictionary discoveries и восстановление реального crash.

| Файл | Назначение и функциональность |
|---|---|
| [efz_staged_parser.erl](../examples/staged/efz_staged_parser.erl) | Различает `TOKEN`, boundary/arithmetic values и empty input; prefix `BOOM!` вызывает искусственный error. Обычный target без ручных coverage hooks. |
| [run.escript](../examples/staged/run.escript) | Инструментирует parser, запускает 200 staged executions, извлекает crash recipe, проверяет exact regeneration и повторный crash через executor; сохраняет report/input/recipe/replay expectation под `_build`. |
| [tokens.hex](../examples/staged/tokens.hex) | Две hex-строки для binary tokens `TOKEN` и `BOOM!`, плюс комментарий. Читается штатным `efz_dictionary`; это данные mutation stage. |

### examples/staged/corpus

Пять raw seed files для `scripts/prepare.escript` и общего launcher.
Документация остаётся вне этой директории, чтобы CLI не считал её seed.

| Файл | Назначение и точное содержимое |
|---|---|
| [00-empty.seed](../examples/staged/corpus/00-empty.seed) | Пустой binary, 0 байт; проверяет empty-input path. |
| [01-zero.seed](../examples/staged/corpus/01-zero.seed) | Один нулевой byte, исходный parent для boundary/arithmetic discoveries. |
| [02-near-token.seed](../examples/staged/corpus/02-near-token.seed) | `UOKEN` без newline; мутация первого byte открывает `TOKEN` clause. |
| [03-near-crash.seed](../examples/staged/corpus/03-near-crash.seed) | `COOM!` без newline; bitflip/arithmetic первого byte создаёт искусственный crash `BOOM!`. |
| [04-binary.seed](../examples/staged/corpus/04-binary.seed) | Hex `00 ff 80 41 0d 0a`; binary ingestion с NUL, non-UTF-8 и CR/LF. |

### examples/cowboy

Каталог [examples/cowboy/](../examples/cowboy/) адаптирует внешний checkout
Cowboy/Cowlib. Не добавляет эти библиотеки в зависимости EFZ и не запускает HTTP
listener: target синхронно разбирает query string.

| Файл | Назначение и функциональность |
|---|---|
| [README.md](../examples/cowboy/README.md) | Команды подготовки внешнего Cowboy, проверки и запуска; описывает область `parse_qs`, instrumentation limitations и исторические результаты на конкретной сборке. |
| [efz_cowboy_target.erl](../examples/cowboy/efz_cowboy_target.erl) | Передаёт raw query bytes в `cowboy_req:parse_qs/1` через минимальный Req map. Штатные `request_error` для `qs`/`limit_reached` превращает в return; неожиданные exceptions остаются crash. |
| [efz_cowboy_checks.erl](../examples/cowboy/efz_cowboy_checks.erl) | Дополнительные EUnit checks для percent decoding, binary bytes, repeats и числа ключей; сравнивает coverage backends и подтверждает discovery от реальной dictionary mutation. Запускается example runner в режиме `check`. |
| [run.escript](../examples/cowboy/run.escript) | Проверяет внешние BEAM, компилирует harness, инструментирует `cowboy_req` и `cow_qs`, запускает checks либо staged campaign. Для Cowboy использует explicit non-strict instrumentation и выводит limitations. |

<a id="bench"></a>
## bench — измерения производительности

Каталог [bench/](../bench/) содержит **9 файлов** вспомогательной инфраструктуры
измерений. Они не запускаются при обычном старте EFZ. Результаты сохраняются в
`_build`; зафиксированные исторические samples находятся в `docs/performance`.

| Файл | За что отвечает | Реализуемая функциональность |
|---|---|---|
| [run.escript](../bench/run.escript) | Benchmark launcher | Компилирует локальные `efz_perf*` helpers, выбирает workload `hooks/executor/campaign/memory/startup` или `all` и варианты backend/validation. Поддерживает путь `EFZ_PERF_EBIN`. |
| [efz_perf.erl](../bench/efz_perf.erl) | Основной измерительный драйвер | Собирает fixtures, проверяет семантику, измеряет hooks/executor/campaign/startup/memory, сохраняет environment и samples. `canonical/1` нормализует результаты для сопоставления вариантов. |
| [efz_perf_loop_target.erl](../bench/efz_perf_loop_target.erl) | Binary adapter числового loop | Преобразует первый byte input в число повторов для `efz_bench_fixture`, проверяет checksum формулой. Нужен campaign benchmark с binary contract. |
| [efz_perf_replay.erl](../bench/efz_perf_replay.erl) | Фиксированный поток benchmark candidates | `install/1` размещает tuple inputs в `persistent_term`, `mutate/2` выбирает по iteration, `clear/0` очищает. Изолирует cost mutation в измерениях; не является EFZR replay или production scheduler. |
| [generate_sparse.escript](../bench/generate_sparse.escript) | Генератор sparse fixture | Воспроизводимо записывает `fixtures/performance/efz_perf_sparse.erl` с 2048 числовыми clauses. Меняет source-файл; не требуется перед каждым запуском fuzzing. |
| [profile.escript](../bench/profile.escript) | `eprof` profiling | Компилирует loop/parser/sparse target, предварительно загружает execution path и профилирует hooks либо executor; поддерживает prepared validation. Результат profiling не считается throughput sample. |
| [report.escript](../bench/report.escript) | Чтение результатов benchmark | Читает локальные бинарные `.term` rows для hooks/executor/campaign, выводит median, raw samples, стоимость операции и throughput. Нагрузку повторно не запускает. |
| [archive.escript](../bench/archive.escript) | Архив доказательств Phase 2.1 | Проверяет количество samples, canonical comparisons, source/BEAM/build hashes, memory/profiles; формирует компактный текстовый Erlang term для документации. Рассчитан на конкретную структуру исторических artifacts. |
| [mutations.escript](../bench/mutations.escript) | Staged mutation benchmark | Измеряет короткие/средние/предельные inputs, dictionary, splice и havoc; проверяет применение operations. Сравнивает конечные random/staged campaigns, фиксирует memory, reductions, environment и hashes. |

<a id="docs"></a>
## docs — документация, UML и архивы

Каталог [docs/](./) содержит **62 файла с учётом подкаталогов**. Контракты
описывают использование текущих подсистем. Audit/validation/performance records
фиксируют состояние и результаты на дату записи; их старые ошибки, counts и
команды не являются утверждением о текущем checkout.

### Основные документы

| Файл | Назначение и содержание |
|---|---|
| [architecture.md](architecture.md) | Текущая архитектура: модули, процессы, владельцы состояния, startup, feedback, execution, coverage, corpus, mutation, ошибки и границы OTP integration. Включает четыре UML SVG. |
| [repository-map.md](repository-map.md) | Эта пофайловая карта: назначение всех директорий/файлов проекта, runtime/test/example границы, генерируемые artifacts и места изменения функциональности. |
| [cli.md](cli.md) | Универсальный launcher, минимальный внешний harness, compilation artifacts, параметры и campaign map schema. |
| [execution-isolation.md](execution-isolation.md) | Supported binary harness contract, guardian protocol, controlled spawn API, dirty VM policy, shared-state boundaries и следующий disposable-VM backend. |
| [coverage-integrity.md](coverage-integrity.md) | Pins harness/builds, независимое evidence наблюдения, context states, code replacement, campaign diagnostic/strict policy и supported boundaries. |
| [coverage.md](coverage.md) | Automatic source coverage contract: поддержанная syntax, granularity, manifest/build identities, compilation и execution APIs, backend/validation варианты и ограничения. |
| [quickstart.md](quickstart.md) | Подготовка сборки и тестового corpus, точные команды fuzz/replay/restore, текущие ограничения и приоритеты до более широкого применения. |
| [mutations.md](mutations.md) | Staged engine: defaults, dictionary format, lazy enumeration, progress/exhaustion, byte operators, havoc, provenance и accounting. |
| [replay.md](replay.md) | Crash occurrence/signature/group contract, bounded report, Reason policies, EFZR/EFZX schema, raw authority, verified replay CLI/APIs, compatibility и regression evidence. |
| [corpus.md](corpus.md) | Durable corpus schema 1: content-addressed layout, публикация, metadata, restore, duplicate/build policies и corrupt/partial diagnostics. Объясняет отличие reusable corpus от exact resume. |
| [input-and-storage.md](input-and-storage.md) | Единый `max_input_bytes`, границы replay/crash, atomic artifact groups, structured IO failures и сохранение triggering input в runtime context. |
| [calibration-readiness.md](calibration-readiness.md) | Аудит от 9 сентября о prerequisites для повторной calibration/feature stability. Анализирует полноту snapshots, termination, cross-case state и содержит диагностические scripts; предлагаемая модель не означает реализованную feature stability. |
| [phase2-validation.md](phase2-validation.md) | Историческое закрытие automatic instrumentation: команды, retention/continuation, coverage после termination, baseline и ограничения Phase 2. |
| [phase2.1-performance.md](phase2.1-performance.md) | Методика и результаты performance work: ETS variants, prepared validation, executor/campaign costs, memory, profiles и выбор defaults. |
| [phase3-validation.md](phase3-validation.md) | Историческая проверка staged mutation и replay: discoveries, crashes, measured costs, memory, команды и границы Phase 3. |
| [technical-audit-2026-09-12.md](technical-audit-2026-09-12.md) | Полный аудит 12 сентября: component inventory, реальные call paths, integration matrix, experiments, bugs, maturity и план. Найденные тогда scheduler/CLI/persistence/IO gaps нужно сопоставлять с текущим кодом и новыми regression tests. |

### docs/adr

Каталог [docs/adr/](adr/) хранит архитектурные решения: какой подход выбран и
почему. Его baseline относится к моменту принятия решения.

| Файл | Назначение и содержание |
|---|---|
| [0002-automatic-coverage.md](adr/0002-automatic-coverage.md) | ADR выбора source clause/outcome probes и execution-owned ETS. Сравнивает parse transform, OTP coverage и низкоуровневое rewriting; фиксирует isolation/feedback contract и альтернативы. |

### docs/diagrams

Каталог [docs/diagrams/](diagrams/) содержит **10 файлов** UML. `.mmd` —
редактируемые Mermaid-исходники, `.svg` — сохранённые изображения для просмотра
без Mermaid renderer. Эти SVG включены в архитектуру.

| Файл | Назначение и содержание |
|---|---|
| [README.md](diagrams/README.md) | Объясняет UML stereotypes для Erlang, смысл arrows и commands локального рендеринга всех четырёх диаграмм. |
| [mermaid-config.json](diagrams/mermaid-config.json) | Общая тема, шрифты, security/layout settings Mermaid; HTML labels отключены для переносимых SVG. Не относится к campaign config. |
| [modules.mmd](diagrams/modules.mmd) | Исходник structural UML: основные runtime modules и зависимости staged path. |
| [modules.svg](diagrams/modules.svg) | Готовое изображение зависимостей модулей, полученное из `modules.mmd`. |
| [processes.mmd](diagrams/processes.mmd) | Исходник structural UML: supervisor children, links, monitors, worker/guardian/coordinator/target/descendants и владельцы ETS. |
| [processes.svg](diagrams/processes.svg) | Готовое изображение процессов и ресурсов из `processes.mmd`. |
| [feedback-loop.mmd](diagrams/feedback-loop.mmd) | Исходник sequence UML: получение corpus entries, lazy mutation, execution, feedback и retention, делающий discovery доступным будущим мутациям. |
| [feedback-loop.svg](diagrams/feedback-loop.svg) | Готовое изображение полного staged feedback loop. |
| [executor.mmd](diagrams/executor.mmd) | Исходник sequence UML одного input: caller/guardian/coordinator/root/descendants, gates, hooks, DOWN/barriers, timeout и dirty-runner cleanup. |
| [executor.svg](diagrams/executor.svg) | Готовое изображение execution protocol и альтернативных исходов. |

### docs/examples

Каталог [docs/examples/](examples/) хранит небольшую реальную пару artifacts для
документации replay. Эти файлы — данные, не исходники target.

| Файл | Назначение и содержание |
|---|---|
| [staged-crash.input](examples/staged-crash.input) | Exact binary из staged example: шесть bytes `<<"BOOM!", 0>>`. Можно сравнить с восстановлением recipe; это input намеренно падающего искусственного parser. |
| [staged-crash.recipe](examples/staged-crash.recipe) | EFZR v1 recipe того же input: primary, operations, hashes, limits и build provenance исторического запуска. Byte regeneration не требует target; execution требует явной совместимой сборки. |

### docs/performance

Каталог [docs/performance/](performance/) хранит **текстовые Erlang terms**
с историческими measurements. Несмотря на расширение `.term`, здесь не binary ETF:
содержимое предназначено для просмотра или `file:consult/1`.

| Файл | Назначение и содержание |
|---|---|
| [phase2.1-samples.term](performance/phase2.1-samples.term) | Архив environment, sample rows, canonical campaign checks, memory, profiling и source/BEAM hashes для отчёта Phase 2.1. |
| [phase3-mutations.term](performance/phase3-mutations.term) | Измерения mutation workloads и random/staged campaigns, environment, compiler/build identities, memory/reductions и source hashes. Основание performance tables Phase 3. |
| [phase3-validation.term](performance/phase3-validation.term) | Архив Phase 3 acceptance evidence: source hashes, результаты кампании/проверок и ссылка на measurement environment. Фиксирует тот запуск, не автоматически обновляемый test report. |

### docs/audit-2026-09-12

Каталог [docs/audit-2026-09-12/](audit-2026-09-12/) содержит **30 файлов**
диагностик и доказательств старого аудита. Scripts сохранили старый API/layout и
assertions обнаруженных дефектов: например, nested mutation limit, ранний
`mutation_exhausted` и плоские crash files. Они **не являются текущим regression
suite**; после исправлений часть assertions/путей закономерно несовместима.
Актуальные regressions находятся в `test/`.

| Файл | Назначение и зафиксированное содержание |
|---|---|
| [audit_target.erl](audit-2026-09-12/audit_target.erl) | Искусственный parser с paths `A`, `AB`, `ABC`, error на `CRASH` и fallback; source для automatic instrumentation аудита. |
| [audit_harness.erl](audit-2026-09-12/audit_harness.erl) | Реальный binary harness: отправляет observer exact доставленные bytes и вызывает `audit_target:parse/1`. |
| [audit_faults.erl](audit-2026-09-12/audit_faults.erl) | Диагностические targets для `persistent_term`, spawned/linked children, timeout, coordinator kill, повреждения context и классов исключений. Создаёт контролируемые fault scenarios. |
| [run.escript](audit-2026-09-12/run.escript) | Исторический driver: собирает targets, запускает lineage campaign и fault diagnostics, записывает reports и snapshots в заданный рабочий каталог. Требует адаптации старой config к текущему API. |
| [edge-cases.escript](audit-2026-09-12/edge-cases.escript) | Reproducer преждевременного exhaustion на 256 seeds, молча игнорируемых config keys и crash storage failure. Assertions описывают старые дефекты; исправленный scheduler должен им не соответствовать. |
| [fresh-replay.escript](audit-2026-09-12/fresh-replay.escript) | Историческая проверка восстановления `CRASH` и исполнения в новой VM. Ищет старый плоский `crashes/*.recipe`, а текущие artifacts хранятся группами. |
| [before-sha256.json](audit-2026-09-12/before-sha256.json) | Hash baseline файлов до аудита, использованный для доказательства отсутствия изменений исходников во время исследования. |
| [status-before.txt](audit-2026-09-12/status-before.txt) | Снимок `git status` до аудита: tracked modifications и untracked implementation. Не описание сегодняшнего Git status. |
| [verification.json](audit-2026-09-12/verification.json) | Проверка целостности исходных файлов и структуры/ссылок итогового audit report. |
| [e2e-report.term](audit-2026-09-12/e2e-report.term) | Полный **binary ETF** report audit campaign: corpus, coverage, recipes/trace, decisions и crash evidence. В отличие от `docs/performance/*.term`, это не текст для `file:consult/1`. |
| [e2e.txt](audit-2026-09-12/e2e.txt) | Читаемая выжимка lineage: corpus IDs, ancestry, delivery/regeneration counts и crash path. Отсутствие durable restore относится к старой реализации. |
| [child.txt](audit-2026-09-12/child.txt) | Snapshot обычного spawned child: root завершён, child жив, automatic context у child отсутствует. |
| [linked_child.txt](audit-2026-09-12/linked_child.txt) | Snapshot linked child после нормального return root; показывает, что link сам по себе не гарантирует уничтожение child. |
| [child_timeout.txt](audit-2026-09-12/child_timeout.txt) | Snapshot после timeout root: отдельный unlinked child остаётся жив и не получает coverage context автоматически. |
| [coordinator_kill.txt](audit-2026-09-12/coordinator_kill.txt) | Принудительная смерть coordinator: infrastructure outcome при всё ещё живом target. Evidence границы fault isolation. |
| [cross_case_state.txt](audit-2026-09-12/cross_case_state.txt) | Два исполнения одинакового логического сценария до/после записи `persistent_term`; глобальное состояние меняет target outcome и coverage. |
| [caught_malformed_context.txt](audit-2026-09-12/caught_malformed_context.txt) | Target ловит исключение после подмены process-dictionary context; snapshot показывает потерянную диагностику malformed context. |
| [hot_reload.txt](audit-2026-09-12/hot_reload.txt) | Результат замены instrumented code обычной сборкой после preflight: успешный return с пустым coverage. Evidence зависимости от стабильного загруженного кода. |
| [disconnected_artifacts.txt](audit-2026-09-12/disconnected_artifacts.txt) | Campaign с artifacts, не обеспечивающими нужный target path: executions/crashes без discoveries и coverage. Наличие valid artifacts само по себе не доказывает достижение instrumented code. |
| [exception_classes.txt](audit-2026-09-12/exception_classes.txt) | Сопоставляет classes/reasons вроде function_clause, badarg, throw и exit с фактическими executor outcomes и stack traces. |
| [duplicate_initial_seeds.txt](audit-2026-09-12/duplicate_initial_seeds.txt) | Исторический in-memory запуск двух одинаковых initial seeds с разными integer IDs и двумя calibrations. Не тест durable content dedup. |
| [random-example-summary.txt](audit-2026-09-12/random-example-summary.txt) | Сводка random example: execution/discovery/crash counts и parent links в выросшем corpus. |
| [edge-cases.log](audit-2026-09-12/edge-cases.log) | Вывод reproducer: в том checkout 256 idle visits дали 0 candidates/executions; также записаны старые config/storage diagnostics. |
| [fresh-replay.log](audit-2026-09-12/fresh-replay.log) | Подтверждение того исторического fresh VM replay: `CRASH`, 5 bytes, coverage присутствует. |
| [staged-example.log](audit-2026-09-12/staged-example.log) | Counts и replay result standalone staged example на момент аудита. |
| [cowboy-check.log](audit-2026-09-12/cowboy-check.log) | Зафиксированная **неудача запуска**: отсутствовал внешний `cowboy_req.beam`. Не является успешным Cowboy test result. |
| [eunit.log](audit-2026-09-12/eunit.log) | Вывод `rebar3 eunit` в историческом checkout; список tests и результаты того запуска. |
| [ct.log](audit-2026-09-12/ct.log) | Вывод Common Test: три automatic coverage сценария прошли в момент аудита. |
| [xref.log](audit-2026-09-12/xref.log) | Вывод cross-reference analysis старого checkout. |
| [dialyzer.log](audit-2026-09-12/dialyzer.log) | Вывод Dialyzer и использованные тогда PLT/project file counts. |

<a id="generated"></a>
## Генерируемые и служебные файлы

### _build

`_build/` исключён из Git. Он содержит результаты Rebar3, instrumented targets,
crash/corpus artifacts и локальные доказательства проверок. В отличие от исходных
файлов, состав зависит от выполненных команд. Например, fresh-VM tests создают
каталоги со случайным суффиксом; часть tests удаляет их после завершения.

| Каталог / семейство путей | Назначение и содержимое |
|---|---|
| `_build/default/lib/efz/` | Сборка обычного профиля: `ebin/*.beam`, `ebin/efz.app`, compiler cache и ссылки на исходники. Эту ebin использует launcher. |
| `_build/test/lib/efz/` | Сборка test profile и скомпилированные test modules; не заменяет default ebin универсального CLI. |
| `_build/test/logs/` | Common Test runs: HTML отчёты, suite logs, summaries, CSS/JS для локального просмотра. |
| `_build/plt/`, `_build/default/*plt`, `*.dialyzer_warnings` | Базовая и проектная PLT Dialyzer и диагностический вывод анализа. Это type-analysis cache, не fuzz corpus. |
| `_build/*targets/`, `*-target/`, `instrumented-example/` | BEAM/manifest pairs, созданные compilation facade для tests, examples и benchmarks. Вложенные `target/`, `instrumented/` выполняют ту же роль. |
| `_build/*crashes/`, вложенные `crashes/` | Crash artifacts соответствующего запуска. Старые эксперименты могут содержать плоские files; текущий `efz_crash` публикует группы, описанные ниже. |
| `_build/feedback-loop-test/` | `report.term`, `lineage.txt`, retained entry recipes и fresh replay evidence реальной цепочки `A → AB → ABC`; `target/` хранит её instrumented parser. Дополнительные `checks/` и negative-parent logs — локальные проверки regression. |
| `_build/durable-e2e-*/` | Раздельные VM phases: descriptor, plain/instrumented/v2 targets, persistent `corpus/`, phase reports/logs и `lineage.txt`. `durable-e2e-latest.txt` указывает последний каталог. |
| `_build/cli-test-*/`, `cli-acceptance/`, `cli-checks/` | Временные fixtures/launcher copies, fresh VM results и локальные подтверждения CLI. `*-test-*` обычно убираются test cleanup. |
| `_build/quickstart/`, `quickstart-checks/` | Подготовленные seeds, instrumented parser, reusable corpus/findings и логи проверки скрипта подготовки, общего CLI, restore и replay. |
| `_build/limits-test-*/`, `limits-checks/`, `limits-storage-failure.term` | Inputs/targets и fault-injection artifacts тестов лимитов, command logs и report с сохранённым triggering input при storage failure. |
| `_build/scheduler-checks/`, `scheduler-progress.term` | Локальные evidence исправления staged progress/exhaustion, включая campaign с 256 seeds. |
| `_build/isolation-test/`, `isolation-checks/` | Instrumented lifecycle fixture, fresh VM dirty-policy logs и результаты проверки guardian regression suite. |
| `_build/architecture-checks/` | Локальная проверка Markdown/UML, preview PNG и validation report. Исходники UML и публикуемые SVG лежат в `docs/diagrams`. |
| `_build/performance*/`, `perf-*/`, `phase21-*/`, `phase3-performance*/` | Варианты performance experiments: compiled fixtures, raw samples, memory/profile output и comparisons. Сохранённые выводы опубликованы в `docs/performance`. |
| `_build/phase2-*/`, `phase3-*/`, `backend-test-*/`, `fixture-check/`, `relocated/` | Рабочие каталоги acceptance: повторная/перемещённая сборка, manifest corruption, strict syntax, replay и termination diagnostics. Конкретный producer ищется по пути в tests/bench. |
| `_build/*report.term`, `*.term`, `*.txt`, `*.log`, `*.json` | Отчёты и локальная evidence. Расширение `.term` само по себе не определяет encoding: producer пишет либо binary ETF, либо текстовый Erlang term. |
| `_build/*.input`, `*.recipe`, `*.hex` | Bytes и recipes для replay, повреждённые negative fixtures и dictionary test files. Их значение определяется producer test/script, а не одним расширением. |

### Форматы runtime artifacts

Эти paths задаёт campaign/CLI. Они могут находиться вне `_build/` и сохраняются
между запусками, если пользователь выбрал постоянный каталог.

| Путь / файл | За что отвечает | Кто создаёт / читает |
|---|---|---|
| `ARTIFACTS/Module.beam` | Загружаемый instrumented Erlang code с embedded manifest | `efz_instrument:compile/2`; загрузка/preflight через `efz_instrument`. |
| `ARTIFACTS/Module.efz-manifest` | Sidecar metadata: build, probes и source locations; должен соответствовать BEAM | Compilation facade и preflight/manifest validation. |
| `OUT/report.term` | Итоговый binary ETF report campaign, включая stats/corpus/decisions/crashes | `efz_cli` через atomic file helper. Сам по себе не является campaign checkpoint. |
| `CORPUS/<sha256>/input` | Exact binary reusable corpus entry | `efz_corpus_store`; SHA-256 content identity не зависит от старого queue ID. |
| `CORPUS/<sha256>/metadata` | EFZC v1 metadata envelope: content/parent/build/discovery и доступная mutation recipe | `efz_corpus_store:save/4` и restore; проверяется целостность/совместимость. |
| `CRASHES/<signature>/<occurrence>/artifact.input` | Exact triggering input выбранного immutable representative | `efz_crash` через `efz_fs:atomic_group/3`; execution replay читает bytes. |
| `CRASHES/<signature>/<occurrence>/artifact.term` | Binary ETF schema v2: полный raw Reason/stack, result/metadata, identities и campaign input limit | Crash storage; используется для анализа причины и provenance. |
| `CRASHES/<signature>/<occurrence>/artifact.replay` | EFZX v1: ожидаемые builds/harness, input hash, signature, policy и limit | `efz_crash` создаёт, `efz_replay` безопасно загружает и проверяет перед execution. |
| `CRASHES/<signature>/<occurrence>/artifact.recipe` | EFZR recipe при наличии staged provenance; в random path может отсутствовать | `efz_crash` проверяет соответствие input; malformed recipe даёт error и raw-only publication; `efz_recipe` восстанавливает bytes. |
| `CRASHES/<signature>/<occurrence>/manifest` | Group schema и identities файлов для проверки полной опубликованной группы | `efz_fs:validate_group/1` проверяет всю группу; replay raw намеренно не зависит от диагностик и optional recipe. |
| `CRASHES/<signature>/summary` | EFZG v1 durable occurrence count и bounded representative ID/hash pairs | `efz_crash_store`: bounded safe ETF decode, проверка группы, atomic replacement + fsync. Счётчик сохраняется между VM, scheduler state не сохраняется. |
| `CRASHES/<signature>/.lock/` | Exclusive writer lock | Store создаёт перед изменениями и удаляет с directory sync после записи. Конкурирующий writer или оставшийся lock дают `writer_active_or_interrupted`; автоматического угадывания dead owner нет. |
| `.tmp-*` в storage directory | Незавершённая staging запись до atomic rename; не считается committed corpus/crash entry | Store/filesystem helpers. Обычная ошибка вызывает cleanup; после прерывания VM возможен остаток, restore corpus сообщает диагностику. |

### .git и crash dumps

`.git/` обслуживается Git и не участвует в fuzzing. Ни один из его файлов не
является исходником EFZ или конфигурацией campaign.

| Файл / каталог | Назначение |
|---|---|
| `.git/HEAD`, `refs/`, `objects/`, `index` | Текущая ссылка, branch/tag refs, объекты истории и staging index. |
| `.git/config`, `description`, `info/` | Локальные настройки и служебное описание репозитория. |
| `.git/logs/`, `ORIG_HEAD`, `FETCH_HEAD`, `AUTO_MERGE`, `COMMIT_EDITMSG` | Reflogs и временное состояние Git операций. Наличие/значение меняются независимо от EFZ. |
| `.git/hooks/`, `branches/`, `worktrees/`, `gk/` | Hooks, служебные каталоги Git/worktrees и локальные данные Git-клиента; не runtime EFZ. |
| `erl_crash.dump` в корне | Создаваемый ERTS dump при аварийном завершении VM. Не `.input` target crash и не recipe; в этом checkout присутствует и исключён из Git. |
| `rebar3.crashdump`, `.rebar3/`, `.eunit/`, `_checkouts/` и другие исключения `.gitignore` | Возможные generated/tool files, перечисленные в ignore rules. Само правило не означает, что такой файл или каталог сейчас существует. |

<a id="changes"></a>
## Как найти место для изменения функциональности

| Задача | Основной код | Где проверять поведение |
|---|---|---|
| Добавить CLI option / campaign field | `efz_cli`, `efz_config` | `efz_cli_tests`, `efz_config_tests`; затем `docs/cli.md`. |
| Изменить harness invocation / timeout | `efz_target`, `efz_executor`, `efz_guardian`, `efz_worker` | Executor, Phase 2/backend tests и execution UML. |
| Изменить покрываемую syntax / probe identities | `efz_instrument_pt`, `efz_instrument`, `efz_cov_manifest` | Phase 2 tests, `fixtures/efz_fixture`, strict fixtures и coverage contract. |
| Изменить hooks или snapshot validation | `efz_cov_rt`, `efz_cov`, `efz_cov_manifest` | Backend differential tests и Phase 2 termination/isolation scenarios. |
| Изменить novelty / retention | `efz_feedback`, `efz_worker`, `efz_corpus` | `efz_feedback_loop_tests`: discovered input должен реально стать parent. |
| Изменить scheduling / progress guard | `efz_mutation_plan` | Mutation/Phase 3 regressions с 256 seeds, growing corpus и full feedback-loop test. |
| Добавить byte operator | `efz_mutation_plan`, `efz_mutation`, `efz_recipe` | Mutation model tests, recipe roundtrip/fresh VM tests и staged runtime. |
| Изменить durable schema / restore | `efz_corpus_store`, `efz_corpus`, `efz_config` | Store corruption/duplicate tests и durable fresh VM integration. |
| Изменить input bound / IO contract | `efz_input`, `efz_fs`, `efz_crash` и вызывающие границы | `efz_limits_tests`, CLI ingestion и recipe tests. |
| Изменить описание архитектуры | `docs/architecture.md`, `docs/diagrams/*.mmd` | Сверить call paths с source, перегенерировать SVG, обновить эту карту при добавлении файлов. |

При добавлении или переносе файла обновляйте соответствующую таблицу и число
файлов. Архивные diagnostics сохраняйте как evidence своего времени; текущую
корректность подтверждают действующие tests и новый запуск, а не старый лог.

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
