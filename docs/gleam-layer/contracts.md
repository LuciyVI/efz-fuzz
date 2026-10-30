# Native Erlang/Gleam contract v1

Requirements: **2.0-native**. Contract: **1**. Both
`efz_gleam_adapter:versions/0` and compiled `efz_qs_model:versions/0` return
`{Contract,Model,Codec,Mutator,FeatureSchema,Property} = {1,1,1,1,1,1}`.
Startup requires exact agreement; property replay checks that vector and
`{query_model_agreement,1}`. No incompatible artifact is silently coerced.
[architecture.md](architecture.md) identifies actual EFZ owners and P0 isolation.

## Typed core and Erlang boundary

First parser: pinned Cowlib `cow_qs:parse_qs/1`, commit
`c768a804565ff5b8178ed968a5921e469d6bd7b2`. Harness:
`examples/query_string/efz_qs_target.erl:run/1`. The separate
`efz_qs_defect_target` is an artificial acceptance fixture, not a production bug.
`<<"cow_qs">>` identifies the target family; artifacts additionally pin the harness.

Concrete Gleam ADTs live in `gleam/efz_semantic/src/efz_qs_model.gleam`.
These actual compiled representations are tested through BEAM calls:

| Type | Erlang representation / checked boundary |
| --- | --- |
| Bytes / `BitArray` | `binary()` only; non-byte-aligned bitstrings and text lists rejected; no UTF-8 assumption |
| `Field` | `{field,KeyBinary,ValueBinary}`, nonempty key, bounded components |
| `Query` | `{query,ProperFieldList,canonical | bad_escape}`, exact tuple/tag shape |
| `Limits` | `{limits,Bytes,Fields,Component,1}`, bounded integers |
| Gleam result | `{ok,Value}` / `{error,unsupported | limit}` |
| Observation facts | Adapter-constructed integers and `true | false` after checking primary outcome |
| Versions | Fixed six-integer tuple above |

Records are tagged tuples; outer EFZ configuration/metadata are maps. The adapter
validates proper lists, tags, binaries, alignment, integers, and limits before
calling the core. No Dynamic/unsafe cast or atom creation from fuzz bytes exists.
Calls are direct module calls without per-call JSON/ETF/IPC. ETF is confined to
existing versioned artifact codecs.

Actual narrow API, rather than a proposed behaviour:

```erlang
prepare(false | OptionsMap, PreparedEFZConfig) -> {ok,Config} | {error,Reason}.
decode(Binary, Limits) -> {ok,Query} | {skip,unsupported | limit} | {error,Reason}.
encode(Query, Limits) -> {ok,Binary} | {skip,limit} | {error,Reason}.
normalize(Query, Limits) -> {ok,Query} | {error,Reason}.
generate(Index, Limits) -> {ok,Binary} | {skip,limit} | {error,Reason}.
mutate(Binary, OperationId, Limits) -> {ok,Binary,RecipeData}
                                      | {skip,unsupported | limit} | {error,Reason}.
observe(Binary, PrimaryOutcome, Limits) -> {ok,SemanticSet}
                                          | {skip,limit} | {error,Reason}.
oracle(Binary, PrimaryOutcome, Limits) -> {pass,query_model_agreement}
  | {fail,query_model_agreement} | {inconclusive,Reason} | {error,Reason}.
```

EFZ owns explicit RNG selection around the pure core: mutate receives an operation
ID, not a hidden RNG. Generate uses deterministic catalogue index 0..4095; the
preparation script uses consecutive indices and caps output at 64 files. Neither
callback consumes caller RNG state. Generation is offline, not an online family.
The seed catalogue has separately checked `generator_version/0 = 2` and 12 slots
(indices repeat modulo 12); package version is 1.1.0. Seeds persist raw files plus
manifest schema 2 with index range, versions, limits, hashes and total bytes,
at most 64 seeds / 65536 bytes. Runtime startup still checks the eight v1 callbacks;
the generator version is a cold-path capability checked by the preparation command.
The semantic Model-and-next-RNG operation is therefore composed by EFZ with the
pure model callback; actual state transitions are specified below.

An EFZ candidate is `{candidate,Binary,PlanMetadata,NextPlanState}`; corpus
`input` stays the actual raw binary. The decoded model is transient, never the
persistent input. Existing executor/target term contracts remain unchanged.

## Codec laws, operations, and limits

Supported canonical models preserve field order and duplicate names. Decode
supports nonempty names with explicit `=`, `&`, percent escapes, plus-as-space,
and arbitrary bytes including NUL/non-ASCII. Name-only fields, empty names,
redundant separators, and bad escapes return unsupported and retain raw reachability.

For canonical models, `decode(encode(M)) == normalize(M)` and
`normalize(normalize(M)) == normalize(M)`; normalization is identity. Raw byte
identity is not promised. Deliberate `bad_escape` appends `&x=%` without repair
and is excluded from the valid-model decode/encode law.

| Bound | v1 value / configurable range |
| --- | --- |
| Structured input/output bytes | 0..4096; capped by existing EFZ `max_input_bytes` |
| Fields / component maximum bytes | 1..32 / 1..128; empty query/value permitted |
| Nesting | Fixed Query → Field depth 2; no recursive variant |
| Structured operations per candidate | Exactly 1 |
| Observer primary parser result | ≤100 pairs, ≤4096 bytes per component |
| Execution features / campaign vocabulary | ≤4 / 12 allowed IDs |
| Oracle checks | 0..10000 per campaign, default 64; calibration included |
| Semantic cache/queue/additional workers | None (size 0) |

Byte bounds precede decoder recursion; field/component bounds stop traversal.
Encoder computes output size before allocating encoded bytes. Mutator checks
field/component capacity before prepend/append allocation and computes wire size
without allocating a discarded encoding. Encoder independently checks size before
encoded-byte allocation. Large catalogue components/lists have allocation guards.
Callbacks are pure bounded
BEAM calls. Elapsed-time accounting does not interrupt a hung callback.

Fixed operations: 0 prepend `x={0,255}`; 1 empty first value; 2 remove first field;
3 reverse fields; 4 append byte 255 to first value; 5 select `bad_escape`.
0..4 preserve validity when within limits; 5 deliberately violates escape syntax.
Unsupported/limit/unchanged results use controlled ordinary fallback.

## PRNG and recipes

`efz_mutation_plan:new/1` uses explicit `rand:seed_s(exsplus,mutation.seed)`.
An absent seed retains the existing one-time crypto derivation. Reproduction
requires parent bytes, seed/state, plan configuration, versions, and limits.
Legacy random mutation/selection process-local rand policy is preserved; the
layer never uses it implicitly. Current EFZ has one worker, so completion order
is not a randomness source. After existing parent and lane selection:

| Case | State transition |
| --- | --- |
| Off / fraction zero | No added draw; ordinary starts at R0 |
| Fraction >0 | `{Branch,R1}=rand:uniform_s(100,R0)` |
| Branch exceeds fraction | Ordinary starts at R1 |
| Structured selected | `{OpPlusOne,R2}=rand:uniform_s(6,R1)`, Op=OpPlusOne−1 |
| Success | Candidate and next plan use R2; pure core draws nothing |
| Unsupported / limit / unchanged | Ordinary starts at R2, then uses its normal state progression |
| Layer error | Return diagnostic with R2 and stop; no rollback/retry/fallback |

Recipe operation is data-only:
`{structured_replace,1,{1,1,1,1,1,1},OperationId,OutputBinary}`, ≤4096 output bytes.
It uses existing `efz_recipe:make/4` / `efz_mutation:apply_operation/3`.
EFZR envelope stays v1; new structured recipe schema is 3, operation version 2.
Old structured schema 2 / operation 2 and ordinary schema 1 / operation 1 remain
readable. Only structured plan metadata adds `source_kind=>structured` and
`structured=>#{schema_version=>1,versions=>V,operation=>Op,limits=>Limits,
fraction=>F,rng_before=>[A,B],rng_after=>[NextA,NextB]}`. These are the exact two
58-bit exsplus state words immediately before branch selection and after operation
selection, represented as proper lists; no runtime functions enter artifacts.
Cold recipe validation reconstructs the state with `rand:seed_s({exsplus,[A|B]})`
and verifies branch, operation, next state, limits and exact metadata shape.
Regeneration applies stored bytes; it does not rerun the typed mutation.
Allowed operations cannot dispatch modules,
functions, or executable terms. Replacement regeneration works without Gleam;
property replay requires it. Original primary bytes, seed/config identity,
output hash, and build IDs are recorded. No adaptive hints/cache/energy change.

## Configuration and capabilities

Existing `efz_config` / `efz_cli` owns parsing. `gleam_layer=>false` is default;
a map enables one fixed adapter, so no adapter registry or parallel CLI exists.
Existing top-level `target` selects the supported harness/labelled test fixture.

| Layer field | Values / default |
| --- | --- |
| `structured_fraction` | Integer 0..100 / 10; positive requires staged mode |
| `feedback` | disabled, observation_only, guided / disabled |
| `oracle` | disabled, inline / disabled; deferred rejected |
| `oracle_budget` | Integer 0..10000 / 64 |
| `limits` | bytes, fields, component, operations / 4096,32,128,1 |

Existing `mutation.seed`, `random_seed`, `selection_seed` retain separate roles;
`artifacts`, `corpus_dir`, `crash_dir` retain locations. CLI additions:
`--gleam-layer`, `--structured-fraction`, `--semantic-feedback`,
`--semantic-oracle`, `--oracle-budget`; nested limits use the Erlang API.
Native coverage uses existing native preparation/API, not a new CLI backend.
Seeds-only preparation does not enable runtime callbacks.

Startup checks known keys, types/ranges, target/mode, target-only manifests,
package availability, exact versions, and the full eight-function core API
listed in [p2-integration.md](p2-integration.md). These export/module checks do
not repeat in the data path. A missing export returns
`{gleam_configuration,{gleam_callback_unavailable,Function,Arity}}`; versions
are checked before the remaining callbacks. Missing package gives
`{error,{gleam_configuration,{gleam_package_unavailable,Reason}}}`.
Other startup reasons include `unsupported_gleam_oracle_policy`,
`structured_requires_staged_mode`, `unsupported_gleam_target`,
`invalid_gleam_limits`, and `incompatible_gleam_versions`; they are fixed bounded
atoms rather than opaque badmatch diagnostics. Explicitly chosen coverage never
silently falls back. No external-fuzzer capability is checked. Disabled prep
returns unchanged config without optional module/application loading, semantic
state/workers/payloads, or added RNG draws. Off-build never invokes Gleam.

## Feedback and serialized admission

StructuralFeedback stays in existing EFZ collector units: presence probes
`{Module,BuildId,ProbeId}`, native module/line units under a pinned schema, or
existing count buckets. Do not sum them with semantic features into “coverage”.

SemanticFeature is exactly `{<<"cow_qs">>,1,Id}`, Id 0..11. SemanticSet is a sorted
unique proper list per execution. Metadata is
`#{schema_version=>1,namespace=><<"cow_qs">>,feature_version=>1,features=>Fs}`.
Exact tuples/lists have no hash/bitmap representation collisions. IDs: 0 accepted,
1 rejected, 2 timeout, 3 exception; 4..7 count 0,1,2,≥3; 8/9 empty value present/
absent; 10/11 byte ≥128 present/absent. They are bounded facts, not UTF-8 validation.

CampaignSemanticState is corpus-owned `semantic_seen`: the exact historical
successfully admitted/annotated set, ≤12 features. It is not an active refcount
index. Append-only corpus retains representatives of all committed features.
Per-execution reset does not clear campaign history.

For successful primary outcomes `{ok,_}` (including expected rejection):

```text
structural_keep = existing reason in {new_coverage,new_probe,new_hit_count}
semantic_new = execution_features minus corpus.semantic_seen
keep_new_input = structural_keep OR semantic_new is nonempty
```

Calibration annotates retained seeds; initial and other existing retention
reasons remain intact. Failure outcomes use the existing findings channel;
observed timeout/exception IDs do not admit those failures through this predicate.
Findings remain independent of novelty and corpus retention.

`efz_corpus:admit_semantic/4` serializes the decision in its gen_server. Novelty
calculation does not mutate seen. New raw input/metadata is persisted via
`add_checked/3` before entries/seen commit. Failed persistence/rejection leaves
seen unchanged for retry. Without a store, in-memory insertion is the commit.
The existing store sync/rename durability policy is preserved; P1 adds no fsync
rule. Existing-input annotations union feature/structural evidence and preserve
original admission reason rather than creating duplicates.

Semantic-only entries have working metadata `retention_reason=>new_semantic`,
are exposed to ordinary `mutation_entries/0` / `select/0`, and receive no new
energy policy. Observation-only emits metadata/counters without changing
admission. A separate observation log cannot demonstrate guidance.

No online pruning/refcount updates exist. `efz_semantic:cover/1` proposes a
subset preserving recorded structural probes/counts and semantic unions,
protecting initial/uncalibrated entries; it does not apply deletion. Future
merge/prune must preserve required representatives and atomically rebuild the
seen/active index before selection resumes, avoiding historical-seen suppression
of a replacement for a deleted representative.

`efz_corpus:semantic_representatives/0` is a serialized, read-only cold query.
It returns `{ok,#{Feature=>ExistingEntryId}}`, at most 12 keys, and rejects a
seen feature without an active representative. Off/observation-only returns
`disabled`. The index is derived from actual entries, with no stored refcounts,
cache or RNG draws. Semantic metadata requires the exact four-key schema and a
canonical bounded feature set; oversized/improper/unknown-ID metadata is rejected
before sorting. [P4 proofs](p4-feedback.md) apply the conservative subset to a
new store, restart it, and verify structural/semantic preservation. Online store
edits are unsupported; between-campaign edits rebuild seen from the current raw
corpus during explicit calibration, without an obsolete persisted global index.

Restart validates metadata, then calibrates all raw entries to rebuild compatible
annotations/seen before mutation. EFZC envelope v1 and old record v1/v2 remain
accepted; semantic discoveries use record v3. Namespace/schema/feature mismatch
fails restore; build mismatch follows existing reject/recalibrate policy. This
restores reusable corpus, not an exact campaign PRNG checkpoint.

## Observer, oracle, errors, and replay

The interval and module-scoped isolation are fixed in architecture.md. Observer
uses a bounded checked summary of the primary outcome, without decoding or
executing target. Enabled/budgeted oracle compares supported canonical ordered
model fields with the completed parser result. Match gives Pass; mismatch or
rejection of a supported canonical model gives Fail. Generic parse rejection
alone is not a defect. Unsupported/limit/timeout/exception/budget exhaustion
is Inconclusive with a reason, never Pass. Pure oracle has zero extra target calls.
There is no async/deferred implementation. Future repeated target execution must
use a separate EFZ-controlled interval, IDs, finite budget, and call counters.

| Taxonomy | Actual policy |
| --- | --- |
| expected_rejection | Harness-enumerated parser errors return rejected; ordinary target outcome |
| target_exception / target_timeout | Existing exception/exit/timeout findings and cleanup |
| oracle_failure | Independent existing finding store; original bytes/outcome and property/version sidecar |
| semantic_layer_error | Separate counter/diagnostic, stop as infrastructure_failure; never target bug or fallback |
| infrastructure_error | Existing lifecycle/coverage/persistence/config error policy |
| VM/native crash | Existing applicable external-target outcome only; no new native catcher |

Malformed codec/mutator/generator boundary returns `{error,boundary}`. Expected unsupported/limit returns
skip; observer boundary faults and raised/unexpected callback results become
`{error,{semantic_layer_error,Class,BoundedReason}}`. Target failures are saved
before semantic callbacks; observer failure cannot erase them. Elapsed checks
are not cancellation and killing Erlang does not guarantee native interruption.

`efz_crash:signature/2` retains fingerprint version/class/reason policy. Oracle
findings use class oracle_failure, reason `{query_model_agreement,1}`, empty stack.
Default category fingerprints classify by property tag; full property/version
and original input remain in artifacts. Replay requires EFZS v1, compatible
vector/property, raw SHA256, caller-chosen pinned harness/target builds. Artifact
terms cannot select executable callbacks. Minimization preserves the same v1
property failure; other exceptions/timeouts/unsupported inputs do not satisfy
it. Finite budget 1..10000 counts target calls including initial reproduction;
original findings are immutable. Result claims single-byte-deletion minimality
or budget exhaustion, not global minimality.

Fixtures, exit codes, review limits, and handoff: [p1-validation.md](p1-validation.md).
