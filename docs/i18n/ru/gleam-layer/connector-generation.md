# Генерация коннектора из Erlang spec

[English](../../../gleam-layer/connector-generation.md) · **Русский** · [Español](../../es/gleam-layer/connector-generation.md) · [简体中文](../../zh-CN/gleam-layer/connector-generation.md) · [Все языки](../../README.md)

Существующий общий адаптер позволяет подключить API без новой Gleam-модели или
адаптера для конкретной библиотеки. Теперь scaffold читает `-spec` и локальные
объявления `-type` из доверенного локального BEAM, чтобы сгенерировать схему
аргументов:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
mkdir -p _build/my_library
ERL_FLAGS='+S 2:2' erlc +debug_info -o _build/my_library path/to/my_library.erl
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript from-beam \
  _build/my_connector efz_my_target \
  _build/my_library/my_library.beam function_name 2
```

`from-beam OUTDIR HARNESS_MODULE BEAM FUNCTION ARITY` требует единственный spec
функции без constraints и соответствующий export. Он читает metadata, не
загружая библиотеку и не исполняя её callback `on_load`. Используйте только
доверенные BEAM: это локальный инструмент разработки, а не сервис загрузки
недоверенных artifacts.

Результат содержит небольшой harness `run/1`, `campaign.term`, закодированный
seed, инструкции компиляции/запуска и `inference.term`. Evidence фиксирует SHA-256
входного BEAM, entrypoint, выведенную схему, общие границы и ограничения.
Существующие output files никогда не заменяются. При запуске сгенерированной
кампании добавьте каталог ebin библиотеки через `--code-path` вместе с каталогом
сгенерированного harness. Общий адаптер требует optional Gleam build для
semantic callbacks; сгенерированный raw harness использует только model-free codec.

Поддерживаемые типы аргументов: ограниченные integers и integer ranges, конечные
floats, booleans, binaries, strings, типизированные proper lists, фиксированные
tuples, singleton atoms, конечные объединения atoms и нерекурсивные локальные
type aliases, включая type parameters. По умолчанию длина контейнеров ограничена
32, а integers/floats — ограниченным диапазоном codec ±1,000,000. Явные integer
ranges сохраняют свои границы в signed 64-bit envelope codec. Всё дерево
аргументов также должно укладываться в depth, node и byte limits codec. Поэтому
большие или глубоко вложенные корректные specs могут быть отклонены, а не
молча ослаблены.

Type spec **не** определяет формат binary, связи между аргументами, допустимые
переходы состояния или значение возвращаемого результата. Проверьте
сгенерированную схему, прежде чем считать inputs допустимыми по контракту
библиотеки. В частности, сгенерированный ограниченный домен — лишь тестовый
envelope; он не перечисляет тип целиком и не устанавливает semantic
preconditions. `binary()` может быть JSON, UTF-8, digest или произвольными bytes.

Перегруженные specs или specs с constraints, рекурсивные типы, remote/opaque
types, неоднородные unions, широкие `term()`/`any()`, неограниченные atoms, maps,
resources и неподдерживаемые выражения останавливают генерацию с явной ошибкой.
Вместо догадок используйте явный options file:

```sh
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript generic \
  _build/my_connector efz_my_target reviewed-options.term
```

Correctness oracle или whitelist исключений не выводятся автоматически.
Сгенерированная кампания оставляет oracle выключенным. Добавьте проверенный
behavioral predicate и документируйте ожидаемые отказы до классификации сбоев
библиотеки. Stateful API по-прежнему требуют явных setup/reset/cleanup и
контрактов команд.

Один и тот же сгенерированный harness работает с `gleam_layer => false`,
`feedback => observation_only` и `feedback => guided`; режим задаётся настройкой
кампании. Это устраняет необходимость в отдельных реализациях harness для трёх
режимов. Это не устраняет runtime costs callbacks, которые нужно измерять.

## Пример со встроенной зависимостью Cowlib

После `rebar3 compile` команда генерирует рабочий коннектор без редактирования
схемы или harness; используйте новый output directory:

```sh
escript scripts/semantic_scaffold.escript from-beam \
  _build/auto-cow-qs efz_auto_cow_qs \
  _build/default/lib/cowlib/ebin/cow_qs.beam urlencode 1
```

Следуйте сгенерированному README, чтобы скомпилировать harness и optional Gleam
layer. Добавьте `--code-path _build/default/lib/cowlib/ebin` к команде кампании.
Аргумент API `binary()` становится binary schema, ограниченной 32 байтами. Для
смены режима изменяйте только `gleam_layer`/`feedback` в `campaign.term`, а не
сгенерированный исходник. Имя модуля harness должно отличаться от имени модуля
библиотеки.

Валидация на OTP 27.3.4.1: неизменённый сгенерированный Cowlib harness завершил
по 100 mutation executions в каждом из off, observation-only и guided modes без
target crashes или infrastructure failures. Это проверка интеграции коннектора,
а не свидетельство реального дефекта или сравнение performance/discovery.
Regression tests также компилируют сгенерированный исходник, исполняют его,
проверяют декодирование seed, локальные aliases и provenance, а также отклонение
неподдерживаемых типов, отсутствующего debug info, существующего output и
конфликтующих module names. Извлечение проверяется fixture с `on_load`, чтобы
убедиться, что API-модуль не загружается.
