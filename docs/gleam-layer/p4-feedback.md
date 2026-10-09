# P4 oracle and corpus feedback — PASS

Requirements **2.0-native**; contract/model/codec/mutator/feature/property vector
**{1,1,1,1,1,1}**. Package **1.1.0**, cold generator **2**, recipe schemas **1/2/3**
are unchanged. Date: 2026-10-08. Toolchain: OTP **27.0** / ERTS **15.0**,
Rebar3 **3.25.0**, Gleam **1.10.0**. Dependency locks remain unchanged.

Evidence: `artifacts/gleam-layer/20261008-p4-feedback/`; see `gates.json`,
`proofs-complete/proofs.json`, nine corresponding raw `.term` proofs and
`p4-changes.patch`. HEAD remains `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`.
Starting HEAD, dirty/index patches and 65 file fingerprints were preserved.
[Common requirements](../../efz_gleam_native_subagent_prompts/01_COMMON_CONTEXT.txt),
[P0 execution path](execution-path.md), [P1 contract](contracts.md),
[P2](p2-integration.md) and [P3](p3-provider.md) were read before changes.

The starting checkout already contained the pure observer/oracle and guided
worker/corpus dispatch. This pass verifies that complete path, tightens the
exact metadata boundary, and adds a corpus-owned read-only representative query.
The lead owns these changes and fixtures; no subagents or independent review are
claimed. There is no new scheduler, corpus, engine, native bridge or instrumentation.

## Actual source map

| Responsibility | Actual file:function |
| --- | --- |
| Completed execution / immutable snapshot | `src/efz_guardian.erl:finish/2`, `src/efz_executor.erl:run_pinned/4` |
| Existing structural predicate | `src/efz_feedback.erl:evaluate/3`, `native_success/5` |
| Completed outcome → callbacks | `src/efz_worker.erl:execute_result/6`, `semantic_callbacks/4`, `semantic_observe/5`, `semantic_oracle/5` |
| Checked direct BEAM boundary | `src/efz_gleam_adapter.erl:observe/3`, `summary/1`, `oracle/3`, `oracle_model/3` |
| Real compiled typed callbacks | `gleam/efz_semantic/src/efz_qs_model.gleam`; BEAM `efz_qs_model:observe/4`, `check/2` |
| Current admission / serial owner | `src/efz_worker.erl:retain_layer/4`, `src/efz_corpus.erl:semantic_admission/6`, `add_checked/3` |
| Persistence / compatible restore | `src/efz_corpus_store.erl:save/4`, `restore/3`; `src/efz_corpus.erl:init/1` and worker calibration |
| Active representatives / conservative reduction | `src/efz_corpus.erl:semantic_representatives/0`; `src/efz_semantic.erl:representatives/1`, `cover/1` |
| Existing parent selection | `src/efz_corpus.erl:select/0`, `mutation_entries/0`; `src/efz_mutation_plan.erl:next/2`, `visit/2` |
| Finding / fingerprint | `src/efz_worker.erl:record_failure/4`, `src/efz_crash.erl:signature/2`, `save/4` |
| Raw property replay / minimization | `src/efz_semantic_replay.erl:run/5`, `minimize/6`, existing `src/efz_recipe.erl:execute/5` |
| Unchanged real parser | `examples/query_string/efz_qs_target.erl:run/1` → pinned `cow_qs:parse_qs/1` |

## Property and outcome contract

**query_model_agreement / 1** checks the completed real parser's ordered fields
against the separately implemented supported-query decoder. Preconditions:
binary ≤4096 bytes, canonical supported form, ≤32 explicit nonempty-name fields,
each name/value ≤128 bytes; no deliberate bad escape. Arbitrary bytes are accepted
as bytes. This is an expected-result property, not an independent differential
oracle and not `decode(encode(model))`.

| Result | Predicate / policy |
| --- | --- |
| Pass | Completed `{ok,{accepted,Pairs}}` matches supported ordered binary fields |
| Fail | Accepted result differs, or the parser rejects a supported canonical query |
| Inconclusive | Unsupported query, model/byte limit, target exception/timeout, or exhausted check budget; preserve reason |
| expected_rejection | Enumerated harness parse errors return `rejected`; alone they are not findings |
| target_exception / target_timeout | Existing target finding classification and lifecycle cleanup |
| semantic_layer_error | Bounded diagnostic/counter; stop through infrastructure failure, never ordinary fallback or a target bug |
| infrastructure_error | Existing coverage/lifecycle/configuration/storage failure policy |

The minimizable predicate is the same versioned property returning **Fail** for
the unchanged target/build. Unsupported, timeout and Inconclusive do not preserve
failure. Fingerprints use EFZ's existing class/category/frame policy; property ID,
version, target builds and original outcome remain in the semantic sidecar.
Target findings are saved before observer invocation, so a later layer failure
cannot erase them. Oracle failures independently enter the same finding pipeline.
EFZ's current policy continues findings and stops infrastructure failures; its
`crash_policy` controls fingerprints/representatives, not a new stop option.

## Finite semantic vocabulary

Feature = `{<<"cow_qs">>,1,Id}`. IDs are exact sorted tuples, with no hashes,
probabilistic collisions, dynamic atoms, unbounded strings or runtime identities.
Structural units remain native module/build/line units in their existing schema.

| IDs | Meaning |
| --- | --- |
| 0 / 1 / 2 / 3 | Accepted / expected rejection / target timeout / target exception |
| 4 / 5 / 6 / 7 | Accepted pair count: 0 / 1 / 2 / ≥3 |
| 8 / 9 | Empty binary value present / absent |
| 10 / 11 | Byte ≥128 in returned name/value present / absent |

An accepted execution emits four features; other outcomes emit one. The observer
summarizes the completed outcome without decoding input or executing target.
Boundary validation accepts proper lists of at most 100 pairs, binary components
≤4096 bytes, plus Cowlib's name-only `true` representation. Pinned Cowlib itself
limits query keys to 100. Malformed output is a layer error. Oversized input is a
counted observation skip, with no inferred features.

CurrentFeatures is a fresh local list; SeenSemantic belongs to the corpus owner.
Seen and each merged entry set have at most 12 IDs. On this 64-bit VM, measured
flat sizes are 288 bytes for four features, 864 bytes for all 12, and 896 bytes
for a derived 12-key representative map. These are conservative term sizes, not
total VM memory or corpus size. No cache, queue, semantic ETS or persistent active
index is allocated. Entry metadata scales with EFZ's existing corpus; no new
global corpus capacity limit is introduced.

## Admission, persistence and retention

For successful primary outcomes (including `{ok,rejected}`), retain EFZ's
structural reason and add:

```text
SemanticNew = CurrentFeatures minus corpus.semantic_seen
KeepNewInput = ExistingStructuralKeep OR nonempty(SemanticNew)
```

Initial seeds/calibration and existing other reasons remain intact. Exceptions
and timeouts use the existing findings channel; their observation IDs do not
admit failed executions, as agreed in P1. Disabled and observation-only execute
the ordinary admission path. Observation-only stores no historical seen state;
guided starts/rebuilds a fresh corpus-owned history at campaign startup.

The existing gen_server serializes novelty, persistence and commit. New raw
input/metadata is saved before adding entries or seen. Failure/rejection leaves
seen unchanged; in-memory insertion is the commit when storage is disabled.
Existing-input annotations union evidence without duplicating raw corpus entries
or losing the original admission reason. Semantic-only entries use ordinary
storage, `select/0` and staged `mutation_entries/0`; energy policy is unchanged.

Restart validates EFZC/record/namespace versions, then explicitly calibrates
current raw corpus entries to rebuild annotations/seen before mutation. These
executions are reported as calibrations, separately from mutation executions.
Old EFZC records 1/2 and current semantic record 3 remain supported. Incompatible
feature schemas fail restore. No persisted global seen index survives manual
between-campaign deletion; recalibration reflects remaining representatives.

Online corpus is append-only. Cold `cover/1` preserves recorded structural
probe/count unions and all semantic representatives, protecting initial or
uncalibrated entries. Tests apply its subset to a **new** store and restart it;
original corpus is preserved. There is no online deletion/refcount transaction
or globally optimal reducer. Editing corpus files during a campaign is unsupported.
The read-only representative query derives one working ID per feature and checks
that all seen features remain represented.

## Coverage and oracle interval

`reset → target → controlled-tree completion/cleanup barriers → sealed snapshot
→ observer/pure oracle → admission/finding handling`.

Native counters are module-scoped. The existing guardian rejects a concurrent
local target execution with `runner_busy`, reaps controlled descendants, drains
trace barriers, and publishes only after cleanup; the caller waits for guardian
DOWN. Tests confirm a delayed child is dead, native counters remain unchanged
past its deadline, and the following iteration has baseline coverage.
Only `cow_qs` is selected; helpers/Gleam/oracle do not contribute target units.
Unmanaged calls to selected modules in the same VM remain outside this contract.

The production oracle is direct, bounded, pure and adds **zero** target executions.
Budget defaults to 64, maximum 10000, including calibration. It checks each
execution until exhausted, independently of structural novelty; remaining checks
are explicitly Inconclusive/budget and counted skipped. This deterministic prefix
does not claim all-input validation or statistical sampling. No expensive/deferred
oracle, worker protocol, queue or parallel replay is supported; deferred fails
startup. Explicit cold replay/minimization uses separate serialized EFZ intervals
and reports its target executions. No native cancellation claim is made.

## Executed acceptance evidence

| Check | Commands / result (all listed exits 0) |
| --- | --- |
| Full on regression | `rebar3 as gleam eunit`: **313** tests; `full-on-tests.json` |
| Final focused native proof | `rebar3 as gleam eunit --module=efz_gleam_feedback_tests`: **11** tests; `snapshot-test-build.json` |
| Exported final raw proofs | `export_proofs.escript`: reruns **11** tests in its VM, safe-decodes/copies **9** proofs; `export-proofs-final.json` |
| Compiler-free clean off | Private source-only `/tmp/efz-p4-off-vg8psokv`, no package/compiler/BEAM initially; `rebar3 compile` and focused EUnit **55** tests, `clean-off-compile.json`, `clean-off-tests-r2.json` |
| Off runtime / term compatibility | `off_check.escript`: no Gleam/helper/application/state, ordinary campaign and existing term target pass; `off-runtime-check-r2.json` |
| Other backends / static calls | `rebar3 ct`: **3** tests; `rebar3 as gleam xref`; `ct-regression.json`, `on-xref.json` |
| Observation neutrality | Two actual staged campaigns, seed 17, fraction 0, **200** mutations: every candidate hash/stage/parent matches, identical corpus/coverage; `observation-sequence-proof.json` |
| Finding CLI | `scripts/gleam_replay.escript … efz_qs_defect_target 64 …`: reproduced in **1** execution, minimized to `bug=` in **34**; `finding-cli-replay.json` |

For A, inputs `613d31` (`a=1`) and `613dff` (`a=` + byte 255) have exactly the
same **14** native units. All **9** traced primary sealed bit snapshots are
`67041a2c00000300000000`, with the same decoded units. Features are respectively
`[0,5,9,11]` and `[0,5,9,10]`. Guided admits raw second input as `new_semantic`,
with empty `new_probes`; corpus size is 2. Actual existing scheduler parent IDs
are `[1,2,1,1,2,1,1,1]`. Off/observation-only keep size 1. Repetition receives no
additional credit. Trace confirms nine compiled Gleam observe calls and zero
decode calls; the controlled raw mutator is confined to the test fixture.

B tests failed write/retry, 1000 duplicate retries, two simultaneous corpus API
callers receiving exactly one credit, startup rebuild/schema mismatch, conservative
subset restart and recovery after between-campaign removal. A separate contract
fixture performs 10000 admission attempts, reaching 12 seen IDs and only eight
entries; it performs zero target executions and is not a campaign/discovery proof.

C tests target-only coverage, unchanged following intervals and delayed-child
cleanup. Explicit separate target replay cannot change the already returned main
snapshot. No parallel native-coverage PASS is claimed.

D uses the clearly artificial `efz_qs_defect_target`: append NUL to a `bug` value.
One calibration plus two repeated normal mutations yield three oracle failures,
one finding group, zero corpus discoveries, and unchanged features. Original
`bug=11&x=2` bytes, property/version and build metadata are saved. The copied
finding/native artifacts under this run support successful real CLI replay.
This tests wiring; no real Cowlib defect or independent discovery is claimed.

## Counters and cost samples

`gleam_stats` reports observer calls/skips/us, oracle checks/pass/fail/inconclusive/
skipped/us, expected rejection, timeout/exception and layer errors. The pure oracle
reports zero extra executions. Budget fixture: seven primary executions, seven
observations, two Pass checks including a structurally equivalent input, five
explicit skips. Findings are handled without an admission dependency. EFZ has
no corpus capacity option, so a separate full-capacity condition is inapplicable.

Finite component probe: 10000 repetitions, model-derived outcomes, no target
execution, no production trace. Means in microseconds (`component-costs.json`):

| Input bytes / fields | Observer | Pure oracle | Exact set difference | Cold 12-feature index |
| --- | ---: | ---: | ---: | ---: |
| 3 / 1 | 0.28 | 1.34 | 0.46 | 3.31 |
| 4096 / 16 | 14.71 | 304.70 | 0.50 | 3.44 |

Four real same-engine smoke campaigns use seed 17, fraction 10%, six typed seeds,
500 mutations each, with trace disabled:

| Mode | Main calls | Observer calls | Oracle checks / skipped | Corpus / semantic-only | Structural units |
| --- | ---: | ---: | ---: | ---: | ---: |
| Structured, feedback disabled | 506 | 0 | 0 / 0 | 14 / 0 | 48 |
| Observation-only | 506 | 506 | 0 / 0 | 14 / 0 | 48 |
| Guided | 506 | 506 | 0 / 0 | 15 / 1 | 48 |
| Guided + inline oracle | 506 | 506 | 64 / 442 | 15 / 1 | 48 |

Oracle checks were 19 Pass and 45 Inconclusive, no failures. All campaigns
completed without infrastructure errors; target rejection is counted separately.
Individual wall rates (177–226 executions/s) are smoke samples, not performance
superiority or optimum selection. Worker/message overhead is inapplicable to the
direct callbacks; existing target execution overhead is outside component samples.

## Diff, review limitations and P5 handoff

Production changes are `src/efz_semantic.erl` and `src/efz_corpus.erl`: exact
metadata validation and cold representative derivation/query. New files are
three feedback test/fixture modules, `scripts/gleam_feedback_probe.escript`, and
this report. Two explicit modes extend the existing benchmark driver; contract,
guide, ownership and decision docs are updated. `p4-changed-files.json` and
`p4-changes.patch` distinguish these changes from the preexisting dirty worktree.
AGENTS, user prompt archive/texts, target/model/package, locks, coverage, mutation,
worker, findings and replay code remain unchanged in this pass.

Failed attempts remain archived: timestamp-sensitive stats assertion, nonexistent
test-module names, safe proof export before runtime atoms were loaded, invalid
none/manual diagnostic configuration. The first trace proof compared empty
diagnostic lists; corrected acceptance uses sealed native bits/nonempty units.
The source-only preparation command initially collided with its proof filename;
repeat preparation preserves separate command and source-proof files. None of
these earlier attempts is used as final gate evidence.

P5 should independently review this contract/code, run final cross-phase regression
and actual discovery experiments, and perform reproducible multi-seed same-engine
benchmarks with final persistence costs. Preserve conservative defaults and raw
representatives. Exact campaign checkpointing, online pruning, deferred oracles
and unmanaged parallel target execution remain unsupported. No push/PR/commit
was performed; P4 PASS does not close P5 or every orchestration prompt.
