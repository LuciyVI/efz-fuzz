# P5: финальная приёмка replay, регрессий и сравнений на одном движке

[English](../../../gleam-layer/p5-validation.md) · **Русский** · [Español](../../es/gleam-layer/p5-validation.md) · [简体中文](../../zh-CN/gleam-layer/p5-validation.md) · [Все языки](../../README.md)

Этот отчёт заменяет исторические примечания передачи P5 в P1–P4 и
universal-validation от 10 октября. Этап охватывает поддерживаемый ограниченный
синхронный процесс работы на Linux. Превосходство производительности и обнаружение
независимой уязвимости — отдельные вопросы, не условия завершения
этапа приёмки реализации.

## Изменения финальной приёмки

- Безопасная загрузка schema-1 теперь регистрирует фиксированный legacy-словарь до ETF-
  декодирования. `[safe]` остаётся включённым; артефакты не могут вводить atoms или выбирать
  исполняемые модули.
- Обязательные входы legacy replay — raw `.input` и `.semantic` с контрольной суммой.
  VM-local diagnostic `.term` — необязательный путь, не предварительное условие.
- В диагностике недоступного escript общего replay CLI исправлен вызов
  форматирования. Subprocess-тесты покрывают generic replay, минимизацию, точные бюджеты
  исполнений, неверные аргументы, повреждённый input, отказ заменять существующий output,
  forwarding и успешный native legacy replay без diagnostic `.term`.
- Драйверы сравнения принимают несколько RNG seeds/повторов, измеряют устойчивый допуск
  в корпус и записывают identities исходников/runtime/цели.
- Stateful-счётчики проверяются фактическими защищёнными outcomes цели в
  отдельной свежей VM вне времени кампании. Количество завершённых операций равно
  длине возвращённой трассы. Отказ пакета отличается от принятого
  сценария; primary input execution не называется операцией библиотеки.

## Воспроизведение

Используйте OTP 27, Rebar3 3.25.0, Gleam 1.10.0 и `ERL_FLAGS='+S 2:2'`.
До измерений выполните default и optional compile/tests/CT/xref/Dialyzer.
Подготовьте закреплённую зависимость XML-RPC по `examples/xmlrpc/README.md`.
Полный optional EUnit требует каталог ebin этой зависимости в code path.

Подготовьте два архива исходников, не меняя активный checkout: main на
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b` (default build) и исторический
QS layer на `e4c0244c403d74b041df7e0e2f0dd4465a977453` (Gleam build).
Соберите их одинаковым toolchain с закреплёнными commits зависимостей. Каждая cloud-
задача уже имеет изолированный checkout; Git worktree не нужен.

```sh
python3 scripts/run_semantic_bench.py --out /workspace/scratch/p5-semantic-verified
python3 scripts/run_qs_semantic_bench.py \
  --baseline /workspace/scratch/p5-legacy-baseline/_build/gleam \
  --raw-baseline /workspace/scratch/p5-main-baseline/_build/default \
  --out /workspace/scratch/p5-qs-verified
python3 scripts/verify_p5_evidence.py \
  /workspace/scratch/p5-semantic-verified /workspace/scratch/p5-qs-verified
```

Каждый каталог результата должен быть новым. Подготовка, кампании и callback/stateful-
диагностика выполняются последовательно. Ни тесты, ни компиляция не пересекаются с измеряемой
серией. Canonical-этап использует три seeds (17, 29, 43), два повтора, 500 мутаций, свежие VM/корпусы,
два CPU schedulers и фиксированный target timeout.
QS использует один общий native target artifact для всех движков/режимов. Измеряемая
кампания следует за отдельным warmup из 20 мутаций со свежим измеряемым корпусом.
Серия API/XML/stateful не имеет campaign warmup.

Campaign wall включает setup/calibration и устойчивую запись допуска; VM/driver
wall записывается отдельно. Холодная stateful-диагностика включает executor и
setup/cleanup сценария и не заявляет изолированную задержку отдельной операции.

Финальный статус: **P5 PASS, 13 октября 2026.** Предварительные попытки сохранены
вне checkout и не используются как финальные PASS-доказательства.

## Область приёмки и review

Финальный review повторно проверил callback-границу, авторитетные raw inputs,
явный выбор adapter/target, конечные бюджеты, нейтральность off-пути к RNG,
нейтральность observer, устойчивую identity/повторную калибровку и сохранение
семантического предиката. Новые тесты воспроизводят два холодных legacy-сбоя вместо
опоры на прежние авторские PASS-примечания. Отдельный reviewer или субагент не
использовался; независимый внешний аудит не заявляется.

Произвольная отмена native callback, неуправляемые параллельные вызовы цели,
внешние ресурсы без специального harness, глобально минимальные входы,
точные PRNG checkpoints кампании и deferred oracle остаются вне v1-
контракта. Это документированные исключения области, не невыполненные проверки P5.

## Выполненные финальные проверки

| Проверка | Результат |
| --- | --- |
| Default compile / EUnit | PASS / 308 пройдено |
| Gleam compile / полный EUnit с закреплённым XML-RPC | PASS / 374 пройдено |
| Common Test | 3 пройдено |
| Default и Gleam xref / Dialyzer | PASS для обеих сборок |
| Fresh-VM generic и native legacy replay CLI | 2 пройдено в optional suite; generic path также прошёл в default suite |
| Последовательные API/XML/stateful off/on кампании | 36/36 завершены, по 500 мутаций |
| Последовательные QS main / legacy / disabled / seeds / structured / observation / explicit guided / oracle | 48/48 завершены, по 500 мутаций |
| Эквивалентность raw disabled trace и structural coverage с main | 6/6 пар seed/repeat |
| Нейтральность observation-only mutation trace | 6/6 пар seed/repeat |
| Диагностика фактической stateful-нагрузки | 12/12 завершены, по 501 защищённому input execution |
| Хеши исходников / бюджеты кампаний / отсутствие infrastructure errors / наличие durable corpus | PASS |

Сравнительная серия выполнила 42,000 измеренных мутаций. Каждая измеряемая
кампания использовала новый durable corpus. Существующие полные регрессии отдельно
проверяют restore/recalibration, отклонение identity mismatch, semantic-only
допуск и сохранение представителей. Постоянное хранение корпуса — переиспользование входов,
а не PRNG checkpoint.

### Сводка измерений

Каждая строка содержит шесть samples (три RNG seeds, два повтора). Скорости включают измеренные
calibration/admission расходы. Это конечные измерения, не утверждения о значимости
или пороги приёмки превосходства производительности.

| Серия/режим | Медиана primary executions/s | Semantic-only entries, диапазон samples |
| --- | ---: | ---: |
| QS baseline | 398.4 | 0–0 |
| QS old | 388.7 | 0–1 |
| QS new | 380.3 | 1–1 |
| QS off | 405.0 | 0–0 |
| QS seeds | 412.3 | 0–0 |
| QS structured | 385.9 | 0–0 |
| QS observation | 374.8 | 0–0 |
| QS oracle | 377.9 | 0–1 |
| API generic-off | 388.7 | 0–0 |
| API generic-on | 390.3 | 1–1 |
| API xmlrpc-off | 320.0 | 0–0 |
| API xmlrpc-on | 303.0 | 3–4 |
| API stateful-off | 382.7 | 0–0 |
| API stateful-on | 390.8 | 1–1 |

Отключённый путь сохраняет детерминированное raw-поведение и не загружает
Gleam-модель. On-режимы реально получают semantic-only admissions; это подтверждает
интеграцию, а не независимое обнаружение дефектов. Эти samples не доказывают
ускорение, оптимальную structured fraction или нулевые накладные расходы.

### Фактические stateful-операции

Эти количества получены из завершённых защищённых исполнений записанной packet-
нагрузки в отдельных диагностических VM. Они согласуются с canonical-реконструкцией
пакетов. Scenario wall включает executor и setup/cleanup дочерних процессов; это
не benchmark изолированной задержки gen_server-вызова.

| Режим | Принятые сценарии, шесть workloads | Завершённые операции библиотеки | Отклонённые пакеты |
| --- | ---: | ---: | ---: |
| off | 12 | 36 | 2994 |
| on | 178 | 562 | 2828 |

### Контролируемые discovery-испытания

Три дополнительных fresh-VM запуска по 1,000 мутаций использовали явно искусственный
`efz_qs_defect_target`, одинаковые начальные bytes `abc=1`, существующий `bug`
словарь и seeds 17, 29 и 43. Seeds 17 и 29 нашли внедрённое нарушение
свойства; seed 43 завершился без находки (цензурирован по бюджету исполнений).
Все завершились без infrastructure errors. Отдельный legacy CLI-тест
воспроизводит и минимизирует это свойство в новой VM. Ни один результат не представлен как
новая уязвимость или превосходство discovery на реальной библиотеке.

## Доказательства и вывод

[validation.json](../../../gleam-layer/p5-evidence/validation.json) записывает toolchain, хеши исходников и логов,
хеши raw artifacts и discovery outcomes.
[gates.json](../../../gleam-layer/p5-evidence/gates.json) записывает проверки budget/trace/stateful и финальные
сводки измерений. Рядом сохранены манифесты обеих серий.
Полные логи, inputs, recipes, reports и durable corpora остаются в корнях raw-
evidence, перечисленных в validation.json; generated BEAM не коммитятся.

Все ранее открытые исполняемые пункты P5 закрыты для заявленного контракта.
Невыполненных обязательных команд P5 нет. Merge review может опираться на сохранённые
проверки и инструкции воспроизведения; превосходство производительности не заявляется.
