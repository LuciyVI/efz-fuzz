# Plugin декодера XML-RPC

[English](../../../../../examples/xmlrpc/README.md) · **Русский** · [Español](../../../es/examples/xmlrpc/README.md) · [简体中文](../../../zh-CN/examples/xmlrpc/README.md) · [Все языки](../../../README.md)

Fixture использует [etnt/xmlrpc](https://github.com/etnt/xmlrpc) на commit
`fb46463b2acadf164ec534d9e2033e194341c507`. Он один раз вызывает
`xmlrpc_decode:payload(binary_to_list(Input))` внутри обычного EFZ execution.
Не участвуют network server, RPC callback, encoder или второй target execution.
Decoder `{error, Reason}` становится `{rejected, Reason}`; accepted values
остаются настоящими Erlang XML-RPC terms.

Из корня EFZ подготовьте изолированную dependency и target-only coverage artifacts:

```sh
git clone --no-checkout https://github.com/etnt/xmlrpc.git _build/xmlrpc-dependency
git -C _build/xmlrpc-dependency checkout --detach fb46463b2acadf164ec534d9e2033e194341c507
ERL_FLAGS='+S 2:2' rebar3 compile
ERL_FLAGS='+S 2:2' escript examples/xmlrpc/prepare.escript
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
```

Preparation отклоняет другой commit или изменённые decoder sources.
Сгенерированные данные остаются в `_build/xmlrpc-example/`: `dependency-ebin`,
`harness-ebin`, `instrumented`, `seeds` и `dependency-identity.term`.
Добавьте dependency и harness ebin directories в code path. Выбранные
инструментированные modules — `xmlrpc_decode` и `xmlrpc_util`; model, adapter и
harness находятся вне target coverage. Требуется OTP `xmerl`. Его parser
internals здесь не измеряются; `strict => false` сохраняет nonliteral record
defaults `xmerl.hrl`, добавляя probes в исполняемый decoder code.

```erlang
#{target => efz_xmlrpc_target,
  gleam_layer => #{adapter => efz_xmlrpc_adapter,
    adapter_options => #{string_bytes => 128,
                         methods => [<<"echo">>, <<"efz_missing_name">>]},
    structured_fraction => 10, feedback => guided, oracle => inline,
    oracle_budget => 64,
    limits => #{bytes => 4096, depth => 8, nodes => 128,
                collection => 16, operations => 1}}}.
```

Canonical EFZ input остаётся raw XML bytes. Независимая Gleam model поддерживает
`methodCall`, необязательное точное объявление `<?xml version="1.0"?>`, непустые
method/member names, явные `int`, `boolean` (`0`/`1`), `string` и вложенные
`array`/`struct`. Текст — printable ASCII (U+0020..U+007E) с пятью predefined XML
entities. Bytes и codepoints совпадают только в этом envelope. Strings и names
имеют общий limit `string_bytes`; integers — signed 32-bit. Collection limits
применяются к params, arrays и struct members; nodes считают call, values и
members; вложенность value начинается с depth one.

Parser распознаёт намеренно небольшую grammar: без inter-tag whitespace,
attributes, self-closing tags, numeric entities, DTD, CDATA или namespaces.
Target всё ещё может принимать такие inputs, но model возвращает `skip` или
oracle возвращает `inconclusive`; обычные EFZ byte mutations остаются доступны.
Responses/faults, `i4`, doubles, dates, base64, nil, implicit strings, non-ASCII
UTF-8 text и encoder properties вне model version 1. Поддерживаемые generation
и mutations производят accepted methodCall inputs. Operation IDs стабильны:
0 replace first scalar, 1 prepend scalar, 2 delete first param, 3 wrap params
in array, 4 replace params with one struct, 5 reverse params.

`xmlrpc_model_agreement` version 1 сравнивает независимо разобранные expected
values с переданным primary decoder result, нормализуя existing atom или
charlist names в ASCII binaries. Ни model, ни adapter не создают atoms из input.
Unsupported input и expected target rejection не создают property finding.
Поддерживаемые modeled calls должны приниматься с matching values. Observation
использует фиксированный finite vocabulary для acceptance, value types,
emptiness, depth и container-size buckets. Method names, string contents и AST
hashes никогда не становятся feature IDs.

При наличии dependency/model paths запустите optional integration tests:

```sh
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin -pa _build/xmlrpc-example/harness-ebin' \
  GLEAM_BIN=/path/to/gleam-1.10.0 rebar3 as gleam eunit --module=efz_xmlrpc_adapter_tests
```

Тесты явно сообщают об отсутствующих optional dependencies; default build
выполняет descriptor/options checks, не требуя их. Raw replay требует только
ordinary harness/decoder artifacts. Property replay дополнительно требует
matching plugin/model и явной trusted configuration; общие проверки EFZ identity
и predicate применяются без изменений.

`escript examples/xmlrpc/benchmark_callbacks.escript` записывает три конечных
повтора по 10,000 calls на callback и direct uninstrumented decoder в
`_build/xmlrpc-example/callback-measurements.term` после 100 warmup calls.
Отчёт фиксирует 268-byte nested input, limits, BEAM hashes, compile options,
OTP/ERTS и scheduler count. Измерения исключают EFZ execution wrapper, dispatcher,
coverage, corpus и campaign loop и должны сообщаться отдельно от complete
campaign measurements. Observation и oracle используют один уже полученный
result и имеют ноль измеренных target executions.
