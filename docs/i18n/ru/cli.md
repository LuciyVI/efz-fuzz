# Универсальный launcher фаззинга

[English](../../cli.md) · **Русский** · [Español](../es/cli.md) · [简体中文](../zh-CN/cli.md) · [Все языки](../README.md)

`scripts/fuzz.escript` загружает скомпилированное приложение EFZ относительно
расположения скрипта, поэтому его можно вызывать из другого рабочего каталога.
Пути в аргументах задаются относительно рабочего каталога вызывающего процесса.
Сначала выполните `rebar3 compile`.

`--coverage-feedback presence|hit_count` выбирает feedback покрытия. По умолчанию
используется `presence`; `hit_count` — экспериментальный режим точных счётчиков,
описанный в [отчёте об измеренном прототипе](hit-count-experiment.md). Он меняет
правила сохранения успешных входов, используя тот же launcher и движок фаззинга.

Launcher один раз вызывает `efz:start/1`, ждёт через `efz:await/1`, сохраняет
отчёт и останавливает EFZ в блоке `after`. Конфигурация, preflight
инструментирования, калибровка, мутация, планирование, исполнение, покрытие,
сохранение входов и классификация crash используют существующее ядро.
`efz_instrument:discover/1` строит описания artifacts из каталога; `preflight/1`
проверяет их встроенные manifests, парные sidecars и identities загруженного кода
до исполнения любого входа.

## Минимальный внешний harness

Создайте `my_parser.erl`:

```erlang
-module(my_parser).
-export([parse/1]).
parse(<<128, Rest/binary>>) -> {high, Rest};
parse(Input) -> {low, Input}.
```

Создайте `my_harness.erl`:

```erlang
-module(my_harness).
-export([run/1]).
run(Input) when is_binary(Input) -> my_parser:parse(Input).
```

Из корня EFZ подготовьте artifacts и запустите фаззинг:

```sh
rebar3 compile
mkdir -p harness-ebin corpus
erlc -o harness-ebin my_harness.erl
printf '\000' > corpus/seed
erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok, _} = efz_instrument:compile("my_parser.erl",
      #{modules => [my_parser], source_root => ".", outdir => "instrumented"}),
  halt().'

escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin \
  --seeds ./corpus --out ./findings --artifacts ./instrumented \
  --mutation staged --timeout 1000 --max-input-bytes 4096 --max-iterations 100
```

Храните обычные BEAM-файлы harness/dependencies отдельно от инструментированных
artifacts. Выбираются все `.beam` в `--artifacts`; у каждого должен быть корректный
соответствующий sidecar `.efz-manifest`. Обычный BEAM в этом каталоге — ошибка.
Для обычных зависимостей используйте повторяемую опцию `--code-path DIR`; эти пути
добавляются в конец code path VM. Загрузка и проверка exports выполняются после
preflight инструментированных модулей, поэтому `--target` также может указывать
на инструментированный модуль с `run/1`.

Seeds читаются без рекурсии, в порядке отсортированных имён файлов. Каталоги
игнорируются; нечитаемые файлы или неподдерживаемые типы файлов завершают запуск
ошибкой. Нет декодирования текста, удаления переводов строк, разбора terms или
усечения. Пустой файл даёт `<<>>`; каталог без файлов — недопустимый корпус.

`--out` создаётся при необходимости и проверяется временной записью до начала
кампании. Crash groups атомарно публикуются в
`OUT/crashes/SIGNATURE_SHA256/OCCURRENCE_ID/` с `artifact.input`, `artifact.term`,
`artifact.replay`, необязательным `artifact.recipe` и integrity manifest.
`summary` для каждой сигнатуры хранит долговечный счётчик и индекс представителя;
legacy groups без него отклоняют дальнейшие записи. `OUT/report.term` — Erlang
external term с полным итоговым отчётом ядра, включая записи корпуса в памяти и
их metadata; он заменяет предыдущий отчёт по этому пути.
Добавьте `--corpus-dir DIR`, чтобы сохранять и повторно использовать успешные
входы корпуса. Следующий запуск может не задавать `--seeds`, если это хранилище
непустое. `--seeds` и `--corpus-dir` можно сочетать; одинаковое содержимое
объединяется. Политика build mismatch по умолчанию — `reject`;
`--corpus-build-policy recalibrate` явно разрешает повторное использование при
изменённых target/build identities. Обе политики заново калибруют все загруженные
входы. Это не восстанавливает checkpoint кампании. Подробнее о хранении, ошибках
целостности и диагностике: [долговечный корпус](corpus.md).

Значения CLI по умолчанию: staged mode, timeout 100 ms и 1 000 исполнений мутаций.
Исполнения калибровки считаются отдельно. `--mutation random` выбирает существующий
случайный мутатор. Оба режима соблюдают лимит кампании `--max-input-bytes`
(по умолчанию 4096, включительно 0..1048576), в том числе при ограниченном чтении
raw seeds. CLI не поддерживает произвольный MFA, ручное покрытие или исполнение
конфигурационного файла как Erlang-кода. `--help` перечисляет все допустимые
флаги. Неизвестные или повторные однозначные флаги, отсутствующие и некорректные
значения явно завершаются ошибкой.

`--coverage-policy diagnostic` — политика по умолчанию: `report.term` явно
перечисляет artifacts без наблюдённого покрытия, а CLI выводит диагностику
покрытия. `--coverage-policy
strict` возвращает exit **1**, если кампания завершилась
без единого инструментированного probe. Один допустимый пустой вход не приводит
к немедленной ошибке кампании. Эта политика не зависит от строгости синтаксиса
инструментирования. См. [целостность покрытия](coverage-integrity.md).

| Код завершения | Значение |
|---|---|
| 0 | `completed`, действительное исчерпание мутаций или остановка по idle guard; target crashes/timeouts считаются findings |
| 2 | Некорректные аргументы, недоступные пути seeds/output, плохие artifacts, недоступный модуль/callback или некорректная конфигурация кампании |
| 1 | Infrastructure failure кампании, неожиданное исключение launcher/runtime или ошибка сохранения итогового отчёта |

## Схема campaign map

`efz_config:prepare/1`, также вызываемый через `efz:start/1`, требует map и
отклоняет неизвестные ключи верхнего уровня с
`{error,{unknown_campaign_keys,Keys}}` **до** загрузки artifacts или targets.
Схема входа:

| Ключ | Допустимое значение |
|---|---|
| `target` | Обязательный module atom с экспортом `run/1` |
| `seeds` | Обязательный список binaries; может быть пустым, если `corpus_dir` восстанавливает непустой корпус |
| `timeout` | Неотрицательное целое число миллисекунд; по умолчанию 100 |
| `workers` | `1` |
| `mutator` | Модуль с экспортом `mutate/2`; по умолчанию `efz_mutator_random`; пользовательские callbacks требуют random mode |
| `mutation_mode` | `random` (по умолчанию в API) или `staged` |
| `max_iterations` | Неотрицательное целое число или `infinity` в random mode; 0..1,000,000 в staged mode; отсутствующее staged-значение становится 1,000 |
| `max_input_bytes` | Лимит binary кампании, включительно 0..1,048,576; по умолчанию 4,096; применяется к обоим режимам, чтению, восстановлению и исполнению |
| `mutation` | Map только для staged mode, проверяемый `efz_mutation_plan:prepare/2`; см. [лимиты мутаций](mutations.md) |
| `coverage` | `automatic` (по умолчанию) или явный режим совместимости `manual`, доступный только через API |
| `coverage_backend` | `ets` (по умолчанию), `ets_member` или `bitmap` (только automatic presence) |
| `coverage_bitmap_bits` | Ёмкость bitmap в битах, по умолчанию `65536`; положительное число, кратное 64 |
| `coverage_validation` | `prepared` (по умолчанию) или `per_execution` |
| `coverage_policy` | `diagnostic` (по умолчанию) или `strict`: считать ошибкой кампанию без наблюдённых automatic probes |
| `artifacts` | Список artifact descriptor maps; automatic mode требует непустых корректных artifacts |
| `crash_policy` | Строгий map: `reason` = `category` (по умолчанию), `exact` или `ignore`; `max_frames` = 1..32 (по умолчанию 5); `max_representatives` = 1..32 (по умолчанию 3), ограничивает диск и отчёт для каждой сигнатуры между перезапусками. Опция API; см. [crash/replay/report](replay.md) |
| `crash_dir` | Непустой файловый путь list/binary; по умолчанию `_build/efz-crashes` |
| `random_seed` | Необязательный tuple из трёх неотрицательных целых чисел для legacy worker PRNG |
| `selection_seed` | Необязательный tuple из трёх неотрицательных целых чисел или `undefined` для legacy corpus selection |
| `corpus_dir` | Необязательный непустой файловый путь; загрузка и долговечное хранение повторно используемых входов корпуса |
| `corpus_build_policy` | `reject` (по умолчанию) или `recalibrate`; требует `corpus_dir` |

Настройки staged mutation RNG относятся к `mutation.seed`. Аргументы CLI
`--code-path`, каталоги seeds и output обрабатывает launcher; они не являются
дополнительными ключами campaign map. Производные `manifests`, планы покрытия и
состояние координатора также не принимаются как пользовательские параметры
кампании.

`function` и `arity` отклоняются даже со значениями `run` и `1`: контракт callback
фиксирован. Помещайте адаптацию внутрь `Module:run(Input)`.
`corpus_dir` теперь выбирает выделенный persistent format; каталог `--seeds`
по-прежнему содержит обычные raw seed files. `max_input_bytes => N` — опция
кампании верхнего уровня; `mutation => #{max_input_bytes => N}` отклоняется с
`{campaign_level_option,max_input_bytes}`. CLI напрямую отображает
`--max-input-bytes` в опцию кампании. См. [контракт входов/хранения](input-and-storage.md).

```sh
rebar3 eunit --module=efz_cli_tests,efz_config_tests
```

Black-box suite запускает production launcher в новых Erlang VM, упаковывает
текущую сборку, чтобы исключить устаревшие BEAM default profile, и использует
внешний обычный harness с автоматически инструментированным parser. Он проверяет
передачу raw input, реальное сохранение по покрытию, оба режима мутации,
некорректные пути и artifacts, ошибки callback, crash/timeout findings и коды
завершения при сбоях.

## Автоматическая runtime-диагностика

`--runtime-diagnostics` включает политику ядра `runtime_oracles` (по умолчанию
выключена). `--runtime-runs N` задаёт общее число seed/interesting/suspicious/failure
runs, включая исходный, 1..16; `--verification-budget N` ограничивает extra
executions за кампанию, 0..1000000; `--sample-interval MS` задаёт 1..10000 ms.
Эти флаги со значениями требуют флага активации. Вся валидация общая с ядром.
Verification не расходует `--max-iterations`. Расширенные thresholds/caps доступны
через namespaced map API; неизвестные вложенные ключи отклоняются.

Runtime observations независимы от crashes. Используйте
`scripts/replay.escript
--runtime-finding DIRECTORY --target MODULE --artifacts DIR --runs 3`,
добавив `--code-path` для обычного harness. Содержимое artifact не может выбирать
код target. CLI разрешает имена модулей из доверенных локальных BEAM, не интернируя
текст аргументов. См. [полную схему и лимиты](runtime-diagnostics.md).

## Внешняя worker VM

В Linux добавьте `--supervised` к обычной команде фаззинга. Делегирование
выполняется до загрузки harness или target в CLI. Внешний контроллер вычисляет
identities из локальных файлов и запускает настоящий CLI/campaign в отдельном
процессе BEAM ОС. Все target executions, включая калибровку и P0 verification,
проходят через долговечный input barrier в `efz_executor`.

Дополнительные ограниченные опции: `--restart-budget` (по умолчанию 8),
`--supervised-runs` (10000), `--campaign-ms` (3600000), `--startup-ms` (10000),
`--ipc-grace-ms` (1000) и `--journal-bytes` (268435456). Они принимаются только в
supervised mode. Output включает `external-report.json`, журнал `external-runs/`,
каталоги поколений worker и внешние finding indexes в `crashes/external/`.
Повторно проверьте finding командой:

```sh
escript scripts/replay.escript \
  --external-finding OUT/external-runs/CAMPAIGN/RUN \
  --target MODULE --artifacts ARTIFACTS --code-path HARNESS_EBIN \
  --out RECHECK_OUT --reproduce-runs 3
```

Artifact никогда не выбирает исполняемый код. Локальные target/artifact identities
должны совпадать. Supervised campaign возвращает 0 только при нормальном
завершении или завершении по бюджету (recheck также возвращает 0 со своим явным
reproduction verdict), 2 при ошибках аргументов и 1 при ошибках startup, protocol,
storage, hard timeout без восстановления или исчерпании restart budget.
Контроллер сообщает `observed N/M`, `not_observed` или `inconclusive`; один
успешный запуск никогда не считается опровержением нестабильного crash.
См. [P1-01: внешний supervisor](p1-01-external-supervisor.md).
