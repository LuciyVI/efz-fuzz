# XML-RPC data-flow harnesses

**English** · [Русский](i18n/ru/xmlrpc-harness-suite.md) · [Español](i18n/es/xmlrpc-harness-suite.md) · [简体中文](i18n/zh-CN/xmlrpc-harness-suite.md) · [All languages](i18n/README.md)

This suite checks six local functional data flows in
[etnt/xmlrpc](https://github.com/etnt/xmlrpc), pinned at commit
`fb46463b2acadf164ec534d9e2033e194341c507`. Each surface runs the same target,
initial corpus, RNG seed and mutation budget with the optional Gleam layer
disabled, observing results, or guiding mutation and corpus retention.

Inputs are payload bytes, limited to 512 bytes. The harness derives bounded
XML-RPC values from those bytes and constructs complete messages with fixed XML
tags. Valid flows use fixed atom method and struct-member names; validation uses
fixed malformed alternatives. String values are printable ASCII derived from the
payload. Byte mutations do not become XML markup or new atoms. In typed-value
flows, the first byte modulo eight selects an integer, boolean, string, double,
date, base64 value, array or struct; empty input selects an integer with an empty
payload. Containers hold at most four children and nest at most two levels.
Methods are `echo` and `sum`; struct-member names are `value`, `count`, `enabled`
and `items`. The independent XML builder escapes all five predefined XML
entities.

## Input surfaces and implemented paths

Each name selects `efz_xmlrpc_<name>_target:run/1`. The thin targets share
[`efz_xmlrpc_flow.erl`](../examples/xmlrpc/efz_xmlrpc_flow.erl); separate
entrypoints keep coverage, corpus and outcomes attributable to each flow.

| Name | Actual data flow | Contract checked | Scope limit |
| --- | --- | --- | --- |
| `call` | Payload → manually constructed `methodCall` XML → `xmlrpc_decode:payload/1` | Decoded method and parameters equal the constructed call | Fixed method names and bounded typed values; no arbitrary XML grammar |
| `response` | Payload → manually constructed one-parameter `methodResponse` XML → decoder | Decoded response value equals the constructed value | Successful responses contain exactly one parameter |
| `fault` | Payload → manually constructed fault XML → decoder | Fault code and string equal the constructed values | Bounded integer codes and printable strings |
| `roundtrip` | Payload → `{call, echo, [TypedValue]}` → `xmlrpc_encode:payload/1` → decoder | Decoded call equals the value given to the encoder | One parameter with a supported bounded value |
| `dispatch` | Payload → encoded call → decoder → local echo/sum fixture → encoded response → decoder | The final response matches the fixture's expected result | In-process fixture; no external RPC service |
| `encoder_validation` | Payload → deliberately unsupported Erlang values → encoder | Record `{error, Reason}` as rejection and any encoder success as accepted | A finite set of validation cases; expected errors are not defects |

The decoder rejects XML for an empty successful response (`{response, []}`).
That case is not asserted as a successful encode/decode round trip. Encoder
validation errors are expected API outcomes, recorded as `target_rejected`;
they are not defects or crashes.
Validation cases cover an invalid payload tuple, an unsupported map value, a
string member name, a malformed member, an unsupported array atom, nonstring
fault text, two response parameters and a list method name. The observation
records whether the result matches the expected error; exceptions propagate.

Dispatch chooses echo for even payload lengths and sum for odd lengths. Sum
uses at most the first four payload bytes, subtracts 128 from each byte and
compares the fixture response against an independently computed total.

The dispatch fixture calls no `xmlrpc_http`, server or HTTP code and opens no
sockets. It exercises encoding, decoding and a small local application decision.
The suite does not establish behavior for HTTP transport, listeners, callback
lifecycles, concurrent requests, arbitrary XML grammar or full XML-RPC
conformance. The existing [raw XML decoder adapter](../examples/xmlrpc/README.md)
remains a separate example with a different input format and model.

## Prepare the dependency

Run from the repository root with Erlang/OTP 27 or newer, Rebar3 and OTP `xmerl`:

```sh
git clone --no-checkout https://github.com/etnt/xmlrpc.git _build/xmlrpc-dependency
git -C _build/xmlrpc-dependency checkout --detach fb46463b2acadf164ec534d9e2033e194341c507
export ERL_FLAGS='+S 2:2'
escript examples/xmlrpc/prepare_flows.escript
rebar3 compile
```

Preparation compiles `xmlrpc_encode`, `xmlrpc_decode` and `xmlrpc_util` into
`_build/xmlrpc-example/dependency-ebin`. It refuses a different commit or changes
to any of those three source files or `src/log.hrl`. The example targets and
helpers compile through the existing Rebar3 `examples/xmlrpc` source directory.
The ordinary build requires no Gleam compiler or generated model BEAMs.

For another checkout location, pass that path to preparation and use the same
path with the runner's `--source` option:

```sh
escript examples/xmlrpc/prepare_flows.escript /path/to/pinned-xmlrpc
```

## Run without Gleam

```sh
ERL_FLAGS='+S 2:2' escript scripts/xmlrpc_suite.escript \
  --surface all --mode off --iterations 500 --seed 424242 \
  --source _build/xmlrpc-dependency --out _build/xmlrpc-flows-off
```

Output directories must be new. Each surface/mode cell runs in a fresh VM with
its own corpus and coverage state. The seed corpus includes empty input, XML
special characters, binary bytes and the 512-byte boundary. Use
`--surface dispatch`, for example, to select one path. The runner accepts `--surface all|NAME`,
`--mode all|off|observation_only|guided`, `--iterations N`, `--seed N`,
`--profile default|gleam`, `--source PINNED_CHECKOUT` and `--out NEW_DIR`.

## Run all three modes

```sh
export ERL_FLAGS='+S 2:2'
export GLEAM_BIN=/path/to/gleam-1.10.0
rebar3 as gleam compile
escript scripts/xmlrpc_suite.escript --surface all --mode all --profile gleam \
  --iterations 500 --seed 424242 --source _build/xmlrpc-dependency \
  --out _build/xmlrpc-flows-three-modes
```

| Mode | Structured fraction | Admission | Optional model |
| --- | --- | --- | --- |
| `off` | 0% | Structural coverage | None |
| `observation_only` | 0% | Structural coverage; observations recorded | Existing Gleam `efz_term_model` |
| `guided` | 30% | Structural coverage or new semantic features | Same term model with `efz_xmlrpc_flow_adapter` |

Observation-only preserves the baseline mutation stream and RNG consumption.
Guided mode changes selected mutations and can subsequently change the corpus.
The adapter observes results with the existing generic term model and finite
features for the result type, item-count bucket, encoded-size bucket and expected
encoder-error match. Structured operations replace the selector, append a byte
or choose a bounded sample. The adapter does not reimplement the XML parser or
encoder in Gleam. The off mode runs without the model.

The same harness contracts execute in every mode. The semantic-layer oracle is
disabled: retaining a new semantic feature does not create a property finding.
Unexpected exceptions and timeouts require investigation; they are not
automatically confirmed library defects. This is a functional integration suite,
not a search for a known bug or evidence that one mode discovers more defects.

## Coverage and output

Native coverage includes only the selected pinned XML-RPC modules:
`xmlrpc_encode`, `xmlrpc_decode` and `xmlrpc_util`, as used by each surface. OTP
`xmerl` parser internals, the flow helpers, local dispatch fixture, adapter,
observer and EFZ code are excluded. The denominator includes all executable lines
in each selected module, including paths unreachable from the chosen flow.

Every `<surface>/<mode>/` directory contains:

- `initial-corpus/`, `config.term` and `identity.term`: exact seed bytes, campaign
  settings, source and build identities, OTP/ERTS and helper identities.
- `target-beams/` and `artifacts.term`: native coverage builds for the selected
  library modules.
- `report.term`, `snapshot.term` and `summary.term`: campaign outcomes, coverage,
  corpus, timings, semantic and structured statistics, and invocation counts.
- `report.etf`: the lossless binary report. UTF-8 text terms use explicit
  `{efz_runtime_identity, Kind, Text}` tags for runtime identities so
  `file:consult/1` can read the reports while binary payload bytes remain intact.
- `corpus/` and `crashes/`: persistent EFZ artifacts for ordinary replay.

The output root contains `matrix.term`, aggregate summaries, `summary.csv` and
`comparisons.csv`. Comparisons pair matching surfaces with an off run and check
the initial corpus hash, RNG seed and requested budget.

`target_invocations`, `target_accepted` and `target_rejected` include calibration
and mutations. Invocation accounting checks them against the execution budget.
For `encoder_validation`, expected `{error, Reason}` returns contribute to
`target_rejected`. `discoveries` and `corpus_equivalent_rejections` describe
corpus admission, independently of API acceptance or rejection. Calibration
coverage is separate from `mutation_new_coverage_lines` so seed coverage is not
reported as mutation progress.

Timing columns describe one campaign per cell. They do not isolate observer or
adapter cost, and guided mode has a different input workload. A single run does
not support speed, coverage or defect-discovery superiority claims.

## Regression checks

The optional dependency must be prepared and present on the test VM's code path:

```sh
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin' \
  rebar3 eunit --module=efz_xmlrpc_flow_tests
ERL_FLAGS='+S 2:2 -pa _build/xmlrpc-example/dependency-ebin' \
  GLEAM_BIN=/path/to/gleam-1.10.0 \
  rebar3 as gleam eunit --module=efz_xmlrpc_flow_tests
```

The focused checks exercise the shared contracts, bounded payload handling,
repeatable structured operations, suite settings and optional observation paths.
Local validation completed 18 campaigns of 500 mutations: 9,000 mutations and
270 calibrations. There were 7,725 accepted flow invocations and 1,545 expected
encoder rejections, with no exceptions, timeouts or infrastructure failures.
Off and observation-only retained identical inputs, coverage and mutation
statistics for all six surfaces. All observed structural coverage was reached
during calibration; mutations added no lines in this bounded run. Guided dispatch
retained 17 corpus entries versus 15 off, without additional line coverage.
These results establish functional execution, not a guided-mode advantage.

The shared [CSV results](xmlrpc-harness-suite-validation/summary.csv),
[build identities](xmlrpc-harness-suite-validation/identities.term) and
[reproduction manifest](xmlrpc-harness-suite-validation/manifest.json) record
the run. Full reports remain in the local `_build` tree; their hashes and exact
reproduction command are in the manifest. Other local verification jobs ran
concurrently, so timing samples do not isolate layer overhead.
