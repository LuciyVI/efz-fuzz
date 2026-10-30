# Длительный Cowboy benchmark: ETS, bitmap-v2 и OTP-public

## Назначение и граница target

Benchmark запускает обычную кампанию EFZ на 900 секунд. Вход — байты одного
HTTP/1.x request. `efz_cowboy_long_target:run/1` подаёт их в настоящий
`cowboy_http:init/6` через in-memory `efz_cowboy_transport`; `cowboy_http:loop/1`
и его внутренние `parse_request/3`, `parse_header/4`, `request/*`,
`parse_body/2` выполняют parsing request line, method, URI, version, headers,
`Content-Length` и chunked transfer encoding. `efz_cowboy_stream:init/3`
вызывает `cowboy_router:execute/2` и `cowboy_req:parse_qs/1`; для body он
принимает `cowboy_stream:data/4` до `fin`. Сетевого listener, Ranch acceptor и
TCP здесь нет. Это реальный parser/stream path Cowboy, но не полный pipeline
обработчика HTTP и не сетевой benchmark.

Парсерные ошибки и неполные requests возвращают штатный `{ok,rejected}`.
Неожиданные исключения stream sink передаёт стандартной crash classification
EFZ. Каждый запуск одного input происходит в одном target process; закрытие
in-memory transport и очистка маркера результата выполняются в `after`.
Harness не обращается к coverage API.

Зависимость Cowboy зафиксирована в `rebar.config`/`rebar.lock`: Cowboy 2.19.0,
Cowlib 2.20.0, Ranch 1.8.1. Поддерживаемый проектом OTP: 27+. В каждом
запуске автоматически компилируется и инструментируется только allowlist:

| Модуль | Probes |
| --- | ---: |
| `cowboy_http` | 485 |
| `cowboy_req` | 282 |
| `cowboy_router` | 101 |
| `cowboy_stream` | 19 |
| **Всего** | **887** |

Числа проверены на OTP 27.0 с указанной версией Cowboy; runner печатает и
сохраняет фактический счётчик. Карта bitmap содержит 65 536 **бит**. Превышение
ёмкости останавливает запуск до кампании. `strict => false` необходим из-за
нескольких record defaults/list comprehensions, которые существующий
`efz_instrument_pt` сохраняет без внутренних probes. Их список выводится при
сборке и находится в `.efz-manifest` каждого target module. Это ограничение
instrumentation, общее для обоих backend.

Экспериментальный `otp_native_public` собирает тот же allowlist Cowboy с
`line_coverage` и читает покрытие через `code:get_coverage(line, Module)`.
Для Cowboy 2.19.0 в этом окружении получилось 1089 native line slots. Это
исполняемые строки OTP, поэтому 1089 нельзя сравнивать с 887 структурными
probes EFZ как равные единицы покрытия. Режим выбирается до загрузки target.

Seeds лежат в `test/targets/cowboy/seeds/`: 12 небольших requests с CRLF,
включая GET, query, POST с длиной, несколько заголовков, HEAD, OPTIONS,
absolute URI, HTTP/1.0, chunked body и два повреждённых запроса.

## Запуск

Из корня `efz/`:

```sh
./scripts/run_cowboy_long_bench.sh --backend ets --duration 900 --seed 424242
./scripts/run_cowboy_long_bench.sh --backend bitmap --duration 900 --seed 424242
./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 900 --seed 424242
```

Для профилирования стоимости engine добавлены экспериментальные режимы
`--backend none` (Cowboy без instrumentation), `--backend none_instrumented`
(Cowboy с OTP line instrumentation, но без reset/read/feedback), а также
`--target noop` и `--profile`. Короткие измерения, интерпретация overhead и
команды просмотра `profile.term` приведены в
[профиле engine](engine-performance-profile.md). `none` не является
coverage-guided режимом и не меняет default ETS.
Результаты следующего этапа с 15-минутными прогонами, одинаковой
последовательностью inputs (`--fixed-replay`) и временным профилем:
[engine-performance-profile-v2.md](engine-performance-profile-v2.md).

Каждая команда запускает новую Erlang VM. Для дополнительной пары с обратным
порядком выполните затем bitmap → ETS с теми же аргументами. Для другого
начального corpus укажите `--corpus DIR` (плоский каталог regular files), для
явного нового каталога результата — `--out DIR`. Существующий `--out` не
перезаписывается. `--duration` задаётся в секундах. `--seed` используется для
EFZ random mutation и выбора parent из corpus. Сопоставимость seed означает
одинаковое начальное состояние, а не гарантированно идентичную историю: разная
скорость backend за фиксированное время даёт разное число mutations и может
привести к разному corpus. Для строгой проверки семантики coverage используйте
дифференциальные тесты одинаковой истории событий EFZ.

На машинах, где Rebar3 не может скачать зависимости, нужны доступ к GitHub или
предварительно заполненный кэш Rebar3. В локальной ограниченной среде Rebar3
не смог разрешить настроенный proxy; для проверки pinned repositories были
клонированы в `_build/default/lib/` вручную. Это не меняет version lock.

Результаты идут в новый каталог:

```text
artifacts/cowboy-long-bench/<UTC timestamp>-ets/
artifacts/cowboy-long-bench/<UTC timestamp>-bitmap/
```

В каждом: `config.term`, `environment.txt`, `samples.csv`, `summary.term`,
`summary.csv`, `coverage.term`, `cleanup.term`, `corpus/`, `crashes/` и
`target-beams/`. Каталоги результатов игнорируются Git. `environment.txt`
содержит git commit/status, OTP/ERTS, Cowboy, OS/CPU/architecture, schedulers,
backend, bitmap size, EFZ config, duration и seed.

Сравнение готовой пары:

```sh
python3 scripts/compare_cowboy_long_bench.py \
  artifacts/cowboy-long-bench/<ETS_RUN> \
  artifacts/cowboy-long-bench/<BITMAP_RUN> \
  artifacts/cowboy-long-bench/<OTP_PUBLIC_RUN>
```

Скрипт принимает 2–4 каталога, проверяет исходную конфигурацию, печатает
exec/s и разброс, first/last 60s, coverage/corpus, память и процессы, а для
длинного запуска — RSS/VM/ETS memory около 0/5/10/15 минут. Абсолютное
число точек EFZ и строк OTP выводится с предупреждением о разных единицах
измерения. Различия между независимыми fuzz runs описательные: они сами по
себе не доказывают изменение семантики backend.

## Отдельный эксперимент: `erlang-fuzzer(1)`

`./scripts/run_cowboy_long_bench.sh --backend erlang_fuzzer` вызывает отдельный
`scripts/run_erlang_fuzzer_cowboy_bench.py`. Он запускает предоставленный исходный
код `erlang-fuzzer(1)` на **том же Cowboy 2.19.0, тех же четырёх target modules,
том же harness path и тех же seed files**. Он компилирует Cowboy с
`line_coverage`, а внешний `fuzzer.erl` выбирает OTP `line_counters` и
регистрирует счётчики в libFuzzer через `core.c` NIF. Источник берётся из
`~/test/erlang-fuzzer(1)/erlang-fuzzer/fuzzer` (или `--source DIR`), не
копируется в Git и не меняет EFZ. Копия собирается в отдельном каталоге
`/tmp`: исходный Makefile использует GDB для получения смещений текущего
`beam.smp`; wrapper только отключает пользовательский GDB init (`gdb -nx`),
не подставляя готовые смещения. SHA256 исходника `core.c`, драйвера и
`beam.smp` сохраняются в `environment.txt`.

```sh
./scripts/run_cowboy_long_bench.sh --backend erlang_fuzzer \
  --source "$HOME/test/erlang-fuzzer(1)/erlang-fuzzer/fuzzer" \
  --duration 900 --seed 424242
```

Запуск происходит в отдельной Erlang VM. Runner откажет в результате, если
хотя бы один Cowboy module не зарегистрирован в native coverage или libFuzzer
не получил features. Доступны `--corpus DIR` и `--out NEW_DIR`. Результат
пишется в `artifacts/cowboy-long-bench/<timestamp>-erlang_fuzzer/`:
`samples.csv`, `summary.csv`, `environment.txt`, `fuzzer.log`, копия corpus,
crash artifacts и build logs. После прогона сравнение с тремя EFZ режимами:

```sh
python3 scripts/compare_cowboy_long_bench.py \
  artifacts/cowboy-long-bench/<ETS_RUN> \
  artifacts/cowboy-long-bench/<BITMAP_RUN> \
  artifacts/cowboy-long-bench/<OTP_PUBLIC_RUN> \
  artifacts/cowboy-long-bench/<ERLANG_FUZZER_RUN>
```

Это **сравнение полных fuzzing engines**, не измерение одной операции сбора
покрытия: libFuzzer исполняет input в одном процессе без guardian EFZ,
применяет другую мутацию и собственные правила сохранения corpus. Даже при
одинаковом seed последовательности inputs расходятся. `ft` и `cov` libFuzzer
не равны ни структурным probes EFZ, ни числу уникальных строк OTP. В
предоставленном `core.c` NIF регистрирует байты `line_counters` и создаёт
синтетическую PC table по индексам, поэтому его feature count нельзя
сопоставлять с `code:get_coverage/2`. В общей таблице внешние coverage count,
discoveries и недоступные VM/process метрики показываются как `n/a`; `ft` и
`NEW/REDUCE` выводятся отдельно. Exec/s не является доказательством скорости
самого coverage collector. Для этого нужен изолированный replay одинаковых
inputs с сопоставимым execution lifecycle.

Этот NIF использует приватные структуры ERTS и указатель на coverage buffer
без доказанной защиты lifetime при reload/purge. Запускать только в
одноразовой VM; это исследовательский режим, не backend EFZ. При изменении
OTP, отсутствии DWARF/debug symbols или ошибке регистрации результат нельзя
использовать. Скрипт не выполняет module reload и не включает внешний NIF
в основной EFZ runtime.

Короткая проверка 2026-10-03: `--duration 2 --seed 424242` завершилась с
кодом 0, лог подтвердил `coverage on` для всех четырёх Cowboy modules,
`ft` вырос с начального значения, corpus пополнился. Raw output:
`artifacts/cowboy-long-bench/20261003T172502Z-erlang_fuzzer/` (локально,
не в Git). `rebar3 eunit`: 256 PASS. 900-секундный внешний прогон **NOT RUN**;
короткая проверка не даёт оценки устойчивого throughput.

## Sampling и summary

`samples.csv` содержит sample на старте и затем каждые 10 секунд без сбора
телеметрии на каждой iteration. Счётчики EFZ, размер corpus и global coverage
читаются согласованно через read-only
`efz_fuzzer:benchmark_snapshot/0` / `efz_worker:handle_call/3`. Точный
`coverage.term` создаётся один раз после окончания sampling. Колонки:
elapsed, total/window exec/s, corpus, global coverage, discoveries,
crashes/timeouts/errors, process count, memory total/processes/binary/ETS,
Linux RSS, run queue, reductions, GC count, map arms/allocations и broken
coverage observations. Поле `execution_maps_allocated` считает только карту,
заранее выделенную worker; это не число всех возможных временных карт.
`summary.term` и `summary.csv` содержат total/mean,
median, p10/p90 window exec/s, first/last 60s, итоги покрытия/corpus,
crashes/timeouts и изменения памяти/числа процессов.
`total_executions` включает calibration, а скорости за интервал отсчитываются
от первого sample после `efz:start/1`.

`cleanup.term` записывается после `efz:stop/0`. Отсутствие процессов EFZ
проверяется по зарегистрированным именам; абсолютное число процессов и память
после остановки сохраняются для ручной диагностики. В bitmap-v2 доступен
счётчик arms и одна заранее выделенная execution map в worker. Число retired maps
через текущий публичный API не наблюдаемо, поэтому метрика не заявляется.
Всем memory выводам нужна полная 15-минутная временная серия и повторения.

## Проверка перед long run

Выполнено 2026-10-02 на OTP 27.0:

- `rebar3 compile` — PASS;
- `rebar3 eunit` — 255 PASS, включая 12 Cowboy harness cases;
- `rebar3 ct` — 3 PASS;
- `./scripts/run_cowboy_long_bench.sh --backend ets --duration 30 --seed 424242`
  — 3582 executions, 119.36 exec/s, 266 final coverage points, 56 corpus
  inputs, 0 crashes/timeouts/errors;
- та же команда с `--backend bitmap` — 1992 executions, 66.36 exec/s,
  259 final coverage points, 49 corpus inputs, 0 crashes/timeouts/errors.

30-секундные raw results сохранены под
`artifacts/cowboy-long-bench/20261002T190436Z-ets/` и
`artifacts/cowboy-long-bench/20261002T190514Z-bitmap/` локально. Среднее
bitmap/ETS для этой пары ≈0.556. Bitmap остаётся experimental opt-in, а ETS —
default. Эти данные не заменяют четыре 15-минутных прогона в порядке
ETS → bitmap → bitmap → ETS: 30 секунд недостаточно для вывода о насыщении
coverage, стабильности throughput и росте памяти.
