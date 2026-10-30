# Непрерывный фаззинг

[English](../../continuous.md) · **Русский** · [Español](../es/continuous.md) · [简体中文](../zh-CN/continuous.md) · [Все языки](../README.md)

Обычный цикл EFZ в одной VM поддерживает неограниченные random и staged/Gleam
кампании через `max_iterations => infinity`. Конечные кампании сохраняют свои
прежние defaults, лимиты исполнения и поведение при исчерпании мутаций/idle stop.

```erlang
{ok, _} = efz:start(#{target => my_harness, seeds => [<<0>>],
    artifacts => Artifacts, mutation_mode => staged,
    max_iterations => infinity, corpus_dir => "out/corpus"}).
%% Позже, из управляющей VM:
ok = efz:request_stop().
Report = efz:await(infinity).
stopped_by_user = maps:get(status, Report).
ok = efz:stop().
```

`request_stop/0` асинхронен и идемпотентен. Он останавливает планирование после
текущего вызова target/итерации, соблюдая timeout и cleanup. `await/1` возвращает
итоговый отчёт; `stop/0` по-прежнему завершает приложение и должен вызываться
после получения отчёта. Уже завершённая кампания сохраняет исходные status/report.

Для кампаний CLI:

```sh
escript scripts/fuzz.escript --config campaign.term --out out \
  --max-iterations infinity
# Из другого терминала:
touch out/stop.request
```

CLI сохраняет out/report.term и возвращает 0 при запрошенной остановке, если
существующий сбой или нарушение strict coverage policy не приводит к ошибке
отчёта. Перед повторным использованием output directory удалите старый
stop.request. Конечный режим CLI не меняется. Ctrl-C/SIGTERM завершает процесс,
а не выполняет этот протокол штатной остановки с сохранением отчёта.
Внешний launcher `--supervised` сохраняет отдельные конечные политики числа
запусков, перезапусков и deadline; это изменение не снимает эти ограничения.

Подготовка continuous staged добавляет havoc, если его нет среди выбранных
stages, и вычисляет обычную configuration/recipe identity из этого фактического
плана. Детерминированные cursors не сбрасываются. При idle exhaustion выполняется
реальная byte mutation с тем же передаваемым в состоянии PRNG, стандартными
replay operations и счётчиком `continuous_fallbacks`. В непустом input меняется
один бит; в пустой добавляется один байт. Staged infinity требует
max_input_bytes > 0.

Сохранение и persistence корпуса, semantic feedback, primary target execution,
cleanup и replay остаются под управлением EFZ. Gleam provider fallbacks и конечные
oracle budgets не меняются. Когда проход мутаций простаивает, кампания целиком
не перезапускается и не калибруется заново. Infrastructure failures по-прежнему
останавливают её.

Continuous mode ограничивает поясняющий список decisions 1 024 записями и считает
отброшенные decisions; ограниченные recipe traces и runtime-check reports
сохраняют существующие caps. Рабочий корпус и действительно различные finding
groups автоматически не сокращаются, поэтому ёмкость памяти и диска всё ещё
нужно планировать.

См. [управление TUI](tui.md#непрерывный-режим): непрерывный demo и клавиша `s` для
остановки с сохранением.

## Валидация

- Default EUnit: 319 passed; focused continuous tests с Gleam: 9 passed.
- Common Test: 3 passed; xref и Dialyzer прошли; Python TUI checks: 2 passed.
- Focused tests покрывают infinity configuration, replayable fallback для пустых
  и непустых родителей, idle exhaustion без сброса cursor, непрерывный прогресс,
  повторные stop requests и отсутствие executions после итогового отчёта.
- Настоящий Gleam term/API provider работает непрерывно с guided feedback и
  ограниченным oracle budget; тест CLI запрашивает остановку через stop.request
  и проверяет exit 0 и сохранённый отчёт.
- Demo в псевдотерминале прошло более 11 000 мутаций (11 183 на итоговой остановке),
  затем клавиша `s` сохранила report.term и зафиксировала итоговый execution count.
  Отдельный durable-demo сохранил записи input/metadata корпуса и штатно
  остановился после 761 мутации.

Непрерывная работа подтверждается снятием execution cap и проверками границ
progress/stop; эти конечные acceptance runs не утверждают, что проверили
бесконечную длительность или неограниченное хранилище.

## Lifecycle долгоживущих клиентов

Вызовы `efz:await/1` с истёкшим timeout освобождают свои ожидающие записи в
координаторе. Клиенты, погибшие во время ожидания, также отслеживаются мониторами
и удаляются; успешное завершение отвечает оставшимся клиентам и освобождает
их monitors.

Stop requests остаются отзывчивыми во время исполнения target, а повторные
запросы ставят в очередь одну остановку worker. Штатная остановка ждёт возврата
этого execution или достижения настроенного timeout. Сбой worker во время
ожидающей остановки остаётся infrastructure failure в итоговом отчёте.

Остановленную continuous campaign можно перезапустить с тем же `corpus_dir` и
`seeds => []`: сохранённые inputs восстанавливаются и калибруются заново до
возобновления мутаций. Это восстанавливает корпус, но не прежнюю позицию RNG.
