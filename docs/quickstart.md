# Подготовка и запуск EFZ

Состояние проверено 15 сентября 2026 года на OTP 27.0 / ERTS 15.0,
Rebar3 3.25.0, Linux x86_64. Основной coverage-guided loop уже работает:
mutation → target → новые probes → retain → повторное использование input как parent.
Это подтверждает [интеграционный тест реального staged engine](../test/efz_feedback_loop_tests.erl).
Текущая область применения — синхронный `Module:run(binary())` и controlled
descendants; произвольное OTP-приложение пока не является поддержанным target.

## Собрать и подготовить

Нужны `erl`, `erlc`, `escript` из Erlang/OTP **27 или новее** и `rebar3` в `PATH`.
Минимум задан сборкой; другие версии OTP пока не проверены этим запуском.
Внешних Rebar dependencies нет. Скрипт не устанавливает системные пакеты.

Из корня checkout `efz/`:

```sh
escript scripts/prepare.escript
```

[Скрипт](../scripts/prepare.escript) проверяет инструменты и OTP, выполняет
`rebar3 compile` в default profile, компилирует существующий
[efz_staged_parser](../examples/staged/efz_staged_parser.erl) через
`efz_instrument:compile/2`, проверяет BEAM/manifest и `run/1`, копирует raw seeds.
В конце печатает полную команду запуска с абсолютными, shell-quoted путями.
Кампанию исполняет существующий `scripts/fuzz.escript`; нового fuzzing engine нет.

Повторная подготовка сохраняет идентичные seed files, corpus и findings.
При отличающемся содержимом одноимённого seed скрипт возвращает ошибку и сохраняет
пользовательский файл. Instrumented target пересобирается. Подготовку и fuzzing
следует запускать последовательно: rebuild во время кампании нарушает pinned identity.
Некорректные аргументы, ошибки сборки и файловой системы дают ненулевой exit code.

```sh
escript scripts/prepare.escript --help
# Собственный каталог данных; относительный путь считается от текущего cwd:
escript scripts/prepare.escript --dir /tmp/my-efz-run
```

Скрипт можно вызывать абсолютным путём из любого каталога. Default output —
`efz/_build/quickstart/`. Для длительной работы задайте `--dir` вне `_build`, чтобы
ручная очистка build-каталога не удалила corpus/crashes. Скрипт их сам не удаляет.

## Тестовый корпус

Исходные файлы находятся в [examples/staged/corpus](../examples/staged/corpus/),
рабочие копии — в `_build/quickstart/seeds/`. Все пять inputs завершают calibration
успешно. Готового crashing input в исходном корпусе нет.

| Файл | Точные bytes (hex) | Назначение |
|---|---|---|
| `00-empty.seed` | пусто, 0 байт | Empty-input clause и мутации от пустого seed |
| `01-zero.seed` | `00` | Числовые boundary/arithmetic paths, получение `80` и `01` |
| `02-near-token.seed` | `55 4f 4b 45 4e` (`UOKEN`) | Один bit flip первого байта до `TOKEN`, новая успешная clause |
| `03-near-crash.seed` | `43 4f 4f 4d 21` (`COOM!`) | Один bit flip либо arithmetic −1 первого байта до `BOOM!` |
| `04-binary.seed` | `00 ff 80 41 0d 0a` | NUL, non-UTF-8 и CR/LF передаются без преобразований |

В текстовых seeds нет завершающего newline. Последние два байта binary seed —
намеренные CR/LF. README и dictionary в seed directory не кладутся: CLI читает
каждый regular file как input. `tokens.hex` остаётся отдельно и используется
словарным [staged example](../examples/staged/run.escript); у общего CLI пока нет
опции dictionary, здесь работают штатные default stages.

## Запустить фаззинг

Все команды ниже — из `efz/`, после подготовки:

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_staged_parser \
  --seeds _build/quickstart/seeds \
  --out _build/quickstart/findings \
  --artifacts _build/quickstart/instrumented \
  --corpus-dir _build/quickstart/corpus \
  --mutation staged \
  --coverage-policy strict \
  --timeout 1000 \
  --max-input-bytes 4096 \
  --max-iterations 1000
```

Это ограниченная кампания: 1000 mutation executions плюс calibration.
Четыре BEAM schedulers в `ERL_FLAGS` не означают четыре EFZ workers: worker один.
`BOOM!` намеренно вызывает `error(artificial_staged_exception)` в учебном parser;
это демонстрационная ошибка, не найденная уязвимость Erlang/OTP. Target crashes
сами по себе не дают ненулевой exit code. Infrastructure error даёт exit 1,
неверная CLI/config — exit 2. Остановка по execution budget выводит `completed`.

| Путь | Содержание |
|---|---|
| `_build/quickstart/instrumented/` | BEAM и `.efz-manifest` выбранного parser |
| `_build/quickstart/seeds/` | Пять исходных raw inputs |
| `_build/quickstart/corpus/` | Initial seeds и успешные discoveries, SHA-256 content identity |
| `_build/quickstart/findings/report.term` | Binary ETF report: stats, active corpus, recipes, crash groups |
| `_build/quickstart/findings/crashes/` | Bounded representatives: `.input`, `.term`, `.recipe`, `.replay`; durable counters |

Повторное использование сохранённого corpus в новой VM:

```sh
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --target efz_staged_parser \
  --artifacts _build/quickstart/instrumented \
  --corpus-dir _build/quickstart/corpus \
  --out _build/quickstart/restored-findings \
  --mutation staged --coverage-policy strict \
  --timeout 1000 --max-input-bytes 4096 --max-iterations 1000
```

Restored inputs заново проходят calibration. Это новая campaign, а не точное
продолжение RNG/cursor/global coverage. Несовместимый build отклоняется; осознанное
переключение на новую сборку допускает `--corpus-build-policy recalibrate`.
См. [durable corpus](corpus.md). Существующий `report.term` перезаписывается при
повторном использовании того же `--out`; разные output directories сохраняют оба отчёта.

Воспроизведение первого сохранённого representative:

```sh
EFZ_CRASH_INPUT=$(find _build/quickstart/findings/crashes -name artifact.input -type f -print -quit)
test -n "$EFZ_CRASH_INPUT" && \
  ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
    --input "$EFZ_CRASH_INPUT" --target efz_staged_parser \
    --artifacts _build/quickstart/instrumented --max-input-bytes 4096

test -n "$EFZ_CRASH_INPUT" && \
  ERL_FLAGS='+S 4:4' escript scripts/replay.escript \
    --recipe "${EFZ_CRASH_INPUT%.input}.recipe" --target efz_staged_parser \
    --artifacts _build/quickstart/instrumented --max-input-bytes 4096
```

Оба варианта проверяют saved build/harness identity; успешный verdict —
`reproduced`, exit 0. Raw `.input` остаётся authoritative artifact.
Для собственного target используйте [общий CLI и правила instrumentation](cli.md).

## Что осталось до более широкого применения

Для синхронных binary targets EFZ уже работает как coverage-guided fuzzer.
Следующие задачи расширяют область применения и надёжность длительных campaigns;
они не означают отсутствия основного feedback loop.

| Приоритет | Работа | Текущее ограничение и критерий готовности |
|---|---|---|
| P1 | Disposable Erlang VM backend | Guardian очищает controlled descendants, но не произвольную OTP application, NIF, ports или внешнее состояние. VM halt/native crash должны классифицироваться родительским runner с сохранённым input; timeout/cancellation должны уничтожать всю принадлежащую запуску VM. См. [execution contract](execution-isolation.md). |
| P1 | Повторная calibration и feature stability | Сейчас каждый initial/restored seed исполняется один раз (`efz_worker:handle_info/2`). Нужны повторные exact coverage/outcome observations, диагностика нестабильности и A→dirty→A/fresh-VM проверки. Детерминизм recipe не гарантирует детерминизм target. [Предлагаемая модель](calibration-readiness.md) ещё не реализована. |
| P1 | Расширение и проверка instrumentation на OTP | Сейчас это source clause/outcome probes. Comprehensions, `maybe` и nonliteral record defaults отклоняются strict transform либо получают ограничения. Нужны semantic-equivalence tests, реальные parser harnesses и CI по заявленным версиям OTP; нельзя выдавать partial probes за полное branch/edge coverage. См. [поддержанную syntax](coverage.md). |
| P1 | Эксплуатация длительных кампаний | Exact checkpoint/resume отсутствует; durable corpus сохраняет только reusable inputs. Нужны отдельные контракты checkpoint, crash-store recovery/migration и общей disk quota. Лимит representatives действует на одну signature; stale writer lock сейчас требует разбора оператором. [Crash storage](replay.md). |
| P2 | Уменьшение corpus и crashes | Content dedup уже есть; coverage-preserving corpus minimization и crash-input reduction пока нет. Проверка: уменьшенный input сохраняет signature на pinned build; минимизированный corpus сохраняет объединение probes. |
| P2–P3 | CLI mutation config и дальнейшее scheduling | Словарь/stages/RNG доступны через Erlang config, общий CLI пока их не выводит. Затем — удобная проверка config, очереди favored inputs и независимые VM workers. `efz_config` сейчас допускает только `workers => 1`; внутривиртуальный parallel pool нарушил бы текущую модель изоляции. |

Минимальный следующий этап для интеграции со stateful Erlang/OTP — disposable VM
backend и regression suite его lifecycle. Для текущих синхронных parsers полезнее
сначала повторная calibration и minimization. Distributed execution и UI не
заменяют эти проверки корректности.

## Проверка этой подготовки

На чистом quickstart store получено: `completed`, 5 calibrations, 1000 executions,
3 discoveries, 8 active inputs, 2 crash occurrences одной signature и 0 infrastructure
failures. Первый crash: `COOM! → BOOM!`, parent ID 4,
`stage = arithmetic`, `operations = [{add,0,8,big,-1}]`.
Счётчики произвольного повторного запуска могут отличаться: CLI не фиксирует RNG,
а сохранённый corpus изменяет начальное состояние.

Raw/recipe replay и restore проверены в отдельных Erlang VM. Новая campaign без
`--seeds` загрузила 8 inputs, выполнила 8 calibrations и 100 mutation executions
без infrastructure failures. Проверены повторная
подготовка без изменения findings/corpus, запуск из другого cwd, пробел/апостроф в
пути, неизвестная опция, пропущенный аргумент, конфликт seed и недоступный output.
Локальные результаты: `_build/quickstart-checks/`.

Полный набор проверок: `rebar3 compile`, `rebar3 eunit` (**186 passed**),
`rebar3 ct` (**3 passed**), `rebar3 xref`, `rebar3 dialyzer` — все exit 0.
Setup/CLI smoke checks выполнены дополнительно; они не входят в число EUnit tests.
