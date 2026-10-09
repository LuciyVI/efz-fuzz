# Native Gleam architecture — contract v1

Requirements: **2.0-native**. Contract: **1**. Base revision:
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b`. This describes the current checkout,
including integration code present before the P1 audit. See [baseline.md](baseline.md)
for actual P0 results and its source-directory workaround.

## EFZ ownership and extension points

Paths are repository-relative; function arities are part of the source map.

| Responsibility | Actual EFZ owner |
| --- | --- |
| Campaign lifecycle/report | `src/efz_fuzzer.erl:init/1`, `handle_info/2`, `terminate/2` |
| Calibration/main loop | `src/efz_worker.erl:handle_info/2`, `staged_iteration/1` |
| Parent/scheduler | `src/efz_corpus.erl:select/0`, `mutation_entries/0`; `src/efz_mutation_plan.erl:next/2`, `visit/2` |
| Mutation dispatch/operations | `src/efz_mutation_plan.erl:attempts/6`, `structured/3`, `ordinary_attempts/6`; `src/efz_mutation.erl:apply_operation/3` |
| PRNG | Staged `src/efz_mutation_plan.erl:new/1`, `uniform/2`; legacy random `src/efz_worker.erl:init/1`, `src/efz_mutator_random.erl:mutate/2`; selection `src/efz_corpus.erl:init/1`, `handle_call/3` |
| Target/timeout/reset/cleanup | `src/efz_executor.erl:run/4`, `invoke/4`; `src/efz_guardian.erl:run/6`, `start/6`, `cleanup/2`, `finish/2` |
| Coverage snapshot | `src/efz_guardian.erl:finish/2`; existing `src/efz_cov_native_public.erl:collect/1`, `collect_profiled/1` and `src/efz_coverage.erl` backends |
| Structural novelty | `src/efz_feedback.erl:evaluate/3` |
| Corpus/admission/persistence | `src/efz_worker.erl:retain_layer/4`; `src/efz_corpus.erl:admit_semantic/4`, `semantic_admission/6`, `add_checked/3`; `src/efz_corpus_store.erl:save/4` |
| Findings/fingerprint | `src/efz_worker.erl:record_failure/4`; `src/efz_crash.erl:signature/2`, `save/4`; `src/efz_crash_store.erl` |
| Recipes/raw/property replay | `src/efz_recipe.erl:make/4`, `regenerate/1`, `execute/5`; `src/efz_replay.erl:run/6`; `src/efz_semantic_replay.erl:run/5`, `minimize/6` |
| Conservative corpus reduction | `src/efz_semantic.erl:cover/1`, read-only proposed subset; no online deletion |

Existing behaviours are `src/efz_mutator.erl:mutate/2` and
`src/efz_target.erl:run/1`. The mutator behaviour serves ordinary random mutation;
it does not carry the staged plan's RNG state or semantic verdicts. The layer
extends that plan's dispatch with one fixed, checked `efz_gleam_adapter`. No
second behaviour platform or plugin registry is needed. The `efz_` prefix follows
existing module names. Gleam returns data; EFZ retains all scheduling decisions.

## Control, data, and cold paths

**Control:** `efz_config:prepare/1` validates existing coverage/target capabilities,
then `efz_gleam_adapter:prepare/2` checks options, package, limits, and versions.
It also validates every required core export once. [p2-integration.md](p2-integration.md)
records actual compiler artifacts, clean builds, and traced callback reachability.
`efz_fuzzer:init/1` starts existing owners. `scripts/gleam_seeds.escript` prepares
raw seed files separately before the loop; runtime activation is independent.

**Data:** EFZ selects parent and lane, chooses the optional structured family,
then decodes/mutates/encodes only that branch. Ordinary mutations stay in the
same plan. The same target entrypoint runs under EFZ's executor. Its completed
snapshot precedes observer/oracle and serialized EFZ admission. Off/fraction-zero
dispatch adds no RNG draws; unsupported/malformed inputs retain the ordinary path.

**Cold:** EFZ stores bounded declarative recipes and immutable finding sidecars.
Replay/minimization explicitly use its executor. The current inline oracle is
pure and budgeted, with zero extra target calls. Deferred/expensive online
oracles are unsupported v1 capabilities; they fail startup. Future support must
use existing supervision/execution boundaries and finite budgets.

## Coverage isolation and compatibility

P0 confirmed public native line coverage on OTP 27.0. Counters are module-scoped,
not process-local. `efz_guardian:run/6` registers `efz_execution_guardian`; another
EFZ execution receives `runner_busy`. `loop/1` drains descendants and trace
barriers before `finish/2` snapshots coverage; `efz_executor:run_pinned/4` also
waits for guardian termination. The interval is:

`reset/open → target → completion/cleanup barrier → snapshot → callbacks → admission`.

Enabled adapter manifests may select only `cow_qs`, excluding EFZ, Gleam,
harness/adapter, and oracle. Unmanaged calls to selected modules in the same VM
are outside this isolation contract. No async semantic observer/late-response
queue exists. Any future target-repeating oracle requires a separate serialized
EFZ interval after the primary snapshot, execution/campaign IDs, and separate
execution counters.

Other existing coverage backends are preserved; explicit selection never falls
back silently. The low-level executor retains term inputs. Campaigns already
required binaries at P0; the first adapter does not impose a new restriction on
other APIs. No C ABI, NIF, port, extra VM, external engine, or OTP patch is added.

## Ownership and review

The lead owns this P1 documentation/test pass and shared configuration, loop,
and corpus. No workers are active; no delegated or independent review is claimed.
[p1-validation.md](p1-validation.md) records source checks, tests, limitations,
and P2/P3/P4 handoff. Existing user requirements and `AGENTS.md` remain intact.
