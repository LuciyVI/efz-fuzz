# Gleam Layer: implementation and verifiable results

**English** · [Русский](../i18n/ru/gleam-layer/universal-validation.md) · [Español](../i18n/es/gleam-layer/universal-validation.md) · [简体中文](../i18n/zh-CN/gleam-layer/universal-validation.md) · [All languages](../i18n/README.md)

**Current status as of October 13, 2026: P5 PASS within the stated contract.**
Checks were resumed and completed at the user's request; see
[p5-validation.md](p5-validation.md). The historical October 10 report below
preserves the status and limitations at that time.

Status as of October 10, 2026: the common contract, term/API adapter, QS and
XML-RPC plugins, stateful harness and persistence/replay integration are implemented.
Actual calls and the main checks were performed before the user's latest
instruction, “Do not run tests.” After that, only static review, replay-script
and documentation edits, and inspection of existing artifacts were performed.

Full acceptance remains open: the new general replay CLI has not yet been run,
and comparative measurements refer to earlier snapshots. A new isolated series
for the final sources was not run, following the user's instruction.
The saved measurements below are neither performance acceptance nor evidence
of a speedup/discovery improvement.

## Initial state and preservation of work

Baseline: `e4c0244c403d74b041df7e0e2f0dd4465a977453`, branch `feat/gleam-layer`.
HEAD was unchanged. Before edits, the following were saved:
[baseline.json](../../artifacts/gleam-layer/20261010-universal/baseline.json),
[user-before.status](../../artifacts/gleam-layer/20261010-universal/user-before.status)
and `user-before.patch`. The user's untracked `artifacts/`,
`efz_socket_regression_pack/`, `fuzz/` were already present; no reset/clean/stash
was performed, and the user's corpora and findings were not replaced. Results
of this work were added to `artifacts/gleam-layer/20261010-universal/`.

The old layer used a separate source checkout made with `git archive HEAD`
at `/tmp/efz-universal-baseline-e4c0244`, without changing the main working copy.
This is a separate checkout, not a Git worktree. Settings: OTP 27.0 / ERTS 15.0,
Rebar3 3.25.0, `ERL_FLAGS='+S 2:2'`, Gleam 1.10.0 from
`/tmp/efz-gleam-toolchain/gleam`. Fetching baseline dependencies over the network
did not complete; the existing local pinned dependency cache was used.
Baseline ordinary/optional compilation passed. The full baseline EUnit run did
not pass: 269 passed, 1 failed and cancelled tests; the log was saved as
[baseline-eunit-prior.log](../../artifacts/gleam-layer/20261010-universal/baseline-eunit-prior.log).
The failure includes old wall-clock waits in corruption/scheduler tests. Current
test wrappers received longer wait timeouts; execution budgets and checked
assertions were preserved. This is not a baseline performance fix.

## Architecture and public contract

[efz_semantic_adapter.erl](../../src/efz_semantic_adapter.erl) is the public behaviour;
[efz_gleam_adapter.erl](../../src/efz_gleam_adapter.erl) provides cold preflight,
dispatch and shared result validation. There is no central list of new
libraries/targets. An adapter checks compatibility with harness metadata in its
own `prepare/3`. One adapter is selected explicitly per campaign.

Exact signatures and bounds are recorded in
[adapter-contract.md](adapter-contract.md):

```erlang
descriptor() -> DescriptorMap.
prepare(Target, Options, Limits) -> {ok, ImmutableContext} | {error, Reason}.
code_dependencies(Context) -> #{semantic => [Module], target => [Module]}.
generate(Index, Context) -> {ok, Raw} | {skip, Atom} | {error, Reason}.
mutate(Raw, OperationId, #{choice => Integer}, Context) ->
    {ok, Raw, RecipeDataMap} | {skip, Atom} | {error, Reason}.
observe(Raw, PrimaryOutcome, Context) ->
    {ok, LocalFeatureIds} | {skip, Atom} | {error, Reason}.
oracle(Raw, PrimaryOutcome, Context) ->
    {pass, {PropertyId, Version}} | {fail, {PropertyId, Version}} |
    {inconclusive, Atom} | {error, Reason}.
shrink(Raw, Context) -> {ok, [RawCandidate]} | {skip, Atom} | {error, Reason}.
```

Only `descriptor/0` and `prepare/3` are required; `code_dependencies/1` is optional.
Operational callbacks are required when the corresponding capability is declared.
The descriptor contains a stable binary ID, API version 1, model/observer/recipe/
operation-catalogue versions, capabilities, a catalogue of operation IDs, model
modules and property IDs/versions. Generation index 0..4095; the only mutation
parameter is `choice` 0..65535; the catalogue has at most 256 unique IDs 0..65535.
The observer returns at most 64 local IDs 0..255. The dispatcher creates the
namespace `{AdapterId, ObserverVersion, LocalId}` and removes duplicates.
Shrink returns at most 64 bounded binary candidates. All versions are 1..65535.

EFZ retains its own loop, RNG, scheduler, mutation plan, feedback and corpus.
Callbacks run inline on BEAM, with an immutable context. There is no new
engine/NIF, model service, mandatory worker or separate process per callback.
API 1 passes the completed result of the single primary execution;
observation/oracle do not rerun the target. Catch handles exceptions but does not
stop an infinite callback: a plugin must implement finite algorithms and budgets.

`skip`, unchanged and limit during mutation use the existing byte fallback.
`inconclusive` does not create a finding. An invalid callback/exception is an
infrastructure-layer error that ends the campaign, not a library defect. A finding
is created only by an explicit violation of a declared property on the supported
subset. Expected parser rejection outside such a predicate does not become a
semantic finding.

With `gleam_layer => false`, there is no semantic dispatch/model decode/additional
RNG draw. With fraction 0, there is no structural-branch selection or mutation
decode; separately enabled observer/oracle retain their functions.
`observation_only` does not guide the corpus/scheduler. With `guided`, semantic-only
inputs are admitted to the ordinary corpus and participate in standard parent
selection.

## Term/API, domain and stateful integrations

[efz_term_codec.erl](../../src/efz_term_codec.erl) stores the argument list in the
custom deterministic `EFZT` binary codec, schema 1. It does not change raw XML/QS
inputs. Supported types are signed 64-bit integer, finite float, boolean, binary,
Unicode scalar charlist, proper list, tuple, map and bounded nested combinations.
Atoms are allowed only from a finite set of existing atoms in a trusted config;
fuzz bytes do not create atoms. Return type does not define arguments.
The generic observer performs bounded classification of the outcome/result tree
and does not prove the correctness of an arbitrary API.

[efz_term_api_adapter.erl](../../src/efz_term_api_adapter.erl) uses shared Gleam
primitives `efz_term_model`; no new package is required for each library.
The generic oracle is disabled by default. A custom property separately specifies
a callback `(DecodedArgs, PrimaryOutcome) -> true | false | inconclusive`, with ID
`generic_custom_property` version 1 and its own code identity.
Five structural operations change a scalar, insert/delete an element, replace
a subtree or transform a bounded container within the constraints. EFZ makes RNG
decisions and records them in provenance.

Validated integrations using the same adapter:

| API | Harness/config | Arguments and result |
| --- | --- | --- |
| `lists:reverse/1` | `efz_term_reverse_target`, [lists_reverse.term](../../examples/semantic_configs/lists_reverse.term) | Integer list → list |
| `maps:find/2` | `efz_term_maps_target`, [maps_find.term](../../examples/semantic_configs/maps_find.term) | Key/map → `{ok, Value}` or `error` |
| `efz_term_tuple_library:combine/2` | `efz_term_tuple_target`, [tuple_api.term](../../examples/semantic_configs/tuple_api.term) | Map/tuple → Erlang term |
| Stateful counter | `efz_stateful_target`, [stateful.term](../../examples/semantic_configs/stateful.term) | Command list/resource handles → bounded trace |
| XML-RPC | `efz_xmlrpc_target`, [xmlrpc.term](../../examples/semantic_configs/xmlrpc.term) | Raw XML bytes → decoder term |
| cow_qs | `efz_qs_target`, [cow_qs.term](../../examples/semantic_configs/cow_qs.term) | Raw QS bytes → parser pairs/rejection |

The standard path for a hypothetical `example_library`: add a harness with `run/1`
and `semantic_contract/0`, configure `{Module, Function, Arity}` and arguments,
and select `efz_term_api_adapter`. For special wire constraints, add a domain
adapter/model with the same behaviour. Worker/config/corpus/scheduler/replay do
not change. An independent length-prefixed plugin fixture is implemented only
through target/adapter/config; observer-only and generator-only fixtures need no
XML/QS model, mutation or oracle. Two different adapters with local feature ID 1
receive different namespaces.

Defaults: bytes 4096, depth 8, nodes 128, collection 32, operations 1; maxima:
1 MiB, depth 16, nodes 4096, collection 256. By default a binary/charlist argument
is also limited to collection 32, not all 4096 bytes. The charlist codec stores
codepoints as tagged integers; the harness converts them into the required API
encoding. Supported arity is 0..min(collection,255). The campaign decoding
envelope cannot exceed the harness's declared `semantic_contract.input_limits`.
A separate fixture checks collection 64 with a list longer than 32.

PID/ref/port/fun cannot be saved as portable literal inputs. Symbolic
`{'$efz_resource', Handle}` is encoded with a finite enum; the harness recreates
the resource for execution/replay and cleans it up in `after`. The stateful
counter permits up to 16 get/put/add/reset commands, a state reset to zero and
a new unregistered gen_server for every input. The EFZ guardian requires admitted
child spawning; the fixture uses `efz_target:spawn_link/1`, OTP 27 proc_lib metadata
and public `gen_server:enter_loop/3`. This tie to OTP 27 is documented; arbitrary
unmanaged OTP spawns/resources are not automatically supported. The trace stores
`scenario_executions => 1` and `library_operations => N` separately; setup/cleanup
are excluded from N. Independent outcomes, absence of state carryover and cleanup
on exception/timeout were checked.

## Persistence, identities and compatibility

The existing BEAM/execution identity mechanism is used, rather than a second
store. Semantic identity includes the descriptor, adapter/model/helper/target
code identities, opaque deterministic options, effective limits and SHA-256 of
the portable prepared context. Property ID/version, observer/catalogue versions
and RNG provenance are saved in metadata.

New recipes, schema 4/operation version 3, contain a bounded raw replacement and
opaque RecipeData. Raw load/regeneration/replay require no adapter/model;
a generic harness requires the ordinary codec BEAM as an execution dependency.
`regenerate_semantic/2` is a separate opt-in mutation-callback check with exact
identity. Semantic property artifacts schema 2 require an explicit trusted config
and matching target/harness/adapter/model/property identities. An artifact does
not select code. Restart retains canonical raw bytes and recomputes feedback
through standard calibration; mismatch follows `reject | recalibrate`, and
foreign features are not silently reused.

Minimization preserves the same property ID/version/context/predicate and counts
initial reproduction, all candidates and final verification. Structural shrink
only offers candidates to the existing predicate; byte reductions follow.
The canonical corpus and original finding groups are not overwritten.
Budget/deadline exhaustion is reported explicitly; a global minimum is not
promised.

The QS model `efz_qs_model` is preserved. Specific operations, limits, outcomes,
features and `query_model_agreement` moved to `efz_qs_adapter`.
`efz_qs_legacy` contains only the old implicit config for the two historical QS
targets; it is not an integration path for new libraries. Old direct-facade
signatures, recipe schemas 1/2/3 and QS finding schema 1 retain their previous
guarantees. Legacy mutation retains its previous RNG draws; the new explicit
adapter also records `choice`, so campaign traces from new and old configs need
not match.

A fixed before/after probe compared 24 generation cases, 11 fixtures,
66 operations, decode/outcome/features/oracle. Results are identical, SHA-256:
`daa8274871c75cc0a611e9509b5154b9d1a335d6ac986694f103ada30cd6c87e`.
See [qs-compatibility.json](../../artifacts/gleam-layer/20261010-universal/qs-compatibility.json).
This fixture evidence supplements real regression tests, not their diff.

The general `scripts/gleam_replay.escript` now accepts `--config`, `--finding`,
`--budget`, `--out` and repeated `--code-path`. Cold preflight compares effective
trusted limits/identity before execution; the workflow budget includes replay and
the minimizer. Output is created after reproduction; an existing directory/symlink
is rejected. The five-argument QS body moved into the separate
`gleam_replay_legacy.escript`. **The new wrapper and forwarding were statically
reviewed, but were not verified by execution after the instruction not to run
tests.** The main Erlang replay/minimization APIs were checked earlier.

## XML-RPC: actual scope

The etnt/xmlrpc commit
`fb46463b2acadf164ec534d9e2033e194341c507` was used, with identity/artifact
preparation in `_build/xmlrpc-example/`. `efz_xmlrpc_target:run/1` converts a raw
binary to a charlist and calls the real `xmlrpc_decode:payload/1` once. HTTP/TCP,
application methods and the encoder are not used.

Independent Gleam model v1 supports methodCall, parameters, explicit int32,
boolean 0/1, string, nested array/struct. Printable ASCII U+0020..U+007E and the
five predefined XML entities; a limited exact XML grammar. Example limits:
4096 bytes, depth 8, nodes 128, collection 16, string/name 128 bytes. Method/member
names from existing atoms or charlists are normalized into binaries without
atom creation. The independent model's semantic values are compared with those
of the actual decoder, not XML bytes.

Oracle/generation/mutation do not support response/fault, i4, double, date,
base64, nil, implicit strings, non-ASCII UTF-8, the wider XML grammar, inter-tag
whitespace, attributes, self-closing tags, numeric entities, DTD, CDATA or namespaces.
The observer can classify response/fault; this is not an oracle for their
correctness. Encoder properties and semantic round-trip are also unimplemented.
Its atom-name requirements/iolist output do not expand the decoder predicate.

Target coverage: only prepared `xmlrpc_decode`/`xmlrpc_util`. `xmerl_scan`
participates in execution identity, but its internal coverage is not measured.
`strict => false` is required for record defaults from xmerl.hrl; executable
decoder clauses have probes. Adapter/model/observer/oracle/core helpers are not
included in target coverage. Stdlib APIs without prepared artifacts use `none`.

## Checks already performed

The commands below record completed runs. They were not repeated after the user's
prohibition. Logs are in `artifacts/gleam-layer/20261010-universal/`.

| Command / check | Saved result | Log/artifact |
| --- | --- | --- |
| `ERL_FLAGS='+S 2:2' rebar3 compile` | PASS; default build without Gleam/model | `compile-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 eunit` | 300/300 PASS before adding CLI tests | `eunit-off-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_semantic_cli_tests` | 3/3 PASS | `semantic-cli-off-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 ct` | 3/3 PASS | `ct-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 xref` | Exit 0, no warnings | `xref-final.log` |
| `ERL_FLAGS='+S 2:2' rebar3 dialyzer` | Exit 0, no warnings | `dialyzer-final.log` |
| `ERL_FLAGS='+S 2:2' GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` | PASS | `optional-compile-final.log` |
| `ERL_FLAGS='+S 2:2 -pa /home/fbogoslavskii/efz-fuzz/_build/xmlrpc-example/dependency-ebin' GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam eunit` | 368/368 PASS, exit 0 | `eunit-optional-final.log` |
| All 7 example configs through `scripts/fuzz.escript --config … --max-iterations 2` | Exit 0; unknown adapter exit 2 | `cli-final/results.json` |
| Generic/domain scaffold, compile `-Werror`, seed call, CLI; repeated creation | PASS; repeat exit 2 and original hashes unchanged | `scaffold-final.json` |
| Before/after QS fixture probe | Exact equality | `qs-compatibility.json` |

Behavioral checks cover direct BEAM dispatch, different APIs/arities,
nested codec/mutation bounds, finite atoms/resources, state reset/cleanup,
missing/optional callbacks, unknown adapter/options/capabilities, model ABI,
layer errors, malformed/rejection/fallback, deterministic RNG provenance,
semantic-only corpus admission/parent selection, restart/recalibration,
raw replay in a separate VM without adapter/model BEAMs, semantic identity
mismatch, raw/semantic regeneration, predicate-preserving minimization and
budget/deadline. XML integration checks 18 actual generated calls, 216 mutations
and independent model agreement. Old QS integration fixtures are also preserved.

Early failed logs were retained, including an incorrect focused-test selection,
a stale test output directory, and the subsequently fixed missing
expected_harness in the new XML raw-replay test. They are not presented as PASS;
the final optional full suite passed after fixes. Default full suite 300 and
focused CLI 3 are not represented as one full run of 303.

## Saved comparative measurements: preliminary

On the same Intel i7-1260P machine, affinity CPUs 0/1, OTP 27 and `+S 2:2`:

* QS old/new/off: 3 repeats, the same six seeds, RNG `{17,18,19}`,
  300 mutations + 6 calibration = 306 primary/total executions per sample.
  A separate warmup of 20 mutations is excluded from 306. Backend `otp_native_public`,
  shared target BEAM SHA-256
  `c407d6be5bb023b5ea907ff2bfc69820fe90dc9f39932caf688bcba7ea07464f`,
  target timeout 1000 ms, campaign deadline 120000 ms, driver timeout 135 s.
* Generic/XML/stateful off/on: 3 repeats, one identical seed for each API,
  RNG `{17,23,41}`, 100 mutations + 1 calibration = 101 primary/total executions,
  extras 0; target-only ETS, timeout 1000 ms, campaign deadline 30000 ms,
  driver timeout 45 s, campaign warmup 0. Generic is the tuple library's combine/2.

All saved QS 9/9 and other 18/18 samples completed their execution budget,
with exit 0 and no driver timeout. These are completed snapshots, not early
timeouts called completed. Wall-time medians include campaign setup/calibration;
driver wall time including VM startup is saved separately in runs.json.

| Snapshot / mode | Median wall, ms | Wall range, ms | Primary/s | Coverage | Semantic-only novelty | Provider success / fallback |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| QS old | 739.309 | 713.198..753.390 | 413.900 | 47 | 1 | 11 / 16* |
| QS new explicit | 723.828 | 722.336..729.559 | 422.752 | 48 | 1 | 9 / 22 |
| QS off | 756.010 | 742.380..771.641 | 404.757 | 46 | 0 | 0 / 0 |
| Generic off | 1332.773 | 495.633..1693.731 | 75.782 | 1 | 0 | 0 / 0 |
| Generic on | 314.443 | 307.972..370.118 | 321.203 | 1 | 1 | 7 / 4 |
| XML-RPC off | 1740.152 | 461.274..1854.316 | 58.041 | 26 | 0 | 0 / 0 |
| XML-RPC on | 1923.890 | 1865.013..2250.691 | 52.498 | 37 | 1 | 5 / 5 |
| Stateful off | 524.489 | 327.623..1620.321 | 192.568 | 6 | 0 | 0 / 0 |
| Stateful on | 337.611 | 334.484..389.764 | 299.161 | 6 | 1 | 3 / 5 |

Fallback here is read from raw counters, not the incorrect earlier aggregate.
`*` Old QS had no common fallback counter: 27 attempts − 11 successes = 16,
also 3 limit + 11 unsupported + 2 unchanged. In the old XML/stateful/new QS
summaries, unchanged was added again to fallbacks that already included it;
the summaries therefore contain 6/6/26 instead of 5/5/22. The original artifacts
were not rewritten; drivers were fixed for a future series.

Stateful cost in this series is the cost of all input executions, including
codec rejection, not the isolated cost of an accepted scenario. Reconstructed
from canonical packets: off 1 valid scenario/3 commands/100 rejected packets,
on 5 valid scenarios/14 commands/96 rejected packets. This reconstructs planned
operations, not a runtime aggregate of completed gen_server calls. The old
summary field `primary_scenarios=101` incorrectly named 101 primary input
executions. The outcome fixture distinguishes 1 scenario/N operations; separate
full measurements of accepted scenarios and actual operation totals remain open.

Separate callback microbenchmark: 3×1000 calls for each path, 100 warmup calls,
one setup target execution outside timing, 0 measured target executions.
Medians for direct adapter / validated facade, µs:

| Callback | Generic | QS | XML-RPC |
| --- | --- | --- | --- |
| Generation | 0.943 / 1.003 | 0.211 / 0.270 | 0.499 / 0.560 |
| Mutation | 1.935 / 2.394 | 2.539 / 3.552 | 1.494 / 1.890 |
| Observation | 0.479 / 1.251 | 0.250 / 0.491 | 0.187 / 0.490 |
| Oracle | 0.024 / 0.060 | 1.531 / 1.672 | 0.581 / 0.669 |

The generic oracle here is `inconclusive,no_property`, not the cost of checking
an API. This is fixed-input callback cost, not all possible sizes/formats.
Features from different adapters are not compared as a common scale.

Evidence:
[performance-final manifest](../../artifacts/gleam-layer/20261010-universal/performance-final/manifest.json),
[runs](../../artifacts/gleam-layer/20261010-universal/performance-final/runs.json),
[QS manifest](../../artifacts/gleam-layer/20261010-universal/qs-performance-final/manifest.json),
[QS runs](../../artifacts/gleam-layer/20261010-universal/qs-performance-final/runs.json),
individual summary.json and *-callbacks.json.

Why the status is preliminary: performance-final source hashes already differ
from the current core/codec/worker and driver; the QS manifest records the shared
target and a limited portion of engine identities, but not the whole final
plugin/dispatcher. The earlier series also had artifact preparation overlapping
with another measurement. With n=3, identical RNG traces and the observed
wall-time variation, no speedup, better discovery or performance acceptance can
be claimed. Failed preparation of the first QS series (missing `cow_inline.hrl`)
is saved separately and did not produce fabricated results.

## Changed files and remaining validation

| Group | Files/directories | Purpose |
| --- | --- | --- |
| Public boundary/plugins | `src/efz_semantic_adapter.erl`, `efz_gleam_adapter.erl`, `efz_term_api_adapter.erl`, `efz_term_codec.erl`, `efz_qs_adapter.erl`, `efz_qs_legacy.erl`, `efz_xmlrpc_adapter.erl` | Contract, generic codec, preflight, bounded dispatch and private semantics |
| Core integration | `efz_mutation_plan.erl`, `efz_mutation.erl`, `efz_worker.erl`, `efz_semantic.erl` | Adapter catalogue, RNG provenance, single-outcome callbacks and semantic admission |
| Durable APIs | `efz_recipe.erl`, `efz_replay.erl`, `efz_semantic_replay.erl`, `efz_corpus_store.erl`, `efz_semantic_corpus.erl` | Versioned identity/restart/replay/reduction/minimization |
| CLI/build | `efz_cli.erl`, `rebar.config`, `scripts/build_gleam.sh`, `gleam_replay*.escript`, `semantic_scaffold.escript` | Trusted config path, optional models and reusable scaffolding |
| Models/examples | `gleam/efz_semantic/src/efz_term_model.gleam`, `efz_xmlrpc_model.gleam`, `examples/{term_api,stateful,xmlrpc,semantic_configs}`, QS metadata | Real reusable integrations; original QS model preserved |
| Behaviour evidence | `test/efz_{plugin_*,semantic_api,semantic_cli,semantic_portability,term_api,xmlrpc_adapter}*`, regression tests | Boundary, lifecycle, identity, persistence and compatibility |
| Comparative evidence | `scripts/{run_semantic_bench.py,run_qs_semantic_bench.py,semantic_bench.escript,gleam_bench.escript,qs_compatibility_probe.escript}` | Finite serial drivers, manifests and before/after probe |
| Docs | `adapter-contract.md`, `connecting-erlang-libraries.md`, `user-guide.md`, this report, XML README | Public contract, 8-step guide, configs/limits and validation status |

Replay CLI review and accounting for saved results were completed without new
runs. Runtime/syntax verification of the new replay CLI and legacy forwarding,
the final isolated comparison series, and measurement of actual accepted stateful
scenario/operation costs remain open. Prepared commands for a future run,
**not executed** here:

```sh
python3 scripts/run_semantic_bench.py --out /tmp/efz-semantic-verified
python3 scripts/run_qs_semantic_bench.py \
  --baseline /tmp/efz-universal-baseline-e4c0244/_build/gleam \
  --out /tmp/efz-qs-verified
```

Practical guide, templates and configs:
[Connecting an Erlang library to Gleam Layer](connecting-erlang-libraries.md).
The execution envelope is limited by the available code path, permitted EFZ
lifecycle, reproducible harness and actually prepared target coverage. External
services, devices, custom ports/NIFs, unmanaged processes and other resources
require separate adapters/harnesses/environment checks. A common contract does
not automatically infer the semantics of an arbitrary library.
