# ADR 0002: source clause/outcome probes с ETS, принадлежащим execution

[English](../../../adr/0002-automatic-coverage.md) · **Русский** · [Español](../../es/adr/0002-automatic-coverage.md) · [简体中文](../../zh-CN/adr/0002-automatic-coverage.md) · [Все языки](../../README.md)

Статус: принято до реализации transform, 2026-09-08.

Baseline: OTP 27.0 / ERTS 15.0, x86_64-pc-linux-gnu; Rebar3 3.25.0.
Существующие семь EUnit tests, компиляция и Dialyzer проходят. В Common Test
нет suites (ноль тестов). В репозитории нет formatter/linter или AGENTS.md.
Phase 1 в основном не закоммичена; сохранить и адаптировать эту реализацию.

## Альтернативы

* Parse transformation abstract forms: установленный compiler предоставляет
  clause bodies и вложенные формы case/if/receive/try/fun до lowering.
  Добавление вызовов в начало bodies сохраняет guards, patterns, порядок
  вычислений и tail position. Явный обход выражений и диагностика ограничивают
  синтаксический риск. Hook может использовать context исполняющего процесса
  и внешнего владельца ETS.
* OTP cover и native coverage: OTP 27 имеет native coverage APIs (проверено в
  установленном модуле code); cover использует native support, когда он доступен.
  Эти средства дают line/function coverage и cover analysis, но их API сбора/
  сброса на уровне модулей не предоставляет EFZ execution references и не
  изолирует посторонние процессы. Адаптер потребовал бы дополнительного
  проектирования изоляции и атрибуции. Мы не измеряли cover и не заявляем
  преимущество по скорости.
* Переписывание Core Erlang или BEAM: lowering скрывает некоторые source outcomes
  и создаёт зависимость от версии compiler и работу по mapping. Редактирование
  недокументированных opcodes добавляет риск верификации, не решая атрибуцию
  execution.

Выбрать один backend abstract forms. Компилировать только source modules из
allowlist независимо от приложения или кампании. Встраивать manifest attribute
в BEAM и записывать sidecar через явный compilation facade. Использовать SHA-256
build namespaces и детерминированные structural probe paths. Не редактировать
текст исходника.

Runtime: один public unnamed ETS set на execution; владелец — monitoring
coordinator исполнителя, находящийся вне target. Coordinator также мониторит
вызывающую сторону и при отмене убивает/дожидается target. Snapshot/delete
хранилища допустимы только после DOWN target. Runtime hooks используют
namespaced process-dictionary context; dictionary не является coverage store.
Ошибки backend — sticky infrastructure failures, даже если обработчики исключений
target их перехватывают.

Кампания: один worker; калибровать seeds, объединять coverage только успешных
executions, сохранять exact set novelty, хранить target crashes отдельно.
Фиксировать build IDs на preflight и отклонять несовместимые observations.
Сохранить manual hit API в отдельном identity namespace только для явного
compatibility mode.

Измерять ordinary, instrumented inactive и instrumented active paths прогретым
повторяемым benchmark. ETS добавляет работу на каждый hit; предпочесть
корректность lifecycle оптимизации. Фиксировать фактические измерения в
docs/coverage.md.

Ссылки: [OTP 27 cover](https://www.erlang.org/docs/27/apps/tools/cover.html)
и [OTP 27 code](https://www.erlang.org/docs/27/apps/kernel/code.html).
Онлайн-документация OTP 27 описывает более поздний patch 27.x; также изучены
установленные exports и исходники. Native support добавлен в OTP 27.
