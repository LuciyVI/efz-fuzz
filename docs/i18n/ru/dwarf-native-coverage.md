# DWARF/native coverage: контрольная точка осуществимости

[English](../../dwarf-native-coverage.md) · **Русский** · [Español](../es/dwarf-native-coverage.md) · [简体中文](../zh-CN/dwarf-native-coverage.md) · [Все языки](../README.md)

Статус: **прямой DWARF backend не реализован** (2026-10-03). Безопасный
comparison backend `otp_native_public` использует только документированные OTP
API; см. [`dwarf-native-coverage-results.md`](dwarf-native-coverage-results.md).
ETS остаётся default, bitmap — opt-in. Эта контрольная точка останавливается
до чтения памяти VM, поскольку текущая среда не предоставляет доказанного
способа удержать динамически выделенное coverage storage во время копирования.
Offsets DWARF ниже — наблюдения об одном binary, а не готовый coverage reader.

## Граница интеграции EFZ

`efz_config:valid_field/2` принимает `ets`, `ets_member`, `bitmap` и
`otp_native_public`.
`efz_coverage` диспетчеризует эти backends. `efz_guardian:run/6` владеет coverage
context итерации; `efz_feedback` определяет novelty и global merge.
Cowboy runner (`scripts/cowboy_long_bench.escript`) компилирует четыре модуля
Cowboy через `efz_instrument:compile/2` для ETS/bitmap, добавляя EFZ structural
probes. Публичный native path использует `efz_cov_native_public:compile/2` с
`line_coverage` и выбирает mode `line` до загрузки этих модулей.
Он представляет executable lines, а не EFZ clauses/outcomes, поэтому абсолютные
coverage counts несопоставимы.

## Проверенные runtime и layout

Runtime: OTP 27, ERTS 15.0, x86-64 Linux. Активный executable, определённый для
этого исследования: `beam.smp` из установки Erlang/OTP 27.0 (ERTS 15.0).
Его SHA256:
`dcc7fac32e6f401be539022fce3e15a3f92461600208a41f1e7bfe3ef9e5d98f`;
его ELF GNU build-id: `545a52682e29950d87511c488a8d0f31551f5ad2`.
ELF содержит `.debug_info`, символы не удалены.

Запрос типа DWARF в GDB (`gdb -q -batch -ex 'ptype /o BeamCodeHeader'
<beam.smp>`) сообщает 144-байтовый `BeamCodeHeader` с такими полями:

| Поле | Byte offset | Тип DWARF |
| --- | ---: | --- |
| `coverage_mode` | 80 | `Uint` |
| `coverage` | 88 | `void *` |
| `line_coverage_valid` | 96 | `byte *` |
| `loc_index_to_cover_id` | 104 | `Uint32 *` |
| `line_coverage_len` | 112 | `Uint` |

В этом binary `Module` (`struct erl_module`) имеет `curr.code_hdr` по offset 32
и `old.code_hdr` по offset 96. Эти значения нужно обнаруживать заново для каждого
точного executable; их нельзя копировать в runtime configuration другой сборки.
Source OTP 27.0 объявляет `coverage` как `void *`, поэтому сам тип не задаёт
allocation, тип элемента массива или время жизни:
[OTP 27.0 `beam_code.h`](https://github.com/erlang/otp/blob/OTP-27.0/erts/emulator/beam/beam_code.h).
Source таблицы модулей явно отличает lock-free lookup активного instance от
отдельно защищённых old/staging instances:
[OTP 27.0 `module.c`](https://github.com/erlang/otp/blob/OTP-27.0/erts/emulator/beam/module.c).

`code:coverage_support/0` возвращает здесь `true`. Модуль, скомпилированный с
`[binary, line_coverage, debug_info]` и загруженный после
`code:set_coverage_mode(line)`, дал `[{3,false},{4,true}]` после одного исполнения
ветви через `code:get_coverage(line, Module)`; публичный
`code:reset_coverage(Module)` очистил его до двух записей `false`. Это проверяет
только публичное поведение OTP. Прямое чтение не выполнялось и не сравнивалось.

## Почему прямое чтение заблокировано

DWARF описывает положение **поля-указателя** `coverage` внутри уже найденного
`BeamCodeHeader`; он не определяет heap address header загруженного модуля и
не удерживает этот объект живым. PIE/ASLR также означают, что адреса ELF symbols
не являются адресами процесса. Чтение через `Module.curr.code_hdr`, затем
`coverage` без правил ERTS code-index/thread-progress может гоняться с
reload/purge и разыменовать освобождённую память. Сравнение build-id и MD5 модуля
до чтения не закрывает гонку check-to-use.

Чистый Erlang предоставляет coverage как Erlang terms через `code:get_coverage/2`,
а не как закреплённый pointer. Отдельный port не может вызывать внутренний module
lookup VM и не имеет синхронизации code loader; на этом хосте
`/proc/sys/kernel/yama/ptrace_scope` равен `1`, поэтому child обычно также не может
читать parent BEAM через `/proc/<pid>/mem`. Внутрипроцессный NIF в принципе мог бы
вызывать private routines ERTS, но корректный helper потребовал бы соответствующих
OTP source/build headers и проверенного контракта времени жизни active-code-index.
Эти prerequisites здесь отсутствуют. Угадывание offsets и вызов private symbols —
неприемлемая замена, даже для benchmark.

Поэтому `otp_native_direct` **не** добавлен в `coverage_backend` или Cowboy
runner. Нет direct-read correctness test, smoke test, microbenchmark или
15-минутной команды. Измерения public API записаны отдельно; они не доказывают,
что DWARF helper повысит сквозную пропускную способность фаззинга.

## Минимальная воспроизводимая подготовка для безопасного продолжения

1. Получить полный **source OTP 27.0, соответствующий этой точной сборке
   `beam.smp`**, и её build configuration. Сохранить SHA256/build-id executable
   в layout artifact; запрещать работу, если исполняемый `/proc/<beam-pid>/exe`
   отличается.
2. Собрать минимальный внутрипроцессный, специфичный для сборки helper **только
   для чтения**, используя фактические ERTS coverage и code-loader definitions.
   Он должен получать active module instance по документированным правилам
   ERTS thread-progress/code-index, проверять mode, module identity и bounds,
   копировать ограниченный compact buffer и освобождать pin до возврата. Никогда
   не сохранять ERTS pointers между вызовами. Если это нельзя установить по
   source, использовать небольшой ERTS accessor patch в одноразовой
   исследовательской сборке OTP вместо небезопасного NIF.
3. Обнаруживать поля и размеры из DWARF этого executable при старте. Требовать
   соответствующие SHA256/build-id и отказывать при отсутствии DWARF или mismatch.
   Выводить фактический тип элемента coverage array и индексацию из matching
   source; `void *` в DWARF недостаточно.
4. Запрещать/прерывать target reload или code upgrade, пока кампания активна.
   Доказать, что reset и read происходят только после quiescence child writers,
   включая случаи timeout и cleanup failure.
5. Сначала сравнить direct snapshots с `code:get_coverage(line, Module)` на
   небольшом `line_coverage` fixture по branches, повторному execution, reset,
   reload и invalid-layout tests. Лишь затем интегрировать native mode в
   `efz_coverage`/`efz_guardian`, сохранив EFZ feedback и corpus policy.
6. Оставить реализованный OTP-public mode opt-in. Измерять любой последующий
   direct helper против него на той же line schema до предложения ручного
   900-секундного запуска. Сохранить ETS как default и отдельно сообщать
   line-coverage counts и EFZ structural-probe counts.

Воспроизвести public-API fixture в одноразовом каталоге:

```sh
cat >/tmp/efz_dwarf_fixture.erl <<'EOF'
-module(efz_dwarf_fixture).
-export([run/1]).
run(0) -> zero;
run(N) when N > 0 -> X = N + 1, {positive, X}.
EOF
erl -noshell -eval '{ok,M,B}=compile:file("/tmp/efz_dwarf_fixture.erl",[binary,line_coverage,debug_info]), code:set_coverage_mode(line), {module,M}=code:load_binary(M,"/tmp/efz_dwarf_fixture.erl",B), io:format("before=~p~n",[code:get_coverage(line,M)]), efz_dwarf_fixture:run(1), io:format("after=~p~n",[code:get_coverage(line,M)]), ok=code:reset_coverage(M), io:format("reset=~p~n",[code:get_coverage(line,M)]), halt().'
```

Команда — baseline публичного OTP, **не** DWARF reader.
