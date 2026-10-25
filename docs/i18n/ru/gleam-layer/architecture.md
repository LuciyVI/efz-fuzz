# Нативная архитектура Gleam — контракт v1

[English](../../../gleam-layer/architecture.md) · **Русский** · [Español](../../es/gleam-layer/architecture.md) · [简体中文](../../zh-CN/gleam-layer/architecture.md) · [Все языки](../../README.md)

Требования: **2.0-native**. Контракт: **1**. Базовая ревизия:
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b`. Здесь описан текущий checkout,
включая код интеграции, существовавший до аудита P1. Фактические результаты P0
и обход ограничения каталогов исходников приведены в [baseline.md](baseline.md).

## Владельцы состояния EFZ и точки расширения

Пути заданы относительно репозитория; арности функций — часть карты исходников.

| Ответственность | Фактический владелец в EFZ |
| --- | --- |
| Жизненный цикл кампании/отчёт | `src/efz_fuzzer.erl:init/1`, `handle_info/2`, `terminate/2` |
| Калибровка/основной цикл | `src/efz_worker.erl:handle_info/2`, `staged_iteration/1` |
| Родитель/планировщик | `src/efz_corpus.erl:select/0`, `mutation_entries/0`; `src/efz_mutation_plan.erl:next/2`, `visit/2` |
| Диспетчеризация/операции мутаций | `src/efz_mutation_plan.erl:attempts/6`, `structured/3`, `ordinary_attempts/6`; `src/efz_mutation.erl:apply_operation/3` |
| PRNG | Staged: `src/efz_mutation_plan.erl:new/1`, `uniform/2`; прежний random: `src/efz_worker.erl:init/1`, `src/efz_mutator_random.erl:mutate/2`; выбор: `src/efz_corpus.erl:init/1`, `handle_call/3` |
| Цель/тайм-аут/reset/очистка | `src/efz_executor.erl:run/4`, `invoke/4`; `src/efz_guardian.erl:run/6`, `start/6`, `cleanup/2`, `finish/2` |
| Снимок покрытия | `src/efz_guardian.erl:finish/2`; существующие `src/efz_cov_native_public.erl:collect/1`, `collect_profiled/1` и backend-реализации `src/efz_coverage.erl` |
| Структурная новизна | `src/efz_feedback.erl:evaluate/3` |
| Корпус/допуск/постоянное хранение | `src/efz_worker.erl:retain_layer/4`; `src/efz_corpus.erl:admit_semantic/4`, `semantic_admission/6`, `add_checked/3`; `src/efz_corpus_store.erl:save/4` |
| Находки/отпечаток | `src/efz_worker.erl:record_failure/4`; `src/efz_crash.erl:signature/2`, `save/4`; `src/efz_crash_store.erl` |
| Рецепты/raw/property replay | `src/efz_recipe.erl:make/4`, `regenerate/1`, `execute/5`; `src/efz_replay.erl:run/6`; `src/efz_semantic_replay.erl:run/5`, `minimize/6` |
| Консервативное сокращение корпуса | `src/efz_semantic.erl:cover/1`, предложение подмножества только для чтения; без удаления во время кампании |

Существующие behaviour: `src/efz_mutator.erl:mutate/2` и
`src/efz_target.erl:run/1`. Behaviour мутатора обслуживает обычные случайные мутации;
он не передаёт состояние RNG staged-плана или семантические вердикты. Слой
расширяет диспетчеризацию этого плана одним фиксированным проверяемым `efz_gleam_adapter`.
Вторая платформа behaviour или реестр плагинов не нужны. Префикс `efz_` соответствует
существующим именам модулей. Gleam возвращает данные; все решения планирования остаются за EFZ.

## Управляющий, рабочий и холодный пути

**Управление:** `efz_config:prepare/1` проверяет существующие возможности покрытия/цели,
затем `efz_gleam_adapter:prepare/2` проверяет опции, пакет, ограничения и версии.
Также он однократно проверяет каждый необходимый экспорт ядра. В [p2-integration.md](p2-integration.md)
зафиксированы фактические артефакты компилятора, чистые сборки и трассировка достижимости callbacks.
`efz_fuzzer:init/1` запускает существующих владельцев состояния. `scripts/gleam_seeds.escript`
отдельно подготавливает raw seed-файлы до цикла; включение во время исполнения независимо.

**Рабочие данные:** EFZ выбирает родителя и lane, выбирает необязательное структурное семейство,
затем декодирует/мутирует/кодирует только эту ветвь. Обычные мутации остаются в том
же плане. Та же точка входа цели работает под executor EFZ. Завершённый снимок
предшествует observer/oracle и сериализованному допуску EFZ. Диспетчеризация при off/нулевой
доле не добавляет обращений к RNG; неподдерживаемые/некорректные входы сохраняют обычный путь.

**Холодный путь:** EFZ хранит ограниченные декларативные рецепты и неизменяемые sidecar-файлы находок.
Replay/минимизация явно используют его executor. Текущий inline oracle — чистый и
ограниченный бюджетом, без дополнительных вызовов цели. Отложенные/дорогие онлайн-oracle
не поддерживаются контрактом v1; их выбор отклоняется при старте. Будущая поддержка должна
использовать существующие границы supervision/исполнения и конечные бюджеты.

## Изоляция покрытия и совместимость

P0 подтвердил публичное нативное покрытие строк в OTP 27.0. Счётчики имеют область модуля,
а не процесса. `efz_guardian:run/6` регистрирует `efz_execution_guardian`; другое
исполнение EFZ получает `runner_busy`. `loop/1` дожидается потомков и trace-барьеров
перед снимком покрытия в `finish/2`; `efz_executor:run_pinned/4` также
ждёт завершения guardian. Интервал:

`reset/open → target → completion/cleanup barrier → snapshot → callbacks → admission`.

Манифесты включённого адаптера могут выбирать только `cow_qs`, исключая EFZ, Gleam,
harness/адаптер и oracle. Неуправляемые вызовы выбранных модулей в той же VM
находятся вне этого контракта изоляции. Асинхронного semantic observer/очереди поздних
ответов нет. Любой будущий oracle с повторным вызовом цели требует отдельного сериализованного
интервала EFZ после основного снимка, идентификаторов исполнения/кампании и отдельных
счётчиков исполнений.

Остальные существующие backend-реализации покрытия сохранены; явный выбор никогда не
заменяется незаметным fallback. Низкоуровневый executor сохраняет term-входы. Кампании
уже требовали binary в P0; первый адаптер не вводит нового ограничения для
других API. Не добавляются C ABI, NIF, port, дополнительная VM, внешний движок или патч OTP.

## Ответственность и review

Ведущий отвечает за этот проход документации/тестов P1, общую конфигурацию, цикл
и корпус. Активных исполнителей нет; делегированное или независимое review не заявляется.
В [p1-validation.md](p1-validation.md) записаны проверки исходников, тесты, ограничения
и передача P2/P3/P4. Существующие требования пользователя и `AGENTS.md` сохранены.
