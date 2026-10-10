# XML-RPC decoder plugin

The fixture uses [etnt/xmlrpc](https://github.com/etnt/xmlrpc) at commit
`fb46463b2acadf164ec534d9e2033e194341c507`. It calls
`xmlrpc_decode:payload(binary_to_list(Input))` once inside the ordinary EFZ
execution. No network server, RPC callback, encoder or second target execution is
involved. Decoder `{error, Reason}` becomes `{rejected, Reason}`; accepted values
remain real Erlang XML-RPC terms.

Prepare an isolated dependency and target-only coverage artifacts from EFZ root:

```sh
git clone --no-checkout https://github.com/etnt/xmlrpc.git _build/xmlrpc-dependency
git -C _build/xmlrpc-dependency checkout --detach fb46463b2acadf164ec534d9e2033e194341c507
ERL_FLAGS='+S 2:2' rebar3 compile
ERL_FLAGS='+S 2:2' escript examples/xmlrpc/prepare.escript
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
```

Preparation refuses a different commit or modified decoder sources. Generated
data stays in `_build/xmlrpc-example/`: `dependency-ebin`, `harness-ebin`,
`instrumented`, `seeds`, and `dependency-identity.term`. Add dependency and
harness ebin directories to the code path. Instrumented selected modules are
`xmlrpc_decode` and `xmlrpc_util`; model, adapter and harness are outside target
coverage. OTP `xmerl` is required. Its parser internals are not measured here;
`strict => false` preserves nonliteral `xmerl.hrl` record defaults while probing
decoder executable code.

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

The canonical EFZ input stays raw XML bytes. The independent Gleam model
supports `methodCall`, optional exact `<?xml version="1.0"?>` declaration,
nonempty method/member names, explicit `int`, `boolean` (`0`/`1`), `string`, and
nested `array`/`struct`. Text is printable ASCII (U+0020..U+007E), with the five
predefined XML entities. Bytes and codepoints coincide only in this envelope.
Strings and names have a shared `string_bytes` limit; integers are signed
32-bit. Collection limits apply to params, arrays and struct members; nodes
count the call, values and members; value nesting starts at depth one.

The parser recognizes a deliberately small grammar: no inter-tag whitespace,
attributes, self-closing tags, numeric entities, DTD, CDATA or namespaces. These
inputs may still be accepted by the target but the model returns `skip` or the
oracle returns `inconclusive`; ordinary EFZ byte mutations remain available.
Responses/faults, `i4`, doubles, dates, base64, nil, implicit strings, non-ASCII
UTF-8 text and encoder properties are outside model version 1. Supported
generation and mutations produce accepted methodCall inputs. Operation IDs are
stable: 0 replace first scalar, 1 prepend scalar, 2 delete first param, 3 wrap
params in array, 4 replace params with one struct, 5 reverse params.

`xmlrpc_model_agreement` version 1 compares independently parsed expected values
to the supplied primary decoder result, normalizing existing atom or charlist
names to ASCII binaries. Neither model nor adapter creates atoms from input.
Unsupported input and expected target rejection produce no property finding.
Supported modeled calls must be accepted with matching values. Observation
uses a fixed finite vocabulary for acceptance, value types, emptiness, depth
and container-size buckets. Method names, string contents and AST hashes never
become feature IDs.

With dependency/model paths present, run the optional integration tests:

```sh
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin -pa _build/xmlrpc-example/harness-ebin' \
  GLEAM_BIN=/path/to/gleam-1.10.0 rebar3 as gleam eunit --module=efz_xmlrpc_adapter_tests
```

The tests report absent optional dependencies explicitly; a default build runs
descriptor/options checks without requiring them. Raw replay needs only the
ordinary harness/decoder artifacts. Property replay additionally needs the
matching plugin/model and explicit trusted configuration; the general EFZ
identity and predicate checks apply unchanged.

`escript examples/xmlrpc/benchmark_callbacks.escript` records three finite
10,000-call repetitions per callback and direct uninstrumented decoder in
`_build/xmlrpc-example/callback-measurements.term`, after 100 warmup calls.
The report pins the 268-byte nested input, limits, BEAM hashes, compile options,
OTP/ERTS and scheduler count. These measurements exclude the EFZ execution
wrapper, dispatcher, coverage, corpus and campaign loop and must be reported
separately from complete campaign measurements. Observation and oracle consume
one already obtained result and have zero measured target executions.
