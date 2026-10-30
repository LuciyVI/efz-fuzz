# EFZ coverage tracking: audit and comparison with AFL++

**English** · [Русский](i18n/ru/coverage-tracking-audit.md) · [Español](i18n/es/coverage-tracking-audit.md) · [简体中文](i18n/zh-CN/coverage-tracking-audit.md) · [All languages](i18n/README.md)

Date: September 15, 2026. Production snapshot under review:
[`205e18ba172d74bd6c652a68abfc73e02e4a1f86`](https://github.com/LuciyVI/efz-fuzz/commit/205e18ba172d74bd6c652a68abfc73e02e4a1f86).
Experimental environment: OTP 27 / ERTS 15.0, Linux x86_64, `+S 4:4`.
The production implementation was not changed. New diagnostic targets and the
runner are in [coverage-audit-2026-09-15](coverage-audit-2026-09-15/).

This document describes that snapshot and default presence semantics.
The subsequent opt-in counter prototype and its separate measurements are in the
[hit-count experiment](hit-count-experiment.md); historical results below do not
describe the new mode.

## 1. Executive conclusion

**RESULT B — AFL++-like feedback semantics implemented, different representation.**

Answers to two different questions:

* **Coverage feedback exists? YES.** Automatic hooks record coverage for a
  particular execution; the worker compares it with accumulated coverage and adds
  successful discoveries to the real corpus available to subsequent scheduling.
* **AFL++-style bitmap/hit-count map exists? NO.** There is no byte-indexed trace
  bitmap, hit counter, bucket, `virgin_bits`, previous edge or call-context hashing.

The correct name for the current structure is **execution coverage set / exact probe set**.
“Sparse probe-presence map” is acceptable if set semantics are explicit.
Calling it a bitmap or edge-hit-count map is incorrect.

EFZ's representation is not equivalent to AFL++ in feedback sensitivity: **a new
probe is detected; new multiplicity of an old probe and new combinations of old
probes are not**. Identities denote source clause/outcome points, not CFG edges.

Evidence: [hook](../src/efz_cov_rt.erl#L43), [snapshot](../src/efz_cov.erl#L31),
[novelty](../src/efz_feedback.erl#L16), [retention](../src/efz_worker.erl#L122),
[scheduler](../src/efz_mutation_plan.erl#L54), independent runtime experiments in
section 13 and the real [parent-reuse integration test](../test/efz_feedback_loop_tests.erl).

## 2. AFL++ reference model

The reference is pinned to AFL++ `stable` commit
[`dbaf11913c1b2702dee5b4d3dcfffd52f1defe50`](https://github.com/AFLplusplus/AFLplusplus/commit/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50),
commit date 2026-09-02. AFL++ was neither built nor run here: the comparison uses
official source. This models ordinary coverage-guided mode; additional
value-profile/CmpLog/path/sanitizer channels and crash-only mode do not replace it.

```text
target execution
  → compiler/runtime instrumentation
  → edge/guard mapped to a numeric slot
  → byte hit counter in shared trace_bits
  → count classification
  → compare with virgin bits and clear newly observed feature bits
  → save_if_interesting / add_to_queue
  → clear current trace before next run
```

| Concept | Meaning in the reference |
|---|---|
| Edge coverage | Information about control-flow transitions; instrumentation placement depends on compiler/backend. It is not merely a set of source lines. |
| Bitmap slot | A numeric position in the trace buffer. A slot need not correspond to one unique edge. |
| Hit counter | Usually a byte updated on every hit; not an exact unbounded call count. |
| Count bucket | A counter-value class. A new bucket for a known slot can yield novelty. |
| Per-execution trace | `fsrv.trace_bits`, current target observations in shared memory. |
| Virgin map | Bits for bucket features not yet observed; accumulation is logically stored in inverse form. |
| Novelty | Intersection of classified current bits with virgin bits. A new slot and a new bucket of an old slot are distinguished. |
| Reset | Clearing the current trace between runs while preserving virgin state. |
| Collisions | In hashed instrumentation, multiple edges may share a slot and mix counts. LTO and PCGUARD can use nonoverlapping IDs. |
| Context | Ordinary edge identity excludes the call chain. Additional instrumentation modes can account for caller/context; that is a separate setting. |

The historical AFL scheme indexes `cur_location XOR prev_location`, with
`prev_location` updated using the current point. This **does not universally
describe all modern AFL++ backends**. The PCGUARD reference runtime updates
`__afl_area_ptr[*guard]`; LTO documents unique IDs and range requirements for
multiple instrumented libraries. [Historical model](https://aflplus.plus/docs/technical_details/),
[runtime PCGUARD](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/afl-compiler-rt.o.c#L2692),
[LTO](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/README.lto.md).

**Version detail:** active `count_class_lookup8` in the selected revision has
the following classes; the traditional table with a separate class for 3 remains
in source as an `OLD` comment:

| Raw byte count | Classified bit |
|---|---:|
| 0 | 0 |
| 1 | 1 |
| 2–3 | 2 |
| 4–7 | 4 |
| 8–15 | 8 |
| 16–31 | 16 |
| 32–63 | 32 |
| 64–127 | 64 |
| 128–255 | 128 |

`classify_counts` transforms byte counts; `discover_word` checks
`current & virgin` and applies `virgin &= ~current`. `has_new_bits` returns 0
without novelty, 1 for a new count-class of a known slot, and 2 for a new slot.
This does not retain every unique full trace vector.
[Table and has_new_bits](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-fuzz-bitmap.c#L46),
[classify_counts/discover_word](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/include/coverage-64.h#L77).

Byte counters can overflow. The shown PCGUARD runtime uses NeverZero:
255 is followed by 1. This is **not saturation**. Thread-safe instrumentation is
a separate mode; ordinary increment alone does not guarantee exact counts under
concurrency. Instrumented threads/fork descendants may share a shared-memory
buffer, but input boundaries require a coordinated target lifecycle.
[Counters and thread safety](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/README.llvm.md#L200),
[mapping runtime](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/instrumentation/afl-compiler-rt.o.c).

Trace-buffer size is fixed while a particular map is in use, but capacity is
chosen/negotiated with the target. It is incorrect to assume every AFL++ map is
always 64 KiB. The ordinary forkserver path zeroes `trace_bits` before execution.
[Map resize and run/reset](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-forkserver.c#L2410).

`save_if_interesting` adds candidates to the queue. Crash/hang dedup uses
separate `virgin_crash`/`virgin_tmout` after simplifying the trace to remove
counts; this differs from ordinary successful-queue novelty.
[Queue and crash/hang paths](https://github.com/AFLplusplus/AFLplusplus/blob/dbaf11913c1b2702dee5b4d3dcfffd52f1defe50/src/afl-fuzz-bitmap.c).

## 3. Actual EFZ coverage architecture

Actual default staged/prepared path:

```text
efz_cli:launch/1 → efz:start/1
  → supervisor:start_child/2 (efz_sup) → efz_fuzzer:start_link/1
  → efz_config:prepare/1
  → efz_instrument:preflight/1 → efz_cov_integrity:pin/2
  → efz_fuzzer:init/1 → efz_corpus:start_link/4
  → efz_worker_sup:start_link/1 → efz_worker:start_link/1
  → efz_worker:init/1
       efz_cov_manifest:prepare/2       % campaign allowlist, not current coverage
       efz_feedback:new/1               % empty accumulated successful probe set
  → efz_worker:staged_iteration/1
  → efz_corpus:mutation_entries/0
  → efz_mutation_plan:next/2
       → attempts/6 → efz_mutation:apply_operation/3
  ← {candidate, Binary, Provenance, NextPlan}
  → efz_recipe:make/4
  → efz_worker:execute/4 → execute_checked/4
  → efz_executor:run/4 → run_checked/4 → run_pinned/4
  → spawn_monitor guardian → efz_guardian:run/6 → start/6
       efz_cov:open/1; efz_cov_integrity:open/2
       coordinator = efz_executor:coordinate/1
       root = efz_guardian:admit/2
  → root: efz_cov:attach/1 → efz_executor:invoke/4
  → HarnessModule:run(Binary) → selected instrumented functions
  → efz_cov_rt:hit({Module, BuildId, ProbeId})
       → publish/2 → insert/4 → ets:insert_new/2
  → guardian cleanup + process DOWN + trace barriers
  → efz_guardian:finish/2
       → efz_executor:coverage/3 → efz_cov:snapshot/1
       → efz_cov_manifest:validate_prepared/3
       → efz_cov:close/1
  ← execution result; efz_executor waits for guardian DOWN
  → efz_worker:execute_result/6 → efz_feedback:evaluate/3
  → efz_worker:retain/2 → efz_corpus:add/2
  → accepted/5; worker stores next feedback state; self() ! iterate
  → next efz_corpus:mutation_entries/0 includes the retained input
```

Source anchors: [worker](../src/efz_worker.erl#L47), [planner](../src/efz_mutation_plan.erl#L54),
[executor](../src/efz_executor.erl#L11), [guardian](../src/efz_guardian.erl#L33).
Random mode uses `efz_corpus:select/0 → Mu:mutate/2`, followed by the same
execution, coverage and feedback path. `coverage_validation => per_execution`
calls `validate_observed/3` instead of prepared membership. No new engine was
created for the experiment.

Key interprocess messages:

| Message | Sender → receiver | Meaning |
|---|---|---|
| `{coordinate,Root,Context}` / `{coordinator_ready,Coordinator}` | guardian ↔ coordinator | Install the root monitor before code starts |
| `{start_owned,Capability}` | guardian/helper → target | Open the gate after ownership registration |
| `{target_result,Ref,Root,Outcome}` | root → coordinator | Return/exception classification |
| `{coordinator_done,Coordinator,Outcome}` | coordinator → guardian | Enter cleanup |
| `{efz_cov_observed,Ref,Identity}` | first insert hook → guardian | Independent evidence of the first hit |
| `{efz_cov_failure,Ref,Reason}` | integrity/hook → guardian | An observation error must survive a caught exception |
| `DOWN`, `trace_delivered` | runtime → guardian | Confirmation of termination and trace processing |
| `{Request,Guardian,Result}` | guardian → executor caller | Completed snapshot and lifecycle status |
| `gen_server:call(...,{add,Binary,Meta},infinity)` | worker → corpus | Confirmed entry insertion |

Input arguments are `binary()`. `Provenance`/`Recipe` contain primary bytes/hash,
parent ID, operations and output hash. `Result` is a map with `outcome`,
`coverage` (list of identities), `coverage_status`, `coverage_observation`,
`builds`, `cleanup`. The global set receives the coverage list; input bytes
remain with the worker/corpus.

## 4. Coverage data structures

| State | Physical representation | Owner / lifetime |
|---|---|---|
| Per-execution hits | Unnamed public ETS `set`, internal name `efz_execution_coverage` | Guardian; one execution until snapshot/close |
| Target context | Process dictionary key `'$efz_execution_context'` → context tuple | Root/controlled child; until process death |
| Independent observation evidence | Guardian state `observed_probes => sets:set()` | Same execution; first hit of each identity |
| Attachment/integrity registry | Named protected ETS `efz_coverage_observers`, `{Pid,Context}`, `{identities,Pins}` | Guardian; one execution active in the VM at a time |
| Allowed coverage identities | Protected ETS `efz_coverage_plan` | Worker; campaign, until release/owner death |
| Successful global coverage | `S.feedback.global`, Erlang `sets:set()` | Worker; campaign |
| Campaign diagnostics | `coverage_seen`, empty/broken/unstarted counts | Worker; campaign; **not** novelty state |
| Dirty marker | `persistent_term` `{efz_guardian,dirty_runner}` | VM; **not** a coverage map |
| Persistence | Source manifests; historical metadata in corpus/crash/report | Filesystem; not a per-execution trace buffer |

Exact context and row format:

```erlang
{efz_context, 1, ExecutionRef, Table, GuardianPid}
{efz_context, 1, ExecutionRef, {ets_member, Table}, GuardianPid}

%% Complete ETS object: one-element tuple.
{{probe, {Module, BuildId, ProbeId}}}
%% Its ETS key (default keypos = 1):
{probe, {Module, BuildId, ProbeId}}
```

One row means the presence of one exact probe. No separate value/counter field
is stored. There is no fixed-size slot space, binary bitmap, shared-memory byte
array or `counters`/`atomics` coverage backend. `ProbeId` is a numeric ID inside
a tuple key, not an array index. ETS resolves its internal hash collisions by
comparing keys; it does not combine distinct identities into one coverage bit.
[open/attach/snapshot](../src/efz_cov.erl), [insert](../src/efz_cov_rt.erl#L43).

On **the tested OTP 27**, `sets:new()` returns a version-1 tuple `{set,...}` with
hash segments, not a native map. EFZ uses the `sets` API and does not depend on
private layout. The word `map` in `S.feedback` is not evidence of a bitmap:
it is an ordinary Erlang map containing a set.

The prepared table contains `{Identity}` and service rows
`{'$efz_plan',{Mode,Builds}}`, `{'$efz_identities',PinsResult}`. It knows all allowed
probes, including ones never executed. This is a **validation allowlist**, not
accumulated coverage. [make_plan/2](../src/efz_cov_manifest.erl#L60).

## 5. Probe identity

The unit is a **source clause/outcome probe**, manifest metric `clause_outcome_probe`.
`efz_instrument_pt:body/5` places a hook at the start of the body after clause
selection. Actual kinds: `function_clause`, `case_clause`, `if_clause`,
`receive_clause`, `receive_after`, `try_body`, `try_of_clause`, `catch_clause`,
`try_after`, `fun_clause`, `named_fun_clause`. Guards/patterns are not separately
instrumented; short-circuit operands do not automatically get individual
true/false probes. This is neither full branch coverage nor instrumentation of
all BEAM basic blocks.
[body/probe](../src/efz_instrument_pt.erl#L106), [AST traversal](../src/efz_instrument_pt.erl#L129).

Identity: `{Module :: atom(), BuildId :: binary(32), ProbeId :: pos_integer()}`.
The transform starts at `next => 1` and assigns IDs in AST traversal order,
incrementing `next` for each point. The hook contains this triple as a
compile-time literal. The manifest maps ID to module/function/arity, kind,
source_file, line/column and structural_location. Line is metadata,
**not a coverage key**.

BuildId is SHA-256 of `{1, OTPRelease, CompilerModuleMd5, CanonicalForms,
IdentityOptions}`. Paths inside `source_root` are normalized relative to root.
Another module has a separate namespace; another build identity is separate too.
Manifest validation rejects duplicate IDs and structural paths.
[Build computation](../src/efz_instrument_pt.erl#L36), [validation](../src/efz_cov_manifest.erl#L4).

Stability: executions of one build use the same identity; identical canonical
source/options/toolchain produce reproducible IDs in the tested environment.
Reordering/adding AST points can shift numeric IDs, and changes to source,
annotations/options/toolchain can change BuildId. Stable IDs are not promised
across arbitrary edits or OTP changes. Tests `determinism/1`, `build_options/0`
and fresh replay check specific boundaries.

Identity-contract limitation: the initial constant `1` is a schema version;
the transform's own contents are not automatically hashed into BuildId.
Changing instrumentation semantics requires an explicit version bump.
BEAM/attributes/harness pinning adds an independent current-code check.
SHA-256 collisions are theoretically possible, but this is not ordinary slot
compression as in a hashed bitmap.

**EFZ ProbeId is not an AFL++ edge/slot index.** It identifies an AST point in a
module/build namespace. There is no `(previous,current)` tuple, XOR slot mapping
or call-stack/caller contribution. The context's `ExecutionRef` controls lifetime,
not context-sensitive feature identity.

## 6. Per-execution lifecycle

1. `efz_executor:run_pinned/4` creates an independent monitored guardian.
2. The guardian checks pinned modules, creates fresh ETS through `efz_cov:open/1`
   and a fresh execution reference. The guardian owns ETS, not root/coordinator.
3. `admit/2` registers root/child before opening the gate; `attach/1` then puts a
   reference to this case's shared table in the process dictionary.
4. The hook checks the expected context against the external registry and performs insert/member.
5. After root outcome, timeout or caller/coordinator DOWN, the guardian terminates
   root, descendants and coordinator, waits for monitors and trace-delivery barriers.
6. `finish/2` checks identities, takes a snapshot/allowlist validation, checks
   independent observed probes and attachment, then closes ETS/registry/trace.
7. The result is sent to the worker; the caller also waits for guardian DOWN.
   Feedback receives an independent coverage list after the per-execution table closes.
8. The next case creates a new table/reference; there is no explicit bitmap memset/reset.

[Guardian start/admit/loop](../src/efz_guardian.erl#L33),
[finish](../src/efz_guardian.erl#L163), [executor result protocol](../src/efz_executor.erl#L33).

A root crash does not destroy the coverage table: the owner is the guardian.
Timeout preserves probes written before kill. Coordinator failure produces an
infrastructure outcome; the snapshot may contain real hits, but these do not
enter global coverage. Caller death triggers cleanup even though nobody can
receive the result. Loss of the guardian cannot count as confirmed cleanup:
the executor marks the runner dirty and prohibits reuse; a late guardian failure
preserves the primary infrastructure cause.

**Within the supported model, hits from the previous input do not enter the next.**
Distinct contexts, absence of ETS after the result and A→B→A confirm this.
A closed old context is not redirected to the new table.
However, target changes to VM-global state can alter the next input's *behavior*:
this is a separate source of nondeterminism, not coverage-map mixing.
Persistent-term/env changes are diagnosed; writes to another preexisting ETS,
external services and arbitrary background processes are not fully isolated.
This is a cooperative runner, not a security sandbox. [Policy](execution-isolation.md).

The low-level/manual API alone does not provide all guardian guarantees.
`reset_local/0` does not clear a reused global bitmap: it creates a context or
refuses if a context is already attached. `snapshot/0` and `{manual,Id}` are
compatibility surfaces; automatic campaigns use `snapshot/1` and prohibit manual
identities in the automatic allowlist.

## 7. Global coverage

Authoritative state:

```erlang
%% efz_worker state
#{feedback => #{builds => Builds, global => GlobalSet}}

%% efz_feedback:evaluate/3, valid successful outcome
New = lists:sort(sets:to_list(
    sets:subtract(sets:from_list(Observed), Global))),
NextGlobal = efz_cov:merge(Global, Observed).
%% efz_cov:merge/2 = sets:union(Global, sets:from_list(Observed))
```

Thus `New = Current − Global`, `Global' = Global ∪ Current` **is actually
implemented**, for exact identities and only with a suitable outcome.
[evaluate/3](../src/efz_feedback.erl#L16).

| Execution | Does global change? | Decision / retention |
|---|---|---|
| Successful mutation, valid coverage | Union with current | `new_coverage` for nonempty delta; otherwise `equivalent_coverage` |
| Successful calibration | Union with current | Always `seed_calibration`; the seed is already in corpus |
| `error` / `throw` / `exit` / external root kill | No | `target_failure`, `new_probes => []`; separate crash path |
| Timeout | No | `target_failure`; timeout artifact/count |
| Infrastructure / invalid coverage / build mismatch | No | `{error,Reason}`, campaign stops |
| Valid zero-hit success | Union with the empty set | Not a discovery; observation is distinct from broken coverage |

An ordinary returned value `{error,invalid_input}` is still a successful execution:
the executor wraps it in `{ok,Value}`. An exception and a returned term are different.

`coverage_seen`/`coverage_diagnostics` also include observation information from
failures; they must not be equated with the successful global set. Strict policy
rejects the campaign if no probes were observed at all; this is not a new novelty criterion.

Global belongs to one worker and is not restored on restart. The durable corpus
restores bytes/history, then the worker recalibrates inputs and builds new
accumulated coverage. A filesystem failure during retention stops the campaign;
`accepted/5` does not confirm new feedback state before successful retention.

## 8. Hit-count analysis

`efz_cov_rt:insert/4` calls `ets:insert_new(Table,{{probe,Id}})`:
the first hit adds a row and sends a guardian notification; a repeat returns
`false` and leaves the row unchanged. `ets_member` first checks membership, but
the eventual insertion is also atomic `insert_new`. Concurrent controlled
children can see a missing row simultaneously; only one insertion is new.

Search of production source:

```sh
rg -n 'counter|count_class|bucket|bitmap|update_counter|atomics|counters:|array:|prev_loc|edge' src
```

Matches for `counter` refer to **crash occurrence storage**, not probe hits.
No integer/saturating/8-bit hit counter, lookup bucket table or frequency-aware
coverage feature was found in the production path. Compile-time `next` in the
transform counts assigned probe IDs; statistics count executions/discoveries —
these are different counters.

| Calls to one x/0 | EFZ row count | Snapshot | Can it yield count-only novelty after the first hit? |
|---:|---:|---|---|
| 1 | 1 | `{X}` | The first X can yield novelty |
| 2 | 1 | `{X}` | No |
| 3 | 1 | `{X}` | No |
| 8 | 1 | `{X}` | No |
| 10 | 1 | `{X}` | No |
| 1000 | 1 | `{X}` | No |

This was checked with **automatic hooks**, not manual `efz_cov:hit/1`. The target
has a separate diagnostic invocation counter in its own process dictionary to
confirm that the loop really made 1000 calls. It does not participate in EFZ
coverage. A per-execution coverage counter cannot overflow because none exists.

## 9. Novelty semantics

The following concerns a successful mutation with valid coverage. In AFL++,
A/B/C denote collision-free slots/features; where counts are unspecified,
assume their buckets do not change.

| Scenario | EFZ `new_probes` | EFZ result | AFL++ coverage-only reference |
|---|---|---|---|
| A: current `{A,B}`, global `{}` | `{A,B}` | `new_coverage`, union `{A,B}`, retain | New slots, novelty class 2 |
| B: current `{A,B}`, global `{A,B}` | `{}` | `equivalent_coverage`, no retention | 0 with unchanged buckets |
| C: current `{A,B,C}`, global `{A,B}` | `{C}` | `new_coverage`, retain, union `{A,B,C}` | New slot C, class 2 |
| D: known A executes 100 times | `{}` | Count alone is not interesting | Can yield class 1 if that bucket was not previously observed |
| E: new combination of only known points | `{}` | Not new coverage | The combination of known slot/bucket features is not novel itself; new edges or counts can change the result |

A set also loses order: `AB` and `BA` are equal if instrumentation yields the
same points. In AFL++, reordering *basic blocks* can mean new **edges**;
this differs from reordering already known edge features. AFL++ should not be
credited with full execution-signature uniqueness merely because it retains
trace hashes for calibration/scheduling.

## 10. Corpus feedback integration

`efz_worker:execute_result/6 → efz_feedback:evaluate/3 → retain/2` calls
`efz_corpus:add(Input,Meta)` **only** for `new_coverage`.
`efz_corpus:add_checked/3` compares bytes with entries, saves a durable record
if the store is enabled, then adds `#{id,input,metadata,added_at}` to entries.
The next `mutation_entries/0` also returns compact `#{id,input}` for the new entry.
The planner reads the actual current corpus, maintains per-content cursors and
resets previous idle observations as the corpus grows. Donor candidates also
come from there.
[Worker retain](../src/efz_worker.erl#L122), [corpus](../src/efz_corpus.erl#L36),
[growing scheduler](../src/efz_mutation_plan.erl#L54).

This is not a telemetry-only pipeline. `efz_feedback_loop_tests:feedback_loop/0`
runs a real campaign with staged dictionary operators and only tokens A/B/C:

```text
ID 1: <<>>
  → ID 2: <<"A">>,   parent 1
  → ID 3: <<"AB">>,  parent 2
  → ID 4: <<"ABC">>, parent 3
```

The test checks real new probes, input delivery by execution ref, primary
bytes/hash in the recipe and fresh-VM replay. This run has **30 mutation
executions, 31 harness deliveries, 3 discoveries**. No scripted mutator is used.
The additional audit experiment also feeds retained AB into the real planner
and checks `parent => 2, primary => <<"AB">>`.

The new entry need not be the very next one: the planner finishes the current
snapshot round. That is scheduling fairness, not a break in the feedback loop.

## 11. Cross-process limitations

| Variant | Coverage | Lifecycle/admission |
|---|---|---|
| Root calls instrumented function | Writes to execution ETS | Supported |
| `efz_target:spawn/1` | Context attached automatically before user code; shared exact set | Supported; guardian waits for cleanup |
| `efz_target:spawn_link/1` | Same | Supported; the link does not define coverage identity |
| Nested controlled child | Same, through the same guardian | Supported within the admission limit |
| Ordinary `erlang:spawn` | Context is not inherited automatically | Tracing detects uncontrolled spawn; infrastructure/dirty runner |
| Preexisting background process | Usually no attached context, hook inactive | Outside supported execution scope |
| Manual `efz_cov:attach/1` in an arbitrary child | Does not itself grant lifecycle ownership | Does not make ordinary spawn supported |

Thus **users of the controlled API do not need manual attachment**. However,
coverage does not automatically extend to every Erlang process. Ordinary process
dictionaries are not inherited by spawn; a native instrumented hook outside an
admitted process remains inactive when context is absent. [Target API](../src/efz_target.erl),
[admission](../src/efz_guardian.erl#L51), [uncontrolled detection](../src/efz_guardian.erl#L143).

An unlinked child's exception alone does not determine the root outcome: the
harness must await the child and express its result. Controlled-child probes
enter the snapshot before cleanup; the root outcome determines whether that
snapshot is admitted to successful feedback. Shared ETS creates neither
caller-sensitive nor PID-sensitive coverage features.

## 12. EFZ vs AFL++ matrix

`YES` means the same specific property is present, not binary compatibility.
`FUNCTIONALLY SIMILAR` means the same role with a different implementation.

| Mechanism | AFL++ | EFZ | Equivalence |
|---|---|---|---|
| Instrumentation | Compiler/runtime hooks | Erlang parse transform + runtime hook | FUNCTIONALLY SIMILAR |
| Coverage granularity | Usually CFG edges; mode-dependent | AST clauses/selected outcomes | PARTIAL |
| Per-execution coverage | Shared byte trace array | Fresh public ETS exact set | FUNCTIONALLY SIMILAR |
| Fixed-size bitmap | Allocated numeric slot buffer | Absent | NO |
| Coverage slot | Numeric index | Exact tuple ETS key | NO |
| Edge ID | Edge/guard identity according to mode | Source point, no previous/current edge | NO |
| Hit counter | Byte increments, mode-specific overflow policy | Absent | NO |
| Count buckets | Classified counter classes | Absent | NO |
| Global/virgin state | Unobserved feature bits | Observed successful probe identities | FUNCTIONALLY SIMILAR |
| New coverage detection | New slot or bucket | Only new probe identity | PARTIAL |
| Reset between executions | Clear/reinitialize trace | Destroy ETS, allocate new context/table | FUNCTIONALLY SIMILAR |
| Collision behavior | Hashed modes collide; LTO/PCGUARD can be exact | No slot aliasing; exact keys | PARTIAL |
| Crash coverage | Trace + separate crash/hang novelty maps | Snapshot retained, dedup by normalized crash signature | PARTIAL |
| Corpus feedback | Novelty → queue → further mutations | Novelty → corpus → scheduler → mutations | YES |
| Build identity | Slots tied to instrumented binary/mapping; no BuildId in every byte | Module + BuildId in every identity, pinned harness/BEAM | NO |
| Cross-process coverage | Shared mapping among participating instrumented processes/threads | One ETS for root + controlled descendants | PARTIAL |

The matrix uses the source references in section 2 and actual EFZ paths in
sections 3–11. `NO` for Build identity does not mean AFL++ has no target checks:
it refers specifically to an embedded namespace in every coverage element.

## 13. Runtime experiments

Reproduce from the EFZ root:

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
escript docs/coverage-audit-2026-09-15/run.escript
ERL_FLAGS='+S 4:4' rebar3 eunit
ERL_FLAGS='+S 4:4' rebar3 ct
ERL_FLAGS='+S 4:4' rebar3 xref
ERL_FLAGS='+S 4:4' rebar3 dialyzer
```

[Sites](coverage-audit-2026-09-15/efz_cov_audit_sites.erl) are compiled with the
real `efz_instrument:compile/2`. The
[harness](coverage-audit-2026-09-15/efz_cov_audit_harness.erl) uses the ordinary
compiler. This deliberately excludes dispatch/loop-control probes: otherwise
LOOP1/LOOP10 might differ because of a new probe in another loop clause, falsely
suggesting count sensitivity.

The [runner](coverage-audit-2026-09-15/run.escript) uses the real executor,
prepared validation, feedback and corpus. A diagnostic driver supplies inputs
for algebra checks; this **does not claim the mutator generated them**. The
production campaign in `efz_feedback_loop_tests` separately proves real
mutation→execution→parent reuse. No mock coverage/corpus or custom mutator was added.

This target's identity map: A=probe 1, B=2, C=3, X=4; all share one module/build
pair. The first two diagnostic corpus entries are initial empty ID 1 and
retained AB ID 2.

| Input in order | Current probes | New probes | Retention reason | Global afterward | Corpus size |
|---|---|---|---|---|---:|
| AB | A,B | A,B | new_coverage | A,B | 2 |
| AB repeat | A,B | — | equivalent_coverage | A,B | 2 |
| ABC | A,B,C | C | new_coverage | A,B,C | 3 |
| BA | A,B | — | equivalent_coverage | A,B,C | 3 |
| AC | A,C | — | equivalent_coverage | A,B,C | 3 |
| LOOP1 | X | X | new_coverage | A,B,C,X | 4 |
| LOOP2 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP3 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP8 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP10 | X | — | equivalent_coverage | A,B,C,X | 4 |
| LOOP1000 | X | — | equivalent_coverage | A,B,C,X | 4 |

Results were identical for `ets` and `ets_member`. In every LOOP, raw ETS
contained **one object**, the diagnostic x-call count matched 1/2/3/8/10/1000,
and snapshot stayed `{X}`. ETS memory was 324 machine words for each such input
(2592 bytes with wordsize 8), including table overhead but excluding
guardian/registry/plan/result heaps. For 2 and 3 probes, 343 and 362 words were
observed. This is a local storage sample, not a throughput benchmark or a
universal memory-use formula.

Additional assertions verified:

* all contexts in the series differ, the owner is the guardian and ETS is closed after the result;
* A→B→A: exact coverage of first and third runs matches; B excludes A;
* genuine zero-hit success → `valid_empty_coverage`;
* calibration A updates global, with reason still `seed_calibration`;
* crash and timeout after X retain `{X}`, feedback leaves empty global unchanged;
* erase context + caught hook exception → infrastructure, rejected by feedback;
* child/linked/nested: one C probe, shared context, respectively 2/2/3 known
  processes, all already dead when the result arrives;
* ordinary spawn in a separate VM: empty coverage, infrastructure/dirty-runner,
  two known processes terminated, next input not started;
* retained AB is actually selected by `efz_mutation_plan:next/2` with parent ID 2.

Raw runtime records and command logs: `_build/coverage-audit-2026-09-15/`.
Compact preserved results: [results.txt](coverage-audit-2026-09-15/results.txt),
[validation.json](coverage-audit-2026-09-15/validation.json).

Validation results: compile — exit 0; EUnit — **186 passed**, exit 0;
Common Test — **3 passed**, exit 0; xref and dialyzer — exit 0.
New audit assertions run separately and do not increase the EUnit case count.
SHA-256 hashes of all production source files were checked before/after; no changes.

The full suite also checks paths not duplicated by the new experiment:

| Test | Area checked |
|---|---|
| `efz_phase2_tests` | AST semantics, manifest identities, repeatability, separate contexts, exceptions/timeouts, compiler options |
| `efz_backend_tests` | Backend equivalence, prepared/per-execution validation, lifecycle and broken observations |
| `efz_integrity_tests` | Plain/different-build hot reload, pinned harness, lost/corrupted context, caught exceptions, legitimate empty coverage |
| `efz_isolation_tests` | Caller/coordinator death, descendants during timeout, nested scope, dirty state and guardian failure |
| `efz_crash_retention_tests` | Late guardian failure preserves the primary infrastructure cause |
| `efz_feedback_loop_tests` | Real staged discovery→retain→parent reuse and fresh replay |
| `efz_durable_tests` | Discovery restored in another VM, recalibrated and used as a parent |
| `efz_coverage_SUITE` | Automatic campaign, crash and timeout observations |

## 14. Final classification

**RESULT B — AFL++-like feedback semantics implemented, different representation.**

Every link is proven: automatic instrumentation → execution-owned observations →
validated snapshot → worker global set → exact novelty delta → real corpus insert →
future mutation parent. Results C/D therefore do not describe current EFZ.

Result A is ruled out: the physical trace structure is an ETS set, and hit
multiplicity is lost at `insert_new/2`. Naming it a “bitmap” in documentation
would not change this. Result B describes the overall feedback architecture,
**not AFL++-equivalent observation power for edges/counts/context**.

## 15. Recommended next step

**There is no need to rewrite the current system to resemble AFL++.** First
separate three independent changes: (1) representation, (2) count sensitivity,
(3) edge/context granularity. A dense buffer alone creates neither edges nor buckets.

| Aspect | Conclusion for EFZ |
|---|---|
| Lookup/update speed | ETS provides hashed lookup/atomic insertion, but every hit also checks registry/context. A benchmark should separately measure hook, integrity tracing and full executor. Bitmap speedup cannot be assumed from its name. |
| Memory usage | A sparse set grows with hit count, with table/tuple-row overhead and duplicated evidence. A dense buffer allocates for the whole slot range, including unexecuted probes. |
| Number of probes | Sparse may benefit when total N is large and hit K small; with dense coverage a compact numeric representation may win. Workloads with different N/K are needed. |
| ETS overhead | Compact exact keys/lookup mapping can be evaluated first while preserving presence semantics. Snapshot currently uses tab2list + sort and copies term data. |
| Hit-count sensitivity | A useful independent option for loops. It can be prototyped with exact counters without hash collisions or a complete bitmap rewrite. |
| Collisions | Introducing modulo/hash aliasing without a demonstrated need loses current precision. Prefer a collision-free dense index prepared from manifests. |
| Deterministic identity | Preserve public `{M,Build,Probe}`; numeric slots should internally map the selected build set. |
| Parallel workers | The current VM permits one execution. Changing storage does not fix the singleton registry/guardian or the shared state-isolation model. |
| Distributed fuzzing | Begin with independent VMs, versioned identity/metric and exchange raw inputs with local calibration. Do not combine arbitrary slot maps from different builds. |
| Corpus compatibility | Bytes are reusable; old `new_probes` remain historical presence metadata. Bucket discoveries need a separate metric/schema version, not silent reinterpretation of old records. |
| Replay | A recipe reconstructs bytes independently of storage. Pinned build/harness checks stay; replay coverage expectations must know metric/version. |
| Backward compatibility | Keep presence as default/reference; make a new mode opt-in. Differential tests must preserve existing outcomes/identities. |

Minimal **proposed**, unimplemented architecture if need is confirmed:

```text
existing instrumentation → {Module,BuildId,ProbeId}
  → immutable prepared exact identity↔dense-slot mapping
  → execution-owned counter array / exact sparse counter backend
  → explicit saturating/overflow policy
  → versioned bucket classification
  → novelty of (ProbeIdentity,Bucket) against campaign global features
  → existing feedback retention path → existing corpus/scheduler
```

For quality comparisons, retain compatibility `coverage => [Identity]` and add
separate `coverage_features` / `new_features`; a count-only discovery must not
falsely report a new source probe. The new snapshot must preserve guardian
lifetime, controlled-child atomic updates, integrity checks, cleanup, build
validation and correct reset. A shared persistent bitmap without a scoped owner
would violate guarantees already proven.

`efz_mutation`, `efz_mutation_plan`, raw input/recipe regeneration, corpus
selection and most of `efz_worker`, `efz_executor`, `efz_guardian`,
`efz_instrument_pt` remain without rewrites. Changes would focus on `efz_cov`,
`efz_cov_rt`, prepared mapping/validation, `efz_feedback`, config and versioned
metadata in corpus/crash/replay. Coverage-integrity evidence must adapt to
counters: the current first-observation set does not confirm count accuracy.

Acceptance for the next experiment: presence mode gives previous results;
count mode retains LOOP1 then LOOP10 on a new bucket; same-bucket repeats are
not retained; A→B→A stays clean; controlled concurrent increments are not lost;
crash/timeout cleanup does not corrupt the snapshot; build/metric mismatch is
rejected. Decide on a production bitmap after measuring end-to-end cost and useful
discovery counts on real targets, not merely the speed of a standalone array.
