# P2: необязательная нативная интеграция BEAM

[English](../../../gleam-layer/p2-integration.md) · **Русский** · [Español](../../es/gleam-layer/p2-integration.md) · [简体中文](../../zh-CN/gleam-layer/p2-integration.md) · [Все языки](../../README.md)

Текущая приёмка P5 записана в [p5-validation.md](p5-validation.md).
Утверждения о передаче и незавершённом статусе ниже описывают исторический запуск этапа.

Требования **2.0-native**; контракт **v1**, вектор `{1,1,1,1,1,1}`.
**Функциональная проверка P2: PASS.** Доказательства находятся в
`artifacts/gleam-layer/20261008-p2-native/`; `gates.json` индексирует команды,
exit codes, хеши исходников и сохранённые неудачные попытки. Это не закрывает приёмку P3/P4,
независимый review или финальные benchmarks P5.

## Область и ответственность

Прочитаны common context, фактические P0 baseline/execution-path и контракты P1.
HEAD остаётся `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`; dirty state записано
до редактирования. Единственный ведущий отвечает за package/API, adapter/tests, общую сборку
и конфигурацию. Субагенты и независимый reviewer не использовались.

Необязательные профиль, пакет, hook EFZ и существующий код P3/P4 уже
присутствовали к началу прохода. P2 добавляет полную startup-проверку экспорта, ограниченную tagged-error диагностику, реальные
BEAM-fixtures достижимости/lifecycle, конечный диагностический драйвер и доказательства.
Production structured policy или semantic guidance не добавляются. Model/core,
mutation planner, worker, corpus, configuration и build hook не менялись
относительно входного snapshot P2. Пользовательские prompts, ZIP, AGENTS.md и lock-файлы сохраняют
хеши. Commit, push, PR, удаления корпуса и глобальных изменений не было.

Файлы текущего прохода: `src/efz_gleam_adapter.erl`,
`test/efz_gleam_beam_tests.erl`, `test/efz_gleam_layer_tests.erl` (экспорты fault stub),
`scripts/gleam_beam_bench.escript`, этот отчёт, `contracts.md`, `architecture.md`,
`user-guide.md`, `baseline.md` (пути toolchain), `agent-plan.md` и `decision-log.md`. Ограниченный diff —
`p2-changes.patch`; generated artifacts не являются изменениями исходников.

## Toolchain, профиль и артефакты

Фактические инструменты: **OTP 27.0 / ERTS 15.0**, **Rebar3 3.25.0**, **Gleam 1.10.0**,
Linux x86_64, `+S 2:2`. Компилятор локальный:
`/tmp/efz-gleam-toolchain/gleam`, SHA-256
`5d86c226aad4fb32e501bc1a6c5c90394e3bd3e462476b1552f4b734e74f7906`.
Глобальные установка/обновление не нужны. `gleam.toml` фиксирует `== 1.10.0`, target
`erlang`; `manifest.toml` содержит ноль пакетов. Закрепления Rebar/Cowboy/Cowlib/Ranch
не менялись, фактические Git HEAD зависимостей проверены (`toolchain.json`).
Основной runtime root — `/home/fbogoslavskii/.asdf/installs/erlang/27.0`.
Первоначальная minimal-PATH off-сборка выбрала системный OTP 27.3.4.13 / ERTS
15.2.7.9. Эта дополнительная успешная сборка/проверка сохранена в `system-otp-off/`;
финальная независимая off-проверка явно выбирает bin-каталог основного OTP 27.0
без Gleam в PATH (`toolchain-paths.json`).

`rebar.config` включает `scripts/build_gleam.sh` только в профиле `gleam`:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam ERL_FLAGS='+S 2:2' rebar3 as gleam compile
```

Hook вызывает `gleam export erlang-shipment`, затем копирует
`efz_qs_model.beam` и нормализованный `efz_semantic.app` в
`_build/gleam/lib/efz/ebin/` (`gleam+test` для EUnit). Runtime app metadata перечисляют
только `efz_qs_model`, без application dependencies. Сгенерированный неиспользуемый CLI
launcher исключён. Старт/загрузка optional application не нужны и не наблюдались.

Закреплённый 1.10.0 фактически выдаёт три generated Erlang source в дереве сборки;
Rebar-интеграция потребляет только BEAM/application artifacts. Она не
компилирует и не ищет generated `.erl`. Две сборки с архивированием частного Gleam cache
между ними дали одинаковые SHA-256 модели и `.app`
(`reproducibility.json`). Байтовая идентичность при разных абсолютных source paths
не заявляется; пути compiler/debug могут менять хеши файлов.

Проверены первичные ссылки: [Gleam externals](https://gleam.run/documentation/externals/),
[публичные API покрытия OTP](https://www.erlang.org/doc/apps/kernel/code.html) и
[анонс компилятора Gleam 1.19](https://gleam.run/news/gleam-doesnt-compile-to-erlang-source-anymore/).
Этап подтверждают установленные исходники OTP 27 и фактический output закреплённого компилятора;
более новый анонс не доказывает артефакты 1.10.0 и не является указанием обновиться.

## Фактический runtime-путь и граница

Прослеженная цепочка:

`efz_config:prepare/1 → efz_gleam_adapter:prepare/2 → existing EFZ lifecycle/worker`

`efz_qs_target:run/1 → efz_cov_native_public:collect/1 → efz_gleam_adapter:oracle/3`

`→ efz_gleam_adapter:decode/2 → efz_qs_model:decode/2 → efz_qs_model:check/2 → EFZ report`.

Нативный plugin — фиксированный adapter/dispatch P1, не вторая plugin-платформа.
Фактические экспорты compiled core: `versions/0`, `decode/2`, `encode/2`,
`normalize/1`, `generate/2`, `mutate/3`, `observe/4` и `check/2`.
`prepare/2` загружает/проверяет их один раз, начиная с версий. Отсутствующий экспорт
возвращает `{gleam_configuration,{gleam_callback_unavailable,Function,Arity}}`.
Горячие callbacks используют обычный BEAM `apply(efz_qs_model,Function,Args)` без module
lookup, dynamic loading, старта application или transport-сериализации.

`hook_trace/0` запускает реальную native-coverage кампанию EFZ с fraction zero,
feedback disabled, одной чистой inline oracle-проверкой и без mutation iterations.
Trace подтверждает target → primary snapshot → adapter → реально скомпилированный Gleam;
рабочие callbacks исполняются на существующем worker EFZ. Startup model lookup выполняется один раз.
Результат: один Pass, ноль дополнительных вызовов цели, нет structured counters или
semantic state. `beam-proofs-complete/hook/trace.json` непосредственно записывает проверенную
последовательность вызовов; соседний `proof.term` сохраняет отчёт без trace-
аргументов. `runtime-root.json` записывает фактические exports/imports/layout.
Core импортирует только Erlang builtins; единственный объявленный FFI — `erlang:bit_size/1`.

Адаптер проверяет aligned binary против text/bitstring, tuple tags/arity,
proper lists, целые, ограниченные limits/models/results/features и фиксированные error-
tags. Нет unsafe Dynamic или atoms, полученных из входа. Проверяются пустые, non-UTF8, ровно
4096-байтовые входы, oversized input, malformed results, неверные версии и отсутствующие
экспорты. Unsupported/limit отличается от layer error. Диагностические
причины остаются ограниченными; находки цели сохраняются до последующей ошибки слоя.

## Выполненные проверки

Команды выполнялись последовательно с `ERL_FLAGS='+S 2:2'`. Точные argv/cwd/env/exit находятся в
соответствующих `.json`; логи сохраняют полные результаты тестов.

| Команда/проверка | Exit | Результат / артефакт |
| --- | --- | --- |
| Частный source-only `rebar3 compile`, основной OTP bin + `/usr/bin:/bin`, несуществующий GLEAM_BIN | 0 | `pinned-off-build`: нет каталога/компилятора/артефактов Gleam, ноль BEAM до сборки |
| Частный off EUnit: smoke, BEAM/contract/layer, phase2, mutation модули | 0 | **52 пройдено**, `pinned-off-tests-final` |
| Корневой off EUnit: BEAM/contract/layer модули | 0 | **9 пройдено**, `off-focused-final` |
| Частный `rebar3 as gleam compile`, дважды | 0 / 0 | `clean-on-first`, `clean-on-second`; одинаковые хеши пакета |
| Корневой `rebar3 as gleam compile` | 0 | `on-build`; фактический optional shipment |
| Корневой on EUnit: BEAM/contract/layer модули | 0 | **32 пройдено**, `on-focused-final` |
| On EUnit BEAM-модуль после уточнения snapshot-trace/JSON | 0 | **7 пройдено**, `beam-trace-json-corrected` |
| `rebar3 as gleam xref` | 0 | `on-xref-final`, нет undefined runtime calls |
| Fresh-VM проверка exports/layout, частная дважды и корневая | 0 | `runtime-first`, `runtime-second`, `runtime-root` |
| Свежие кампании, baseline/off/on-runtime-off, seeds 17 и 43 | По 0 | 100 mutation candidates/mode/seed; exact traces совпадают, `complete-raw-equivalence/` сравнен с неизменяемыми P0 traces |
| Диагностические dispatch и BEAM драйверы | 0 | `dispatch-overhead`, `beam-overhead-complete`; samples ниже |

Частные source-only сборки используют копии закреплённых **обычных** исходников зависимостей,
не cached dependency BEAMs, через Rebar `_checkouts`. Rebar переписывает
только scratch lock; repository locks остаются неизменными. Новая сетевая
загрузка зависимостей не заявляется. `prepare_scratch.py` / `prepare_on.py` и preparation
JSON записывают пути и хеши исходников. Off физически остаётся без пакета/артефактов
после всех проверок (`clean-off-final-isolation.json`). Существующий несвязанный C
launcher собирается как обычно; это не Gleam bridge.

Runtime-off в on-сборке отдельно трассируется contract-fixture: ноль рабочих
callbacks и semantic state. Свежие raw-кампании также не имеют model/application
load или layer counters. Candidate/stage/parent hashes совпадают с P0 и clean off;
точная эквивалентность RNG плана остаётся покрыта `determinism/0` и `fallback_rng/0`.
Существующая семантика term executor и обычные raw mutation tests проходят.

`repeated_calls/0` выполняет 1000 пар decode/encode без изменения process dictionary,
затем две независимые кампании со свежими oracle budgets и очисткой владельца.
Fault-fixtures проверяют, что malformed/throwing callbacks сохраняют управляющий
fuzzer живым при заданной stop policy, сохраняют более раннюю находку цели
и допускают последующую здоровую кампанию. Mocks закрывают только эти error-контракты.

Сохранённые промежуточные сбои: предупреждение shadowed stub-variable (exit 1), отсутствие
scratch `fixtures/` с отменой legacy setup (exit 1) и трассировка
`collect_profiled/1`, тогда как непрофилированная кампания вызывала `collect/1` (exit 1).
И test-stub, и trace-JSON comprehensions сначала содержали shadowed variables;
warnings-as-errors отклонил их до тестов, исправленные запуски проходят. Необязательный
fresh-VM report-summary helper отклонил неизвестные report atoms при safe
ETF decoding; от него отказались без unsafe decoding, trace-fixture
теперь пишет JSON напрямую. `unused-proof-summary.json` отмечает helper как
не являющийся gate. Исправления не превращают неуспешные команды в успешные.
Соответствующие финальные повторные проверки выше проходят. Отменённые тесты
и неверный trace assertion не считаются доказательствами.

## Наблюдаемость и измеренные расходы

Production-отчёты EFZ сохраняют существующие oracle/observer/structured/outcome counters
и суммарные времена. Детальные call/reason/byte counters и выборочные timings
явно диагностические и собираются `gleam_beam_bench.escript` без
production-state или PRNG draws. Его 48 фактических вызовов адаптера дают 16 success,
8 unsupported, 8 limit, 16 boundary rejection, ноль layer exceptions; 32 decode /
16 encode calls, 32912 binary input bytes и 64 encoded output bytes. Шесть временных
samples выбираются порядково каждым седьмым вызовом с пределом шесть. Полные payloads
не логируются; ограниченные failure tests отдельно вызывают layer exceptions.

Пять последовательных чередующихся испытаний: dispatch использует 1M calls/trial, малые BEAM-
компоненты — 20K, maximum-input decode — 500. Медианные samples после вычитания control:

| Компонент | Медиана | Диапазон пяти trials |
| --- | --- | --- |
| Добавочная стоимость disabled plan dispatch | 0.546 ns | 0.189–0.622 ns |
| Добавочная стоимость disabled worker dispatch | −0.282 ns | −1.958–−0.022 ns |
| Проверка input + model boundary, 8-байтовый вход | 26.7 ns | 25.85–27.05 ns |
| Реальный core decode / adapter decode | 667.85 / 735.65 ns | 660.0–686.2 / 729.35–766.9 ns |
| Реальный core encode / adapter encode | 193.6 / 236.5 ns | 184.85–196.65 / 235.8–248.0 ns |
| Чистый adapter oracle | 882.85 ns | 872.75–895.45 ns |
| Core / adapter decode, 4096-байтовый вход | 171.974 / 173.088 μs | 170.902–173.252 / 172.176–174.044 μs |

Отрицательная dispatch delta и малая direct-check delta ниже уровня достоверной
интерпретации добавочной стоимости, а не доказательства ускорения или нулевых расходов. Компоненты
измерены независимо; вычитание их медиан не является точным аддитивным
разложением стоимости. Diagnostic clock samples включают стоимость часов и выполняются отдельно
от пакетного измерения. Временный export_all ограничен диагностическими VM.
Накладных расходов layer worker/messages нет. Преимущество кампании по скорости не заявляется.

## Ограничения и передача

Production callbacks остаются прямыми ограниченными BEAM-функциями без дополнительных semantic
workers, queue, cache, ETS, нового NIF, port, socket/RPC, JSON/ETF transport, внешнего
движка, JavaScript target или OTP patch. Существующая изоляция цели и VM-scoped
сериализация покрытия не меняются; неуправляемые параллельные вызовы цели остаются
вне контракта. Async response protocol не используется.

Hang-fixture убивает monitored **test-only** Erlang worker через 30 ms и
подтверждает DOWN/cleanup. Это не доказывает отмену произвольных direct/native
callbacks и не добавляет production worker/deadline mechanism. Будущий дорогой
oracle требует отдельно одобренного ограниченного EFZ supervision/execution контракта.

P3 должен проверить существующие typed provider, seed preparation, recipes и RNG
transitions без незаметного изменения core representation. P4 должен проверить
существующий semantic consumer/admission и отдельный канал находок по P1.
P5 должен закрыть финальные replay/minimization/regression и same-engine campaign
benchmarks. Ни завершение всего пакета, ни независимый review не заявляются.
