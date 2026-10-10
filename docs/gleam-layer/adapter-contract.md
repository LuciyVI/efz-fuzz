# Semantic adapter API 1

This contract is frozen before implementation. EFZ owns execution, RNG, scheduling,
coverage, corpus and replay. Exactly one explicit adapter is prepared per campaign.
Callbacks run inline in the EFZ VM and must use finite algorithms. Catching exceptions
does not preempt a loop; trusted plugin code must enforce its documented bounds.

Mandatory callbacks:

```erlang
descriptor() -> #{id := binary(), api_version := 1, model_version := pos_integer(),
    observer_version := pos_integer(), recipe_version := pos_integer(),
    operations_version := pos_integer(), capabilities := [capability()],
    operations := [non_neg_integer()], model_modules := [module()],
    properties := [{atom() | binary(), pos_integer()}]}.
prepare(Target :: module(), Options :: map(), Limits :: map()) ->
    {ok, ImmutableContext :: term()} | {error, Reason :: term()}.
```

Capabilities are `generation`, `mutation`, `observation`, `oracle`, `shrink`.
Only advertised capabilities require their callback. Minimal observer-only and
generator-only plugins need no parser, mutator or oracle. Descriptor IDs have at
most 64 bytes; versions are positive integers. Operation IDs are unique integers
0..65535. Model modules and adapter modules are excluded from target coverage.
A harness may expose `semantic_contract/0`; the plugin validates this metadata in
prepare/3, never by a central target name allowlist. Runtime-off targets need none.

Optional operational callbacks (required when advertised):

```erlang
generate(Index :: non_neg_integer(), Context) ->
    {ok, binary()} | {skip, atom()} | {error, term()}.
mutate(Raw :: binary(), Operation :: non_neg_integer(), Params :: map(), Context) ->
    {ok, binary(), RecipeData :: map()} | {skip, atom()} | {error, term()}.
observe(Raw :: binary(), PrimaryOutcome :: term(), Context) ->
    {ok, [LocalFeatureId :: 0..255]} | {skip, atom()} | {error, term()}.
oracle(Raw :: binary(), PrimaryOutcome :: term(), Context) ->
    {pass, Property} | {fail, Property} | {inconclusive, atom()} | {error, term()}.
shrink(Raw :: binary(), Context) ->
    {ok, [binary()]} | {skip, atom()} | {error, term()}.
```

Property is exactly `{Id, Version}` and must appear in descriptor `properties`.
Observer returns a list of at most 64 local IDs; duplicates are permitted and
deduplicated by the dispatcher. Dispatcher adds `{AdapterId,
ObserverVersion, LocalId}`; namespaces do not contain input-dependent strings.
`PrimaryOutcome` is the existing EFZ executor outcome (`{ok, Value}`, timeout,
crash or exit). Adapters validate and summarize their supported subset before a
Gleam call. Observation and oracle never execute the target again in API 1.

Mutation Params is exactly `#{choice => Integer}` (0..65535), drawn by EFZ's RNG
and recorded; extra keys are a boundary error. Shrink returns at most 64 binary
candidates, each bounded by the effective byte limit.
The facade accepts generation indices 0..4095. Version integers are 1..65535;
operation catalogues have at most 256 entries, model_modules/properties at most
32 each. Descriptor keys are exactly those listed above, capabilities and
operation IDs are unique, and an advertised mutation/oracle requires a nonempty
catalogue/property list. Defaults are bytes 4096, depth 8, nodes 128, collection
32, operations 1; accepted common ranges are bytes 0..1048576, depth 1..16,
nodes 1..4096, collection 1..256 and operations exactly 1. The effective byte
limit also respects the campaign max_input_bytes.
Adapters have no independent RNG. RecipeData is bounded data, not executable
code. New recipes record API/model/operation catalogue identity, options/limits,
operation, params and EFZ RNG states. Ordinary raw replay consumes stored bytes
and never loads a plugin. Recipe regeneration is a separate opt-in operation.

`skip` means unsupported format/size/limit and mutation uses the ordinary byte
fallback; unchanged mutation also falls back. `inconclusive` means no justified
oracle decision. `error` or a caught callback exception is a layer error, never a
target finding. Expected parser rejection is a target outcome, not automatically
an oracle failure. Only an explicit supported property failure creates a finding.
The dispatcher validates all output types and sizes. Common limits are `bytes`,
`depth`, `nodes`, `collection`, `operations` (one in API 1); plugin-specific limits
are validated in adapter_options. Callback context is immutable and prepared once.
Portable options/context/RecipeData accept finite atoms, bounded integers and
finite floats, binaries, proper lists, tuples and maps; runtime PID/ref/port/fun
values are rejected. Boundary traversal permits depth at most 24 and 8192 data
nodes, tuple/map size at most 256 and individual binaries at most 1 MiB.
Encoded options are at most 65536 bytes, context at most 1 MiB, RecipeData at most
4096 bytes and reported error detail at most 1024 bytes. These cold/boundary data
limits are distinct from the input representation limits enforced by a plugin.

Semantic property artifacts pin descriptor, adapter/model BEAM identities,
effective configuration, target/harness builds and property version. Replay must
receive an explicit trusted adapter configuration; artifact data never selects
code. Mismatch rejects replay. Corpus restart recalibrates stored raw bytes with
current callbacks; persisted semantic namespaces are never trusted as calibration.
Shrinking must use the same property predicate and count every target execution;
raw inputs and original finding groups remain unchanged.

The historical QS facade signatures and schema-1 QS artifacts remain an isolated
compatibility interface. Configurations without `adapter` are accepted only by the
legacy QS shim. New integrations must explicitly select an adapter.

Cold optional `code_dependencies(Context) -> #{semantic := [module()], target :=
[module()]}` declares up to 32 modules per category. EFZ pins their code using its
existing BEAM identity mechanism. Semantic helpers/properties are excluded from
target coverage; declared target dependencies may be selected for coverage. This
callback makes dynamically configured properties and APIs reproducibly identifiable
without dispatcher knowledge of option names. The absence means no extra modules.
Durable identity stores effective adapter options as opaque uncompressed ETF bytes;
raw replay never decodes options or interns plugin-specific atoms. Descriptor
module/property names are portable binaries. Semantic replay compares against a
freshly prepared trusted caller config. The same identity also pins SHA-256 of
the deterministic portable prepared context (encoded context at most 1 MiB).
Changing cold context cannot silently change a recorded replay predicate.
prepare/3 must be reproducible from the declared target/options/environment;
non-reproducible ambient configuration produces an explicit identity mismatch.

New structured provenance stores callback RecipeData as opaque deterministic ETF
bytes (at most 4096), avoiding adapter-specific atoms in raw recipe decoding.
Schema-4 recipe regeneration uses stored replacement bytes, while a separate
explicit regeneration API requires compatible trusted adapter configuration.
