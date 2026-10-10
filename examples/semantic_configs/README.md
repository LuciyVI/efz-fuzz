# Campaign configuration examples

Each term file contains one trusted campaign map accepted by efz:start/1 and
the CLI --config option. Seeds are raw binaries, not paths. Generic packets
were encoded using the real harness argument specifications.

| File | Target/API | Adapter | Property |
| --- | --- | --- | --- |
| lists_reverse.term | lists:reverse/1, list argument | efz_term_api_adapter | Disabled |
| maps_find.term | maps:find/2, finite atom and map of tuple values | Same generic adapter | Disabled |
| tuple_api.term | efz_term_tuple_library:combine/2, map and tuple | Same generic adapter | Disabled |
| stateful.term | Bounded fresh gen_server command scenario | Same generic adapter | Explicit independent trace callback |
| xmlrpc.term | Pinned xmlrpc_decode:payload/1 charlist ingress | efz_xmlrpc_adapter | xmlrpc_model_agreement v1 |
| cow_qs.term | cow_qs:parse_qs/1 binary ingress | Explicit efz_qs_adapter | query_model_agreement v1 |
| cow_qs_legacy.term | Historical QS configuration | Isolated implicit-QS shim | Same QS property |

All examples use coverage_backend=none: they run real APIs and semantic
feedback without claiming structural library coverage. Prepare target-only
artifacts separately, then select the appropriate backend and artifacts. Do
not instrument adapters/models/property helpers as target coverage.

Build the optional Gleam profile, then run from EFZ root:

    ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript --config examples/semantic_configs/maps_find.term --code-path _build/gleam/lib/efz/ebin --out /tmp/maps-campaign

XML-RPC additionally requires the pinned dependency prepared by
examples/xmlrpc/prepare.escript and code paths
_build/xmlrpc-example/dependency-ebin and _build/xmlrpc-example/harness-ebin.
QS requires _build/default/lib/cowlib/ebin. --out is supplied by the caller;
explicit CLI overrides can adapt a config without editing it.

See [the full integration guide](../../docs/gleam-layer/connecting-erlang-libraries.md)
for argument constraints, lifecycle, plugin templates, identities and replay.
