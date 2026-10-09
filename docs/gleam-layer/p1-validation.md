# P1 contract validation and handoff

Requirements **2.0-native**, contract **v1**, vector `{1,1,1,1,1,1}`.
Run artifacts: `artifacts/gleam-layer/20261008-p1-contract/` (repository root).
P1 contract and executable acceptance checks are implemented and tested.
The consistency review below is the author's self-review; an independent reviewer
has **not** run. This does not close the whole orchestration package or P5.

## Inputs and changed files

Read `efz_gleam_native_subagent_prompts/01_COMMON_CONTEXT.txt`, actual P0
[baseline.md](baseline.md), original source snapshot, and current source/tests.
HEAD remains `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`. This pass recorded its
existing dirty diff before changes; it did not overwrite work from earlier phases.
All nine user prompt files, their ZIP, and `AGENTS.md` retain their hashes.

P1 changed:

- `docs/gleam-layer/architecture.md`: EFZ ownership, actual extension points,
  control/data/cold paths, coverage boundaries.
- `docs/gleam-layer/contracts.md`: versioned representations, configuration,
  explicit RNG transitions, limits, errors, admission/restart/pruning contract.
- `docs/gleam-layer/p1-validation.md`, `agent-plan.md`, `decision-log.md`:
  evidence, ownership, decisions, and handoff.
- `test/efz_gleam_contract_tests.erl`: additional executable contract fixtures.
- `src/efz_gleam_adapter.erl`: bounded, actionable startup errors for incompatible
  options/modes/targets/limits, preserving successful and disabled dispatch.
- `gleam/efz_semantic/src/efz_qs_model.gleam`: capacity check before prepend/append
  allocation; supported outputs and rejection semantics remain unchanged.
- `scripts/build_gleam.sh`: ship only the callable model, remove the unused
  generated CLI launcher from runtime application metadata, archive its previous
  generated BEAM outside active ebin. No new stdlib package is added.

Existing EFZ ownership/behaviours and the contract vector are unchanged. No new
C ABI, NIF, plugin registry, engine, or target rewrite is introduced.

## Executed commands and results

All commands ran from the repository root with `ERL_FLAGS='+S 2:2'`, serially.
`contract_test_modules` below is the comma-separated EUnit module argument:

```sh
contract_test_modules=efz_gleam_contract_tests,efz_gleam_layer_tests,efz_config_tests,efz_corpus_store_tests,efz_recipe_tests,efz_mutator_tests,efz_native_public_tests
```

| Check / command | Exit | Result | Artifact in run directory |
| --- | --- | --- | --- |
| `GLEAM_BIN=/no/compiler rebar3 eunit --module="$contract_test_modules"` | 0 | 34 tests passed; optional integration not selected in off-build | `p1-off-eunit.log` / `.json` |
| `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam eunit --module="$contract_test_modules"` | 0 | 51 tests passed, real Gleam BEAM and native EFZ integration | `p1-on-eunit.log` / `.json` |
| `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` | 0 | Runtime shipment built with pinned Gleam 1.10.0 | `p1-on-build.log` / `.json` |
| Same environment, `rebar3 as gleam xref` | 0 | No undefined runtime references | `p1-xref.log` / `.json` |
| `escript artifacts/gleam-layer/20261008-p1-contract/check_source_refs.escript "$PWD" "$PWD/_build/gleam"` | 0 | 26 explicit `file:function/arity` references checked against compiled abstract forms | `source-references.log` / `.json` |
| `GLEAM_BIN=/no/compiler rebar3 eunit --module=efz_phase2_tests,efz_mutation_tests` | 0 | 42 legacy term/executor and staged-plan tests passed | `legacy-compatibility.log` / `.json` |
| `git diff --check` | 0 | No tracked whitespace errors | `diff-check.log` |

The initial Gleam-profile xref exited **1**: generated
`efz_semantic@@main:print_term/1` referenced absent `gleam@string:inspect/1`.
`xref.log` / `.json` preserve this failure. The final runtime shipment excludes
that unused launcher and its application module declaration; final xref passes.
Initial intermediate EUnit runs (34/50) also remain recorded. A source-reference
checker initially rejected a document with no explicit path references (exit 127);
it was corrected, and final reference verification passes.

Exact commands/env/exit codes and source hashes are in `gates.json` and per-check
JSON; no full environment/secrets are saved. `preserved-inputs.json` verifies
user files unchanged. `acceptance-proofs-final/` copies actual guidance, restart,
coverage attribution, and artificial-finding artifacts from the final tests;
its source paths are recorded in `acceptance-proofs-final.json`.

## Acceptance fixture map

| Requirement | Executed fixture / evidence |
| --- | --- |
| Valid ADT, codec laws, arbitrary bytes | `efz_gleam_layer_tests:codec/0`: canonical empty/binary/duplicate models; byte vocabulary differential against pinned real Cowlib |
| Malformed terms, alignment, depth/bytes/elements | `boundary_test/0`, `limits_and_failures/0`; `efz_gleam_contract_tests:malformed_model_and_limits_test/0`, `outcome_verdicts/0` |
| Missing package, versions, target/mode/config | `invalid_capabilities_test/0`, `package_capabilities/0`; version stub is explicitly a contract fault fixture |
| Deterministic mutation, off/fraction-zero RNG, raw fallback | `determinism/0`, `fallback_rng/0`; same candidates and final explicit RNG state |
| Runtime-off no callbacks/state | `off_preserves_configuration_test/0`, `runtime_off_callbacks/0`: actual campaign call tracing; no semantic state/report fields |
| Same structural units, different semantic facts | `coverage_attribution/0`, `guidance/0`: real native snapshot; semantic-only working entry then ordinary parent selection |
| Observation-only no admission change | `observer_only/0`, compared with runtime-off working inputs |
| Failed admission/retry/repeated feature | `persistence_retry/0`: seen unchanged on failed write; retry succeeds, duplicate preserves admission reason |
| Representative retention/restart | `reduction/0`, `restart/0`: recorded structural/semantic unions and semantic-only flag survive; reduction is read-only |
| Pass/Fail/Inconclusive, zero budget | `limits_and_failures/0`, `outcome_verdicts/0`, `zero_budget_random_mode/0`; zero additional target calls |
| Findings independent of novelty, property replay/minimize | `finding_replay/0`: artificial fixture, three failures with one working input; same-property replay and bounded byte deletion |
| Layer error is diagnostic, not fallback | `fault_injection/0`: explicit fault stub; campaign stops before mutation target execution |
| Schema mismatch / legacy artifacts | `semantic_schema_restore_test/0`, corpus store v1/v2 tests, recipe v1/negative/fresh-VM tests, property version mismatch test |
| Existing term inputs / ordinary scheduling | `efz_phase2_tests` comprehension fixtures include list/map/tuple terms; `efz_mutation_tests` retains ordinary operations, fairness, limits, and selection |
| Shipment requires no optional CLI/stdlib | `runtime_shipment/0`: model-only module list, no optional application start |

Mocks/stubs close only error contracts. Real model and EFZ/native coverage tests
close integration evidence; no mock is counted as guidance. The known artificial
finding is a wiring/replay fixture, not independent bug discovery.

## Source consistency review

The lead checked P0 and current owners against [architecture.md](architecture.md):
parent selection precedes structured decode; ordinary retry keeps its existing
budget/cursors; off draws nothing extra; target execution/snapshot precedes pure
callbacks; only cow_qs manifests are accepted; guardian serializes EFZ intervals;
findings precede observer failure; corpus commits semantic seen after insertion;
restart rejects schema mismatch and calibrates raw bytes; reduction does not
silently delete a representative. The early allocation, opaque startup diagnostics, and unused-launcher issues
found by this pass were fixed and the affected checks rerun.

Review limitations: author self-review, no independent reviewer/subagents;
unmanaged target calls in the same VM remain outside isolation. No parallel,
deferred, or native-interruptible oracle is claimed. Off-equivalence/performance
series from the earlier run are not reclassified as final P5 measurements after
these source changes. Full clean-off packaging and final same-engine benchmark
series remain P5 work. The complete prompt package is **not finished**.

## P2/P3/P4 handoff and ownership

The lead owns shared architecture/contracts, build/configuration, loop, and corpus;
there are no concurrent writing workers. Any later delegation must assign files
explicitly and pass common context, P0 evidence, this v1 contract, and `gates.json`.

- **P2:** keep pinned Gleam 1.10.0 and real BEAM calls, validate external terms,
  package only callable runtime modules, and preserve compiler-free off-build.
  Generated Erlang source is not a required build artifact. Current shipment and
  missing/incompatible capability checks have real test evidence.
- **P3:** retain EFZ-owned operation derivation/RNG transitions and existing plan;
  enforce limits before field/byte/output allocation, preserve deliberate invalid
  representation, and persist raw bytes/data-only recipe v2. No scheduler or
  cache/hint policy is authorized by this contract.
- **P4:** consume finite features only through serialized EFZ admission, retain
  observation-only neutrality and persistence retry/restart behavior, keep primary
  coverage separate, and count/budget any added target execution. Deferred support
  requires a revised capability contract; it is rejected in v1.

These are handoff invariants, not a claim that all downstream phase gates or
independent orchestration review have completed.
