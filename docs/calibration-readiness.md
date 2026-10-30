# EFZ readiness audit for calibration and feature_stability

**English** · [Русский](i18n/ru/calibration-readiness.md) · [Español](i18n/es/calibration-readiness.md) · [简体中文](i18n/zh-CN/calibration-readiness.md) · [All languages](i18n/README.md)

Date: 2026-09-09. **Verdict: READY WITH PREREQUISITES.**

For a fixed build, a cooperative target and a scope of **one target process**,
complete exact observation sets for individual executions are already available. A second executor,
a new backend, hit counters or buckets are unnecessary. Reliable integration first requires
an explicit termination reason, completeness/cleanup and runner-loss handling contracts,
followed by a separate repeat collector that does not invoke novelty on each repeat.

For an arbitrary process tree, a stateful OTP application, native/NIF coverage
or recovery after a whole-VM crash, the current implementation is **NOT READY**: those
contracts/runners do not exist. This is a scope limitation, not a reason to represent their coverage
as empty and obtain 100%.

The calibration mechanism was **not implemented** in this task. Production code, APIs, dependencies,
defaults and search algorithms were unchanged. The only permanent new file is this
report. Fixtures, diagnostic scripts and logs are in
`/tmp/efz-calibration-audit.rIBEql/`; their sources are included in the appendix for
reproduction after the temporary directory is removed.

Evidence notation: **C** — found in current code; **E** — confirmed by
a new run; **D** — documentation claim; **P** — proposed, not yet
implemented; **NV** — not verified. Historical measurements are not treated as results
of this audit.

## 1. Checkout, tools and current architecture

**C/E.** Repository: `efz/`, branch `main`, HEAD
`ac09c1f3e938c3a79b369fc6a87d61c1ae739db4` (`chore: initialize efz OTP project`).
The commit does not describe the entire implementation examined: the initial tree already had changes to
`README.md`, `rebar.config`, `src/efz.app.src`, untracked directories `bench/`, `docs/`,
`examples/`, `fixtures/`, `scripts/`, `test/` and most `src/efz_*.erl` modules.
The complete initial status/diff is saved in [status.txt](/tmp/efz-calibration-audit.rIBEql/status.txt)
and [diff.txt](/tmp/efz-calibration-audit.rIBEql/diff.txt).

SHA-256 hashes of all 78 existing files listed by
`git ls-files --cached --others --exclude-standard` were captured before the run. Their
contents matched after the experiments. None of those files changed before this report was added.
No reset/clean/stage/commit/push operations or Git identity/remote changes were performed.
No applicable `AGENTS.md` files were found in the repository or checked parent directories.

The source-tree list hash (sorted UTF-8 lines
`path + NUL + file_sha256 + LF`) —
`24eafa7e45d6584b1ff2eb03021391c3e299b95df2a51ab7041726c9a612cf23`.
The full list is in [before-sha256.json](/tmp/efz-calibration-audit.rIBEql/before-sha256.json).
Key files that bind the conclusions to the dirty checkout:

| File | SHA-256 |
|---|---|
| `src/efz_executor.erl` | `c4a7802a9ac299445b5b6b50fd1ded92ae09e814ad25f4f300054503e6745f47` |
| `src/efz_cov.erl` | `2d32b0aca9c1641e40ab111e844d020004fb5cb9b743d76c40a46385fa4489d0` |
| `src/efz_cov_rt.erl` | `47e84c8f84861ff7ec7817fa34b9b1234af571ce3bf316fe3d2867428dcfb466` |
| `src/efz_cov_manifest.erl` | `4951ecc1f7104fca08928ee7dfa669cfacc8b27cac856961db06f9ea14451544` |
| `src/efz_feedback.erl` | `0be0ecc64e967b776cc990259d569539e520ba7f603e838c444cdd44e2b30bb6` |
| `src/efz_worker.erl` | `3e4f4d383f86b0bfe9af2d6a366fda848818dcb33f85652efd69d325a9e3baa4` |
| `src/efz_instrument.erl` | `c4dfbe3b9caadfc4ed60153d1a6573b152f31fc5b95e34a168a6bea730695351` |
| `src/efz_instrument_pt.erl` | `b781f83981aef57f59a79c42c099a07076002434ceecd2ecef8feb05930766cd` |

**E.** `rebar3 version`: Rebar3 3.25.0, OTP 27 / ERTS 15.0.
`releases/27/OTP_VERSION` contains `27.0`. Architecture:
`x86_64-pc-linux-gnu`, Linux. The audit's standard VM had **16 schedulers, 16 online**;
`ERL_FLAGS`, `ERL_AFLAGS`, `ERL_COMPILER_OPTIONS` were unset. The main diagnostic
script and its three fresh VMs also recorded 16 online. The value 4 from Phase 2.1
was not carried over here. Existing fresh-VM EUnit helpers explicitly use two schedulers;
those are separate test settings, not the main measurement configuration.

**C.** [rebar.config](../rebar.config), lines 1–14: minimum OTP 27,
`debug_info,warnings_as_errors`, `src_dirs = ["src","examples/simple_parser"]`,
`deps = []`; `rebar.lock` is empty. There are no named project profiles. `compile`
uses default; EUnit/CT use Rebar3's standard test profile. No GitHub/GitLab CI configuration,
separate Makefile, Go module/controller or Python control
layer was found in the current tree. The README lists local rebar commands;
this is not evidence of a CI run. No formatter/linter is configured.

**C/E.** This is a single Erlang-native OTP implementation of EFZ:

```text
escript / Erlang caller
  efz:start/1 -> efz_sup -> efz_fuzzer
                              |-> efz_corpus (entries, selector RNG)
                              |-> efz_stats
                              `-> efz_worker_sup -> one efz_worker
                                       |-> prepared validation plan
                                       |-> random / staged mutation state
                                       `-> efz_executor:run/4
                                              -> coordinator -> target process
```

`src/efz.erl:start/1`, lines 3–7; `efz_fuzzer:init/1`, lines 17–25;
`efz_worker_sup:init/1`, line 2. Application `efz` version 0.1.0 depends on
`kernel`, `stdlib`, `crypto` (`src/efz.app.src:1–18`). Using crypto does not
imply native coverage support.

| Search term | Findings |
|---|---|
| EFZ/ErlFuzz, Go controller, `input_coverage` | The current runtime uses EFZ and Erlang; the other names/mode were not found |
| `efz_instrument`, `efz_cov`, `efz_feedback`, `efz_executor` | Present |
| `efz_cov_runtime`, `efz_run_context` | The actual implementation is `efz_cov_rt` and a tuple context in `efz_cov`; no modules have the specified names |
| `efz_value_runtime`, `efz_hook_runtime`, `efz_data` | Not found; value/transition feedback is absent |
| `execution_ref`, `builds`, `coverage_status`, `elapsed_us`, `target_outcome` | Present in the `run/4` result, but the failure branch may lack `target_outcome` |
| `input_id` | Input SHA-256 in worker/corpus metadata, not a field of the normal executor result |
| `cleanup_status`, generation, layout digest, `feedback_epoch` | Absent; they must not be attributed to the existing contract |
| `RunRef` | An internal `Request` and a separate context `Ref` exist; neither provides a portable input ID |

**C/E.** Defaults confirmed by `efz_config:defaults/0`, lines 4–6, and runtime:
`coverage => automatic`, `coverage_validation => prepared`,
`coverage_backend => ets`, `workers => 1`, `mutation_mode => random`, timeout 100 ms.
`ets_member` is explicitly allowed; `per_execution` is an alternative validation mode. These are two
independent axes, not four different feature spaces. Low-level `run/4`
does not create a prepared plan itself: the caller supplies `coverage_plan` or `manifests`.
`run/3` uses manual compatibility and returns only the outcome.

**C/E.** `seed_calibration` is **one execution of each initial seed**:
`efz_worker:init/1`, lines 20–24, `handle_info/2`, 26–30;
`efz_feedback:evaluate/3`, 9–17. A check with two seeds and zero mutations produced
`calibrations=2, executions=0, discoveries=0`, with two `seed_calibration` reasons.
There are currently no R repeats, intersection/frequencies or stability metric.
The word “calibrates” in the README means this initial processing, not repeated
stability evaluation.

## 2. Actual testcase path and state ownership

Main code links: [executor](../src/efz_executor.erl),
[coverage context](../src/efz_cov.erl), [hook](../src/efz_cov_rt.erl),
[worker](../src/efz_worker.erl), [feedback](../src/efz_feedback.erl).

```text
Before measurement:
  config + artifacts preflight; load selected BEAM; create plan once
  take seed unchanged OR corpus selection -> mutation -> binary/recipe

For one run/4:
  caller creates Request, spawn_monitor(coordinator)
    coordinator monitor(caller)
    open: new context Ref + new public ETS         [before Started]
    Started = monotonic_time(microsecond)
    spawn_monitor(target)
      attach(Context) -> M:run(Input)
      selected module bodies -> synchronous ETS membership publications
      outcome / caught error, throw, exit
      target_result{Ref, target PID, Outcome}
    wait: result + target DOWN, or DOWN/timeout/caller DOWN
    timeout/cancel -> kill(target) + confirmed DOWN
    ordinary branch: sticky failure -> snapshot -> identity validation -> result
    send result to caller                         [still before finally cleanup]
    after: repeat kill_and_drain -> close ETS -> demonitor caller
    coordinator terminates
  caller waits for coordinator DOWN before returning from run/4

After run/4:
  worker increments calibration OR mutation execution counter
  feedback(status, outcome, builds, Observed) -> novelty/merge decision
  corpus add for new successful input; crash storage separate
  decisions/statistics; next iteration
```

**C.** `elapsed_us` starts after `efz_cov:open/1` and includes target startup,
attach, `M:run/1`, waiting for termination, snapshot reading and validation; it ends
before `builds(Options)`/sending the result and finally cleanup
(`efz_executor:coordinate/6:28–59`). This is neither pure target time nor the full wall time of
`run/4`. The full synchronous call includes context allocation and cleanup. The deadline
in `wait_target/5:62–79` is measured separately in milliseconds after target spawn;
it is not a guaranteed wall-time upper bound for a stuck native call.

**C.** There is no common decoder, `before_input`, target-state reset, `after_input` or target
cleanup callback. Seeds are binary, mutations return binary; the staged recipe
is composed before the executor (`efz_worker:staged_iteration/1:42–52`). Size
and dictionary checks are outside coverage. Low-level `run/4` accepts any
Erlang term as `Input`, passing it directly to `M:run/1`; diagnostic tuple
inputs containing PIDs use this low-level seam, not a new campaign API.
Replay file reading/regeneration/preflight happen before execution
(`efz_recipe:execute/5`, `execute_file/5`, lines 85–114).

**C.** The feature scope is the bodies of selected modules called by the process after attach.
Therefore decoder/setup inside the selected `M:run/1` is also measured if
present. Target `try ... after` is measured until normal/exception termination;
forced kill does not guarantee target cleanup execution. The EFZ hook, executor,
statistics collector and transform are excluded from the allowlist by the transform itself
(`efz_instrument_pt:parse_transform/2:26–33`). Compilation/load before attach and coordinator cleanup
after target DOWN add no EFZ probes. A user-selected
adapter may otherwise add its own shared probes; record this in the allowlist,
rather than subtracting those features after calculating a percentage.

| State/resource | Owner and lifetime | Guarantee / boundary |
|---|---|---|
| Corpus and selector RNG | `efz_corpus` gen_server; campaign lifetime | insertion order; random selector or staged planner; `src/efz_corpus.erl:5–14` |
| Mutation RNG/cursors, global novelty, decisions | `efz_worker` | Must not change due to stability repeats; `worker:7–24,42–56,108–125` |
| Prepared plan | Worker; offline caller `prepare/2` | protected unnamed ETS; until release/owner death; not an observation buffer |
| Request and coordinator monitor | Caller `run/4:7–24` | Response is bound to Request/PID; caller waits for coordinator termination |
| Context Ref and public ETS set | Coordinator `coordinate/6:26–29`; `cov:open/0:11–13` | ETS survives target death and is destroyed with its owner; no heir |
| Context reference in PD | Only the target after attach | Not the only hit store; not inherited by children |
| Caller/target monitors, deadlines | Coordinator, `wait_target/5`, `kill_and_drain/2` | `receive after`, not a timer process/port; separate fresh monitor during cleanup |
| Snapshot list | Coordinator, then result copy at caller | Immutable Erlang list; survives ETS deletion; data precedes novelty |
| Ports in the production executor | Absent | Fresh-VM ports in tests/audit belong to the external diagnostic escript |
| Children, OTP servers, target timers, external resources | Not managed by executor | No target-tree list, child ACK barrier or common reset |

### What actually proves quiescence

**C/E.** A completed synchronous `ets:insert` publishes presence before the hook returns.
`target_result` alone is insufficient: the executor also waits for monitor DOWN.
Timeout/cancel call `exit(Target,kill)` and wait for a fresh monitor's DOWN without sleeping
(`kill_and_drain/2:82–87`). The target PID can no longer write after that; each new
execution creates fresh PID/Ref/Tid values. The snapshot list is read before ETS deletion.
The caller cannot receive a successful `run/4` return before coordinator termination.

This proves **one PID**, not a tree. Child processes have neither an ACK
protocol nor a transitively joined scope. Spawned children do not inherit PD; their normal
hooks are inactive. A child given the context manually can write to the old
table while it exists, including after parent termination. There is no barrier between snapshot and
close for such an unsupported writer. After close, a stale hook gets a table
error, not a new context. The diagnostic explicitly waited for the child after the root,
started the next context and confirmed no pollution of that next context.
This does not confirm complete coverage of the child tree.

**C/E.** There is **no** generation validation on hit. Ref matches result/failure
messages, but is not stored in an ETS row or checked against the table on hit.
`attach/1:24–29` checks table ownership and the reference/PID types, not the Ref-to-Tid binding.
Replacing only Ref with the same owner/Tid was accepted in the diagnostic. Normal-path
isolation comes from fresh, non-reused Tid values and processes, not a
generation check. `snapshot/1:31–34` does not check whether writers have stopped: directly
reading a live context returned `{a}`; after an allowed write by the same writer it returned `{a,b}`.
Calibration must consume the `run/4` result rather than read ETS arbitrarily.

### Termination branches: current result and metric eligibility

| Branch | Actual data and cleanup | Decision for a future series |
|---|---|---|
| Normal return | `outcome={ok,V}`, identical `target_outcome`, complete root snapshot when status is ok; DOWN precedes reading and close precedes return | Measurable repeat when the root/reset/build contract is met |
| Target returns `{error,invalid_input}` | This is `{ok,{error,invalid_input}}`, not a separate executor invalid category; current feedback treats the return as successful | Do not exclude based on the Value's name; record the outcome separately; empty U gives N/A |
| Invalid configuration/oversized staged seed | Rejected before target; no snapshot is created (`efz_config:prepare/1,prepare_mutation/1`) | Request error, not an empty measurable repeat |
| Target `error`/`throw` | `{crash,Class,Reason,Stack}`; hook hits retained, target DOWN and cleanup normal | Valid snapshot of a terminal exception; do not exclude crashes from stability based on outcome |
| Target `exit(Reason)` | `{exit,Reason}`, status may be ok | A semantically completed exception is eligible, but current results do not distinguish it from external termination; origin is required |
| External target kill | `{exit,killed}`, published prefix retained; root DOWN proven | Complete prefix of a terminated PID, **not a complete testcase**; generally incomplete, not an empty F |
| Timeout | `{timeout,T}`, status may be ok, hooks before actual kill/DOWN retained | Do not treat a deadline cut as complete x; keep diagnostic prefix separately, mark main series incomplete |
| Completion/timeout race | If Result + DOWN arrive in time: Outcome; otherwise timeout wins; late messages stay with the retiring coordinator | Check terminal source instead of guessing from duration or hit presence |
| Caller death / campaign cancel | Coordinator kills/drains target and closes table, returns no snapshot (`cancelled -> ok`, executor:44) | Missing/cancelled slot; incomplete. Caller/worker DOWN does not substitute for coordinator DOWN |
| `efz:await(Timeout)` expires | This is a `gen_server:call` timeout; campaign continues | Do not treat as target cancellation; explicit separate cancel/stop is needed |
| Worker kill | Fuzzer returns `status={infrastructure_failure,{worker_down,killed}}`; report has no snapshot; coordinator asynchronously cleans target | Incomplete; do not infer success from a zero infrastructure_failures counter |
| Coordinator killed | `run/4`: infrastructure `coordinator_down`, `coverage=[]`, error status, empty builds; table disappears; target may survive | Missing, dirty/unknown VM state; stop series, do not reuse VM without proven cleanup |
| Backend/plan/validation failure | Infrastructure, error status, diagnostic hits sometimes available; coordinator executes finally on ordinary exceptions | Not an empty F or a target bug; series incomplete/incomparable with a reason |
| Abnormal coordinator DOWN after result | `cleanup_failed` replaces outcome/status (`run/4:15–18`) | Data is diagnostic only until cleanup is confirmed; do not admit automatically |
| Node/VM crash | Controller in the same VM is also lost; no result | Lost series is incomplete; record external exit status separately; do not construct U from a missing file |

For `halt(23)` in an **external diagnostic VM**, exit status 23 and
the absence of a result/snapshot file were confirmed. This controls VM loss; it is not a NIF segfault test.
EFZ has no distributed runner or separate `nodedown` branch.

`kill_and_drain` deliberately waits for actual DOWN rather than declaring cleanup after an
arbitrary delay. Its wait is not bounded by a second timer, however: a NIF that
never returns may require external VM termination. Such a NIF was not
tested. Dirty shared/application state does not become clean when a single
target PID dies. Without proven reset/cleanup, the future collector must stop the series
with `requires_fresh_vm`, rather than continue and declare the counters reliable.

## 3. Exact feature space and comparability

**C/E.** Automatic feedback unit:
`{Module, BuildId_SHA256, ProbeId_integer}` — **presence of a source-level
clause/outcome probe**. The row in both backends is `{{probe,Id}}` in an ETS `set`:

* `ets`: inserts the same row on every hit (`efz_cov_rt:hit/1:20–26`).
* `ets_member`: first checks membership and inserts the same
  row if absent (`hit/1:8–19`). Repeated writes increase no value.
* `manual`: a separate `{manual,Id}` space through `efz_cov:hit/1:38–39`, using the same
  two ETS storage variants. This is a compatibility API; the caller must ensure stability of
  arbitrary user IDs. Automatic/manual spaces are not mixed.

There are no counters, buckets, CFG edges, value features, transition sequences or hashed
bitmaps. No counter overflow exists because there is no counter. Exact ETS keys compare
the full term, not a small hash. The SHA-256 build namespace is not a mathematical
guarantee against every possible hash collision, but this implementation has no intentional
bitmap/index collisions. Repeated publications are not lost through a local cache: there is none.
Experimentally, multiplicities 1 and 100 at the same site produced the same singleton F
in both backends. Thus `feature_stability` here equals site-presence
stability; a second duplicate metric or buckets are unnecessary.

`efz_cov:snapshot/1` returns **the entire sorted list of present IDs**,
not a count/hash/delta. `efz_feedback:evaluate/3:10–17` only then calculates
`Observed - Global`. `Result.coverage`, `Report.coverage` and `Decision.new_probes`
differ: the last is the retention delta; report coverage is the union of successful executions.
Full snapshots of successful/rejected executions are not
saved in a normal campaign report; a crash result retains its own complete coverage. An old report cannot
recover missing F_r values. Re-execution through `run/4` or a future
observer before feedback is needed; do not propose reconstructing them from SHA/count/new_probes.

**C/E.** Each input change creates a fresh empty table instead of clearing a shared bitmap. Isolation
of repeated/concurrent contexts was verified with identical probe IDs. Return/exception
preserve all completed root publications under an immutable-context contract.
For kill/timeout, these are all published hits before that process terminates,
not all branches it could have executed without interruption. An insertion interrupted by kill
does not justify declaring the unfinished hit observed. The snapshot is intact,
but testcase completeness is a separate question.

**C.** Identity is defined by `efz_instrument_pt:parse_transform/2:35–53` and
`probe/4:114–121`: SHA-256 `{instrumentation_version, OTP release, compiler MD5,
canonical preprocessed forms, relevant compiler options}`, followed by a deterministic
ordered AST index. Manifest schema/instrumentation version = 1,
metric = `clause_outcome_probe`. Probe mapping contains M/F/arity/kind/path/file/
line/column. The root-relative source path is normalized; absolute path-sensitive
literals can change the build. There is no separate native layout or feedback_epoch.
An arbitrary hash of a whole ETF map cannot serve as a portable digest without
canonicalization: map serialization order is not such a contract.

`efz_instrument:preflight/1`, `load/1`, `loaded_manifest/2`, lines 94–142,
check BEAM, decoded sidecar, manifest and loaded-module attribute. The sidecar
is compared by exact term, not bytes (`matching_sidecar/2:111–113`).
The existing reversed-map-order/fresh-VM test passed again. In three new VMs, one
artifact produced **the same complete IDs**, the same build map and S=100%; equivalence was checked
using ID lists, not only count/digest.

Hot replacement after preflight is not continuously monitored. In the diagnostic, an old
valid plan after controlled loading of an **ordinary** version of the same module produced
`coverage_status=ok, coverage=[]` and the old build map. Repeating explicit preflight
rejected `loaded_module_identity_mismatch`. A change to a new instrumented build
publishing new IDs is caught by the validator; replacement with code without probes is
not caught this way. The lifetime contract requires immutable selected builds and harness. Changing
the build or manifest requires a new plan and series; arbitrary hot reload is not
declared supported.

**C/E.** A prepared plan is `{efz_cov_plan,1,Tid,BuildMap}`. `prepare/2:51–68` validates
manifest schema, instrumentation version, uniqueness, nonempty automatic selection
and absence of duplicate modules; it creates protected ETS marker `{'$efz_plan',{Mode,Bs}}`
and exact allowed identities. It **does not replace preflight** and contains no input,
execution Ref, RNG or accumulated coverage. The worker owns it until stop, including after
`await` completes. The low-level API allows a foreign caller while the owner is alive; writes
to someone else's protected plan are prohibited. The owner releases it after all readers;
owner death automatically deletes the table.

On every execution, validation checks marker/mode/builds and every observed ID,
including the marker check for empty F (`validate_prepared/3:72–85`). A disposed plan, wrong
mode or substituted build map cannot become a successful empty snapshot. A different tuple version
may additionally fail in `builds/1:70` and produce coordinator_down infrastructure.
Existing negative/lifetime tests cover this, including plan-owner death during
an active execution. The plan is backend-independent; storage backend and validation
strategy are nevertheless recorded in experiment configuration because their timing overhead differs.

## 4. Applicability of feature_stability and admission rules

**P.** This is EFZ's own metric, not libFuzzer's standard formula or a numerical
equivalent of AFL++ stability. Normalization v1 is deduplication + canonical ordering of **complete**
probe identities; no site/counter masking or exclusion of crash-only IDs.
For the same x under a fixed state contract and R >= 2:

```text
frequency_x(f) = number of measured repeats where f appeared at least once
U_x = union of all F_r(x)
I_x = { f in U_x | frequency_x(f) == R }
V_x = U_x \ I_x
S(x) = feature_stability = 100 * |I_x| / |U_x|
S_C = 100 * sum_x |I_x| / sum_x |U_x|
```

Repeated hits within one F do not increase frequency. No reference run is needed.
If desired, call the fraction of entirely matching runs a separate metric with an explicitly
chosen reference; do not substitute it for S. For exact threshold comparisons, retain
numerator/denominator and compare integer products; round only for display.

**E.** A diagnostic target with only four probes produced the following for one input:

```text
F1={a,b,c}; F2={a,b,d}; F3={a,b,c}
frequency={a:3,b:3,c:2,d:1}; I={a,b}; U={a,b,c,d}; V={c,d}; S=50%
```

All sizes equal three. A second input alternating in reverse also has S=50%;
the correct corpus aggregate is 50%. If the two inputs of each
round are unioned first, `{a,b,c,d}` appears three times and yields a false 100%. This was asserted,
not inferred from visually similar logs.

**P.** Result state machine for one input:

| Condition | Status / value |
|---|---|
| Requested R < 2 | N/A `insufficient_repeats`; not 100 |
| All R reliable and comparable, U nonempty | `complete`, S and full frequencies |
| All R reliable, U empty | N/A `empty_feature_union`; distinguish empty bytes from an empty snapshot separately |
| Missing snapshot, infrastructure error, unconfirmed quiescence/reset/cleanup, cancellation, owner/VM loss, interrupted testcase | `incomplete`, main S absent |
| Build/manifest/schema/scope changed or IDs incomparable | `incomparable`, main S absent; do not automatically convert to another namespace |
| Only k<R reliable repeats exist | `incomplete`; a separate diagnostic S for actual k>=2 may be shown, without automatic admission |
| Complete terminal error/throw/caught exit or normal invalid return | May participate in stability; account for outcome separately, do not exclude solely by class |

Comparability assumes no interference with instrumentation-owned
state. Status ok alone does not prove this against a hostile target. If
interference or code changes are detected, the series is invalid/incomplete regardless
of whether a nonempty subset of identical hits remains.

For a fixed C, freeze content identity, order/permutations and the repeat
protocol beforehand. The aggregate weights **input–feature pairs**, not unique
features across the whole corpus. Alongside S_C, require rows for every x, min S(x), the number of
unstable inputs (`|V_x|>0`), `selected_entries`, `unique_inputs`, `measured`,
`scored`, `empty`, `incomplete`, `incomparable` and their input IDs. Explicitly map byte-identical
duplicate entries to one x for this control metric; do not remove or alter the original seed entries,
their order/status or normal calibration counters.

For an incomplete corpus, the main aggregate has incomplete/incomparable status,
not “everything is stable”. A separate `complete_subset` aggregate is allowed with an exact
list of included x values and denominators. Complete empty x values contribute zero to the sums,
but remain N/A rows, explicitly marked, rather than becoming “verified 100%”.
If the total denominator is zero, S_C=N/A. Do not silently exclude failures
or missing repeats, replace them with an empty set, or retry until a convenient R is obtained.
A new consistent run after failure is a new series with a new diagnostic job ID.

The main outcome comparison is proposed separately: exact return value or exception
class/reason; keep target stack as evidence, not a feature. Volatile PID/ref/
port/fun values must not be declared portable matches across VMs. Record outcome
changes/incomparability separately; do not destroy the original result. Complete
F equality proves neither identical execution order, identical outcome nor
absence of defects.

If feedback ever becomes `{site,bucket}`, a bucket change may create
several unstable features for one site; this differs from the number of stable
AFL++ cells. No such backend exists currently. Introduce a second schema and a separate
site-presence metric only if feedback actually changes, not for this audit.

Proposed configurable internal guidelines: target **100%**, warn at
`S < 95%`, investigate more deeply at `S < 90%`; all variable x values remain visible above 95% too.
These are initial project thresholds, not an industry standard or proof of
correctness. Incomplete data does not pass the threshold check. A higher R increases
the chance of detecting variability; percentage comparisons require fixed R, C,
feature schema, builds/manifest and execution/reset/warmup mode.

## 5. BEAM isolation and repeatability protocols

| Mode | What is confirmed / what a future run must record |
|---|---|
| Repeats of x through normal `run/4` | Fresh target PD/mailbox, new context; main schedulers 16; first call included. Deterministic fixture has identical complete F and S=100 |
| A→B→A, fixed permutations | Independent `only_a`/`only_b` sets are disjoint, both A values match, permutations yield the same input→F mapping |
| Controlled independence violation | `state_b` changes `persistent_term`; A before/after produces c/d, S=0. Explicit fixture reset restores A. This indicates shared VM state, not defective ETS isolation |
| Fresh VM for each x | Three independent VMs, same artifact/manifest and IDs, S=100; normal 16 schedulers. Control mode, not an OS-isolation guarantee |
| Planned warmup | This audit uses W=0. The first call was not discarded. Future W/warmup sequence is an explicit part of the protocol/key; warmup failures count too |

The first ETS experiment had `elapsed_us=[919,10,7]`; the subsequent ets_member
experiment began with `[15,12,11]`; F values match. The second group already ran in a warm VM, so
this is **not a backend performance comparison**. The numbers show why the first call must not be silently
excluded or cold/steady modes mixed. Full warmup/stability
was not measured on a real library.

**E.** Target-local `put`, mailbox messages and implicit rand state did not carry into
the next fresh target. Shared ETS/registered servers/persistent_term/application
state, however, is not reset by the executor. In the test, an already-running gen_server, a synchronous OTP
callback and a timer-delivered message called an instrumented site without an attached
context: child/background hooks were inactive. `spawn`, `spawn_link`, `spawn_monitor`
left the child alive after normal root return; neither a parent link nor a parent monitor
ensures whole-tree termination. Child release/ACK were explicit, not triggered after
a sleep. Timers/messages do not carry the process dictionary; the recipient determines the
execution process. Existing OTP servers are not automatically given a context.

If the target is intentionally stateful, x must include initial state, configuration and
the action sequence. `state_a` after different intentional states must not
be represented as one scenario x. Current EFZ accepts binary+`run/1`, with no scenario/reset API.
The minimum first integration must explicitly restrict itself to the existing
`fresh_target_process / unreset_shared_vm / root_probe_scope` and agreed
harness independence. Do not present this as a universal OTP-application reset.

Unverified boundaries: arbitrary ETS owned by others, registry/global state,
shared applications, files/ports, unmanaged timers/background actors, distributed-node
state, shared native resources. A fresh VM isolates its own process state, but does not
guarantee resetting external OS resources. Neither context Ref, public ETS nor a prepared
plan is a security boundary. A target in the same VM can change runtime,
kill the coordinator or corrupt instrumentation state. Some interference is already
classified as infrastructure failure; full protection/a dirty-worker detector is absent.

## 6. Runs and evidence matrix

All commands were run from `efz/`. Input build flags are the current rebar.config;
diagnostic modules were compiled with `debug_info,warnings_as_errors`, without new
dependencies; only `audit_sites` was allowlisted. Its four probes:
`a/0:3`, `b/0:4`, `c/0:5`, `d/0:6` (column 1), build
`68bd7a9201c0be5e43ed13f5850558fcefe6e07493252a66204f7fe36fc7e809`.
The adapter/background fixture is intentionally uninstrumented so shared control branches
do not pollute the specified a/b/c/d sets. Normal production examples were also
checked, rather than replaced by this special probe space.

| Command | New result | Log |
|---|---|---|
| `rebar3 compile` | exit 0 | [compile.log](/tmp/efz-calibration-audit.rIBEql/compile.log) |
| `rebar3 eunit` | exit 0, **62 passed** | [eunit.log](/tmp/efz-calibration-audit.rIBEql/eunit.log) |
| `rebar3 ct` | exit 0, **3 passed** | [ct.log](/tmp/efz-calibration-audit.rIBEql/ct.log) |
| `escript /tmp/efz-calibration-audit.rIBEql/audit.escript /tmp/efz-calibration-audit.rIBEql` | exit 0, **54 evidence records**, all assertions passed | [diagnostic.log](/tmp/efz-calibration-audit.rIBEql/diagnostic.log) |
| `escript /tmp/efz-calibration-audit.rIBEql/existing_example.escript /tmp/efz-calibration-audit.rIBEql` | exit 0; `efz_example_target` with `<<0>>` and `<<255>>`, R=3 each, exact F match, S=100; exception not excluded | [existing-example.log](/tmp/efz-calibration-audit.rIBEql/existing-example.log) |

Complete diagnostic results before novelty, including exact IDs and metadata, are in
[events.term](/tmp/efz-calibration-audit.rIBEql/events.term) and
[events.txt](/tmp/efz-calibration-audit.rIBEql/events.txt). Assertions compare
canonical sets, not just sizes. Logs/scripts are temporary; this table
and embedded sources are the permanent reproducible record. The first trial
script had an OTP warning about float pattern `0.0`; this was changed to `+0.0` only
in the temporary script, and the final experiment was repeated successfully. Earlier temporary results
were kept with the `first` suffix; the conclusions use the final run.

SHA-256 hashes of final evidence: `eunit.log` —
`1aaf27c24e7f320e7b331d2f9e7f06dea647981627050cd53aba37c513fe8a3e`,
`diagnostic.log` —
`b4bc09d285bd1681b13ffbd7f4a61233ccef6ace37af8dfabf7dc32ddac3ba66`,
`events.term` —
`fc7773394e458dedd9f742b80c5b0d9f7c44913add1e48d79146d9e8a2ea37c9`.
The sources embedded in the report were then extracted **using the appendix commands themselves** into
`/tmp/efz-calibration-reproduce.5h0yayqu`; both diagnostic escripts again
finished with exit 0. This verifies command reproducibility; it is not a new sample to
mix into the percentages/timings. See [reproduction check](/tmp/efz-calibration-audit.rIBEql/report-reproduction.txt).

| Requirement / experiment | Current implementation and evidence | Gap / minimum change |
|---|---|---|
| Deterministic x, R=3 | Both backends: abc three times, S=100; `{B,deterministic}` | Public metric needs a separate collector |
| Equal-size different sets / known alternation | abc/abd/abc, frequencies 3/3/2/1, S=50; `{B,alternation}` | Calculate by identity, not count/hash |
| Corpus aggregation | Two opposing x values: correct 50, collapsed 100 | Retain separate `(x,feature)` frequencies |
| Different multiplicities | 1 and 100 hits at site a → one probe; `{B,multiplicity}` | Do not introduce counters/buckets |
| A→B→A/permutations | Disjoint a/b, both A values match; `{B,aba}` | Freeze order/reset contract |
| Shared state | persistent_term changes A; fixture reset restores it | No universal target reset; do not equate a process to a fresh VM |
| Delayed child | All three spawn variants inactive, next root set clean; explicit-copy child got invalid table after close | Tree quiescence/coverage unsupported; explicitly root-only scope |
| Existing OTP server/timer | Background hook inactive, root snapshot only a | OTP-application scope requires a separate future runner, not this integration |
| Concurrent contexts, identical IDs | Different Ref/Tid, both exact `{a}`, no tables after return | Do not infer production multiworker support from this test |
| Error/throw/exit | All retained a, status ok; `{B,exceptions}` | Terminal exception eligible; exit origin required |
| External kill / timeout | ACK after a, then kill or deadline, a retained, target/owner DOWN | This is a prefix; full testcase completeness is absent |
| Completion/deadline race | Existing `efz_backend_tests:boundary/1:188–198` and Phase 2 tests passed | Terminal-source metadata instead of guessing |
| Caller/cancel/shutdown | Existing `caller_death/1`, `cancel/1:179–210` passed for four combinations; new campaign cancel confirmed await != cancel | No cancellation snapshot; cleanup asynchronous relative to caller death |
| Empty input/snapshot | `<<>>` returning invalid and a separate empty route are distinguishable; both empty series N/A | Do not confuse error/missing with valid empty |
| Worker crash | infrastructure status, no report snapshot, stats infra=0; `worker_kill` | Observer must read status; telemetry needs clarification |
| Coordinator crash | a saved before kill was lost with the table; root stayed alive, harness explicitly killed it | Incomplete + dirty; cleanup guard or no reuse/VM disposal |
| Prepared ownership/dispose/foreign | `efz_backend_tests:plan_lifetime/1:128–166` passed; disposed + empty gave infrastructure failure on both backends | Keep owner alive until readers finish; no release while executing |
| Missing/mismatched manifest/sidecar | EUnit preflight negatives and `efz_phase2_tests:sidecar_encoding/0:229–253` passed | Offline API must perform preflight; raw run/4 does not |
| Same build, fresh VM | Three new VMs accepted one sidecar and returned exact abc + identical builds | Namespace change means incomparable, not merge |
| VM loss | External helper exited 23; no snapshot file | No existing native runner; external job must mark missing |
| Live snapshot / Ref | a before quiescence, ab afterward; modified Ref accepted with the same Tid | Do not take snapshots directly; Ref is correlation, not a generation/security guard |
| Broken active state | Invalid table caught and remains sticky infrastructure failure; malformed PD context caught by target gave ok+empty | See finding F4; no blanket trust based on status ok |
| Hot ordinary replacement | Old plan accepted empty; explicit preflight rejected loaded identity | Freeze builds and check at supported series boundaries |

Existing EUnit coverage includes transform semantics, same-line/nested syntax, exception
class/reason, tail position, instrumentation identities, backend/validator canonical
outcomes/novelty, cancel/shutdown, and repeated execution-resource release.
Expected malformed-plan errors in logs are negative tests, not build failures.
`efz_backend_tests:variants/0:21` actually checks both storage implementations
with both validators. The 38/3 figures in old reports were not used as new
results: the current run is 62/3.

**NV.** Dialyzer/xref were not rerun in this audit: there are no production changes,
applicable instructions requiring a gate, or questions that require new static
analysis instead of the runtime tests examined. Their old PASS results are not presented as this
run. Phase 2.1 profiling/soak, Cowboy (no dependency/harness),
arbitrary external targets, native/NIF coverage reset/quiescence, NIF segfault,
distributed nodedown, and exhaustive OTP resource isolation were not tested. These boundaries are not closed
by the present a/b/c/d tests.

## 7. Prioritized findings

### F1 — P1: outcome/status do not establish completeness or termination source

**C/E.** `efz_executor:coordinate/6:35–38`, `wait_target/5:64–79`, `coverage/3:89–104`.
Caught `exit(killed)` and external kill produced **identical** outcome, target_outcome,
coverage_status, coverage, and builds; only incidental Ref/time differed. Timeout
can also have status ok and a nonempty F. Treating this as sufficient for a complete
repeat can make interrupted executions appear falsely stable.

**P. Minimum:** additive terminal origin/scope/quiescence/snapshot/cleanup metadata;
do not rename existing outcome tuples. Derive metadata from the executor branch
taken, not Reason heuristics. The series validator admits terminal caught
exceptions but not incomplete deadline/monitor-exit testcases. **Acceptance:** the same
public `{exit,killed}` is distinguishable by origin; prefix and missing never
become full/empty for the metric.

### F2 — P1: untrappable coordinator death leaves an unsupported live target

**C/E.** The target is created with `spawn_monitor`, without an owner-surviving cleanup guard
(`coordinate/6:31–41`). Killing the coordinator skips `after:55–60`; `run/4:20–23`
returns infrastructure, but the target was still alive in the test. The diagnostic harness
monitored and killed that exact target, then waited for DOWN; unrelated processes were untouched.

**P. Minimum for the metric:** abort the series, mark the snapshot missing, and use `requires_fresh_vm` when
cleanup is unconfirmed; do not run subsequent x in a dirty VM. Allowing reuse
after such a failure requires a separate owner-surviving guardian/tracked target cleanup
and an ACK for actual DOWN. A simple link is insufficient for a target with `trap_exit`; sleep
is not a fix. Do not change outcome or add counters for speed.
**Acceptance:** forced owner kill never produces a score; continuation is allowed only
after tracked writers are proven stopped, or in a new external VM.

### F3 — P1: a plan does not prove the executing code is unchanged

**C/E.** `efz_cov_manifest:validate_prepared/3:72–85` compares observed IDs to the marker,
not loaded code. `efz_instrument:loaded_manifest/2:124–127` checks the actual loaded
attribute only at preflight. Ordinary hot replacement produced a valid empty snapshot
with the old build map. The full result.builds comes from options/plan, not a trace.

**P. Minimum:** fix selected modules **and target adapter** for the series lifetime;
preflight at entry, capture/check selected loaded identities at agreed
series boundaries, and invalidate on build/manifest/harness changes. This does not protect against code changing during
execution and reverting to its old form; do not promise arbitrary
hot loading. **Acceptance:** incompatible boundary rejected; a new build means a new series,
not a subset merge; an unchanged fixed build can safely reuse the plan.

### F4 — P1 for runtime-contract violations: caught malformed context is lost

**C/E.** `efz_cov_rt:hit/1:16–27`: bad table sends a sticky notification, while the final
invalid-context clause only raises. The fixture replaced PD context and caught that
exception; executor returned `{ok,caught}`, status ok, and empty coverage. RunRef does not
protect instrumentation state from the target.

**P. Minimum:** explicitly prohibit modification of instrumentation-owned state in the supported
harness; check original context from the wrapper before completion, fail closed, and
diagnose violations. Checking only “at exit” does not protect against deliberate
replacement/restoration. A hostile target needs a different security/isolation boundary,
not a calibration promise. **Acceptance:** bad/erased context remaining after a caught
error means infrastructure/incomplete; runtime available without attach in an ordinary
unmeasured child remains a permitted inactive no-op.

### F5 — P1 for integration: campaign report data cannot be treated as F_r

**C.** `efz_worker:execute/4:60–82`, `finish/2:115–118`, `efz_feedback:evaluate/3:10–20`.
Success snapshots enter the global merge and are not retained as per-run reports.
`new_probes=[]` for a crash is retention policy, not absence of execution features.

**P. Minimum:** the collector stores the full result before novelty, or independently
repeats selected bytes through the same run/4. Do not call `feedback:evaluate/3`
on every repeat. **Acceptance:** an identical repeat series does not produce several NEW events,
change corpus/RNG/cursors, or merge crash-only features into global state.

### F6 — P2: worker loss and source failure are less clearly represented in telemetry

**C/E.** `efz_fuzzer:handle_info/2:34–39` returns worker_down infrastructure but does not
increment infrastructure_failures; the observed counter was 0. **C:**
`efz_feedback:evaluate/3:6–7,22` first requires equal builds; coordinator_down
with builds=#{} can become `instrumentation_build_mismatch`, masking the
original infrastructure reason, although it is not classified as a target bug.

**P. Minimum:** determine stability from structured result/status,
not aggregate counters. Preserve the primary failure reason; any future stats
change should count worker failure exactly once. **Acceptance:** a lost run stays missing,
and the actual reason is available in the calibration row; nobody declares an infra counter of 0
proof of completeness.

### F7 — P2 / scope: root isolation is not testcase independence

**C/E.** The executor has no reset/child registry; persistent_term and delayed-child tests
confirmed this boundary. Direct `snapshot/1` and Ref replacement do not establish quiescence.
**P:** record root-only/unreset-VM mode; diagnostic A→B→A and fixed permutations;
an inconsistent stateful scenario is unsupported, not automatic zeroing of
frequency. **Acceptance:** measure a known contract; do not delete unstable seeds or
mask probes to increase the percentage.

## 8. Minimal integration design — proposal only

### API boundaries and owners

**P, not an existing API:**

```erlang
%% Complete offline control corpus, without mutator or feedback side effects.
efz_calibration:run(Target, Entries, Artifacts, Options)
    -> {ok, CalibrationReport} | {error, ConfigurationReason}.
%% Pure aggregation, separate from storage/execution.
efz_stability:fold(Accumulator, ValidatedRun).
efz_stability:finalize(Accumulator, RequestedR).
```

Proposed options: `repeats` (R>=2, initial bounded opt-in example R=5), timeout,
backend/validation strategy, `mode=fresh_target_process`, `scope=target_process`,
`warmup=0`, protocol/order/reset-contract identity, limits on inputs/R/total wall
budget, output trace/witness budget. Exceeding the feature cap must finish the
input as incomplete, not truncate the set. Enabled functionality must not
create infinite retries. Do not accept arbitrary stateful
scenarios as binary input in the first version; a fresh VM is a separate explicitly selected helper mode.

The initiator receives a fixed set of bytes/identities and explicit Target/Artifacts,
as current replay does. `efz_config`/`efz_instrument` validate selection; no
arbitrary callable targets from a result file. Decoder/recipe regeneration occurs
once before the series; each measurement receives **the same bytes**, not another mutation.
The low-level executor is not replaced.

Proposed ownership scheme:

* The job controller/caller owns the frozen corpus, compatibility key, and aggregator;
  receives bounded progress for every scheduled run index.
* One calibration collector process owns the prepared plan and calls
  `efz_executor:run/4` sequentially. No concurrent production fuzzing workers.
  The plan is created after preflight, lives until all run/4 calls finish, and is released
  by its owner in `after`. Per-execution contexts, ETS, and monitors remain owned by the existing
  coordinator. Parent JobRef/PID provide correlation only, not a durable cache key.
* The collector passes an immutable full RunResult to the controller after run/4 returns,
  that is, after coordinator DOWN/cleanup. The controller increments frequency once
  per feature in the current slot, using the complete snapshot, not the decision delta.
* Offline-job cancellation is initially **cooperative between run/4 calls**: wait for the current
  call without releasing its plan, then do not start the next slot. Remaining slots are
  cancelled/not_run; the result is incomplete. This does not promise immediate cancellation of a hanging
  NIF. The collector monitors the initiator and checks stop/death before the next run.
* On forced collector/owner death, the job controller preserves previously received slots,
  marks the rest missing, observes existing cleanup guarantees, and requires
  a new VM if quiescence is unproven. A collector DOWN alone cannot be accepted as an ACK for all
  resources. Immediate cancellation with continuation in the same VM requires an
  explicit executor cleanup observer/guardian; this is a separate additive extension
  of the existing protocol, not a second executor.

**P:** extend existing `run/4` metadata while preserving its outcome/coverage fields and
the old `run/3` wrapper. Proposed structure (names not implemented yet):

```erlang
#{termination_origin => returned | caught_error | caught_throw | caught_exit |
                         monitor_exit | deadline | caller_cancel | coordinator_loss,
  coverage_scope => target_process,
  writers_stopped => confirmed | unknown,
  snapshot_status => full_scope | terminated_prefix | missing | invalid,
  cleanup_status => complete | failed | unknown}.
```

`full_scope` is limited to root and compliance with the instrumentation contract, not “the whole OTP
application.” Executor branches set the fields; calibration admission separately
checks builds, scope, reset contract, terminal origin, and coverage_status. Sending
the result before finally is permitted only with the current caller wait for DOWN; cleanup
metadata must reflect the result of this barrier, not be set in advance.
Cancellation without a returned result stays missing until an explicit
observer exists. Epoch is not a substitute for quiescence.

### Result schema and invalidation key

**P:** add a separate versioned `calibration` report/index; do not rename existing corpus,
mutation recipes, crash tuples, decisions, or counters.
For each x, store:

```erlang
#{schema_version => 1, compatibility_key => Key,
  input_id => SHA256, input_size => N, corpus_ids => [...],
  requested_repeats => R, attempted => A, trusted_repeats => K,
  status => complete | incomplete | incomparable | not_applicable,
  reason => Reason, union_size => UCount, intersection_size => ICount,
  variable_features => [...], frequencies => [{ExactFeature, PresenceFrequency}],
  feature_stability => NumberOrUndefined,
  outcomes => BoundedOutcomeSummaries, outcome_changes => Changes,
  runs => BoundedRunMetadata, witness_inputs => References,
  timing => #{startup_us => ..., repetitions_us => ..., aggregation_us => ...}}.
```

Also include corpus summary, minimum S, unstable count, selected/measured/incomplete
with exact ID lists. Do not retain every rejected recipe/snapshot indefinitely.
Frequencies suffice for I/U/V; raw snapshots/witnesses are a bounded option. Input
bytes themselves must remain verifiable by hash/length in the corpus or a packaged
copy; repeating a ready binary does not require donor/RNG state.

**P.** `Key = SHA256(canonical versioned structure)` with the following mandatory
components; never serialize a noncanonical map as a “portable key”:

| Component | Actual basis / rule |
|---|---|
| Input/scenario | SHA-256 of **bytes + length**, packaged-byte validation; for future scenarios, initial state/config/actions digest, not one message |
| Target/harness | Explicit `{Module,run,1}`, identity of the actual loaded adapter/ordinary harness BEAM (matched code MD5/object digest), harness/reset contract version; selected BuildMap alone does not cover the adapter |
| Selected code | Sorted `{module-name-binary, BuildId, canonical manifest digest}`; schema/instrumentation version, limitations, and toolchain |
| Feature semantics | `clause_outcome_probe / exact_presence / normalization_v1 / target_process`; version/code digest of the active EFZ runtime/executor/validator; manual uses a separate namespace/explicit ID contract |
| Compatibility epoch | Newly proposed portable digest of the listed schemas/semantics; **no existing feedback_epoch**; policy/schema change requires a new series |
| Execution settings | Timeout, backend implementation, validation strategy, OTP/ERTS/arch, scheduler settings, target configuration, protocol/reset mode; affect environment/load even with comparable features |
| Trial protocol | R, warmup count/inputs, cold/steady policy, consecutive versus corpus rounds/fixed permutations/fresh VM; control corpus/order digest for order-dependent experiments |
| Outcome policy | Outcome-normalization version, without silently discarding return changes/volatile values |

`ets` and `ets_member` have the same feature semantics and comparable F, but
a result cache must not be silently reused across different timing/config
variants. `execution_ref`, PID, Tid, monotonic timestamps, and parent queue
index are not portable identities. Selection/mutation seed is not needed to
regenerate already frozen x; if it defined the control corpus/order,
their identities and provenance are retained. A prepared descriptor cannot be saved
as a reusable artifact; a new VM creates a new plan.

This is an **experiment compatibility** key, not proof that unknown
shared-VM contents are identical. In unreset-VM mode, automatic cache reuse between jobs
based on this key alone should be disabled. Save separate observation series
with the same compatibility key; do not combine their repeats into a new R or substitute
old “100%” results for a new run. Reuse is allowed only under a separately
confirmed initial-state/reset contract and selected freshness policy.
Job ID/time distinguish records but do not become input/feature identity.

Current formats are Erlang report maps/`term_to_binary` and pretty-print in escript;
EFZR is a separate format for a particular mutation recipe, not a calibration database.
A minimal new CLI `scripts/calibrate.escript` could call the proposed API and
save a separate versioned `.term` report. The project has no JSON API/encoder;
do not add a dependency for one. If JSON export is later required, output binary IDs
as hex, undefined score as null + reason, and omit runtime handles; the schema
is equivalent to the report map. This is proposed export, not current functionality.

### Initiators, novelty, and recording exactly once

**P.** Implementation order: offline frozen corpus first; then opt-in report-only
initiators at campaign startup, after a new interesting input, and on an explicit corpus
snapshot check. Changing build/manifest/schema **invalidates** results and requires
fresh preparation; do not support live hot reload in the current campaign.

The offline path has no `efz_feedback:evaluate/3`, `efz_corpus:add/2`, selector/mutator,
or stats restart. In a campaign, capture the original full RunResult in
`efz_worker:execute/4` immediately after line 60 and use it as the first of R repeats,
then perform R−1 observation repeats of those bytes. Their separate queue does not
advance staged cursors, RNG, or mutation iteration, or change parent/recipe.
Existing feedback/retention is invoked **exactly once for the original result**,
in its original order; calibration observations are not merged into Global.

Initial seeds remain baseline entries; the ordinary seed pass with reason
`seed_calibration` stays intact and does not become a mutation discovery. Historical
baseline/candidate streams retain their contract with the feature disabled.
Enabled extra executions inevitably alter timing/VM side effects;
for targets without reset, independence after this insertion requires checking, not
a promise of an identical campaign stream.

Attach repeat results through a separate `Report.calibration` index by
content/key. Current `efz_corpus:add/2` does not update existing-input metadata;
do not misuse it for reinsertion. The first version needs no new corpus-update
API. Original input/metadata/added_at/recipes and discovery count remain unchanged.
No separate scorer/last-new-coverage timestamp exists; do not introduce one accidentally
or reinitialize `stats.started_at` for a stability check.

Save outcome variation and new calibration crash witnesses with provenance
`stability`, raw input, and actual result; do not discard findings because S is low or
count them as mutation discoveries. Existing crash storage can be used
for witness bytes/results with extra metadata and separate repeat accounting.
Crash-only probe observations still do not suppress future successful novelty.

A later **separate** decision to switch search to stable-only feedback would
require a deferred single transaction `G_before + original result + series +
compatibility epoch -> one commit`. Repeated evaluate calls for
R runs or merge(U) cannot provide this: the latter may contain crash-only/variable features.
Such retention and scheduler changes require their own ADR/tests and are outside
the proposed report-only stage. Automatic unstable-seed deletion, probe masking,
crash suppression, and baseline-status reassessment are not proposed here.

### Cost and separate statistics

**P, complexity estimate, not a new benchmark:** offline processing of N unique inputs needs
`N*R` measured executions (+ explicitly selected warmup). When the original
seed/candidate result is reused, the first run is already done: add `R−1` per input.
This estimate needs no new Phase 2.1 backend-throughput measurement.

Let P be manifest probe count, H_r unique hits in a repeat, and T_r hook calls.
Plan preparation uses O(P) storage once; publications depend on T_r.
`tab2list` is O(H_r), sorting O(H_r log H_r), prepared validation uses membership over
H_r; per_execution also builds an allowed set O(P) each time. Hash-map frequency
aggregation is expected O(sum H_r), memory O(|U_x|), and final output is sorted.
Saving all raw F would cost O(sum H_r), so it is bounded and optional; frequencies
do not require R copies of every set. Snapshot/result copying and ETF serialization are also
proportional to data and must be measured separately from target time.

In diagnostics, the four-probe plan occupied 5 ETS rows (4 + marker), 3,128 bytes
on both backends. This is one live plan, **not peak or total campaign memory**.
After experiments, coverage/plan tables were absent. Orphan targets from intentional
coordinator kill were cleaned up **by the diagnostic harness**, not automatically by the engine;
this cannot be hidden behind a final “no leaks” statement. Lifecycle tests separately
confirm normal cleanup after caller/cancel/shutdown.

Proposed additive counters: `stability_attempts`, `stability_completed`,
`stability_missing`, `stability_target_failures`, `stability_infra_failures`.
Do not increment `stats.executions`/`discoveries`/`rejections` for repeats; retain
existing `calibrations` as the initial-seed-pass counter for compatibility.
Wall time: add `stability_us`, `stability_in_mutation_us`,
`mutation_active_us = existing mutation_us - stability_in_mutation_us`.
Existing `mutation_us` can remain the wall time of the original phase; new throughput reporting
uses **mutation executions / mutation_active_us**, not R repeats in the numerator.
Report startup/seed phase, aggregation, serialization, and fresh-VM startup separately.
With the feature disabled, existing timings/counters/stream remain unchanged.

## 9. Implementation plan and acceptance criteria

All changes below are **proposed**, not present in the code today.

| Stage | Files/dependencies | Readiness criterion | Disablement and compatibility |
|---|---|---|---|
| 1. Prerequisites | `src/efz_executor.erl`, with guard `src/efz_cov_rt.erl`; `test/efz_backend_tests.erl`, new focused cases | Terminal origin distinguishes caught exit from kill; metadata does not promise tree completeness; owner loss abort/dirty; caught broken context fails closed; current 62/3 remain | Outcome tuples and run/3 preserved; no default backend/worker changes |
| 2. Snapshot admission contract | Executor metadata + proposed `src/efz_stability.erl`; manifest/preflight reuse | Full immutable F after root DOWN and before store destruction; series checks scope/build/cleanup; empty != missing, timeout prefix != full | Snapshot backend code is not replaced; existing feedback does not depend on the new observer |
| 3. Offline collector | Proposed `src/efz_calibration.erl`, `scripts/calibrate.escript`, permitted internal modules in transform denylist | Frozen bytes, R/state protocol, live plan owner, same run/4; versioned keys; bounded cancellation/limits; no novelty side effects | Explicit separate call only; current campaigns do not use collector |
| 4. Regression suite | Proposed `test/efz_stability_tests.erl`, calibration integration suite, existing backend/semantic tests | 50% vector, equal-size sets, frequency vs multiplicity, corpus-masking trap, R<2/empty/incomplete/incomparable; A→B→A, child scope, fresh-VM IDs; exception/kill/timeout/owner/cancel; corruption/build mismatch | Tests do not fix performance thresholds or alter expected old probe/outcome sets |
| 5. Campaign report-only integration | `efz_config`, `efz_worker`, `efz_stats`, report docs; optional index without corpus reinsertion | First result + R−1 repeats; original feedback exactly once; no RNG/cursor advance; separate times/counters; witness failures are not hidden | **`stability => disabled` by default**; explicit enablement, configurable R/95/90; old baselines run without a new series |
| 6. Reporting/measurement | CLI/README/coverage documentation, short fixed-budget overhead experiment | Per-input rows, weighted corpus/min/unstable/subset membership; actual overhead, cold/warm distinction; JSON only when needed | Existing reports/EFZR/CLI preserved; additive versioned section |

Implementation must not begin by repeating `efz:start` for every input: that
confuses seed initialization with stability, creates separate feedback state, and does not
reset the whole VM. Nor should scheduler count/target rand seed be changed for
a prettier percentage. The main mode stays standard; altered runtime is a separate
labeled diagnostic experiment.

Open external questions are limited to what cannot be learned from this checkout:
the reset/warmup/initial-state contract of a particular real target and whether
the chosen R/95/90 are justified on it. Cowboy harness/dependencies are absent; universal
independence of real Erlang applications has not been verified. For the described root-only
engine contract, owners, snapshots, failure paths, and initial implementation points
are established; no hidden Go/OTP application runner need be assumed.

## 10. Reproducing diagnostics without permanent fixtures

The sources below are for audit use only. They are not included in the application or build
profiles and do not implement a production calibration API. One `audit_sites` is compiled
with ordinary automatic instrumentation; the other modules provide controlled
inputs, state, and ACK. Kill experiments first receive a message after a completed
probe; no sleeps are used to prove publication. Every created child is
explicitly terminated, and the VM-loss test kills only its own external helper.

From the `efz/` root:

```sh
AUDIT_DIR=$(mktemp -d /tmp/efz-calibration-audit.XXXXXX)
python3 - "$AUDIT_DIR" <<'PY'
from pathlib import Path
import re,sys
text=Path('docs/calibration-readiness.md').read_text()
blocks=re.findall(r'<!-- audit-source: ([a-z_.]+) -->\n```erlang\n(.*?)\n```',text,re.S)
assert {name for name,_ in blocks} == {'audit_sites.erl','audit_target.erl','audit_background.erl','audit.escript','existing_example.escript'}
for name,source in blocks:
    Path(sys.argv[1],name).write_text(source+'\n')
PY
rebar3 compile > "$AUDIT_DIR/compile.log" 2>&1
rebar3 eunit > "$AUDIT_DIR/eunit.log" 2>&1
rebar3 ct > "$AUDIT_DIR/ct.log" 2>&1
escript "$AUDIT_DIR/audit.escript" "$AUDIT_DIR" > "$AUDIT_DIR/diagnostic.log" 2>&1
escript "$AUDIT_DIR/existing_example.escript" "$AUDIT_DIR" > "$AUDIT_DIR/existing-example.log" 2>&1
```

Do not silently add `+S 4:4` to this reproduction: the original main and fresh controls
used standard configuration. Check each command's exit status; log files
alone do not prove success. This script intentionally detects the described
current limitations with assertions; after future fixes, the expected audit
result must be reconsidered rather than using the old script as a policy test.

<!-- audit-source: audit_sites.erl -->
```erlang
-module(audit_sites).
-export([a/0,b/0,c/0,d/0]).
a()->a.
b()->b.
c()->c.
d()->d.
```

<!-- audit-source: audit_target.erl -->
```erlang
-module(audit_target).
-export([run/1]).
run(<<"a">>)->audit_sites:a(),audit_sites:b(),audit_sites:c(),ok;
run(<<"b">>)->audit_sites:a(),audit_sites:b(),audit_sites:d(),ok;
run(<<"only_a">>)->audit_sites:a();
run(<<"only_b">>)->audit_sites:b();
run(<<"alternate">>)->
 N=persistent_term:get({?MODULE,alternate},0),persistent_term:put({?MODULE,alternate},N+1),
 case N rem 2 of 0->run(<<"a">>);1->run(<<"b">>) end;
run(<<"state_a">>)->case persistent_term:get({?MODULE,dirty},false) of false->audit_sites:c();true->audit_sites:d() end;
run(<<"state_b">>)->persistent_term:put({?MODULE,dirty},true),audit_sites:b();
run(<<>>)->{error,invalid_input};
run(<<"empty">>)->ok;
run(<<"halt">>)->audit_sites:a(),erlang:halt(23);
run(<<"hold">>)->run({hold,persistent_term:get({?MODULE,observer}),campaign});
run({repeat,N})->lists:foreach(fun(_)->audit_sites:a() end,lists:seq(1,N)),ok;
run({fail,Kind})->audit_sites:a(),case Kind of error->error(artificial);throw->throw(artificial);exit->exit(killed) end;
run({hold,P,Tag})->audit_sites:a(),P!{published,Tag,self(),get('$efz_execution_context')},receive finish->ok end;
run({local_state})->
 Before={get(audit_user_key),process_info(self(),messages),rand:export_seed()},
 put(audit_user_key,dirty),self()!audit_old_message,rand:seed(exsplus,{1,2,3}),audit_sites:a(),Before;
run({child,Kind,P,Copy})->
 audit_sites:a(),C=get('$efz_execution_context'),
 F=fun()->Before=get('$efz_execution_context'),
   case Copy of true->efz_cov:attach(C);false->ok end,
   P!{child_ready,self(),Before},receive go->ok end,
   Result=try audit_sites:c(),ok catch error:E->{error,E} end,
   P!{child_done,self(),Result}
 end,
 Child=case Kind of spawn->spawn(F);spawn_link->spawn_link(F);spawn_monitor->{CP,_}=spawn_monitor(F),CP end,
 {child,Child};
run({background,Bg})->audit_sites:a(),gen_server:call(Bg,work);
run({background_timer,Bg,P})->audit_sites:a(),erlang:send_after(0,Bg,{work,P}),ok;
run(<<"bad_context_caught">>)->put('$efz_execution_context',bad_context),try audit_sites:a() catch error:_->caught end;
run(<<"broken_table_caught">>)->C=get('$efz_execution_context'),put('$efz_execution_context',setelement(4,C,make_ref())),try audit_sites:a() catch error:_->caught end.
```

<!-- audit-source: audit_background.erl -->
```erlang
-module(audit_background).
-behaviour(gen_server).
-export([init/1,handle_call/3,handle_cast/2,handle_info/2]).
init([])->{ok,#{}}.
handle_call(work,_,S)->audit_sites:c(),{reply,get('$efz_execution_context'),S}.
handle_cast(_,S)->{noreply,S}.
handle_info({work,P},S)->audit_sites:c(),P!{background_done,get('$efz_execution_context')},{noreply,S}.
```

<!-- audit-source: audit.escript -->
```erlang
#!/usr/bin/env escript
-mode(compile).
main([D,"fresh",Out])->
 paths(D),{ok,AB}=file:read_file(filename:join(D,"artifact.term")),A=binary_to_term(AB),
 {ok,Ms}=efz_instrument:preflight([A]),{ok,P}=efz_cov_manifest:prepare(automatic,Ms),
 R=run(<<"a">>,options(ets,P)),ok=efz_cov_manifest:release(P),
 ok=file:write_file(Out,term_to_binary(#{result=>R,online=>erlang:system_info(schedulers_online)}));
main([D,"halt",_Out])->
 paths(D),{ok,AB}=file:read_file(filename:join(D,"artifact.term")),{ok,Ms}=efz_instrument:preflight([binary_to_term(AB)]),
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),run(<<"halt">>,options(ets,P));
main([D])->
 paths(D),put(events,[]),
 lists:foreach(fun(M)->File=filename:join(D,atom_to_list(M)++".erl"),
   {ok,M}=compile:noenv_file(File,[debug_info,warnings_as_errors,{outdir,filename:join(D,"plain")}])
 end,[audit_target,audit_background]),
 {ok,A}=efz_instrument:compile(filename:join(D,"audit_sites.erl"),
   #{modules=>[audit_sites],source_root=>D,outdir=>filename:join(D,"targets")}),
 ok=file:write_file(filename:join(D,"artifact.term"),term_to_binary(A)),
 {ok,[M]}=efz_instrument:preflight([A]),
 put(identities,maps:from_list([{maps:get(function,X),{audit_sites,maps:get(build_id,M),maps:get(probe_id,X)}}||X<-maps:get(probes,M)])),
 OTPFile=filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"]),
 emit(environment,#{otp_file=>file:read_file(OTPFile),otp=>erlang:system_info(otp_release),erts=>erlang:system_info(version),
  architecture=>erlang:system_info(system_architecture),schedulers=>erlang:system_info(schedulers),
  online=>erlang:system_info(schedulers_online),erl_flags=>os:getenv("ERL_FLAGS"),
  compiler=>compile:module_info(md5),manifest=>M,defaults=>efz_config:defaults()}),
 lists:foreach(fun(B)->suite(B,[M]) end,[ets,ets_member]),
 campaign_cases(A),fresh_vms(D),hot_code(D,A,[M]),
 []=tables(),emit(final_resources,#{coverage_and_plan_tables=>tables()}),
 Events=lists:reverse(get(events)),
 ok=file:write_file(filename:join(D,"events.term"),term_to_binary(Events)),
 ok=file:write_file(filename:join(D,"events.txt"),unicode:characters_to_binary(io_lib:format("~tp.~n",[Events]))),
 io:format("ALL DIAGNOSTIC ASSERTIONS PASSED (~B records)~n",[length(Events)]).
paths(D)->true=code:add_patha(filename:absname("_build/default/lib/efz/ebin")),
 ok=filelib:ensure_dir(filename:join([D,"plain","x"])),true=code:add_patha(filename:join(D,"plain")).
options(B,P)->#{coverage=>automatic,coverage_backend=>B,coverage_plan=>P}.
run(I,O)->efz_executor:run(audit_target,I,1000,O).
hits(R)->ok=maps:get(coverage_status,R),maps:get(coverage,R).
ids(Names)->lists:sort([maps:get(N,get(identities))||N<-Names]).
emit(K,V)->put(events,[{K,V}|get(events)]),io:format("PASS ~tp~n",[K]).
series(Sets)->
 R=length(Sets),U=lists:foldl(fun ordsets:union/2,[],Sets),
 F=lists:foldl(fun(S,M)->lists:foldl(fun(X,A)->A#{X=>maps:get(X,A,0)+1} end,M,ordsets:from_list(S)) end,#{},Sets),
 I=lists:sort([X||{X,N}<-maps:to_list(F),N=:=R]),
 Score=case R>=2 andalso U=/=[] of true->100*length(I)/length(U);false->not_applicable end,
 #{r=>R,union=>U,intersection=>I,variable=>ordsets:subtract(U,I),frequencies=>F,score=>Score}.
suite(B,Ms)->
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),O=options(B,P),
 First=[run(<<"a">>,O)||_<-lists:seq(1,3)],[H,H,H]=[hits(X)||X<-First],H=ids([a,b,c]),
 #{score:=100.0}=Stable=series([hits(X)||X<-First]),emit({B,deterministic},#{runs=>First,series=>Stable}),
 persistent_term:erase({audit_target,alternate}),
 Alt=[run(<<"alternate">>,O)||_<-lists:seq(1,3)],As=[hits(X)||X<-Alt],
 [3,3,3]=[length(X)||X<-As],#{score:=50.0}=S=series(As),
 [F1,F2,F3]=As,F1=F3,F2=ids([a,b,d]),
 50.0=maps:get(score,series([F2,F1,F2])),
 Collapsed=series([ordsets:union(X,Y)||{X,Y}<-lists:zip(As,[F2,F1,F2])]),100.0=maps:get(score,Collapsed),
 emit({B,alternation},#{runs=>Alt,series=>S,corpus_input_feature_score=>50.0,wrong_collapsed_score=>100.0}),
 R1=run({repeat,1},O),R100=run({repeat,100},O),H1=hits(R1),H1=hits(R100),H1=ids([a]),
 emit({B,multiplicity},#{once=>R1,hundred=>R100}),
 [AA,BB,AA]=[hits(run(X,O))||X<-[<<"only_a">>,<<"only_b">>,<<"only_a">>]],
 []=ordsets:intersection(AA,BB),
 Perms=[[<<"only_a">>,<<"only_b">>],[<<"only_b">>,<<"only_a">>]],
 Rows=[lists:sort([{X,hits(run(X,O))}||X<-Order])||Order<-Perms],[Row,Row]=Rows,
 emit({B,aba},#{a=>AA,b=>BB,permutations=>Rows}),
 persistent_term:erase({audit_target,dirty}),DA1=hits(run(<<"state_a">>,O)),_=run(<<"state_b">>,O),DA2=hits(run(<<"state_a">>,O)),
 #{score:=+0.0}=Dirty=series([DA1,DA2]),persistent_term:erase({audit_target,dirty}),DA1=hits(run(<<"state_a">>,O)),
 emit({B,shared_state},#{without_reset=>Dirty,after_explicit_fixture_reset=>DA1}),
 L1=run({local_state},O),L2=run({local_state},O),{ok,{undefined,{messages,[]},undefined}}=LO=maps:get(outcome,L1),LO=maps:get(outcome,L2),
 emit({B,local_state},#{runs=>[L1,L2]}),
 E=run(<<>>,O),E2=run(<<"empty">>,O),[]=hits(E),[]=hits(E2),{ok,{error,invalid_input}}=maps:get(outcome,E),
 #{score:=not_applicable}=EmptySeries=series([[],[]]),emit({B,empty},#{invalid_return=>E,empty_snapshot=>E2,series=>EmptySeries}),
 Failures=[run({fail,K},O)||K<-[error,throw,exit]],
 lists:foreach(fun(X)->H1=hits(X) end,Failures),emit({B,exceptions},Failures),
 concurrent(O),terminations(B,O),children(B,O),background(B,O),live_snapshot(B),
 Bad=run(<<"bad_context_caught">>,O),[]=hits(Bad),{ok,caught}=maps:get(outcome,Bad),
 Broken=run(<<"broken_table_caught">>,O),{error,_}=maps:get(coverage_status,Broken),{infrastructure,_}=maps:get(outcome,Broken),
 emit({B,context_interference},#{malformed_context_caught=>Bad,invalid_table_caught=>Broken}),
 {efz_cov_plan,1,PT,_}=P,emit({B,live_plan},#{owner=>ets:info(PT,owner),protection=>ets:info(PT,protection),rows=>ets:info(PT,size),bytes=>ets:info(PT,memory)*erlang:system_info(wordsize)}),
 ok=efz_cov_manifest:release(P),undefined=ets:info(PT),
 Disposed=run(<<"empty">>,O),{error,invalid_coverage_plan}=maps:get(coverage_status,Disposed),
 emit({B,disposed_empty},Disposed).
async(I,T,O)->Parent=self(),Tag=make_ref(),{C,M}=spawn_monitor(fun()->Parent!{done,Tag,efz_executor:run(audit_target,I,T,O)} end),{C,M,Tag}.
ready(Tag)->receive {published,Tag,T,C}->{T,C} after 3000->error(no_publication_ack) end.
finished({C,M,Tag})->R=receive {done,Tag,X}->X after 4000->error(no_result) end,
 down(M,C),R.
down(M,P)->receive {'DOWN',M,process,P,_}->ok after 3000->error(missing_down) end.
table({efz_context,1,_,{ets_member,T},_})->T;table({efz_context,1,_,T,_})->T.
concurrent(O)->
 Q1=make_ref(),Q2=make_ref(),C1=async({hold,self(),Q1},3000,O),C2=async({hold,self(),Q2},3000,O),
 {T1,X1}=ready(Q1),{T2,X2}=ready(Q2),false=element(3,X1)=:=element(3,X2),false=table(X1)=:=table(X2),
 T1!finish,T2!finish,R1=finished(C1),R2=finished(C2),A=ids([a]),A=hits(R1),A=hits(R2),
 undefined=ets:info(table(X1)),undefined=ets:info(table(X2)),
 emit({maps:get(coverage_backend,O),concurrent},#{first=>R1,second=>R2,separate_refs_and_tables=>true}).
terminations(B,O)->
 lists:foreach(fun(Kind)->Q=make_ref(),H={Caller,CM,_}=async({hold,self(),Q},case Kind of timeout->1000;_->3000 end,O),
 {T,C}=ready(Q),Owner=element(5,C),TM=monitor(process,T),OM=monitor(process,Owner),
 {ok,Before}=efz_cov:snapshot(C),Before=ids([a]),
 case Kind of
  kill->exit(T,kill),R=finished(H),{exit,killed}=maps:get(outcome,R),Before=hits(R),down(TM,T),down(OM,Owner),emit({B,kill},R),
    Caught=run({fail,exit},O),Keys=[outcome,target_outcome,coverage_status,coverage,builds],
    true=maps:with(Keys,R)=:=maps:with(Keys,Caught),emit({B,exit_origin_ambiguity},#{caught_exit=>Caught,external_kill=>R});
  timeout->R=finished(H),{timeout,1000}=maps:get(outcome,R),Before=hits(R),down(TM,T),down(OM,Owner),emit({B,timeout},R);
  caller_death->exit(Caller,kill),down(CM,Caller),down(TM,T),down(OM,Owner),emit({B,caller_death},#{snapshot_returned=>false});
  coordinator_kill->exit(Owner,kill),R=finished(H),down(OM,Owner),true=is_process_alive(T),
    {infrastructure,{coordinator_down,killed}}=maps:get(outcome,R),{error,coordinator_down}=maps:get(coverage_status,R),
    []=maps:get(coverage,R),exit(T,kill),down(TM,T),emit({B,coordinator_kill},#{result=>R,target_was_alive_after_result=>true,diagnostic_harness_killed_orphan=>true})
 end,undefined=ets:info(table(C))
 end,[kill,timeout,caller_death,coordinator_kill]).
children(B,O)->
 lists:foreach(fun({Kind,Copy})->R=run({child,Kind,self(),Copy},O),{ok,{child,CP}}=maps:get(outcome,R),
 receive {child_ready,CP,undefined}->ok after 3000->error(no_child_ready) end,
 true=is_process_alive(CP),CM=monitor(process,CP),Q=make_ref(),H=async({hold,self(),Q},3000,O),{T,_}=ready(Q),
 CP!go,CR=receive {child_done,CP,V}->V after 3000->error(child_not_done) end,down(CM,CP),
 case Copy of false->ok=CR;true->{error,{efz_infrastructure,invalid_coverage_table}}=CR end,
 T!finish,Next=finished(H),A=ids([a]),A=hits(R),A=hits(Next),
 emit({B,child,Kind,Copy},#{parent=>R,next_execution=>Next,child_result=>CR,child_context_before_attach=>undefined})
 end,[{spawn,false},{spawn_link,false},{spawn_monitor,false},{spawn,true}]).
background(B,O)->
 {ok,Bg}=gen_server:start(audit_background,[],[]),
 R=run({background,Bg},O),{ok,undefined}=maps:get(outcome,R),
 Timer=run({background_timer,Bg,self()},O),receive {background_done,undefined}->ok after 3000->error(no_timer_ack) end,
 A=ids([a]),A=hits(R),A=hits(Timer),ok=gen_server:stop(Bg),emit({B,background},#{otp_call=>R,timer=>Timer}).
live_snapshot(B)->
 C=efz_cov:open(B),FakeRef=make_ref(),Copied=setelement(3,C,FakeRef),Parent=self(),
 {Writer,Mon}=spawn_monitor(fun()->efz_cov:attach(Copied),audit_sites:a(),Parent!writer_ready,
   receive write_more->audit_sites:b() end,Parent!writer_finished end),
 receive writer_ready->ok after 3000->error(no_writer_ack) end,
 {ok,First}=efz_cov:snapshot(C),First=ids([a]),
 Writer!write_more,receive writer_finished->ok after 3000->error(no_second_ack) end,down(Mon,Writer),
 {ok,Second}=efz_cov:snapshot(C),Second=ids([a,b]),ok=efz_cov:close(C),
 emit({B,unguarded_snapshot_and_ref},#{before_quiescence=>First,after_quiescence=>Second,changed_reference_accepted=>true}).
campaign_cases(A)->
 lists:foreach(fun(Kind)->
  persistent_term:put({audit_target,observer},self()),
  {ok,_}=efz:start(#{target=>audit_target,artifacts=>[A],seeds=>[<<"hold">>],max_iterations=>0,timeout=>3000}),
  {T,C}=ready(campaign),Owner=element(5,C),TM=monitor(process,T),OM=monitor(process,Owner),
  [{efz_worker,W,worker,_}]=supervisor:which_children(efz_worker_sup),
  case Kind of
   cancel->Await=catch efz:await(0),{'EXIT',{timeout,_}}=Await,true=is_process_alive(T),
     ok=efz:stop(),emit(campaign_cancel,#{await_timeout_did_not_cancel=>true,result_snapshot=>unavailable});
   worker_kill->exit(W,kill),R=efz:await(3000),{infrastructure_failure,{worker_down,killed}}=maps:get(status,R),
     emit(worker_kill,R),ok=efz:stop()
  end,down(TM,T),down(OM,Owner),[]=tables()
 end,[cancel,worker_kill]),
 {ok,_}=efz:start(#{target=>audit_target,artifacts=>[A],seeds=>[<<"only_a">>,<<"only_b">>],max_iterations=>0}),
 R=efz:await(3000),#{calibrations:=2,executions:=0,discoveries:=0}=maps:get(stats,R),
 [seed_calibration,seed_calibration]=[maps:get(retention_reason,X)||X<-maps:get(decisions,R)],
 emit(seed_initialization,R),ok=efz:stop().
fresh_vms(D)->
 Samples=[begin Out=filename:join(D,"fresh-"++integer_to_list(N)++".term"),
   {0,Text}=child_vm(D,"fresh",Out),ok=file:write_file(Out++".log",Text),
   {ok,Bytes}=file:read_file(Out),binary_to_term(Bytes)
 end||N<-lists:seq(1,3)],
 [R1,R2,R3]=[maps:get(result,X)||X<-Samples],F=hits(R1),F=hits(R2),F=hits(R3),F=ids([a,b,c]),
 B=maps:get(builds,R1),B=maps:get(builds,R2),B=maps:get(builds,R3),
 emit(fresh_vm_same_build,#{samples=>Samples,series=>series([F,F,F])}),
 Out=filename:join(D,"halt-result.term"),{23,Text}=child_vm(D,"halt",Out),false=filelib:is_file(Out),
 ok=file:write_file(filename:join(D,"halt.log"),Text),emit(vm_halt,#{exit_status=>23,snapshot_file=>missing}).
child_vm(D,Mode,Out)->
 Port=open_port({spawn_executable,os:find_executable("escript")},[binary,exit_status,stderr_to_stdout,
   {args,[filename:join(D,"audit.escript"),D,Mode,Out]}]),port_result(Port,<<>>).
port_result(P,Acc)->receive {P,{data,B}}->port_result(P,<<Acc/binary,B/binary>>);{P,{exit_status,N}}->{N,Acc}
 after 10000->port_close(P),error(child_vm_deadline) end.
hot_code(D,A,Ms)->
 {ok,P}=efz_cov_manifest:prepare(automatic,Ms),O=options(ets,P),
 {ok,audit_sites,Plain}=compile:noenv_file(filename:join(D,"audit_sites.erl"),[binary,debug_info,warnings_as_errors]),
 code:purge(audit_sites),code:delete(audit_sites),{module,audit_sites}=code:load_binary(audit_sites,"diagnostic_plain",Plain),
 R=run(<<"a">>,O),[]=hits(R),{ok,ok}=maps:get(outcome,R),
 {error,{loaded_module_identity_mismatch,audit_sites}}=Preflight=efz_instrument:preflight([A]),
 emit(hot_plain_replacement,#{old_plan_result=>R,explicit_preflight=>Preflight}),
 ok=efz_cov_manifest:release(P),code:purge(audit_sites),code:delete(audit_sites),{ok,_}=efz_instrument:preflight([A]).
tables()->[T||T<-ets:all(),lists:member(ets:info(T,name),[efz_execution_coverage,efz_coverage_plan])].
```

<!-- audit-source: existing_example.escript -->
```erlang
#!/usr/bin/env escript
-mode(compile).
main([D])->
 true=code:add_patha(filename:absname("_build/default/lib/efz/ebin")),
 {ok,A}=efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
  #{modules=>[efz_example_parser],source_root=>".",outdir=>filename:join(D,"existing-target")}),
 {ok,Ms}=efz_instrument:preflight([A]),{ok,P}=efz_cov_manifest:prepare(automatic,Ms),
 Rows=[begin Rs=[efz_executor:run(efz_example_target,B,1000,#{coverage=>automatic,coverage_backend=>ets,coverage_plan=>P})||_<-lists:seq(1,3)],
  [H,H,H]=[maps:get(coverage,R)||R<-Rs],true=H=/=[],[ok,ok,ok]=[maps:get(coverage_status,R)||R<-Rs],
  #{input=>B,runs=>Rs,exact_sets_equal=>true,feature_stability=>100.0}
 end||B<-[<<0>>,<<255>>]],
 ok=efz_cov_manifest:release(P),
 ok=file:write_file(filename:join(D,"existing-example.term"),term_to_binary(Rows)),
 io:format("~tp~n",[Rows]).
```
