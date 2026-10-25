# Примеры конфигурации кампаний

[English](../../../../../examples/semantic_configs/README.md) · **Русский** · [Español](../../../es/examples/semantic_configs/README.md) · [简体中文](../../../zh-CN/examples/semantic_configs/README.md) · [Все языки](../../../README.md)

Каждый term file содержит одну доверенную campaign map, принимаемую efz:start/1
и опцией CLI --config. Seeds — raw binaries, а не paths. Generic packets
закодированы с настоящими argument specifications harness.

| Файл | Target/API | Адаптер | Свойство |
| --- | --- | --- | --- |
| lists_reverse.term | lists:reverse/1, аргумент list | efz_term_api_adapter | Выключено |
| maps_find.term | maps:find/2, finite atom и map значений tuple | Тот же generic adapter | Выключено |
| tuple_api.term | efz_term_tuple_library:combine/2, map и tuple | Тот же generic adapter | Выключено |
| stateful.term | Ограниченный command scenario на новом gen_server | Тот же generic adapter | Явный независимый trace callback |
| xmlrpc.term | Pinned xmlrpc_decode:payload/1, вход charlist | efz_xmlrpc_adapter | xmlrpc_model_agreement v1 |
| cow_qs.term | cow_qs:parse_qs/1, вход binary | Явный efz_qs_adapter | query_model_agreement v1 |
| cow_qs_legacy.term | Историческая конфигурация QS | Изолированный implicit-QS shim | То же свойство QS |

Все примеры используют coverage_backend=none: исполняют настоящие API и semantic
feedback, не заявляя structural coverage библиотеки. Target-only artifacts
подготовьте отдельно, затем выберите соответствующие backend и artifacts.
Не инструментируйте adapters/models/property helpers как target coverage.

Соберите optional Gleam profile, затем запустите из корня EFZ:

    ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript --config examples/semantic_configs/maps_find.term --code-path _build/gleam/lib/efz/ebin --out /tmp/maps-campaign

XML-RPC дополнительно требует pinned dependency, подготовленную через
examples/xmlrpc/prepare.escript, и code paths
_build/xmlrpc-example/dependency-ebin и _build/xmlrpc-example/harness-ebin.
QS требует _build/default/lib/cowlib/ebin. --out задаёт вызывающая сторона;
явные CLI overrides позволяют адаптировать config без его редактирования.

См. [полное руководство интеграции](../../gleam-layer/connecting-erlang-libraries.md):
argument constraints, lifecycle, plugin templates, identities и replay.
