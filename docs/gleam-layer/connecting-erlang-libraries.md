# Connecting an Erlang library to Gleam Layer

**English** · [Русский](../i18n/ru/gleam-layer/connecting-erlang-libraries.md) · [Español](../i18n/es/gleam-layer/connecting-erlang-libraries.md) · [简体中文](../i18n/zh-CN/gleam-layer/connecting-erlang-libraries.md) · [All languages](../i18n/README.md)

The integration uses the existing EFZ execution, corpus, scheduler, coverage,
RNG and replay. Each campaign selects one adapter. The harness retains the public
contract `run(binary()) -> term()`; the actual library function may have a
different arity and accept Erlang terms. The generic adapter does not require a
separate Gleam model for each API. Protocol plugins preserve the original wire
bytes and do not have to use the generic term codec.

[Implementation results and validation limits](universal-validation.md) contains
saved commands/logs, compatibility evidence and preliminary measurements.
The new general replay CLI has passed static review; its execution and the final
isolated comparison series have not yet been performed. The user's latest
instruction prohibits new test/measurement runs.

## 1. Choose an API and integration level

| Method | When to use it | Real example |
| --- | --- | --- |
| Generic term/API | Arguments can be described as bounded Erlang terms | `lists:reverse/1`, `maps:find/2`, `efz_term_tuple_library:combine/2` |
| Domain/protocol | A wire grammar, correlated fields or an independent model is needed | `efz_xmlrpc_adapter`, `efz_qs_adapter` |
| Stateful harness | Setup/reset/cleanup and a command list are needed | `efz_stateful_target`, `efz_stateful_counter` |

Validated envelope: the module is available on the code path, the call runs
locally on BEAM through a reproducible harness, and EFZ manages execution
timeout/cleanup. The harness supplies the required resources. A `-spec` or module
name does not prove that an arbitrary result is correct. Sockets, drivers,
external services, hardware resources and special OS dependencies require their
own harness and separate validation of the execution environment.

## 2. Create a harness

If the API has a `-spec` and its BEAM was built with `debug_info`, the harness,
configuration and seed can be [generated automatically](connector-generation.md)
with `semantic_scaffold.escript from-beam OUT HARNESS LIBRARY.beam FUNCTION ARITY`.
Supported types are converted into the shared adapter's schema; they do not
require a manually written argument description.


Ready-to-use generic example:

```erlang
-module(example_library_target).
-export([run/1, options/0, semantic_contract/0]).
options() -> #{entrypoint => {lists, reverse, 1},
              arguments => [#{kind => list, item => #{kind => integer}}]}.
semantic_contract() -> (options())#{kind => term_api}.
run(Raw) -> efz_term_codec:execute(Raw, options()).
```

For your own `example_library`, change `entrypoint`, `arguments` and the harness;
the EFZ core is not edited. `prepare/3` checks function availability, arity and
agreement between harness metadata and adapter options. No new specialized
package is needed for such a library. Exported arities from 0 to
`min(collection, 255)` are supported: the default `collection => 32` permits up
to 32 arguments, while 255 is BEAM's arity limit. Zero arity uses
`arguments => []`. The result is described independently of argument constraints.

`efz_term_codec:execute/2` decodes the canonical packet and calls
`apply(Module, Function, Args)` without semantic dispatch or model dependencies.
The earlier `efz_term_api_adapter:execute/2` remains as a compatibility delegate.
An unsupported/malformed packet returns `{efz_term_input_rejected, Reason}`.
Ordinary library `{error, Reason}` values remain ordinary results. The harness
defines which API exceptions are expected rejections and explicitly converts
them when required by the selected API's contract.

The harness has its own fixed decoding envelope. If it does not declare
`semantic_contract().input_limits`, codec defaults apply. Campaign limits for
`bytes`, `depth`, `nodes` and `collection` must not exceed those bounds;
exceeding them is rejected before startup with `term_api_input_limits_mismatch`.
Stricter campaign limits are allowed as a structurally supported subset of the
harness, provided the argument constraints remain valid. Raw mutation can still
reach the harness's wider input domain.

To expand its envelope, the harness passes the same limits to its codec and
declares them in metadata, for example:

```erlang
input_limits() -> #{bytes => 4096, depth => 8, nodes => 256,
                    collection => 64, operations => 1}.
semantic_contract() -> (options())#{kind => term_api,
                                   input_limits => input_limits()}.
run(Raw) -> efz_term_codec:execute(Raw, (options())#{limits => input_limits()}).
```

Adapter options remain `entrypoint`, `arguments` and optional `property`;
`input_limits` belongs to the harness contract. Metadata accepts only the common
limit keys within their documented finite ranges; invalid metadata produces
`invalid_term_api_input_limits`. During replay, the same harness/code identity
retains its decoding envelope, while semantic identity additionally checks the
effective campaign limits. A working collection bound of 64 is checked by the
separate `efz_term_custom_limits_target` fixture with a list longer than 32.

Scaffolding creates compilable sources, a config and a seed without overwriting:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
escript scripts/semantic_scaffold.escript generic /tmp/new-api efz_example_target
escript scripts/semantic_scaffold.escript domain /tmp/new-domain efz_protocol_target
```

Generic defaults use the real `lists:reverse/1`. For another library, pass a
trusted `options.term` as the fourth argument, containing exactly
`#{entrypoint => {Module, Function, Arity}, arguments => Specs}`. The scaffolder
rejects resource specs with `resource_harness_required`: their lifecycle must be
written explicitly. The domain skeleton implements an independent length-prefixed
message and an observer-only plugin; a missing model does not produce a passing
oracle. Compilation and CLI instructions are in the generated `README.md`.

## 3. Describe arguments, scenarios and capabilities

Generic codec schema 1 uses its own binary envelope rather than ETF:
`<<"EFZT", 1, ArgumentCount:16, TaggedArguments/binary>>`. Integer fields are
encoded big-endian. It preserves the argument list, type tags, bounded sizes
and deterministic map-key order. Atom/resource tags are indices into a sorted
finite set from the trusted configuration. Fuzz input does not create atoms.

| `kind` | Additional fields and bounds |
| --- | --- |
| `integer` | Signed 64-bit, `min`/`max`; defaults −1000000..1000000 |
| `float` | Finite 64-bit float, finite float `min`/`max`; defaults −1000000.0..1000000.0 |
| `boolean` | `true`/`false` |
| `binary` | Arbitrary bytes, `min_length`/`max_length` |
| `charlist` | Proper list of Unicode scalar integers, without surrogates; encoding is defined by the API |
| `atom` | Required finite nonempty `values => [existing_atom, ...]` |
| `list` | `item => Spec`, `min_length`/`max_length`, proper lists |
| `tuple` | `items => [Spec, ...]`, fixed tuple arity |
| `map` | `key => Spec`, `value => Spec`, bounded size, duplicate keys rejected by the codec |
| `term` | Supported nested scalar/list/tuple/map combinations; atoms only from `atoms => [...]` |
| `resource` | `values => [handle_name, ...]`, stored as `{'$efz_resource', Handle}` |

`min_length` defaults to 0 and `max_length` to `collection` (default 32,
maximum 256), including for binary/charlist. With these defaults, a binary
argument is limited to 32 bytes even if the whole packet permits 4096 bytes.
Charlist length is counted in Unicode codepoints: the codec stores each codepoint
as a tagged signed 64-bit integer, not as UTF-8 bytes. The harness converts a
charlist into the text encoding required by the specific API. Each atom/resource
enum in a spec contains at most 256 existing atoms.

Common limit defaults: `bytes => 4096`, `depth => 8`, `nodes => 128`,
`collection => 32`, `operations => 1`; preflight permits at most 1 MiB,
depth 16, nodes 4096 and collection 256. `bytes` includes the header and type tags.
Argument roots have depth 1; every list/tuple element, map key/value and charlist
codepoint consumes the node budget. The argument-list envelope itself does not
count as a separate node. Argument configuration and data undergo separate
validation. PID/ref/port/fun are not portable literal inputs. The observer can
report their finite result class without storing the values themselves.

The stateful example encodes one argument: a list of at most 16 tuples
`{ResourceHandle, Command, Integer}`. Commands `get`, `put`, `add`, `reset`
are selected from a finite set. `semantic_contract/0` declares
`resource_lifetime => execution, resource_handles => [counter]`.
`efz_stateful_target:scenario/1` creates a new unregistered gen_server through
the permitted EFZ child spawn `efz_target:spawn_link/1`, sets OTP 27 `proc_lib`
metadata (`'$ancestors'`, `'$initial_call'`) and enters the public
`gen_server:enter_loop/3`. The harness does not call internal `proc_lib` functions,
but these process dictionary keys are tied to the validated OTP 27 lifecycle.
This is a validated OTP 27 bootstrap fixture, not a promise to support arbitrary
OTP lifecycles: an ordinary unmanaged `gen_server:start_link/3` inside an EFZ
execution will be rejected. When run directly outside EFZ, the harness uses
ordinary `start_link`. The harness resolves the symbolic handle to a PID,
executes commands and stops the process in `after`; `semantic_contract/0`
declares `execution_modules => [efz_stateful_counter]`. Every execution/replay
starts from zero state. One input is one primary execution; the bounded result
contains separate `scenario_executions => 1`, `library_operations => N`,
`trace => [...]`. `N` counts scenario commands; setup and process shutdown are
excluded. For other resources, the user extends the harness rather than the
scheduler or worker.

## 4. Choose a standard adapter or your own plugin

The exact public interface is described in [adapter-contract.md](adapter-contract.md).
`descriptor/0` and cold `prepare/3` are required; the prepared context is immutable.
The descriptor fixes adapter ID/API/model/observer/recipe/operation versions,
capabilities, operation IDs, model modules and properties. The optional cold
`code_dependencies(Context) -> #{semantic => [module()], target => [module()]}`
binds additional helper/property and target dependency BEAMs to the existing
identity mechanism. The descriptor already binds the adapter itself and its
model modules. An identity dependency does not itself add coverage.
The generic adapter additionally binds `efz_term_codec` as a semantic dependency:
changing the decode/normalization helper rejects old semantic replay just as
changing the model does. Cold generic preparation checks the real Gleam exports
`scalar/4` and `observe/6`; a missing model module or incompatible ABI is rejected
before the campaign. Model-free harness execution and seed creation through the
codec do not require this check.

Operational callbacks are required only for declared capabilities:

```erlang
generate(Index, Context) -> {ok, Raw} | {skip, Reason} | {error, Reason}.
mutate(Raw, Operation, #{choice := Choice}, Context) ->
    {ok, Raw, RecipeData} | {skip, Reason} | {error, Reason}.
observe(Raw, PrimaryOutcome, Context) ->
    {ok, LocalFeatureIds} | {skip, Reason} | {error, Reason}.
oracle(Raw, PrimaryOutcome, Context) ->
    {pass, Property} | {fail, Property} | {inconclusive, Reason} | {error, Reason}.
shrink(Raw, Context) -> {ok, Candidates} | {skip, Reason} | {error, Reason}.
```

`Reason` for skip/inconclusive is an atom; `Property` is exactly `{Id, Version}`
from the descriptor. Features: at most 64 local IDs 0..255. The dispatcher adds
`{AdapterId, ObserverVersion, LocalId}`; identical local IDs from different
adapters are not mixed with structural coverage or with each other.
Generation/mutation are deterministic; `choice` 0..65535 comes from the EFZ RNG
and is recorded in the recipe. The adapter does not create its own RNG,
registry, worker or process per callback.

For an `example_library` with a special wire format, use the domain skeleton:
replace the target call, metadata and observer; if needed, add your own Gleam
model, its name in `model_modules`, bounded generation/mutation and an independent
property. Central dispatch contains no branches based on that library's name.
An observer-only descriptor may have `model_modules => []`, `operations => []`,
`properties => []`; its config then uses `structured_fraction => 0`,
`oracle => disabled`. A generator-only plugin is also allowed without an
observer/oracle, with feedback disabled and fraction 0.

A Gleam model can be supplied as a separate Erlang/rebar3 dependency: compile/export
its BEAMs in advance, add the dependency's `ebin` and required runtime dependencies
to the opt-in campaign's code path, and declare model modules in the descriptor.
An ordinary EFZ build must not download or compile that package. The repository's
optional build uses pinned Gleam 1.10.0; runtime-off and ordinary builds do not
call models.

## 5. Configure seeds, mutation, observer and oracle

Working campaign maps are in [examples/semantic_configs](../../examples/semantic_configs):
`lists_reverse.term`, `maps_find.term`, `tuple_api.term`, `stateful.term`,
`xmlrpc.term`, `cow_qs.term` and `cow_qs_legacy.term`. Seeds were created with the
real codec using each harness's argument specs; XML/QS seeds remain original
wire binaries. These configs use `coverage_backend => none` for execution and
semantic smoke testing. They do not claim measured structural coverage of stdlib
APIs.

```erlang
gleam_layer => #{adapter => efz_term_api_adapter,
    adapter_options => #{entrypoint => {lists, reverse, 1},
        arguments => [#{kind => list, item => #{kind => integer}}]},
    structured_fraction => 10, feedback => guided, oracle => disabled,
    oracle_budget => 64,
    limits => #{bytes => 4096, depth => 8, nodes => 128,
                collection => 32, operations => 1}}
```

The generic observer classifies the outcome and bounded result tree; it does not
prove library correctness. The generic oracle stays disabled until the user
sets `adapter_options.property => #{callback => {Module, Function}}` and
`oracle => inline`. The callback receives `(DecodedArgs, PrimaryOutcome)` and
returns `true`, `false` or `inconclusive`; the predicate has ID
`{generic_custom_property, 1}`, and the callback's code identity is recorded
separately. `stateful.term` explicitly selects an independent counter-trace
property.

`guided` admits semantic novelty to the ordinary corpus and parent selection.
`observation_only` reports features but does not guide the corpus/scheduler.
`disabled` disables the observer. `structured_fraction => 0` performs no branch
RNG draw or mutation decode; enabled observer/oracle callbacks continue working.
`gleam_layer => false` disables all dispatch and preserves the ordinary RNG path.

`skip`, unchanged and limit mutation use the ordinary byte fallback. A layer
exception/invalid result ends the campaign as an infrastructure error in the
adapter itself; this is neither a library finding nor a successful fallback.
`inconclusive` means there is no justified verdict.
An expected parser rejection does not become a finding without violating an
explicitly specified supported property. Callbacks run inline; exceptions are
caught, but this does not stop an infinite callback. A plugin must have finite
algorithms and check budgets before costly allocation/recursion.

For QS, the old config without `adapter` works only through the isolated legacy
shim for the historical `efz_qs_target`/`efz_qs_defect_target`. This rule does not
participate in connecting new targets. An explicit `efz_qs_adapter` checks the
harness metadata `#{kind => query_string, outcome => accepted_pairs}`.
QS-specific `fields` and `component` belong in `adapter_options`, not in common
limits.

XML-RPC uses the [pinned etnt/xmlrpc preparation](../../examples/xmlrpc/README.md).
`efz_xmlrpc_target` calls `xmlrpc_decode:payload/1` on a charlist. Independent
model v1 checks printable ASCII methodCall, int/boolean/string and nested
array/struct, with bytes/depth/nodes/collection/string limits. Names are normalized
from existing atoms or charlists to binaries without atom creation.
Response/fault correctness, i4/double/date/base64/nil, implicit strings,
non-ASCII UTF-8 and the wider XML grammar are not supported by oracle v1.
Observation can classify response/fault; this does not prove their correctness.

## 6. Prepare target-only coverage artifacts

Use the existing `efz_instrument:compile/2` or
`efz_cov_native_public:compile/3`, followed by the standard artifact preflight.
Select the library's own modules; exclude adapter/model/property helpers.
The harness and infrastructure codec do not replace library coverage. For
built-in OTP APIs without a prepared coverage backend, honestly use
`none`/diagnostic and record this limitation separately.

XML-RPC preparation instruments `xmlrpc_decode` and `xmlrpc_util`. OTP xmerl
remains a dependency; its internal coverage is not measured. `xmerl.hrl` record
defaults require the documented `strict => false`; executable decoder clauses
remain probed. For example, for the counter fixture:

```erlang
{ok, A} = efz_instrument:compile("examples/stateful/efz_stateful_counter.erl",
    #{modules => [efz_stateful_counter], outdir => "/tmp/counter-artifacts",
      source_root => ".", erl_opts => [debug_info, warnings_as_errors]}).
```

After preparation, change the config to `coverage_backend => ets, artifacts => [A]`
or pass `--artifacts /tmp/counter-artifacts` to the CLI. Merely having a dependency
on the code path is not enough to claim its coverage was measured.
For the counter fixture, ETS probes in the admitted child and cleanup without
remaining processes were checked separately. This covers `efz_stateful_counter`
itself; internal OTP `gen_server`/`proc_lib` modules are not included.

## 7. Run validation and a campaign

From the EFZ root:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_term_api_tests
ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config examples/semantic_configs/lists_reverse.term \
  --code-path _build/gleam/lib/efz/ebin --out /tmp/reverse-run
ERL_FLAGS='+S 2:2' escript scripts/fuzz.escript \
  --config examples/semantic_configs/stateful.term \
  --code-path _build/gleam/lib/efz/ebin --out /tmp/counter-run
```

`--config` reads exactly one trusted Erlang campaign map through `file:consult`.
Code paths are loaded before consult/preflight. Existing explicitly supplied CLI
flags override the config; `--seeds DIR` imports raw files and `--artifacts DIR`
overrides artifacts. `--out` remains required. A config stores no executable
closure, resource PID or secret. A trusted config can specify atoms; this is a
separate boundary from untrusted fuzz bytes. Earlier CLI flags have not been
renamed.

Startup detects unknown adapters, missing required callbacks/models,
incompatible metadata/options, unsupported capabilities and coverage selection.
`--gleam-layer` without an explicit adapter remains the historical QS CLI
compatibility path; new integrations use a config with `adapter`.

For XML-RPC, first run `examples/xmlrpc/prepare.escript`, then add
`_build/xmlrpc-example/dependency-ebin` and `_build/xmlrpc-example/harness-ebin`
through `--code-path`. For QS, add `_build/default/lib/cowlib/ebin`.
Full validation of a change includes ordinary/optional builds, runtime-off,
relevant EUnit/CT, xref/Dialyzer and finite campaigns with report/artifact evidence.
Comparative results must report wall-clock time, execution budget,
calibration/mutation/extra executions, provider outcomes, coverage and
adapter-local semantic novelty separately. Feature counts from different adapters
are not a common scale. A callback microbenchmark does not replace campaign
throughput or discovery evidence.

## 8. Check persistence, replay and minimization

The canonical corpus stores raw binaries. Restart recalibrates inputs with the
current adapter and does not trust saved semantic features from another model.
The existing `corpus_build_policy => reject | recalibrate` defines mismatch policy.
Adapter/model/options/limits, observer/property and operation-catalogue versions,
code/execution identities and RNG provenance are included in existing metadata.
Identity also records the SHA-256 of the deterministic portable prepared context;
the cold context must be reproducible, otherwise replay gets a mismatch.

Reconstructing raw input and executing it are separate operations.
`efz_recipe:load/1` and `efz_recipe:regenerate/1` for schema 4 reconstruct saved raw
replacement bytes and validate recipe/RNG provenance through the EFZ core.
They do not load the adapter/model, execute the target or decode opaque adapter
options/RecipeData. Historical QS recipe schemas retain their earlier raw-replay
guarantees.

Executing reconstructed input requires target/harness/dependency artifacts,
without semantic callback dispatch, adapter or model BEAMs. The generic harnesses
in this guide use model-free `efz_term_codec:execute/2`: the codec BEAM is needed
as an ordinary execution dependency. Wire-format harnesses call the library
directly. Custom harnesses must also separate their execution dependencies from
optional semantic callbacks.

`efz_recipe:regenerate_semantic(Recipe, PreparedLayer)` reruns structured mutation
with the saved operation/params and checks that raw bytes and RecipeData match.
This opt-in check requires a fresh prepared context from a trusted config,
exact adapter identity and available adapter/model BEAMs. It does not execute
the target either. Semantic property replay below checks the actual target
execution's outcome and requires its own property contract.

```erlang
{ok, Expected} = efz_semantic_replay:load("finding.semantic"),
ReplayOptions = #{timeout => 1000, coverage_backend => none,
                  gleam_layer => TrustedLayerConfig},
efz_semantic_replay:run(Raw, Target, TargetArtifacts, Expected, ReplayOptions),
efz_semantic_replay:minimize(Raw, Target, TargetArtifacts, Expected,
    ReplayOptions#{minimization_timeout_ms => 30000}, 64).
```

`none` matches the smoke configs above. For saved ETS/native artifacts, select
the original `coverage_backend` and supply those exact artifacts.

The same contract is available through the general CLI without library-specific
branches:

```sh
ERL_FLAGS='+S 2:2' escript scripts/gleam_replay.escript \
  --config trusted-campaign.term --finding /path/to/finding-prefix \
  --budget 64 --out /tmp/new-replay-result \
  --code-path _build/gleam/lib/efz/ebin --code-path /path/to/harness/ebin
```

The trusted config specifies `target`, `artifacts`, `coverage_backend`,
`gleam_layer`, `timeout` and optional `max_input_bytes`; this CLI does not execute
seeds or the corpus. Replay supports `ets`, `ets_member`, `otp_native_public`
and `none`; campaign backend `bitmap` is not yet supported by this replay
execution API and is rejected before target execution. Options/config errors
exit with status 2. The CLI first performs cold validation using the trusted
config's effective limits and compares the full adapter identity. Increasing or
decreasing these limits relative to the finding causes a mismatch before target
execution; the finding's recorded byte cap does not replace an explicitly chosen
larger config limit. Neither cold validation nor reading a finding calls the
target.
The finding does not select executable code: only `.input` and `.semantic` are
read; diagnostic `.term` is unnecessary. The output directory must not exist,
including as a symlink; results are created only after actual reproduction.
`not_reproduced` and `inconclusive` exit with status 1 before minimization and
without output. Budget 1..10000 includes the initial replay and all minimizer
target executions: budget 1 saves only `replay.*`; larger budgets also save
`minimized.input`, `minimized.semantic` and `minimization.term`.
The actual deadline/budget status and total executions are saved in the result.
The minimizer uses a 30000 ms deadline: no new candidate executions are scheduled
after it; an already started execution is bounded by the separate target
`timeout`. If final verification is skipped because of budget/deadline, this is
explicitly recorded as `{skipped,budget}` or `{skipped,deadline}`. The saved input
reproduced the predicate at the last candidate check (or initial reproduction
if the input did not change); no additional final check is claimed in that case.

The earlier five-argument command remains as an explicitly limited QS legacy
helper and delegates to `scripts/gleam_replay_legacy.escript`. Its historical
target names, native `cow_qs` artifact and diagnostic JSON remain only in that
helper; new integrations use `--config`.

Semantic property replay requires an explicit trusted caller config, matching
adapter/model/property/target identities and code path. The artifact itself does
not select an adapter or callback module. Incompatibility is rejected; the
predicate is not silently replaced. Minimization uses the same property
ID/version and predicate, accounts for every target execution, initial
reproduction and final verification. It does not promise a global minimum and
reports deadline/budget exhaustion. Results are saved separately; the canonical
corpus and original finding groups are not overwritten.
