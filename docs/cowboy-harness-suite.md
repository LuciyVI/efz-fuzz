# Cowboy data-flow harnesses

**English** · [Русский](i18n/ru/cowboy-harness-suite.md) · [Español](i18n/es/cowboy-harness-suite.md) · [简体中文](i18n/zh-CN/cowboy-harness-suite.md) · [All languages](i18n/README.md)

This suite checks EFZ against the pinned Cowboy 2.19.0 and Cowlib 2.20.0
dependencies. Eleven separate targets follow real library data flows. The same
target code, initial corpus, RNG seeds and mutation budget run with the optional
Gleam Layer disabled, observing results, or guiding mutation and retention.

Inputs are **payload bytes**, up to 1024 bytes. These harnesses construct valid
messages around each payload and check what comes back from the library. A
selector byte chooses a documented variation where applicable. Every in-budget
input reaches library code; there is no term-codec envelope to reject first.
The suite exercises successful parsing and delivery paths rather than treating
ordinary input rejection as a defect.

## Input surfaces and implemented paths

Each name selects `efz_cowboy_<name>_target:run/1`. The implementations share
[`efz_cowboy_flow.erl`](../examples/cowboy/targets/efz_cowboy_flow.erl); the separate
entrypoints allow independent coverage and corpus accounting.

| Name | Input surface and actual data flow | Contract checked | Scope limit |
| --- | --- | --- | --- |
| `qs` | Payload → `cow_qs:urlencode/1` → `cowboy_req:parse_qs/1` → `match_qs/2` | Decoded pair and matched field equal the original bytes, including zero and non-UTF-8 bytes | One named field; constructed valid escapes |
| `headers` | Selector/payload → valid value → `cowboy_req:header/2`, `parse_header/2` → Cowlib parser | Lookup preserves value; content length equals the payload length | Six header families: content length, content type, range, Basic authorization, accept encoding, connection |
| `cookies` | Payload → hex cookie value → `parse_cookies/1` → `match_cookies/2` → `filter_cookies/2` → reparse | Value survives matching; filtering removes the other cookie | Two valid cookies; no arbitrary cookie grammar |
| `router` | Selector/payload → request path → `cowboy_router:execute/2` → constraint conversion → `cowboy_req:binding/2` or `path_info/1` | Selected route, integer binding, and path tail match construction | Trusted fixed dispatch: root, constrained item ID, wildcard file path; no handler execution |
| `http1` | Constructed request → real `cowboy_http:init/6` → existing in-memory Ranch transport → stream handler → router, QS, body delivery | Delivered body length equals the original length for content-length/chunked framing; zero for the no-body variant | One complete request/connection; existing synchronous stream sink, no socket |
| `http2` | Payload → `cow_http2:data/3` → `cow_http2:parse/1` | DATA stream ID, FIN flag, payload and empty remainder match | Cowlib frame round trip, not a Cowboy HTTP/2 connection |
| `http3` | Payload → `cow_http3:data/1` → `cow_http3:parse/1` | DATA payload and empty remainder match | Cowlib frame round trip, not QUIC or a Cowboy HTTP/3 connection |
| `websocket` | Selector/payload → text/binary/ping frame → `cow_ws:frame/2` → `parse_header/3` → `parse_payload/9` | Decoded payload and empty remainder match | Complete unmasked frames, no fragmentation or compression; ping limited to 125 bytes |
| `multipart` | Payload → hex form field with fixed boundary → `cow_multipart:parse_headers/2` → `parse_body/2` → final boundary and content-disposition parse | Body, field name and final boundary match | One complete part; no Cowboy streaming `read_part` lifecycle |
| `hpack` | Payload → header list → `cow_hpack:encode/3` → `decode/3` → second block using the same local tables | Both decoded header lists equal the original | Fresh 512-byte tables per execution, two blocks, at most 16 decoded headers |
| `qpack` | Payload → header list → `cow_qpack:encode_field_section/4` → `decode_field_section/3` | Header list matches; no encoder instructions at zero table capacity | Static/literal field sections; no dynamic table, blocking, or QUIC control streams |

This inventory separates implemented library paths from larger deployment
surfaces. TLS/Ranch sockets, connection scheduling, HTTP/2 and HTTP/3 connection
state machines, QUIC/WebTransport, compressed WebSocket messages, streaming
multipart, and application-specific REST/static/handler behavior require their
own lifecycle fixtures. The suite does not claim coverage of those paths.

The existing raw HTTP/1 benchmark remains documented separately in
[`cowboy-long-benchmark.md`](cowboy-long-benchmark.md). Its wire input corpus is
different from the payload corpus used here.

## Run without Gleam

From the repository root, using Erlang/OTP 27 or newer:

```sh
export ERL_FLAGS='+S 2:2'
rebar3 compile
escript scripts/cowboy_suite.escript --surface all --mode off \
  --iterations 500 --seed 424242 --out _build/cowboy-flows-off
```

The ordinary profile does not need the Gleam compiler or generated model BEAMs.
Output directories must be new. Each surface runs in a fresh VM with its own
corpus and target-only native line coverage artifacts.

## Run all three modes

```sh
export ERL_FLAGS='+S 2:2'
export GLEAM_BIN=/path/to/gleam-1.10.0
rebar3 as gleam compile
escript scripts/cowboy_suite.escript --surface all --mode all --profile gleam \
  --iterations 500 --seed 424242 --out _build/cowboy-flows-three-modes
```

Use `--surface http1`, for example, to run one path. Modes are:

| Mode | Structured fraction | Admission | Optional model |
| --- | --- | --- | --- |
| `off` | 0% | Structural coverage | None |
| `observation_only` | 0% | Structural coverage; observations recorded | Compiled Gleam `efz_term_model` |
| `guided` | 30% | Structural coverage or new semantic features | Same model and `efz_cowboy_flow_adapter` |

Observation-only preserves the baseline mutation stream and RNG consumption.
Guided mode deliberately changes selected mutations and subsequently the corpus.
The shared adapter observes actual results with the existing Gleam term model,
plus finite domain features such as delivered body size, route, header family
and value-length bucket. Structured operations change a selector, extend a
payload, or generate a bounded boundary-size payload. There is no separate
Gleam reimplementation of Cowboy parsing.

The assertions inside the harness execute in **every** mode. They check round
trip/data-delivery consistency, not complete RFC conformance. The semantic-layer
oracle is disabled, so a new semantic feature is not a semantic finding.
Unexpected exceptions propagate to EFZ and require investigation; they are not
automatically confirmed library defects. No known defect or exploit is used.

## Read the output

Every `<surface>/<mode>/` directory contains:

- `initial-corpus/`, `config.term`, and `identity.term`: exact inputs, RNG settings,
  application versions and target build identities.
- `target-beams/` and `artifacts.term`: target-only native coverage builds. Harness,
  adapter, observer and EFZ code are excluded from the measured module list.
- `report.term`, `snapshot.term`, `summary.term`: campaign outcome, coverage,
  corpus, timings, semantic/structured statistics and library invocation counts.
- `report.etf`: complete binary report; text reports tag runtime identities so
  `file:consult/1` can read them without losing binary input bytes.
- `corpus/` and `crashes/`: durable EFZ artifacts for ordinary replay workflows.

Root `summary.csv` compares surfaces and modes. `comparisons.csv` records timing
overhead relative to the matching `off` run. A single paired campaign is a smoke
measurement; it is not evidence of a speed or defect-discovery advantage.
Guided timings include a different input workload.

`target_invocations` and `target_accepted` include calibration plus mutations.
The runner checks invocation accounting against the execution budget. For a
clean run every invocation should complete the library contract. `discoveries`
and `corpus_equivalent_rejections` describe corpus admission, not API success
or rejection. Coverage gained during calibration is reported separately from
`mutation_new_coverage_lines` so an initial corpus cannot masquerade as mutation
progress. The coverage denominator includes the full selected modules, including
functions unreachable from the chosen flow; it is not a reachable-path maximum.

## Regression checks

```sh
rebar3 eunit --module=efz_cowboy_flow_tests,efz_cowboy_long_tests
GLEAM_BIN=/path/to/gleam-1.10.0 rebar3 as gleam eunit --module=efz_cowboy_flow_tests
```

The tests cover empty/binary/maximum-size inputs for all eleven paths,
repeatable structured mutations and shrinking, equal campaign settings, body
delivery, and cleanup of the in-memory HTTP/1 transport. The optional build also
checks that distinct library results produce distinct semantic features.

Recorded local validation completed 33 campaigns of 500 mutations: 16,500
mutations plus 264 calibrations, all 16,764 library calls accepted, with no
exceptions, timeouts or infrastructure failures. The retained inputs, coverage
and mutation statistics matched between off and observation-only for all eleven
surfaces. HTTP/1 reached 313 lines and 26 corpus entries off, versus 312 lines and
32 entries guided; additional retention does not establish better coverage.
See the shared [CSV results](cowboy-harness-suite-validation/summary.csv),
[build identities](cowboy-harness-suite-validation/identities.term) and
[reproduction manifest](cowboy-harness-suite-validation/manifest.json).
Other local verification jobs ran concurrently, so these timing samples do not
isolate layer overhead. Full campaign reports remain in the local `_build` tree;
the manifest records their hashes and the exact reproduction command.
