# Экспериментальное OTP-public line coverage (2026-10-03)

[English](../../otp-native-public-results.md) · **Русский** · [Español](../es/otp-native-public-results.md) · [简体中文](../zh-CN/otp-native-public-results.md) · [Все языки](../README.md)

## Реализовано

Opt-in coverage_backend => otp_native_public использует документированное native
line coverage OTP 27. efz_cov_native_public:compile/2 компилирует target modules с
line_coverage. preflight/1 выбирает code:set_coverage_mode(line) до загрузки и
фиксирует SHA256 каждого модуля, BEAM MD5 и упорядоченный список executable lines.
prepare/1 закрепляет {Module, BuildId, Line} за одним slot на строку и вычисляет
fingerprint schema. Integer line identity соответствует существующему формату
metadata корпуса.

До допуска target efz_guardian:start/6 вызывает efz_coverage:open/3, который
сбрасывает native coverage. После confirmed cleanup efz_guardian:finish/2 читает
через code:get_coverage(line, Module) и сразу упаковывает term lists в bitset по
подготовленному порядку строк. efz_feedback:native_success/5 проверяет novelty и
объединяет только успешные results. Crash, timeout и infrastructure outcomes
не обновляют global coverage. Приём в корпус по-прежнему идёт через
efz_worker:retain/2. Harness и mutation code не содержат native coverage calls.

Line coverage не является EFZ structural point coverage. Сохранённое coverage
не импортируется между backends или изменёнными builds. Экспериментальный backend
требует выделенной VM без посторонних callers выбранных target modules:
coverage storage OTP принадлежит каждому загруженному модулю, а не execution EFZ.
Guardian подтверждает завершение своих controlled descendants до чтения, но не
может изолировать произвольные посторонние calls в той же VM. Несовместимый MD5
модуля или список строк даёт явный coverage failure. ETS — default.

## Корректность

Выделенный EUnit fixture прошёл. Он проверяет empty/reset state, строку A,
повторную A, новую строку B, точное совпадение достигнутых строк raw
code:get_coverage/2 с compact bitset, novelty и merge, политику no-commit для
crash/timeout и отклонение schema после reload изменённого модуля.
Он также выполняет настоящий guardian/executor path с успешными, crashing и
timed-out inputs, затем проверяет, что только успешный result меняет global
feedback state.
Полная валидация итогового кода: rebar3 compile PASS; rebar3 eunit 256 PASS;
rebar3 ct 3 PASS; rebar3 xref PASS; rebar3 dialyzer PASS. Dialyzer PLT включает
Cowboy, а детерминированный in-memory transport имеет узкую annotation, поскольку
socket type Cowboy не описывает его reference token.
В OTP 27.0 code.erl называет mode type line_coverage, тогда как documentation
и runtime используют line; startup вызывает документированный mode через apply/3,
чтобы избежать ложного contract warning. Ни одно чтение coverage не использует
недокументированный API.

Первый Cowboy smoke обнаружил corpus_persistence invalid_probe: native identity
использовала {line,N} третьим членом. Существующий corpus format требует
положительного integer. Теперь это {Module,BuildId,Line}; исправленный
4-секундный запуск завершил 707 executions без infrastructure errors.
Ни одно test expectation не менялось, чтобы скрыть сбой.

## Короткие сквозные запуски Cowboy

Каждый mode один раз запускался в новой VM на 30 секунд с Cowboy 2.19.0,
теми же четырьмя выбранными modules, 12 seeds и random seed 424242.
Это исследовательские одиночные запуски, а не performance gate.

| Backend | Executions | Среднее exec/s | Медиана window exec/s | Discoveries | Итоговый корпус | Ошибки |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ETS | 3911 | 130.33 | 131.49 | 45 | 57 | 0 |
| bitmap-v2 | 1997 | 66.53 | 65.99 | 37 | 49 | 0 |
| OTP-public | 5889 | 196.26 | 196.58 | 35 | 47 | 0 |

Все modes сообщили ноль crashes и timeouts. ETS/bitmap используют 887 EFZ
structural probes; native использует 1089 executable-line slots. Поэтому
итоговые coverage counts имеют разные единицы. Истории корпуса и мутаций
расходятся, поскольку запуски завершают разное число итераций. Raw directories:
 /tmp/efz-ets-smoke-30-compare
 /tmp/efz-bitmap-smoke-30-compare
 /tmp/efz-native-public-final2-smoke-30

## Измерения компонентов

Synthetic fixture генерировал 1, 100 и 1000 исполненных calls на отдельных source
lines. Два warmup samples предшествовали десяти timed samples; 100 итераций/sample
для 1 и 100 строк, 20 для 1000. Значения — медиана микросекунд на итерацию,
OTP 27.0 / ERTS 15.0, x86-64, 16 schedulers.
Raw data: docs/performance/otp-native-public-2026-10-03.term.

| Запрошено строк | Reset | get_coverage | Преобразование | Без novelty | Merge | Полный цикл прямого вызова target |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.046 | 0.050 | 0.147 | 0.047 | 0.104 | 0.476 |
| 100 | 0.034 | 0.167 | 1.271 | 0.166 | 0.232 | 2.363 |
| 1000 | 0.060 | 2.670 | 13.535 | 1.291 | 1.795 | 24.637 |

Compiler добавляет одну дополнительную executable line для run/0, поэтому
фактически достигнутых строк было 2, 101 и 1001. Этот component benchmark
исключает guardian, schema checks, mutation и corpus IO. Парный cycle benchmark
ETS/bitmap-v2 повторён с raw output в
docs/performance/bitmap-v2-cycle-2026-10-03.term. Его workload и instrumentation
отличаются, поэтому значения микросекунд не являются matched native comparison.

Фиксированный настоящий Cowboy GET path использовал два warmup samples и десять
samples по 100 итераций. Median reset 0.50 us, public read 5.63 us, conversion
30.77 us, no-novelty scan 3.37 us, merge 4.97 us, direct target execution 15.08 us,
полный local cycle 68.68 us. Raw data:
docs/performance/otp-native-public-cowboy-2026-10-03.term. Conversion — большая
часть этого local cycle; отдельно get_coverage — нет. Полный запуск EFZ давал
в среднем около 5.1 ms на execution. Эти результаты не показывают public
materialization как главное узкое место полной кампании. Измерения не изолируют
каждую стоимость guardian, mutation или corpus. Безопасный direct reader остаётся
отдельным исследованием с gates. Чтения pointers, NIF и DWARF direct backend
не реализованы.

## Воспроизведение

Запускать из efz/:

    rebar3 compile
    rebar3 eunit --module=efz_native_public_tests
    escript bench/otp_native_public_components.escript docs/performance/otp-native-public-repeat.term
    escript bench/otp_native_public_cowboy_profile.escript docs/performance/otp-native-public-cowboy-repeat.term
    ./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 30 --seed 424242

900-секундный запуск оставлен для ручного выполнения после correctness gates.
