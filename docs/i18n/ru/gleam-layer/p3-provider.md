# P3: структурный provider — PASS

[English](../../../gleam-layer/p3-provider.md) · **Русский** · [Español](../../es/gleam-layer/p3-provider.md) · [简体中文](../../zh-CN/gleam-layer/p3-provider.md) · [Все языки](../../README.md)

Текущая приёмка P5 записана в [p5-validation.md](p5-validation.md).
Утверждения о передаче и незавершённом статусе ниже описывают исторический запуск этапа.

Требования **2.0-native**; вектор contract/model/codec/mutator/feature/property
**{1,1,1,1,1,1}**. Холодный генератор **2**, пакет **1.1.0**. Новая structured
recipe schema **3**, operation version **2**, EFZR envelope **1**; прежние recipe
schemas **1/2** остаются читаемыми. Дата: 2026-10-08.

Доказательства: `artifacts/gleam-layer/20261008-p3-provider/`. HEAD остаётся
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b`. `head.txt`, `status-before.txt`,
`dirty-before.patch`, `dirty-index-before.patch`, `inputs.json` и `before-files/`
сохраняют начальный checkout. Этот проход расширяет provider, уже присутствовавший
в P2; он не утверждает, что тогда были приняты все предыдущие этапы пакета.
[P0](baseline.md), [путь исполнения](execution-path.md), [контракт P1](contracts.md)
и [P2](p2-integration.md) проверены до редактирования.

## Фактическое исполнение и ответственность

| Ответственность | Фактический file:function |
| --- | --- |
| Существующий цикл/lifecycle | `src/efz_worker.erl:staged_iteration/1`, `src/efz_fuzzer.erl:handle_info/2` |
| Рабочий корпус / родители | `src/efz_corpus.erl:mutation_entries/0`, `src/efz_mutation_plan.erl:next/2`, `visit/2` |
| Существующие lane, budget, RNG и family dispatch | `src/efz_mutation_plan.erl:attempts/6`, `structured/3`, `ordinary_attempts/6`, `uniform/2` |
| Нативная граница | `src/efz_gleam_adapter.erl:mutate/3`, `decode/2`, `encode/2` |
| Реальное скомпилированное типизированное ядро | `gleam/efz_semantic/src/efz_qs_model.gleam`; BEAM `efz_qs_model:decode/2`, `mutate/3`, `encode/2`, `generate/2` |
| Неизменённая реальная цель | `examples/query_string/efz_qs_target.erl:run/1` → закреплённый `cow_qs:parse_qs/1` |
| Исполнение / снимок цели | `src/efz_executor.erl:run/4`, `src/efz_guardian.erl:finish/2`, `src/efz_cov_native_public.erl:collect/1` |
| Структурный допуск / хранение | `src/efz_feedback.erl:evaluate/3`, `src/efz_corpus.erl:add_checked/3`, `src/efz_corpus_store.erl:save/4` |
| Подготовка seeds / обычный импорт | `scripts/gleam_seeds.escript:main/1`, `src/efz_cli.erl:read_seeds/2`, `src/efz_corpus.erl:init/1` |
| Ограниченный рецепт / raw-регенерация | `src/efz_recipe.erl:make/4`, `validate_structured/2`, `regenerate/1` |

EFZ сначала посещает родителя корпуса и существующий stage, затем выбирает семейство.
Ordinary вызывает существующие функции мутации. Structured вызывает прямые BEAM
операции decode → mutate → encode; чистые callbacks не исполняют цель и не выбирают
родителей. Unsupported/limit/unchanged один раз использует `ordinary_attempts/6` без
рекурсии в структурный выбор. Layer error возвращает отдельную диагностику,
увеличивает `errors` и останавливает кампанию через infrastructure-канал EFZ.
Controller остаётся доступен для отчёта/остановки. Дефект цели не выводится.

Off/fraction-zero пропускает branch RNG и decode. Положительная fraction потребляет один
выбор `uniform_s(100)`, а структурный выбор добавляет `uniform_s(6)` для операции. Успех
возвращает R2; fallback запускает ordinary с R2; ошибка записывает R2 без retry.
Structured-only provenance записывает точные слова exsplus до/после этих выборов,
fraction, operation, versions и limits. Ordinary candidates/recipes сохраняют
прежнюю форму. Raw binary — canonical постоянный input; модели остаются временными.

Владельцы target, executor, corpus, energy, admission, coverage, findings и replay
не заменялись. Внешний engine, fuzzer callback, новый NIF/C bridge,
transport, VM на мутацию, cache, асинхронный learner или новый worker не добавлялись.
Существующие несвязанные native launcher/backends остаются. Module-scoped OTP counters
сохраняют сериализацию guardian EFZ; неуправляемые параллельные вызовы цели остаются вне
контракта изоляции. Кампании P3 отключают semantic feedback и oracle.

## Модель, ограничения, операции и seeds

Конкретные ADT: `Query(List(Field),Canonical|BadEscape)` и
`Field(BitArray,BitArray)`. Поддерживаемое подмножество: непустые binary names, явный
`=`, упорядоченные/повторные поля, разделители `&`, percent escaping и plus-as-space.
Values могут быть empty/NUL/non-UTF8. Поля только с именем, пустые имена, избыточные
разделители и malformed escapes не поддерживаются моделью; raw-доступ к цели
сохраняется. Это подмножество языка, принимаемого настоящим парсером.

Ограничения: 4096 wire bytes, 32 поля, 128 bytes/component, фиксированная глубина 2 и одна
operation/candidate. Capacity guards предшествуют prepend/append/catalogue аллокации.
Mutator использует size preflight вместо выделения отброшенного encoded value;
encoder независимо проверяет размер выхода. Архивированный P2 BEAM и текущий BEAM
дают одинаковые результаты для **264** model/operation/limit случаев.

| ID операции | Действие |
| --- | --- |
| 0 | Добавить в начало поле `x={0,255}` в пределах field/component/byte limits |
| 1 | Установить нулевую длину первого значения; пустой query создаёт `a=` |
| 2 | Удалить первое поле, включая переход к пустому query |
| 3 | Обратить поля, сохранив pair identity и семантику порядка повторных имён |
| 4 | Добавить байт 255 к первому значению или создать `a=%FF`; limit предотвращает overflow |
| 5 | Намеренно некорректный percent escape suffix `&x=%`; encoder сохраняет его |

Codec-тесты покрывают `decode(encode(M)) == normalize(M)` для canonical поддерживаемых
моделей, идемпотентную нормализацию, явную сетку field/value, все шесть ожидаемых
wire fixtures и фактические результаты Cowlib. Некорректный `BadEscape` исключён из
round-trip закона валидных моделей. Произвольная raw byte-identical гарантия не заявляется.

Детерминированный каталог теперь содержит 12 разных слотов: empty query/value,
binary bytes, duplicates/reserved bytes, named field variant, invalid escape,
127/128-byte values, 31/32 fields, exact 4096-byte wire и ключ максимальной длины.
Результат по умолчанию — **12 файлов / 5349 bytes**, из них **11 приняты / 1 ожидаемо
отклонён** неизменённым парсером. Подготовка ограничена 64 файлами и 65536 суммарными
байтами, отклоняет существующий output и записывает catalogue indices, generator/runtime
versions, limits и per-file SHA-256 в manifest schema 2 вне seed-каталога.
Холодная версия генератора проверяется до создания каталога результата.

`seed-import-r2/proof.json` проверяет manifest hashes, обычный CLI-импорт и raw-
identity рабочего корпуса. Сборка без compiler/package выполняет 12
calibrations, затем отдельная обычная кампания исполняет 50 мутаций. Gleam
остаётся незагруженным, layer counters отсутствуют. Двенадцать независимых parser probes —
явно дополнительные холодные проверки вне coverage-интервалов кампании.
Исходный seed-корпус не меняется на месте.

## Команды и выполненные проверки

Закреплённый toolchain: OTP **27.0**, ERTS **15.0**, Rebar3 **3.25.0**, Gleam **1.10.0**;
`+S 2:2`. Обычные commits/locks зависимостей не меняются. `runtime.json`
записывает реальный module path, exports и package 1.1.0; optional app не загружается.
У каждой команды есть соседний `.json` с аргументами, cwd, выбранными настройками инструментов,
exit и временем, плюс `.log`. Runner — `run_command.py` в каталоге запуска.

| Проверка | Команда / имя evidence | Exit / результат |
| --- | --- | --- |
| Реальная on-сборка | `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` / `on-compile-final` | 0 |
| Focused callback/contract/recipe/provider suite | `rebar3 as gleam eunit --module=efz_gleam_provider_tests,efz_gleam_layer_tests,efz_gleam_contract_tests,efz_gleam_beam_tests,efz_recipe_tests` / `focused-tests-r4` | 0 / 46 пройдено |
| Полная регрессия | `rebar3 as gleam eunit` / `full-on-tests` | 0 / 302 пройдено, включая term targets и прежние staged-операции |
| Финальные свежие имена fixtures | `rebar3 as gleam eunit --module=efz_gleam_provider_tests` / `provider-tests-final` | 0 / 10 пройдено |
| Source-only off | `PATH=/home/fbogoslavskii/.asdf/installs/erlang/27.0/bin:/usr/bin:/bin GLEAM_BIN=/nonexistent/gleam rebar3 compile` в `/tmp/efz-p3-off-0c0joh3_` / `clean-off-compile` | 0 |
| Off-совместимость | `rebar3 eunit --module=efz_gleam_provider_tests,efz_gleam_layer_tests,efz_gleam_contract_tests,efz_gleam_beam_tests,efz_recipe_tests,efz_mutation_tests,efz_phase2_tests,efz_smoke_tests` там / `clean-off-tests` | 0 / 57 пройдено |
| Coverage-регрессия | `rebar3 as gleam ct` / `ct-regression` | 0 / 3 пройдено |
| Статические вызовы | `rebar3 as gleam xref` / `on-xref` | 0 |
| Корневая обычная сборка | `GLEAM_BIN=/nonexistent/gleam rebar3 compile` / `root-off-compile` | 0 |
| Подготовка/импорт seeds | `escript scripts/gleam_seeds.escript RUN/generated-seeds`; `escript scripts/gleam_seed_import_check.escript OFF_BUILD RUN/generated-seeds RUN/seed-import-r2 ROOT` | 0 / raw identities, 12 calibrations, 50 последующих мутаций |
| Подключение реального цикла | `real-loop/proof.term`, созданный финальными provider tests | 200 мутаций + 3 calibrations; настоящие Gleam-вызовы на worker EFZ; target calls равны учтённым executions; нет observe/check calls или semantic state |
| Off/zero последовательность | `python3 RUN/run_campaigns.py` / `raw-{baseline,off,fraction0}-{17,43}` | Все шесть exit 0; 100-candidate hash/stage/parent traces совпадают с P0 по seed |
| Replay без Gleam | `escript /tmp/efz-p3-off-0c0joh3_/scripts/replay.escript RUN/real-recipes/{current,old}.recipe RUN/replayed-{current,old}.input` | Оба 0; schema 3/2 raw results совпадают с ожидаемыми bytes |
| Воспроизведение записанного состояния | `escript RUN/verify_recipe.escript BUILD RUN/real-recipes/current.recipe RUN/recipe-state-proof-result.json` | 0; native callback и EFZ plan из записанного R0 воспроизводят bytes, operation и R2; ноль target executions |
| Отдельные компоненты | `escript scripts/gleam_provider_probe.escript BUILD RUN/p2-model-original.beam RUN/provider-samples.json` | 0 / 264 эквивалентных случая, 40 batches, 36 ordinal samples |
| Отключённая диспетчеризация | `escript scripts/gleam_dispatch_bench.escript RUN/dispatch-samples.json` | 0 / 5 trials × 1M calls на dispatch |

`RUN` сокращает каталог evidence; `BUILD` — `_build/gleam`, `OFF_BUILD` —
частный `_build/default`, `ROOT` — этот репозиторий. Off-копия
содержит обычные закреплённые **исходники** зависимостей, ноль исходных BEAM, без
каталога Gleam или компилятора в PATH. `clean-off-final-isolation.json` подтверждает,
что её production-исходники совпадают с финальным деревом и layer BEAM/app отсутствуют;
`off-runtime.json` дополнительно доказывает, что они не обнаруживаются на VM path.
Rebar переписывает только scratch lock для checkout overrides.

Исполненные fixtures включают malformed boundary/results/version mismatch, limit и
unsupported rejection, success/fallback/error next-state, повторяемую deterministic
mutation, off/fraction-zero exact state, operation/byte counters, recipe tampering,
старую schema 2, обычные corpus persistence/restart и разделение callback faults.
Контролируемые stubs доказывают error-контракты; реальные loop/campaign/codec проверки используют
скомпилированный Gleam и неизменённый парсер Cowlib. Mock не закрывает integration gate.

Начальные сбои сохранены: новые тесты сравнивали configuration maps вместо
runtime state, неверно указали длину fixture, предполагали attempt при 1% за лишь
100 visits, использовали неверную арность trace API, ожидали отсутствие rejection counter, сравнивали
порядок restart и продолжали tracing после barrier. Исправленные тесты проходят. Первая
seed-import диагностика дважды перезагружала уже загруженный harness и вернула
`not_purged` (exit 127); убрана ненужная предварительная загрузка, старая версия очищается
между остановленными кампаниями драйвера. Повтор проходит. Production CLI
не менялся. Финальные fixture-каталоги включают время и unique ID против повторного использования.

## Диагностика fraction и стоимость

Каждый процент использует два явных seed (17 и 43), один engine/backend,
начальный raw `a=1`, 2000 mutation executions на seed, одну calibration и
отдельную warm-up кампанию на 20 executions. Trace отключён. Semantic/oracle
callbacks или дополнительные target executions отсутствуют. Обычная эволюция корпуса разрешена.

| Fraction | Attempts | Successes | Unsupported | Unchanged | Generated bytes | Callback µs | Wall main exec/s, seeds 17 / 43 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1% | 41 | 11 | 29 | 1 | 335 | 607 | 229.9 / 231.5 |
| 5% | 224 | 80 | 130 | 14 | 4962 | 4357 | 173.5 / 183.0 |
| 10% | 391 | 168 | 194 | 29 | 7952 | 7345 | 199.3 / 179.7 |
| 20% | 794 | 324 | 415 | 55 | 15400 | 14568 | 177.5 / 198.1 |

Количества суммируют две измеряемые кампании строки. Все limits/errors равны нулю в
этой серии; явные limit/error fixtures покрывают эти пути отдельно. Количества операций
0..5 находятся в каждом `fractions/SEED/fractionN/summary.json`; их сумма равна
attempts. Выбранный процент — вероятность ветви, не процент успеха.
Все 16000 измеренных mutation executions завершены без layer/infrastructure
ошибок. Structural units сообщаются отдельно; semantic coverage sum не
вводится. Один 20% run заканчивается меньшим числом structural lines; преимущество guidance
из этих samples не выводится.

Отдельные медианные batch deltas пяти trials, включая validated boundary work:

| Input / operation | Decode µs | Core mutate µs | Encode µs | Полный provider µs |
| --- | ---: | ---: | ---: | ---: |
| 8 bytes / append 255 | 1.310 | 0.380 | 0.512 | 2.322 |
| 4096 bytes / empty first value | 363.530 | 52.238 | 165.260 | 488.940 |

Независимые batches не образуют аддитивных временных тождеств. Production-отчёты сохраняют
суммарное время callback; диагностический драйвер даёт конечные per-stage и
ordinal samples без RNG sampling или target execution. Медианная disabled dispatch
разница — **+0.941 ns** для planner и **−0.657 ns** для worker относительно
диагностических controls. Отрицательная delta — шум измерения/code layout,
не результат оптимизации. Временный export_all остаётся в диагностической VM.
Нулевые расходы, ускорение, оптимальная fraction или финальная производительность P5 не заявляются.

## Изменённые файлы, решения и передача

Только P3 `p3-changes.patch` и `p3-changed-files.json` сравниваются с сохранённым
начальным деревом P3, включая untracked source files. Production-правки:
typed catalogue/size preflight и package version, planner provenance/counters,
recipe schema 3, seed producer и один fraction-zero benchmark mode. Новые файлы —
provider tests, component/import evidence drivers и этот отчёт. Обновлены contracts,
guide, ownership/decision документация. Общие build/config,
adapter, corpus, executor, target или dependency lock в P3 не менялись.
`preserved-inputs.json` записывает проверки этих файлов, AGENTS.md и пользовательских prompt-
каталога/zip; исходный корпус не удаляется, Git write/publication не выполняются.
Review выполнен автором, не независимым reviewer или делегированным субагентом.

P4: использовать неизменный normalized-outcome/finite feature contract и существующий
serialized corpus admission; независимо закрыть guided working-corpus selection,
failed persistence retry, historical seen/restart/schema policy и oracle/finding
isolation. P3 доказывает подключение мутаций при отключённом feedback, не полноценное guidance.

P5: проверить полные предикаты replay/minimization и сохранение представителей,
затем выполнить более долгие same-engine контролируемые seed/budget/backend сравнения с
durable finalization и повторами. Сохранить off/zero traces и fixtures schemas
1/2. Текущие RNG metadata воспроизводят конкретную мутацию; restart корпуса —
reuse/calibration, не PRNG checkpoint кампании. Прямые ограниченные вызовы
не гарантируют отмену произвольного зависания. Production cache не оправдан
настоящими измерениями.
