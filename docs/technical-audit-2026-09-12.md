# EFZ Technical Audit — September 12, 2026

**English** · [Русский](i18n/ru/technical-audit-2026-09-12.md) · [Español](i18n/es/technical-audit-2026-09-12.md) · [简体中文](i18n/zh-CN/technical-audit-2026-09-12.md) · [All languages](i18n/README.md)

## 1. Executive Summary

**EFZ is already a working coverage-guided fuzzer for a synchronous binary target in a single Erlang process. The mutation → execution → coverage → active corpus → next mutation loop is complete. This is confirmed by an actual run, not merely the presence of an API.**

In a separate experiment, the standard efz_mutation_plan, efz_worker, efz_executor, automatic instrumentation and efz_corpus built this chain:

~~~text
corpus id=1: <<>>          initial seed from file
    dictionary_insert "A"
corpus id=2: <<"A">>       new coverage; parent=1
    dictionary_insert "B" at position 1
corpus id=3: <<"AB">>      new coverage; parent=2
    dictionary_insert "C" at position 2
corpus id=4: <<"ABC">>     new coverage; parent=3
~~~

40 real mutations were executed, 41 inputs were delivered exactly to a separate harness, and 40 recipes reconstructed the original bytes. There were three discoveries and one crash. The saved CRASH input reproduced error(test_crash), including in a new VM. Evidence: [e2e.txt](audit-2026-09-12/e2e.txt), [experiment source](audit-2026-09-12/run.escript), [complete ETF report](audit-2026-09-12/e2e-report.term), [fresh replay](audit-2026-09-12/fresh-replay.log).

**Operational boundary:** the successful corpus exists in the memory of a single campaign. There is no built-in seed-directory reader, disk persistence for new successful inputs, queue restoration or universal fuzz CLI. After stop/start, the experiment retained the original set of one seed. Existing escripts save the final report themselves; this is not corpus-service persistence.

**The staged mutator is integrated.** Random mode remains the default and also uses the growing corpus. Claims that “the new mutator exists separately” or “the scheduler only sees initial seeds” do not match the current code.

The three main problems:

1. The user-facing campaign lifecycle is incomplete: a common launcher, seed files, durable corpus and restart.
2. Isolation is limited to the root target process; child execution is not measured automatically, children can remain alive, and global state changes later cases. Successful manifest validation does not prove that the selected target executed instrumented code at all.
3. The staged scheduler can stop before reaching available mutations: 256 valid seeds, dictionary_overwrite/bitflip stages, an unsuitable dictionary and the default max_idle_visits yield zero mutation executions. Standard tests do not cover this case or explicitly assert reuse of a parent discovered through coverage.

The next phase should turn the existing single-worker loop into a reproducible tool: establish ancestry with an end-to-end test, fix premature termination, add corpus input/output and restoration, and formalize execution/coverage boundaries and storage errors. This does not require a new mutation engine, another coverage backend, distributed scheduling or a UI.

## 2. Current Architecture

### Audited checkout and scope

Main repository: /home/anonymous_usr/erl:fuzz/efz, branch main, HEAD ac09c1f3e938c3a79b369fc6a87d61c1ae739db4, “chore: initialize efz OTP project”. The parent workspace is not a working Git repository.

HEAD does not describe the audited implementation: most src/*.erl, test/, docs/, examples/, fixtures/, bench/ and scripts/ files were already untracked; README.md, rebar.config and src/efz.app.src were modified. The [initial status](audit-2026-09-12/status-before.txt) and [SHA-256 hashes of all 83 original files](audit-2026-09-12/before-sha256.json) were recorded. The adjacent efz.worktrees/agents-condemned-silverfish contains the same 83 files with identical bytes: it is a separate checkout, not a second runtime engine.

After the audit, the SHA-256 hashes of all 83 files still match. Only this report and audit-2026-09-12/ containing evidence and diagnostic sources were added; production code and standard tests were unchanged, and no commit/push was performed. The saved package was rerun from a new temporary directory: diagnostic assertions and fresh replay passed. [Report integrity and structure verification](audit-2026-09-12/verification.json).

All src modules, test components, launch/replay scripts, examples, fixtures, benchmark-driver purposes, and documentation for architecture, coverage, mutation, replay and previous phases were studied. Historical performance numbers were not recalculated and are not used as new evidence. The calibration-readiness.md document contains an audit and proposals; the production calibration/stability collector in its plan is not implemented.

Environment: OTP 27.0 / ERTS 15.0, Rebar3 3.25.0, Linux. rebar.config sets minimum_otp_vsn=27, debug_info, warnings_as_errors, src_dirs=[src,examples/simple_parser], deps=[]. The main application depends on kernel, stdlib and crypto. No Go/Python runtime code, NIF coverage, rebar provider for the fuzz CLI, CI workflow or additional project profiles was found.

### Directory map

| Directory / file | Actual role |
|---|---|
| src/ — 24 Erlang modules and efz.app.src | The only production implementation |
| examples/simple_parser/ | Two modules, an ordinary parser and adapter; included in the normal build |
| examples/automatic/run.escript | A specific random campaign with target/seeds hard-coded in the script |
| examples/staged/ | Staged parser, hex dictionary and a specific campaign with replay |
| examples/cowboy/ | Separate synchronous parse_qs harness, launcher and 14 additional checks; external dependency |
| test/ | EUnit, Common Test and scripted test mutator |
| fixtures/ | Instrumentation semantics, unsupported AST, include/record/tail cases and performance targets |
| scripts/replay.escript | CLI for recipe → bytes only |
| scripts/coverage_bench.escript, bench/ | Benchmarks, profiling, reports and archiving; not campaign services |
| docs/ | Contracts, historical checks and plans; not implementations in themselves |
| _build/ | Built BEAM files and generated manifests/reports/crash artifacts; not the source of truth |

### Actual process tree

~~~text
application controller
└── efz_sup                    supervisor: one_for_all, intensity=0, period=1
    └── efz_fuzzer             temporary dynamic child, gen_server
        ├── efz_corpus         start_link; linked child, NOT a separate efz_sup child spec
        ├── efz_stats          start_link; linked child
        └── efz_worker_sup     linked supervisor: one_for_one, 5/10
            └── efz_worker     one temporary child
                └·· coordinator  spawn_monitor per input; not a supervised child
                    └·· target   spawn_monitor per input; M:run(Input)
~~~

Dotted relationships indicate creation/monitoring, not links. efz_fuzzer also monitors the worker. Implementation: [efz_fuzzer:init/1](../src/efz_fuzzer.erl), lines 17–25; [efz_worker_sup:init/1](../src/efz_worker_sup.erl), line 2; [efz_executor:coordinate/6](../src/efz_executor.erl), lines 25–60.

After an ordinary target exception, the worker continues the campaign. The worker is not restarted: the fuzzer returns infrastructure_failure/worker_down. Failure of the corpus/stats/worker supervisor stops the fuzzer through a trapped EXIT; terminate/2 stops the worker supervisor, then stats and corpus. Global coverage and mutation cursors are not restored after worker failure. At campaign completion the worker remains alive without another iterate: releasing the corpus, prepared ETS plan and all campaign services requires efz:stop/0.

### State ownership

| State | Owner / mechanism | Lifetime |
|---|---|---|
| Active corpus, next integer ID, random selection PRNG | efz_corpus gen_server state; PRNG in its process dictionary | One campaign |
| Global successful coverage, builds | efz_worker.feedback: map + sets | One campaign |
| Mutation plan, explicit RNG, cursors, pending IDs | efz_worker.mutation_state | One campaign |
| Prepared allowed probe set | Protected unnamed ETS efz_coverage_plan; worker owns it | Until worker death |
| Current execution coverage | Public unnamed ETS efz_execution_coverage; coordinator owns it | One input |
| Pointer to current coverage | Target process dictionary, '$efz_execution_context' | One target process |
| Decisions, crash IDs, bounded recipe trace | Worker state | One campaign |
| Counters | efz_stats gen_server | One campaign |
| Final report, await waiters | efz_fuzzer state | Until stop |
| Instrumented BEAM + manifest sidecar | Filesystem; loaded modules use the shared code server | Beyond a single input |
| Crash .input/.term/.recipe | Filesystem, efz_crash:save/4 | Across runs |

Production src does not use persistent_term. It is used by the benchmark-only efz_perf_replay and may be used by a target, but the executor does not clear it.

## 3. Component Inventory

Status evaluates a component's claimed function, not just compilation. PARTIAL also denotes a missing part of the user workflow, with an explicit note that the corresponding module does not exist. STUB would denote an existing placeholder; none was found in the main path. UNUSED means there are no calls from the main runtime, not permission for immediate deletion.

In the table, “Implementation / purpose” combines Purpose and Current implementation; I/O covers Inputs and Outputs. Module X is in src/X.erl unless another path is explicitly given.

| Component | Relevant modules/files; implementation / purpose | Inputs → Outputs | State ownership | Called by → Calls | Status |
|---|---|---|---|---|---|
| Public entry | efz:start/1, stop/0, stats/0, await/1; OTP API | Config map → {ok,Pid} / error; await → report map | App / fuzzer | Erlang caller, examples → application, supervisor, fuzzer | IMPLEMENTED |
| Generic CLI | No separate efz_cli or common run TARGET CORPUS command; examples/*/run.escript contain specific campaigns | Example-specific args → API config | Escript main | shell → efz:start | PARTIAL — generic launcher absent |
| Configuration | efz_config:prepare/1; defaults, callbacks, coverage preflight; mutation schema handled separately | map → {ok,prepared map}/{error,...} | Caller, then worker | fuzzer → instrument, mutation_plan, code | PARTIAL — top-level schema is permissive |
| Harness contract | efz_target; -callback run(binary()) -> term(); runtime does not require the behavior | binary → any term / exception | Target process | executor → M:run/1 | IMPLEMENTED |
| Harness / target selection | Config target atom; callback fixed at run/1; export checked | target atom, artifacts → loaded callbacks | Code server | config → ensure_loaded/function_exported | PARTIAL — no MFA/arity/source loader in the common API |
| Target invocation | efz_executor:run/4, coordinate/6 | Module, Input, timeout, options → result map | Per-case coordinator | worker, recipe → M:run/1 | IMPLEMENTED within one process |
| Input delivery | worker execute/4 → executor; binary is not decoded | binary + parent → identical binary in harness | Worker/coordinator/target | corpus/planner → executor/harness | IMPLEMENTED |
| Worker | efz_worker gen_server, iterate messages | prepared config/corpus → executions/report | Worker | worker_sup → mutator, executor, feedback, corpus, crash, stats | IMPLEMENTED |
| Timeout handling | executor wait_target/5, kill_and_drain/2; deadline + DOWN | timeout integer ms → {timeout,T} | Coordinator | executor → monitor/exit/receive | PARTIAL — root cleanup; descendants are not tracked |
| Exception handling | executor try/catch; infrastructure separated from target failures | Exception/exit → outcome tuple, stack for error/throw | Coordinator + worker | target → feedback/crash | IMPLEMENTED with origin caveats |
| Coverage compiler facade | efz_instrument:compile/2, preflight/1, load/1 | .erl, allowlist, options → BEAM/manifest/artifact map | Filesystem/code server | Caller/config/replay → compiler/PT/manifest | IMPLEMENTED |
| Coverage instrumentation | efz_instrument_pt:parse_transform/2 | Abstract forms → hook-instrumented forms, manifest attribute | Local compile state | compile → efz_cov_rt:hit/1 in generated code | PARTIAL — limited AST, strict default |
| Coverage hook | efz_cov_rt:hit/1; ETS insert / member+insert | Probe identity → ok or tagged error | Per-case ETS through PD context | Instrumented target → ETS | IMPLEMENTED for attached process |
| Coverage context/collection | efz_cov:open/attach/snapshot/close | Backend/context → exact sorted identities | Coordinator owns ETS | executor → ETS/runtime | IMPLEMENTED |
| Coverage identity/validation | efz_cov_manifest; source mappings, exact allowlist, prepared plan | manifest/hits → ok/error, builds map | Worker ETS / immutable maps | config/executor/recipe → ETS/sets/beam_lib | PARTIAL — validates observed IDs, not continuous loaded-code integrity |
| Coverage state/feedback | efz_feedback:new/1,evaluate/3 | Previous set + result + phase → new set + decision | Worker | worker → efz_cov:merge/2 | IMPLEMENTED |
| Corpus | efz_corpus; entries list, input dedup on add, IDs | [binary], add(binary,meta) → entry/list/{ok,id}/{existing,binary} | Corpus gen_server | fuzzer/worker → rand | PARTIAL — RAM only, initial duplicates remain |
| Queue | Same entries; no separate queue service | Ordered entries → selectable entries | Corpus | worker/planner → corpus API | IMPLEMENTED basic queue |
| Seed selection | corpus:select/0 random; mutation_plan:visit/2 staged round-robin | Entries → parent entry | Corpus RNG / worker plan | worker → rand or plan cursor | PARTIAL — idle cutoff can precede a productive stage |
| Random mutator | efz_mutator callback; efz_mutator_random:mutate/2, four operations | binary, #{iteration=>N} → binary | Worker process PRNG | worker random branch → rand/list operations | IMPLEMENTED, legacy/default path |
| Staged mutation | efz_mutation_plan:new/1,next/2 | Plan + current entries → candidate/skip/done/error | Worker | worker staged branch → efz_mutation, dictionary, rand:*_s | PARTIAL — integrated, premature exhaustion |
| Deterministic stages | mutation_plan:deterministic/4, det_op/4 | Stage, binary, index, config → operation/done | Content/config cursors | Planner → mutation primitives | IMPLEMENTED |
| Mutation primitives | efz_mutation:apply_operation/3,apply_operations/3 | binary + concrete ops + limits → ok/skip/error | No mutable state | Planner/recipe/tests → binary/crypto | IMPLEMENTED |
| Havoc | mutation_plan:random_attempts/5,stack/7 | Primary, active entries, explicit RNG → realized stack | Worker plan | Planner → primitives/random_operation | IMPLEMENTED |
| Dictionary | efz_dictionary:normalize/2,load/2; EFZ hex format | binary tokens or hex file → normalized tokens + hash | Prepared mutation config | mutation_plan:prepare → bounded file read | IMPLEMENTED |
| Splicing | mutation_plan:random_operation/6; mutation splice op | Primary + donors from all entries → prefix/suffix binary, donor bytes/hash | Worker plan | Havoc/splice lane → mutation:apply_operation | IMPLEMENTED |
| Recipes | efz_recipe:make/4, encode/decode, regenerate | Primary + realized ops → EFZR data / exact output | Corpus/crash metadata; optional bounded trace | worker/replay → mutation, hash | IMPLEMENTED for staged |
| Replay | recipe:execute/5, execute_file/5; scripts/replay.escript | Explicit target/builds + input → executor result; CLI recipe → file | Fresh prepared plan | Caller/scripts → preflight/executor | PARTIAL — no generic execution CLI, harness identity not pinned |
| Crash storage | efz_crash:fingerprint/3,save/4 | Input/result/meta/dir → .input/.term/[.recipe], crash record | Files + worker crash_ids | worker → file/crypto/recipe | PARTIAL — non-atomic writes, errors crash the worker |
| Statistics | efz_stats:inc/get; worker timing/counts | Counter key → updated counters/map | Stats gen_server | Worker/fuzzer/API → gen_server | PARTIAL — worker_down does not increment the infrastructure counter |
| Supervision | efz_app, efz_sup, efz_fuzzer, efz_worker_sup | Start/stop/death → lifecycle/report | OTP processes | efz/application → links/monitors/supervisors | PARTIAL — per-case coordinator not supervised |
| Parallel workers | config valid accepts only workers=1 | workers>1 → invalid configuration | None | config rejects | PARTIAL — functionality absent, not a dormant pool |
| Persistent campaign state | Corpus/global coverage/queue cursor/RNG restoration not implemented | — | None | — | PARTIAL — crash artifacts and external reports only |
| Manual compatibility | efz_cov:hit/1, executor:run/3; common executor | Manual ID → {manual,Id}; run/3 → outcome | Same execution context | Legacy callers/tests → runtime | LEGACY, explicitly available |
| Old helper APIs | cov:interesting/2, reset_local/0, snapshot/0 | Direct manual helpers | PD/context | No calls in current src/test/examples | UNUSED by the main path |
| Test prerecorded mutator | test/efz_scripted_mutator | iteration → prerecorded binary; parent ignored | None | Phase2/CT/backend tests → lists:nth | UNUSED in production |
| Benchmark replay / measurement | bench/efz_perf*, *.escript, scripts/coverage_bench | Inputs/workloads → timing/ETF/text | Benchmark VM; replay uses persistent_term | Explicit bench scripts → public EFZ APIs | UNUSED production |

## 4. Actual End-to-End Execution Flow

### Common startup

~~~text
Erlang caller / examples/.../run.escript:main
  -> efz_instrument:compile(SourceFile, CompilerConfig)           % explicit preliminary step
  -> efz:start(ConfigMap)
  -> application:ensure_all_started(efz)
  -> supervisor:start_child(efz_sup, efz_fuzzer child spec)
  -> efz_fuzzer:start_link(ConfigMap)
  -> efz_config:prepare(ConfigMap)
       -> efz_mutation_plan:prepare(MutationOptions, Seeds)       % staged only
            -> efz_dictionary:normalize/2, load/2
       -> efz_instrument:preflight(Artifacts)                    % automatic
            -> load/1 -> loaded_manifest/2
       -> code:ensure_loaded(Target), function_exported(Target,run,1)
  -> efz_fuzzer:init(PreparedConfig)
       -> efz_corpus:start_link([binary()], SelectionSeed)
       -> efz_stats:start_link()
       -> efz_worker_sup:start_link(Config#{coordinator=>FuzzerPid})
            -> efz_worker:init(Config)
                 -> efz_cov_manifest:prepare(Mode, Manifests)     % default
                 -> efz_feedback:new(Builds)
                 -> efz_mutation_plan:new(MutationConfig)        % staged
                 -> self() ! iterate
~~~

The artifact descriptor contains a module atom, absolute beam path, manifest path, binary SHA-256 build_id and warnings. Prepared config is an ordinary map, not application env or persistent_term. Artifacts load before worker creation. The loader does not compile a separate uninstrumented harness from a supplied path: the harness must be available to the code server.

### Calibration and the two mutation paths

The worker first copies efz_corpus:all() into pending_seeds. Each initial entry executes once with Phase=calibration; this initializes GlobalCoverage, rather than performing repeated stability calibration.

~~~text
random:
  efz_worker:handle_info(iterate, State)
    -> efz_corpus:select()
       gen_server:call(efz_corpus, select)
       <- #{id:=integer(), input:=binary(), metadata:=map(), added_at:=integer()}
    -> MutatorModule:mutate(Input, #{iteration => N+1})
       <- binary()

staged:
  efz_worker:staged_iteration(State)
    -> efz_corpus:mutation_entries()
       gen_server:call(efz_corpus, mutation_entries)
       <- [#{id:=integer(), input:=binary()}]                     % entire current corpus
    -> efz_mutation_plan:next(PlanMap, Entries)
       <- {candidate, Binary, ProvenanceMap, NextPlan}
        | {skip, Reason, NextPlan}
        | {done, Reason, NextPlan}
        | {error, Reason, NextPlan}
    -> efz_recipe:make(Provenance, Binary, MutationConfig, Builds)
       <- RecipeMap
    -> efz_worker:execute(Binary, #{id=>ParentId}, mutation, State)
~~~

skip only schedules the next iterate. The iteration/max_iterations counter applies to generated and executed candidates; skips and initial calibration do not count toward it.

### Execution, messages and return

~~~text
efz_worker:execute(Input, ParentEntry, Phase, State)
  -> efz_executor:run(TargetModule, Input, TimeoutMs, ExecutorOptions)
       Request = make_ref()
       spawn_monitor(coordinate(Caller, Request, ...))
         monitor(Caller)
         efz_cov:open(Backend)
           <- {efz_context,1,Ref,TableOrBackendTable,OwnerPid}
         spawn_monitor(target fun)
           efz_cov:attach(Context)
             put('$efz_execution_context', Context)
           TargetModule:run(Input)
             -> synchronous target calls
             -> instrumented clause: efz_cov_rt:hit({Module,BuildId,ProbeId})
                  ets:insert(Table, {{probe, Identity}})
           Parent ! {target_result, Ref, self(), Outcome}
         receive target_result / DOWN / caller DOWN / timeout
         wait for target DOWN; on timeout kill_and_drain/2
         efz_cov:snapshot(Context) -> {ok,SortedHits} / {error,...}
         efz_cov_manifest:validate_prepared(...) -> ok / error
         Caller ! {Request, CoordinatorPid, ResultMap}
         after: kill_and_drain(Target), close(Context), demonitor(Caller)
       caller waits for coordinator DOWN, then returns ResultMap
~~~

ResultMap contains execution_ref, outcome, target_outcome, coverage, coverage_status, elapsed_us and builds. The coordinator_down fallback has no target_outcome, coverage=[], builds=#{} and an infrastructure error; it is not an ordinary empty successful snapshot.

Additional messages: standard {'DOWN',Monitor,process,Pid,Reason}; on an ETS error, the hook sends its owner {efz_cov_failure,Ref,Why}. At campaign completion the worker sends {campaign_done,WorkerPid,Report}; the fuzzer replies to saved gen_server callers awaiting the result. Target input does not pass through a file descriptor, stdin, port, socket or the worker's shared mailbox: spawn_monitor closures capture it.

### Feedback and the next generation

~~~text
ResultMap
  -> efz_feedback:evaluate(FeedbackState, ResultMap, Phase)
       successful: New = Observed \ Global
                   Global1 = Global union Observed
       <- {ok,NewFeedback,#{new_probes=>New,retention_reason=>Reason}}
  -> efz_worker:retain(Input, Metadata)
       if Reason = new_coverage:
         efz_corpus:add(Input, Metadata)
           gen_server:call(efz_corpus,{add,Input,Metadata})
           entries := entries ++ [NewEntry]
           next := next + 1
           <- {ok,Id} / {existing,Input}
  -> efz_worker:record_failure(...)                              % separate artifact branch
  -> self() ! iterate
  -> corpus:select() or corpus:mutation_entries()              % see NewEntry
  -> next mutation, where NewEntry can be Parent
~~~

The exact connection: worker lines 42–49, 58–90; corpus lines 12–14; mutation_plan lines 63–76. There is no gap between successful retention and the next selection. This section performs no filesystem operation.

## 5. Harness and Input Delivery

### How the user selects a target

**A minimal run(Input) when is_binary(Input) can run today without changing EFZ internals.** Export run/1, compile/load the module with ordinary Erlang tools and pass target => Module to efz:start/1. A separate adapter is needed only when an existing target does not match run/1 or error classification needs control. The formal efz_target behavior exists; runtime checks the function but does not require a -behaviour attribute.

Automatic mode also needs instrumented artifacts for the modules that will actually be called. You can instrument the module containing run/1 itself, as in the staged example, or a separate parser while leaving the harness ordinary, as in the automatic/Cowboy/audit examples.

| Question | Actual answer / evidence |
|---|---|
| Target module | Config key target, atom; config:valid/1 lines 29–33 |
| Function and arity | Fixed at run/1. function/arity options are not implemented; arbitrary top-level keys can be silently retained |
| Contract | efz_target: -callback run(binary()) -> term() |
| Loading | Artifacts preflight first; then ensure_loaded(Target); no separate compile_harness API |
| Export check | erlang:function_exported(M,run,1), config lines 42–48 |
| Process | New target process for every input; same BEAM VM |
| Invocation | M:run(Input), executor line 34; no explicit apply/3 |
| Success | Any normal return, including {error,...}, false or {invalid,...}, wrapped in {ok,ReturnValue} |
| Error/throw | {crash,Class,Reason,Stack} |
| exit/1 | {exit,Reason}, stack not retained |
| Linked abnormal exit | Can terminate root → monitor DOWN → {exit,Reason}; if the root traps exits and handles the signal, a normal return counts as success |
| Timeout | Only the root is killed and awaited through DOWN; children are not registered |
| Cleanup callbacks | before_input/reset/after_input/cleanup do not exist |
| Application lifecycle | EFZ does not manage target application initialization/shutdown |

For existing targets expecting a list, iolist, arbitrary term or MFA, the user writes the conversion/adapter. In audit_harness, input was passed unchanged to audit_target:parse/1. In the Cowboy harness, bytes go into #{qs=>Input}; standard request_error qs/limit_reached errors are converted to {invalid,...}, while unexpected exceptions propagate.

### One seed from file to target

The production API accepts a ready-made nonempty list of binaries. Neither config nor corpus reads seed files. The available path is:

~~~erlang
{ok, Seed} = file:read_file(SeedPath),       % caller, not an EFZ function
efz:start(#{target => Harness, seeds => [Seed], artifacts => Artifacts, ...}).
~~~

The binary then lives in entry.input, is selected directly or passed to the planner, and the resulting binary follows execute → run/4 → M:run/1 → parser. The audit script does exactly this; file:read_file and fixture writes are outside coverage. These preparatory actions do not replace the core with mocks.

| Type / limit | Random runtime | Staged runtime |
|---|---|---|
| Initial inputs | binary() only; list must be nonempty | Same; at most 4096 initial entries |
| Upper input bound | No common bound in config/worker/executor | max_input_bytes default 4096, allowed 0…1048576 |
| Generated type | Worker checks is_binary | Primitives return binary; planner handles errors/skip |
| Empty binary | Allowed; delete can yield <<>>, mutate(<<>>) gives <<0>> | Allowed; delete/splice can yield <<>> |
| Oversized seed | Accepted with enough memory | prepare rejects oversized_initial_seed |
| Oversized candidate | No common size check | Size checked by operations; skip(size_limit)/error |
| Byte conversions | Complete binary_to_list and list_to_binary for nonempty input | Binary operations; only literal-byte generation uses a list |
| Exact recipe | None | Primary bytes + concrete ops + literal tokens/donors + hash |
| Successful-input persistence | RAM entry only | RAM entry with recipe only |

Input is passed as an Erlang term between corpus, worker, coordinator and target. This is not a zero-copy API: maps/lists and heap data cross process boundaries; refcounted binaries can share backing storage. Binary semantics are unchanged. In staged mode, mutation_entries/0 transfers the entire corpus list each time; snapshots/report also copy structures. This is a later performance concern, not a break in the feedback loop.

Low-level efz_executor:run/4 does not check is_binary(Input) and receives tuples/atoms in tests. This is useful for executor tests but does not broaden the main fuzz loop's binary contract. Replay execute/execute_file limits raw input to one MiB, whereas random mode has no such common limit.

### Case isolation and effects of previous inputs

| Resource | Actual cleanup / potential influence |
|---|---|
| Root process dictionary | Disappears with root; the next root is new. EFZ adds one internal context key |
| Root mailbox | Disappears; result/monitor messages remain in a separate coordinator and do not reach the next case |
| Coverage ETS | New table per case, deleted by coordinator; normal root termination does not destroy it |
| Target-owned ETS | Ordinary owner tables disappear with root; EFZ does not clean up heir transfers or other/child-owned tables |
| Registered root name | Released on root death; names of living children remain |
| Spawned children | No registry/kill-tree; both unlinked and linked children can survive a normal root return |
| Timers | No common cancellation/reset; messages/actions addressed to surviving processes can run later |
| Root monitors/links | Root terminates; EFZ drains its own monitors. Other processes and their relationships are not traversed |
| Application env, persistent_term, code server | Not cleared and shared across cases |
| Files, external services, sockets, NIF state | No universal reset/isolation |

Confirmed A→B→A scenario: input state calls path_a; dirty writes persistent_term; the identical state input then calls path_ab with a different probe set. See [cross_case_state.txt](audit-2026-09-12/cross_case_state.txt).

Unlinked and linked children were confirmed to execute instrumented path_abc with an undefined execution context: root execution coverage remained empty and the child survived the return. A separate child survived a root timeout. The diagnostic script terminated its own children after recording results; **this cleanup is not attributed to EFZ**.

Therefore, successful isolation of root ETS/PD does not guarantee reproducibility for an arbitrary OTP application. erlang:halt, VM/NIF crashes and unbounded consumption of shared memory are likewise not isolated by a separate process.

## 6. Coverage Pipeline

### Mechanism and granularity

EFZ uses its own source parse_transform and an exact ETS set. The main implementation has no OTP native coverage, cover, counters, hit-count buckets or bitmap. Instrumentation occurs ahead of time in compile:noenv_file/2, not on every iteration.

The manifest metric is clause_outcome_probe. The hook is added at the start of the selected clause/outcome body. Actual kinds:

~~~text
function_clause
case_clause
if_clause
receive_clause
receive_after
try_body
try_of_clause
catch_clause
try_after
fun_clause
named_fun_clause
~~~

This is neither edge coverage, complete branch coverage nor line coverage. Two outcomes on the same line have different probe IDs; lines provide source mapping. Entering a clause body does not reveal every transition between clauses or every guard-check outcome. andalso/orelse are traversed as ordinary op nodes: separate true/false probes are not created for the operator. Patterns and guards remain without hooks.

List/binary/map comprehensions, maybe, unknown AST constructs and executable record defaults receive no internal probes. strict=true rejects incomplete instrumentation; strict=false preserves the construct, records manifest limitations and warns. Semantics checks are in phase2_tests:semantics/1, manifest/1, tail/1 and skipped/0. Native/NIF code and unselected modules are entirely outside measurement.

### Identity and source mapping

Full identity:

~~~erlang
{ModuleAtom, BuildIdSHA256, ProbeIdInteger}
~~~

ProbeId starts at 1 in each module and increases through deterministic AST traversal. BuildId is a SHA-256 hash of a tuple containing instrumentation version, OTP release, compile module MD5, normalized preprocessed forms and relevant compiler options. [efz_instrument_pt:parse_transform/2](../src/efz_instrument_pt.erl), lines 35–55; probe/4, lines 109–118.

| Property | Finding |
|---|---|
| Rebuilding identical source/options/toolchain | Stable identity; verified by phase2 determinism |
| Compilation order of different modules | Does not affect local numbering: there is no shared mutable allocator |
| Reordering/adding AST nodes | Can renumber probes; build namespace changes |
| Different builds | Old IDs cannot be mechanically transferred to a new coverage epoch |
| Collisions | Duplicate integers/structural paths are rejected within a valid manifest. No cross-module bitmap aliasing. SHA-256 remains a cryptographic hash, not a mathematical uniqueness guarantee |
| Relocation | Source paths within source_root are normalized, and the relocated-build test passes; external absolute include paths/toolchain changes can change the hash |
| Mapping | Every probe contains function, arity, kind, structural_location, source_file, line and column |

The BEAM contains an efz_manifest attribute; the sidecar contains the same term. The loader compares the sidecar with the BEAM manifest and the already loaded module with the expected manifest. Prohibiting other parse transforms, a module allowlist, excluding EFZ internals/OTP modules and a separate outdir protect consistency of the normal build path.

### Local → snapshot → global

~~~text
local coverage:
    fresh public unnamed ETS set, execution coordinator owner
    row = {{probe, {Module,BuildId,ProbeId}}}
    duplicate hit overwrites the same key

local context:
    {efz_context,1,FreshRef,TableOr{ets_member,Table},Owner}
    target PD '$efz_execution_context'

snapshot:
    ets:tab2list → sorted list of full probe identities
    after root DOWN; observations survive crash/kill/timeout

validation:
    allowed exact identities in protected worker-owned ETS plan
    alternative per_execution: build allowed set from manifests

global coverage:
    worker.feedback.global, Erlang sets
    only successful input coverage is unioned

reset:
    next execution receives a different table, reference and root process
    previous table is deleted; global set is not reset until campaign ends
~~~

ets_member checks ets:member first, then inserts if absent. This optimizes repeated hits in the same set; it is not a separate metric. Prepared/per_execution are two validation strategies, not different collectors. The differential suite checks all four combinations.

### Exact semantics of interesting

[efz_feedback:evaluate/3](../src/efz_feedback.erl), lines 5–22:

~~~text
require Result.builds == Feedback.builds
require coverage_status == ok

if outcome == {ok, _}:
    New = set(Observed) - Global
    Global := Global union Observed
    calibration -> retention_reason = seed_calibration
    mutation and New == [] -> equivalent_coverage
    mutation and New != [] -> new_coverage
else if infrastructure/coverage error:
    stop campaign as infrastructure failure
else:
    target_failure; Global unchanged; new_probes=[]
~~~

**New coverage = a previously unseen full probe identity in a successful execution.** Not a new count, a new combination of known probes, a hash signature or a new bitmap bit. An identical set with different execution multiplicities is uninteresting. A different set that is a subset of Global is also uninteresting.

The tested formula C_new = C_current − C_global is implemented, with success and phase conditions. Crashes/throws/exits/timeouts may have nonempty execution coverage but do not extend the successful global set or corpus. This explicit policy prevents a crash-only probe from suppressing a future useful successful mutation.

Calibration merges successful initial seeds but does not reinsert them or increment discoveries. After evaluate, a successful input's full snapshot is not saved in corpus metadata: new_probes, builds, outcome, input identity and provenance remain. Report.coverage is the entire campaign's union, not coverage of a specific input.

### Feedback reliability boundaries

1. **Unused artifacts.** An automatic campaign with a valid audit_target artifact and a harness that does not call it completed with coverage=[], infrastructure_failures=0. Validation checks validity of the IDs actually observed; an empty list is valid. Successful preflight does not establish that the harness is connected to the selected target. [Evidence](audit-2026-09-12/disconnected_artifacts.txt).
2. **Hot reload.** After preflight, the selected module was replaced by an ordinary uninstrumented build. The next case returned path_a, coverage=[], coverage_status=ok and the old builds map. A prepared plan is a pinned allowlist, not a per-case check of executing code. [Evidence](audit-2026-09-12/hot_reload.txt). README prohibits this reload, but runtime does not detect the violation.
3. **Children.** spawn does not inherit the process-dictionary context. An instrumented child without attach executes the hook as a no-op. The API permits manual context transfer to a child, but this does not add quiescence/tree cleanup to the executor.
4. **Context corruption.** An ETS error sends a sticky failure message, but the malformed-context clause in cov_rt only raises. A target that replaced its context and caught the exception returned success with empty coverage. [Evidence](audit-2026-09-12/caught_malformed_context.txt). Ordinary code clearing the entire process dictionary can also disable the hook.
5. **Coordinator loss.** The target remains alive; the fallback result contains builds=#{}. evaluate can replace the primary coordinator_down error with instrumentation_build_mismatch. This is not a target crash, but the primary cause is lost at campaign-report level.

These points do not invalidate coverage operation within its stated scope: a fresh root process and an unchanged instrumented build. They limit applicability to stateful/async targets and require explicit diagnostics.

## 7. Corpus and Queue Pipeline

**Corpus feedback loop: WORKING within one campaign. Persistent/restart functionality: PARTIAL, not implemented.**

The key module is [efz_corpus.erl](../src/efz_corpus.erl), only 15 lines; its small size hides significant limitations, not the absence of a queue.

| Concept | What actually exists |
|---|---|
| Initial corpus | Config.seeds = [binary()]; an entry is created for every element without initial deduplication |
| Active queue | State.entries; initially seeds, then all successful new-coverage inputs |
| Interesting input | Mutation with outcome {ok,_} and NewProbes ≠ [] |
| Saved input | Successful path: entry.input in RAM. Crash path: .input file |
| Favored input | No concept/score/flag |
| Donor input | Any entry.input in the current active corpus whose content differs from Primary |
| Queue ID | Sequential integer 1…N, allocated by the serial corpus gen_server |
| Content ID | SHA-256 in worker metadata and planner/recipe; initial metadata starts empty |

### Insertion and reuse

retain/2 calls add/2 for new_coverage. Corpus sequentially checks binary equality over the entry list. If no match exists, it appends the entry and increments the next ID. An existing binary returns {existing,Binary}, not an ID; the worker changes retention_reason to existing_input.

Random select/0 calls rand:uniform(length(Entries)) over the **entire current** list. A newly added entry has a nonzero selection probability. Random mode provides no deterministic guarantee of selection before a finite budget ends.

In staged mode, each next receives current mutation_entries/0; the round's ID snapshot follows insertion order. A newly added entry becomes primary in the next round. The donor list in random_operation(splice,...) comes from all current Entries even when pending primary IDs refer to the round's beginning. A new corpus input can therefore become a donor before its first turn as primary.

The experiment confirmed parent=2 for AB and parent=3 for ABC. Additionally, the standard random example created corpus entry <<>> with parent=2, where entry 2 was a previously discovered mutation <<"@">>. The default random loop can also use a newly discovered parent; that example's specific sequence need not repeat without selection_seed.

### Metadata, deduplication and scheduling

| Property | State |
|---|---|
| Duplicate successful mutations | Full binary equality, linear search; SHA is not a deduplication index |
| Duplicate initial seeds | Retained with different integer IDs; a fresh check with two <<"noop">> inputs yielded corpus size=2 and calibrations=2 |
| Parent | Retained mutation has a parent integer ID |
| Mutation depth/generation | No explicit fields; while ancestors are retained, depth follows from parent links |
| Insertion order | List, appended at the end |
| Coverage signature | No separate signature/full successful snapshot; only discovery delta and build namespace |
| Per-entry seed status | No quarantine for crashing/timing-out/unstable seeds; initial failures remain in the active corpus |
| Favored/power/energy | Not implemented |
| Global corpus size/memory bound | No common quota; staged mode limits initial count and input size, not accumulated entries |
| Random starvation | Possible in a finite campaign; uniform probability is not a service guarantee |
| Staged fairness | Round snapshots protect existing entries against continuous growth until the campaign hits the idle cutoff |
| Identical-content staged state | Cursors keyed by content hash + config ID; initial duplicate queue IDs share progress |

### Disk and restart

Corpus does not call file, DETS, disk_log, Mnesia or persistent_term. It has no load/save/resume API. The corpus_dir config option is not interpreted. Successful discoveries receive no disk input file or sidecar.

Examples write the complete report.term after await. Users can manually extract binaries and pass them as seeds to a new campaign, but EFZ does not import them or restore IDs, cursors, PRNG, global coverage and crash index. Repeated seed calibration is also not continuation of an interrupted campaign.

In the experiment, starting again with the same Config reset corpus size from 4 to 1. Thus the runtime feedback loop is not broken between retain and select, but **progress does not survive stop/restart**.

## 8. Mutation Pipeline

### Working operators

“Deterministic stage” means enumeration without random choices. Each concrete efz_mutation operation is deterministic. “Replayable” below refers to normally recorded staged recipes; legacy random does not create recipes itself.

| Mutation | Implementation | Deterministic stage | Replayable | Used by runtime |
|---|---|---|---|---|
| Bit flip | flip_bits: contiguous 1/2/4 bits, MSB-first; legacy random: one bit | Yes, all fitting offsets | Yes, staged | Random; staged bitflip/havoc |
| Byte flip | invert_bytes: 1/2/4 bytes | Yes | Yes | Staged byteflip/havoc |
| Arithmetic | add: 8/16/32 bits, signed delta, modulo 2^W; big/little endian for multiple bytes | Yes, ±1…±max_delta | Yes | Staged arithmetic/havoc |
| Interesting integers | set_integer: 0,1,2,half−2,half−1,half,half+1,max−1,max | Yes, boundary | Yes | Staged boundary/havoc |
| Insert | Concrete binary block, including append boundary | No separate literal stage | Yes | Havoc; legacy inserts one random byte |
| Delete | Delete a nonempty block, down to empty output | No separate stage | Yes | Havoc; legacy one byte |
| Overwrite | Literal block preserving size | No separate literal stage | Yes | Havoc; legacy one random byte |
| Duplicate | Copy a block to an insertion position | No separate stage | Yes | Havoc |
| Dictionary insert | Insert a token at every byte boundary | Yes | Yes, token bytes in recipe | dictionary_insert/havoc |
| Dictionary overwrite | Token at every fitting offset | Yes | Yes | dictionary_overwrite/havoc |
| Splice | prefix(Current,CutA) ++ suffix(Donor,CutB) | No; random cut points/donor | Yes, donor bytes/hash in operation | splice stage and havoc |
| Havoc | Stack of realized operations of depth 1…havoc_depth | No; explicit RNG state | Yes | Staged havoc lane |

All operations are implemented in [efz_mutation:operation/3](../src/efz_mutation.erl); selection/enumeration is in [efz_mutation_plan](../src/efz_mutation_plan.erl), lines 81–187. Width order and offsets are checked by independent bit/block models and enumeration tests.

### Actual staged-execution order

Default stages:

~~~text
bitflip, byteflip, arithmetic, boundary,
dictionary_insert, dictionary_overwrite, havoc, splice
~~~

These are **interleaved round-robin lanes**, not “finish every deterministic stage of each seed, then start havoc, then splice”.

Each visit selects the next corpus ID. For its content/config key, the lane value selects one stage modulo length(Stages). Lane increases; the stage performs at most attempts_per_visit attempts and emits at most one candidate. The next visit to this content uses the next lane even if the current sweep is unfinished. Havoc can therefore run long before the bitflip sweep finishes.

A per-stage cursor stores the next integer mutation index. On skip/no_change, the deterministic index advances. Once exhausted, the stage stays complete; candidates are not materialized ahead of time. The returned Plan can be passed to the next next/2: in-memory resumability works and is tested. No API persists cursor/RNG plans to disk.

### Limits and resources

| Parameter | Default | Allowed range / meaning |
|---|---:|---|
| max_input_bytes | 4096 | 0…1048576 |
| max_block_bytes | 128 | 1…65536 |
| max_token_bytes | 128 | 1…65536; token is also bounded by max_block_bytes |
| max_tokens | 256 | 0…4096 |
| max_dictionary_bytes | 16384 | 0…1048576 |
| max_delta | 8 | 1…128 |
| attempts_per_visit | 8 | 1…1024; maximum attempts, not output count |
| havoc_depth | 8 | 1…32 |
| random_retries | 4 | 1…128, also bounded by the attempts budget |
| max_idle_visits | 256 | 1…100000 consecutive empty visits across the ENTIRE campaign |
| trace_limit | 0 | 0…10000 recipes |
| max_iterations for staged | 1000 if omitted | 0…1000000; infinity prohibited |

There is no separate maximum mutations per seed. The overall limit is the execution budget, finite deterministic search or idle cutoff. Seeds ≤4096 is checked only by staged prepare. Strict mutation options reject unknown keys, unlike the top-level campaign config.

The dictionary is loaded once through bounded reading; the format is one even-length hex token per line, whole-line # comments and blank lines. This is not an AFL dictionary parser. Empty tokens are prohibited; duplicates are sorted/usorted; count/total-byte limits are checked before deduplication. Tokens and dictionary_id are fixed for the campaign.

No-change primitives are skipped; a havoc stack returning to its original Primary is also skipped and can retry. However, identical binaries from different stages/parents are not filtered before execution. Corpus deduplicates only retained bytes; equivalent-coverage executions remain useful for correctness but consume the budget.

### Donors

random_operation(splice,...) receives Entries directly from efz_corpus:mutation_entries(). Donors are lists:usort of all input binaries different from Primary. Selection is not limited to initial seeds. Provenance retains the donor hash and donor binary itself; the operation checks that hash. Splice can produce empty output; identical donors and no-change outputs are handled as skip.

### Premature exhaustion — reproduced defect

The next/2 condition:

~~~erlang
Idle >= maps:get(max_idle_visits,C) orelse complete(State,Entries)
~~~

Both reasons return the same done mutation_exhausted. With 256 unique one-byte seeds, stages=[dictionary_overwrite,bitflip] and dictionary=[<<"AB">>], the first lane has no fitting overwrite for any seed. After 256 visits the campaign stops **before the first bitflip**, although the initial seeds alone have 5120 bitflip candidates.

An actual run yielded calibrations=256, executions=0, generated_candidates=0, infrastructure_failures=0, status={mutation_exhausted,mutation_exhausted}. [edge-cases.log](audit-2026-09-12/edge-cases.log), [reproducer](audit-2026-09-12/edge-cases.escript), mutation_plan lines 51–77.

The mutations.md documentation warns that the idle cutoff does not prove mathematical exhaustion of all mutations. This is therefore not a hidden missing stage implementation, but a practical scheduling-policy defect: a normal configuration can fail to execute any available mutation stage. Stop reasons should be distinct, and progress should be evaluated over a complete traversal of relevant lanes.

### Recipe determinism

Seed + Recipe → exact mutated Input **works** for a realized staged candidate. The recipe contains Primary bytes, primary hash, parent queue ID, stage, concrete operations, limit values, output size/hash, config/dictionary IDs, target_builds, schema/engine/operation versions and original RNG seed.

All random decisions have already become offsets, widths, deltas, literal tokens and donor bytes. regenerate/1 does not perform random selection, corpus lookup or target execution. It checks the Primary hash, limits, operation validity, output size and hash. The EFZR envelope has magic/version, payload length, SHA-256, a bounded ETF scanner and binary_to_term(...,[safe]); compressed ETF and runtime objects are rejected.

This exactly replays an individual candidate; it does not restart the campaign schedule. A recipe does not contain the entire corpus, other seeds' positions or the full PRNG/cursor state at termination. The config hash is provenance, not serialization of the complete original config. Legacy random can be reproduced with fixed mutation and selection RNG seeds in the same environment, but there is no individual random-recipe path.

## 9. Crash/Timeout Handling

### Classification

| Target event | Outcome | Worker behavior |
|---|---|---|
| Normal return of any term | {ok,Term} | May merge coverage and retain input |
| error(Reason) | {crash,error,Reason,Stack} | Saves exact input/metadata and continues |
| throw(Reason) | {crash,throw,Reason,Stack} | Same |
| exit(Reason), including normal/kill | {exit,Reason} | Saves, counts target failure; no stack |
| Uncaught linked exit / external kill | {exit,Reason} from DOWN | Saves; termination origin is not distinguished from a caught exit |
| function_clause/case_clause/badmatch/badarg/badarith/undef | Error class → crash with the corresponding Reason | No special exception whitelist |
| system_limit as an Erlang error | Error class → crash | Actual exhaustion of shared VM memory can terminate the whole VM; not isolated |
| Deadline | {timeout,TimeoutMs} | Saves input/partial observed coverage; timeouts++, global unchanged |
| Tagged efz_infrastructure error / invalid coverage | {infrastructure,...} or coverage failure | Stops campaign; not counted as a target bug |
| User-mutator error/nonbinary output | Infrastructure failure before execution | Not saved as a target crash |

See executor lines 32–39, 62–85; worker lines 58–107. [Exception diagnostics](audit-2026-09-12/exception_classes.txt) explicitly check catch classification for raised error reasons; this is not a real resource-exhaustion experiment for system_limit. Natural pattern/guard/try semantics are separately covered by fixture tests.

The deadline awaits both target_result and root DOWN. If root has sent its result but has not yet terminated, the remaining timeout still applies. If the timeout branch wins, the result remains timeout even when a message races with it. kill_and_drain creates a fresh monitor and waits for actual DOWN, then removes the original monitor with flush. This correctly separates late messages from different cases.

However, the deadline is not an upper bound on the full wall time of run/4 when native code blocks; cleanup receives have no independent external watchdog. Arbitrary child processes are not covered.

### Fingerprint, deduplication and files

[efz_crash:save/4](../src/efz_crash.erl), lines 6–25:

~~~text
crash ID = SHA256(term_to_binary({Class,Reason,first_3_stack_frames}))
exit ID  = fingerprint(exit,Reason,[])
timeout ID = fingerprint(timeout,deadline,[])

base = crash_dir / hex(crash ID) + "-" + hex(SHA256(Input))
base.input   = exact input bytes
base.term    = ETF #{result=>Result, metadata=>Metadata}
base.recipe  = EFZR, only if metadata contains a staged mutation
~~~

Crash-only coverage is retained in result. new_probes=[] in crash metadata reflects policy, not an absence of coverage. Initial-calibration crashes normally have no recipe because no mutation has occurred yet.

Deduplication levels differ: all encounters increment crashes/timeouts; unique_crashes is determined by the worker's signature set. save runs **before** checking the signature set, so different inputs with one signature get different files, while report.crashes contains only the first record of each signature. Repeating the same input/signature overwrites the same paths. Timeouts from different inputs share one signature, while their inputs are saved separately.

The signature does not normalize file paths, lines, reason terms or arguments in stack frames. Reasons containing PID/ref or data-dependent reasons can split one bug into many signatures. Moving the source directory changes the stack path and can change the crash ID for the same logical failure. Build identity is not a separate signature component.

### Storage errors and reproducibility

The .input, then .term, then .recipe writes are sequential, without temporary+rename/transaction. A crash between operations leaves a partial set. Errors from filelib:ensure_dir/file:write_file/recipe:save are handled with ok=..., crashing the worker.

A diagnostic using crash_dir=/dev/null/efz-audit yielded worker_down with {{badmatch,{error,enotdir}},...efz_crash:save/4 line 17...}. Final infrastructure_failures remained 0; the raw triggering input was not saved in a crash artifact, and the emergency report contains only status/stats/corpus. [Log](audit-2026-09-12/edge-cases.log).

Raw saved input can execute through recipe:execute_file/5 with explicitly selected target, artifacts and expected builds. CLI scripts/replay.escript regenerates bytes without running the target. Fresh-VM replay of the actual audit CRASH and the standard staged exception passed.

An exact-input guarantee does not guarantee the same crash on a stateful target. Replay checks selected artifact builds, but not the fingerprint of a separate uninstrumented harness, its environment/dependencies or external state. Continuous replay of the entire campaign is not implemented.

### Fault isolation and concurrency

When the **caller/worker** is abruptly killed, the coordinator normally receives DOWN and cleans up root/ETS; phase2/backend tests cover this. The test called “owner death cleans target and table” kills the caller, not the ETS-owning coordinator; these scenarios must not be conflated.

Killing **the coordinator itself** prevents its after from executing. In the audit, run/4 returned {infrastructure,{coordinator_down,killed}}, but the target was still alive; the diagnostic script stopped it itself. [Evidence](audit-2026-09-12/coordinator_kill.txt).

Multiple workers are currently impossible: config requires workers=1, there is one child spec, and services use singleton names. The A/B race “both saw a new probe, both retain” therefore does not exist within a supported campaign. Compare/merge and insertion run sequentially in one worker; corpus add and integer-ID allocation are serial gen_server operations. A crash ID is a hash, with no separate allocator.

This does not prove readiness for workers>1. Each worker would own its own GlobalCoverage; compare/merge is not a shared transaction with corpus, and crash writes are unsynchronized. The prepared plan and per-execution contexts can support concurrent reads/separate executions, as tested, but shared campaign scheduling/feedback concurrency is not implemented.

## 10. Component Integration Matrix

“Working” refers to a specific connection. Two endpoints without a runtime call do not count as integration.

| Producer | Output | Consumer | Connection | Working | Evidence |
|---|---|---|---|---|---|
| CLI / caller | Config map | efz_config | Escript → efz:start → fuzzer:start_link → config:prepare | PARTIAL: examples/API yes, no common CLI | efz.erl:3–7; fuzzer:6–10; examples/* |
| Config | Target atom, artifacts | Harness loader / executor | preflight + ensure_loaded + run/1 export validation | YES within fixed contract | config:35–48 |
| Seed file | Binary | Initial corpus | Caller file:read_file → seeds | PARTIAL: external glue, no built-in importer | audit run.escript:e2e/2; corpus:init/1 |
| Corpus | Full entry / id,input entries | Mutator | select/0 random; mutation_entries/0 staged | YES | worker:33–49 |
| Mutator | Binary + staged provenance | Worker | Mu:mutate/2 / mutation_plan:next/2 | YES | worker:35–52; EUnit phase3 |
| Worker | Binary, module, timeout, options | Executor | efz_executor:run/4 synchronous call | YES | worker:58–60 |
| Executor / worker | Exact binary | Harness | Fresh monitored root → M:run(Input) | YES | executor:31–40; 41 exact deliveries |
| Harness | Binary / target-specific arguments | Target | Ordinary synchronous Erlang call | YES for a working harness; config does not verify the connection | audit_harness:run/1; Cowboy adapter |
| Target execution | Probe identity | Coverage | Generated efz_cov_rt:hit/1 → attached ETS | YES, root scope | PT:probe/4; cov_rt:hit/1 |
| Spawned child execution | Probe event | Parent input coverage | Context not inherited automatically | NO | child/linked_child diagnostics |
| Coverage | Exact snapshot + status/builds | Feedback | executor result → evaluate/3 | YES | worker:60–65; differential tests |
| Feedback | new_coverage + delta | Corpus | worker retain → corpus:add | YES, RAM | worker:87–91; e2e A/AB/ABC |
| Corpus | Newly inserted entry | Scheduler | Current entries available to select/next rounds | YES, until idle cutoff / stop | corpus:12–14; plan:63–76; ancestry evidence |
| Scheduler | Parent + lane/index/donor set | Mutator | plan visit/attempts or random select | PARTIAL: works, premature idle exhaustion | edge-cases.log |
| Accumulated corpus | Donor binary/hash | Splice | entries → usort donors excluding Primary | YES | mutation_plan:152–157 |
| Interesting successful input | Binary/meta/recipe | Filesystem corpus | Absent | NO | corpus:13 state append only |
| Filesystem corpus | Seeds/queue/state | Restart | Absent | NO | corpus:init/1; restart size=1 |
| Exception/timeout | Outcome, stack, input | Crash storage | worker:record_failure → crash:save | YES with working storage | crash files/replay; storage failure is a separate defect |
| Recipe | Primary + concrete operations | Replay | recipe:regenerate → mutation:apply_operations | YES | 40/40 audit recipes; recipe tests |
| Raw crash + compatible artifacts | Binary/build set | Execution replay | recipe:execute_file → executor:run/4 | YES in fixed-build scope | fresh-replay.log |
| Worker report | Map | API caller | campaign_done → gen_server:reply await | YES | fuzzer:26–39 |

The matrix shows one working system with a missing durable lifecycle and limited isolation. No separate break in mutator → executor → coverage → active corpus was found in supported mode.

## 11. End-to-End Validation Results

### Commands executed

All commands run from efz/. Standard checks ran against the current dirty source tree; production code was unchanged.

| Command | Current-run result | Evidence |
|---|---|---|
| erl -noshell with system_info; rebar3 version | OTP 27, ERTS 15.0; Rebar3 3.25.0 | Environment-diagnostic output |
| rebar3 compile | PASS | Application built, exit 0 |
| rebar3 eunit | PASS: 62 tests | [eunit.log](audit-2026-09-12/eunit.log) |
| rebar3 ct | PASS: 3 tests | [ct.log](audit-2026-09-12/ct.log) |
| rebar3 xref | PASS, exit 0 | [xref.log](audit-2026-09-12/xref.log) |
| rebar3 dialyzer | PASS, exit 0; 26 files analyzed | [dialyzer.log](audit-2026-09-12/dialyzer.log) |
| escript examples/automatic/run.escript | PASS: completed, 500 executions, 4 discoveries, 2 crashes, 1 unique, 0 infra/timeouts | [Archived summary and parent links](audit-2026-09-12/random-example-summary.txt); _build/example-report.term |
| escript examples/staged/run.escript | PASS: completed, 200 executions, 5 discoveries, 7 crashes, 1 unique; actual replay | [staged-example.log](audit-2026-09-12/staged-example.log) |
| escript /tmp/efz-audit-20260912/run.escript /tmp/efz-audit-20260912 | PASS diagnostic assertions; these include confirmation of existing defects | e2e.txt and adjacent *.txt files |
| escript /tmp/efz-audit-20260912/fresh-replay.escript /tmp/efz-audit-20260912 | PASS, fresh VM, exact CRASH, one automatic probe | [fresh-replay.log](audit-2026-09-12/fresh-replay.log) |
| escript /tmp/efz-audit-20260912/edge-cases.escript /tmp/efz-audit-20260912 | Premature exhaustion, ignored config and storage-failure defects reproduced; diagnostic exit 0 | [edge-cases.log](audit-2026-09-12/edge-cases.log) |
| escript examples/cowboy/run.escript ../cowboy check | BLOCKED prerequisite, exit 1; 14 target checks NOT executed | [cowboy-check.log](audit-2026-09-12/cowboy-check.log) |

Exact Cowboy-launcher error:

~~~text
Missing build artifact: /home/anonymous_usr/erl:fuzz/efz/../cowboy/ebin/cowboy_req.beam
Run make in COWBOY_DIR first.
~~~

The external Cowboy build with dependency downloads was not performed in this audit. It is unnecessary to prove EFZ's own loop: a real ordinary audit target was compiled, instrumented and executed through a separate harness. The historical 14 Cowboy checks and documentation performance numbers are not presented as current-run results.

### Checking every step of the requested experiment

| Step | Status | Observation |
|---|---|---|
| 1. EFZ starts | PASS | efz:start/1 accepted audit_harness and automatic artifacts |
| 2. Initial corpus loads | PASS through existing API | Caller read seed.input; corpus id=1, input=<<>> |
| 3. Mutator changes the seed | PASS | Standard dictionary_insert; no custom test mutator |
| 4. Input reaches the harness | PASS | Observer received 41 delivered events; exact byte equality for seed + 40 regenerated candidates |
| 5. Harness calls the target | PASS | audit_harness:run/1 → ordinary audit_target:parse/1 |
| 6. Coverage changes | PASS | Different function_clause probes for unknown/A/AB/ABC/CRASH |
| 7. New coverage is detected | PASS | Three successful discoveries |
| 8. Input enters the corpus | PASS in RAM; disk part absent | IDs 2,3,4 with new_coverage metadata; core does not write successful corpus files |
| 9. New input selected as a seed | PASS, direct evidence | AB.parent=2 (A); ABC.parent=3 (AB), confirmed by recipes |
| 10. Crash saved | PASS | Exact five-byte CRASH, .term and .recipe |
| 11. Crash replay | PASS | regenerate + execute_file; separate fresh-VM execution returned error(test_crash) |
| 12. Corpus after restart | FAIL for the required persistence function | New campaign retained only the initial seed: size=1 |

No mock saver or manual queue insertion of a discovery was used for the missing disk-persistence path. The within-campaign loop was checked separately because its existence does not depend on durable storage. Writing the final audit report does not count as corpus persistence.

The custom campaign ended with {mutation_exhausted,mutation_exhausted}, executions=40: in **this** experiment all dictionary_insert candidates for four entries were actually exhausted (4+8+12+16). This was normal termination, unlike the separate edge case where the same status was returned with unexecuted bitflip candidates remaining.

### Tests by component

| Component | Existing tests | What is proved / missing |
|---|---|---|
| Legacy mutator | efz_mutator_tests | Binary output/empty seed; very superficial checks |
| Mutation primitives | efz_mutation_tests:operators, limits, bit_model, block_model, boundaries | Concrete vectors, independent models, endian/overflow/size bounds |
| Staged plan | enumeration, fairness, finite, random_state, noop_stack, growing_corpus, duplicate_donors | Lazy cursors, deterministic order, PRNG independence, manually growing entry list |
| Recipe replay | efz_recipe_tests, phase3 fresh_replay/replay_boundaries | Operations roundtrip, invalid data, fresh VM, actual crash |
| Corpus | Phase2/phase3 campaigns, smoke, backend variants | Discovery insertion and reports; no separate corpus unit suite/persistence test |
| Coverage compiler / semantics | efz_phase2_tests | Clause kinds, source mapping, same-line distinct probes, strict AST, plain/instrumented outcomes, builds |
| Coverage runtime | efz_backend_tests, phase2 lifecycle, CT | ETS variants, prepared/reference, simultaneous contexts, target/caller kill, timeout |
| Worker / mutator errors | phase3:mutator_failure, exhaustion; smoke | Infrastructure classification, budget/skip accounting |
| Harness | Example adapters + campaigns; efz_config target validation | Real run/1; generic CLI/source loader absent |
| Timeout | executor_tests, phase2, backend, CT | Root DOWN, coverage survives, table cleanup; tree cleanup absent |
| Crashes | Phase2 campaign; phase3 campaign/replay; CT | Raw storage, exceptions, continuation, crash-only coverage policy |
| Full loop | Phase3 real staged campaign; phase2/CT scripted campaign | A real loop exists, but no explicit “discovered entry later became mutation parent” assertion was found in standard EUnit/CT |

The key difference: phase2/CT use efz_scripted_mutator, which ignores the selected parent and takes a predetermined candidate by iteration. Those tests confirm feedback/insertion, not mutation ancestry. Phase3 uses the real planner and checks discovery/recipe/replay; growing_corpus_test manually adds entries without target/feedback. **The standard suite has no independent test simultaneously asserting discovery and later use of that exact entry.** The audit reproducer now contains such a check, but is not part of rebar3 eunit/ct.

### Reproducing audit diagnostics

Diagnostic target/script sources are saved in docs/audit-2026-09-12. They are not in src_dirs, do not modify EFZ and are not a new feature. run.escript intentionally checks existing limitations too, and cleans up its own leaked test processes.

~~~sh
rebar3 compile
EFZ_AUDIT_DIR=$(mktemp -d /tmp/efz-full-audit.XXXXXX)
cp docs/audit-2026-09-12/audit_*.erl "$EFZ_AUDIT_DIR/"
cp docs/audit-2026-09-12/*.escript "$EFZ_AUDIT_DIR/"
escript "$EFZ_AUDIT_DIR/run.escript" "$EFZ_AUDIT_DIR"
escript "$EFZ_AUDIT_DIR/fresh-replay.escript" "$EFZ_AUDIT_DIR"
escript "$EFZ_AUDIT_DIR/edge-cases.escript" "$EFZ_AUDIT_DIR"
~~~

Each escript uses a separate VM. After fixing the identified defects, negative audit assertions must be updated; current diagnostic PASS does not mean “no bugs”.

## 12. Dead Code / Parallel Implementations

| Implementations of one concept | Runtime connection | Post-audit decision |
|---|---|---|
| efz_mutator_random / efz_mutation_plan + efz_mutation | Both actually used: default random and opt-in staged | KEEP both now; MIGRATE the recommended user path to verified staged after P0; do not abruptly remove compatibility |
| efz_executor:run/3 / run/4 | run/3 wraps run/4 with manual coverage; not a second runner | KEEP; document result-metadata loss in the wrapper |
| Manual efz_cov:hit / automatic PT hooks | Shared runtime/ETS; different manual identity namespace | KEEP as explicit compatibility; DEPRECATE manual use for new automatic campaigns |
| ETS insert / ets_member | Backend switch within the same cov_rt/context/executor | KEEP; differential tests already exist |
| Per-execution validation / prepared validation | Same whitelist contract; prepared default | KEEP reference path for differential correctness |
| efz_cov:interesting/2 / efz_feedback:evaluate/3 | First helper not called by runtime; authoritative decision in the second | DEPRECATE unused helper; DELETE only after checking external callers |
| efz_cov:reset_local/0, snapshot/0 | Legacy standalone helpers; unused by current campaigns/tests | DEPRECATE. reset_local does not clear an existing context: repeated invocation raises context_already_attached |
| efz_stats:handle_cast({inc,...}) / public inc through call | Cast handler exists; public API uses synchronous call | DELETE or document after separate consumer review; does not affect the current loop |
| efz_scripted_mutator / bench:efz_perf_replay / production mutators | Scripted and prerecorded replay only in tests/bench | KEEP for measurements and exact fixtures; do not present their results as evidence of real mutation search |
| bench/efz_perf*, reporting/profile scripts | Explicitly loaded by escripts, not OTP application services | KEEP, separate from core |
| Docs calibration/stability collector proposal | No corresponding production modules | KEEP as a design document; do not count as an implemented component |
| efz.worktrees/agents-condemned-silverfish | Same file snapshot copy, not another runtime | KEEP at the owner's discretion; do not delete during the audit |

No multiple corpus implementations, hidden old worker pool, second coverage collector or alternative orchestration language was found. UNUSED searches are limited to the current repository; exports mean external callers are theoretically possible.

## 13. Bugs and Architectural Gaps

### Three main architectural gaps

**G1. Incomplete usable-campaign lifecycle.** The core API accepts bytes and stores successful progress in RAM; the common user workflow target/config + seed directory → durable corpus → restart is not implemented. Runtime retain→reuse already works. Relevant locations: efz.erl, efz_config.erl, efz_corpus.erl, example launchers.

**G2. Incomplete execution/coverage integrity contract.** Root isolation is correct on the ordinary path, but async children, coordinator loss, shared state and disconnected/replaced instrumentation prevent reliable attribution to an input. This is especially important for Erlang/OTP, where useful work often runs in other processes. Relevant locations: executor, cov_rt, cov_manifest, instrument, harness contract.

**G3. Scheduler progress and regression proof.** The staged engine is integrated and replayable, but the global idle cutoff can stop a campaign before useful lanes. Standard tests do not assert discovered seed → next mutation ancestry and miss this defect. Relevant locations: mutation_plan:next/visit, worker staged path, phase3/mutation tests.

### Specific findings

| ID / priority | Finding and consequence | Evidence / confidence |
|---|---|---|
| F01 / P0 | Successful corpus does not survive restart; the main search result is lost without an external report/export | corpus:9–14; runtime restart size 4→1 |
| F02 / P0 | Global idle cutoff stops available stages; 256 valid seeds yield 0 mutations | mutation_plan:51–77; actual edge-cases campaign |
| F03 / P1 | Killing the coordinator leaves root alive after an infrastructure result has returned | executor:9–23,31–60; coordinator_kill.txt |
| F04 / P1 | Child coverage and cleanup absent; child survives timeout | executor:31–85; child_timeout.txt, linked_child.txt |
| F05 / P1 | Shared VM state changes coverage for a repeated identical input | No executor reset; cross_case_state.txt |
| F06 / P1 | Valid but uncalled artifacts yield completed/empty without disconnected-target diagnostics | config:35–48; manifest validator; disconnected_artifacts.txt |
| F07 / P1 | Hot replacement with an ordinary module does not invalidate prepared builds; separate harness not pinned | instrument:115–127; manifest:72–85; recipe:97–108; hot_reload.txt |
| F08 / P1 | Caught malformed context can become successful empty coverage | cov_rt:26–27; caught_malformed_context.txt |
| F09 / P1 | Storage error crashes worker; no atomic artifact group; trigger may be lost | crash:17–23; edge-cases enotdir |
| F10 / P1 | Top-level function/arity/max_input_bytes/corpus_dir accepted but ignored | config:7–15,29–33; edge-cases IGNORED_CONFIG |
| F11 / P1 | Random input size has no common contractual bound; saved input >1MiB cannot pass the execute_file replay API | config:29–33, worker:37 vs recipe:87,113–114; code-only |
| F12 / P2 | Worker_down report has infra counter=0; coordinator_down can be masked by build mismatch | fuzzer:34–39; feedback:5–7,22; enotdir evidence / code |
| F13 / P2 | No initial-seed deduplication; duplicate IDs share a staged-content cursor | corpus:9–14; plan:68; duplicate_initial_seeds.txt |
| F14 / P2 | Failure decisions grow with every repeat, even for one unique crash signature; default random budget infinity | worker:75–79,94–105; config defaults; code-only |
| F15 / P2 | Signature includes unstable stack paths/reason terms; the exact same bug can have different IDs | crash:fingerprint/3; code-only |
| F16 / P1 test gap | No standard direct ancestry E2E assertion, corpus persistence/restart test or tree-cleanup/owner-kill regression | Search and review of all test modules; new audit reproducer |

Not every limit above contradicts documentation: root scope, fixed build, manual launcher and bounded idle policy are documented. They are nevertheless real limitations relative to the requested complete fuzzing pipeline. Conclusions come from the call path and the current run.

The repository contains no CI execution evidence for the current tree; successful local 62+3 checks do not establish successful remote CI or suitability for arbitrary OTP targets.

## 14. Maturity Assessment

Scale: 0 — absent; 1 — minimal fragment; 2 — partly working; 3 — working MVP with substantial limits; 4 — well-working, verified subsystem within the stated scope; 5 — complete required contract with regression coverage and robust lifecycle. Scores are not benchmarks.

| Component | Score 0–5 | Reason |
|---|---:|---|
| Harness API | 3 | Real run/1 behavior, validation and adapters; no generic launcher/source loader/reset contract, module-only selection |
| Input delivery | 4 | Exact binaries confirmed by 41 deliveries; uniform size/replay bounds and seed-file ingestion absent |
| Execution isolation | 1 | Fresh root/coordinator only; children/shared state/VM failures not isolated, owner kill leaves root alive |
| Coverage collection | 4 | Exact per-execution source probes, manifest mapping, backend/lifecycle tests; root-only and limited AST |
| Coverage feedback | 4 | Exact set difference/union and failure policy work; no stability validation or disconnected-code detection |
| Corpus management | 2 | In-memory append/dedup/select/metadata; no persistence, restart, initial deduplication or lifecycle metadata |
| Corpus feedback loop | 4 | A→AB→ABC directly proved; score applies to active RAM loop, not durable workflow; scheduler cutoff limits other campaigns |
| Mutation engine | 3 | Rich primitives/stages/havoc/splice/recipes and model tests; substantial scheduler exhaustion defect |
| Crash handling | 3 | Error/throw/exit/timeout storage/continuation work; non-atomic writing, weaker failure paths, VM crash not covered |
| Replayability | 4 | Exact realized staged mutation and fresh-VM crash replay; random recipes/campaign resume/harness pinning absent |
| Concurrency safety | 3 | Serial single-worker path and scoped ETS tested; multiple workers rejected, tree lifecycle unresolved |
| End-to-end integration | 3 | Core loop actually complete; packaging, persistence and broad OTP isolation unfinished |

Current maturity is an integrated research MVP for bounded synchronous targets. Describing EFZ as merely disconnected prototypes is wrong; declaring it a ready universal OTP application fuzzer is also premature.

## 15. Recommended Development Direction

**Next phase: a reliable, durable and verifiable single-worker campaign using the existing engine.**

P0 should establish the working feedback loop and eliminate situations where valid config prevents it from running: ancestry E2E, premature exhaustion, real seed import, durable retention and reuse after restart. A minimal universal launcher over existing run/1 is also needed, rather than a new harness framework.

P1 concerns boundary correctness: uniform byte bounds, atomic/error-aware artifact storage, root/descendant cleanup, instrumentation-contract violations, fixed target/harness builds and reproducible replay. The first supported model should explicitly define a synchronous binary harness; moving to arbitrary OTP applications must not happen implicitly through spawn without a coverage context.

Repeated stability calibration can be a useful subsequent correctness feature, but completing the identified loop does not require a large new collector. Reliable source identity, per-input scope and cleanup must come first. The existing calibration-readiness.md is useful as requirements, not evidence of an implemented stability feature.

P2 performance work — corpus indexing, mutation_entries/0 cost, binary conversions, ETS hook tuning — follows the correctness gate. P3 advanced schedules and P4 distributed/UI are outside the proposed phase.

## 16. Prioritized Implementation Plan

What follows is only a proposal for the next phase. This audit did not change production implementation.

| Task | Problem solved | Files/modules affected | Expected behavior | Test/evidence | Priority |
|---|---|---|---|---|---|
| T1. Add a standard lineage end-to-end gate | Tests do not prove reuse of a discovered input | test/efz_phase3_tests.erl or a new integration suite; simple fixture/harness | Real staged mutator obtains A, retains it, then that exact A produces AB; AB may produce ABC; fixed bytes to harness and actual coverage | Assert parent ID + primary bytes/hash + recipe output; no scripted mutator; separate fresh replay check | P0 |
| T2. Fix the lack-of-progress criterion | max_idle_visits stops campaigns before a useful lane | src/efz_mutation_plan.erl; test/efz_mutation_tests.erl; integration tests | Unavailable stage does not prevent visiting an available one; true exhaustion and idle-budget stop have distinct reasons; finite empty search stays bounded | 256-seed reproducer must perform bitflip; empty corpus/dictionary/no donor and genuinely exhausted sweep cases | P0 |
| T3. Minimal common launcher + strict campaign schema | User cannot normally specify harness source/code path, seed directory and outdir; unknown keys silently ignored | New scripts/fuzz.escript or efz_cli; src/efz_config.erl, README, examples | CLI/config choose module with run/1, paths/artifacts, seed directory, mutation mode, limits, timeout, output; seed bytes read unchanged; unknown keys rejected | Black-box fresh-VM launch with external minimal run/1; missing module/export/file, invalid config and no-artifacts cases | P0 |
| T4. Durable corpus retention and restore | Discoveries lost on stop/restart | src/efz_corpus.erl, src/efz_worker.erl, config; new scoped corpus store if needed | Content-addressed exact .input + versioned metadata saved before durable-retain acknowledgment; added to active queue; restart loads successful discovered inputs without duplicates | Kill/restart after A discovery → A loaded and selected as parent; corrupt/partial entries detected; explicit build policy | P0 |
| T5. Uniform input/storage failure contract | Unbounded random size; crash-write errors lose context; partial artifacts | config, worker, crash, recipe, corpus store | Same maximum input for seeds/mutations/replay; atomic individual records; errors returned structurally with triggering input/hash and operation/path; worker report does not present 0 infra as success | Boundary 0/max/max+1; enotdir/read-only/storage failure; exact crash bytes with working storage; interrupted-write recovery | P1 |
| T6. Confirm execution cleanup | Coordinator loss/timeout leaves root/children | executor, target contract; lifecycle tests; separate runner/guardian if needed | Cleanup ownership survives coordinator; DOWN confirmed for root and all supported descendants. If scope cannot be safely cleaned, campaign does not reuse dirty runner; general async scope needs an isolated runner VM destroyed on control loss | Owner kill, root trap_exit, linked/unlinked children, timeout and cancellation; no live targets after completion/abort; A→B→A with a defined state policy | P1 |
| T7. Clarify coverage/harness validity | Empty feedback hides a disconnected target; hot reload/PD corruption invisible | config, instrument, cov_manifest, cov_rt, executor; tests/docs | Harness identity and selected builds fixed; contractual violation detected; campaign with entirely absent feedback explicitly diagnosed. Legitimate empty case distinct from missing/broken snapshot; explicit scope/termination/cleanup metadata | Unused artifact, ordinary hot replacement, erased/malformed context, actual valid empty case; fail closed on invalid instrumentation | P1 |
| T8. Complete crash/replay/report contract | Dynamic signatures, unbounded repeated-failure decisions, different failure origins | crash, worker, fuzzer, stats, recipe, scripts/replay.escript | Exact raw input remains authoritative; signature separate from occurrence/provenance; repeated failures bounded/aggregated; primary infrastructure reason and counters retained; explicit CLI execution replay verifies target+harness identities | Repeat one signature with different inputs; replay same build and reject mismatch; worker_down counter/reason; long-running bounded-report test | P1 |
| T9. Connect a reproducible release gate | Local checks not run automatically, allowing gaps to recur | CI config for chosen platform, rebar.config if needed, docs | compile/EUnit/CT/xref/Dialyzer + T1/T2/storage/restart/lifecycle gate run on stated OTP version; separate auxiliary Cowboy suite | CI logs and artifacts with source/build identity, exact commands, ancestry witness and fresh replay result | P1 |

For T4, minimal correct restoration loads persisted inputs and recalibrates in a new campaign. It must not be called “exact continuation of the old schedule” until global coverage, IDs, cursors and RNG are separately serialized and versioned. Full checkpointing can be a later separate step after proving a reusable disk corpus.

For T6, tree-cleanup acceptance cannot be met by simply stating “children are out of scope”. Before a general async runner exists, explicitly restricting supported targets and rejecting contractual violations is acceptable; if the next version claims to continue in the same VM after an async timeout, the corresponding cleanup must be implemented and verified.

## 17. Acceptance Criteria for the Next Phase

The following checklist is the next version's release gate. Some items already hold within the current synchronous in-memory scope, but all must be confirmed by automated tests on the final implementation.

- [ ] EFZ accepts target/harness through common CLI/config; supported callback contract explicit, module/export and artifact availability checked.
- [ ] Initial seed file read as binary and appears in active corpus; duplicates and invalid paths handled deterministically.
- [ ] Corpus seed actually passed to the standard mutation engine.
- [ ] Mutated binary exactly matches the bytes received by the harness.
- [ ] Harness calls the real instrumented target; entirely disconnected feedback diagnosed.
- [ ] Coverage collected separately for a specific input with validated build/source identity.
- [ ] One input's coverage cannot contaminate another; scope and shared-state policy checked; missing/broken observation not accepted as valid empty.
- [ ] New coverage computed as CurrentCoverage − GlobalCoverage for successful outcomes; global updated deterministically.
- [ ] Input with new coverage saved to disk and added to active corpus with parent/content/build metadata.
- [ ] **This newly generated coverage-discovered input is then actually selected and becomes the parent of the next mutation; the test checks parent ID, exact primary bytes and result.**
- [ ] Restart loads the saved discovered input; it remains available as a future parent. Restoration is distinguished from exact campaign resume.
- [ ] Scheduler does not declare exhaustion before visiting a still-available productive stage; 256-seed regression performs real mutations.
- [ ] Crash saves exact triggering input; storage failure has an explicit infrastructure outcome and retains its explanation.
- [ ] Saved crash reproduced by replay execution in a fresh VM with compatible target/harness builds.
- [ ] Mutation recipe deterministically reconstructs input without live corpus or RNG; mismatch/corruption rejected.
- [ ] Timeout/cancellation/coordinator loss leave no live target processes in the supported model, including its descendants; unproven cleanup forbids runner reuse.
- [ ] Invalid instrumentation, mutation failure, target failure and infrastructure failure distinguished in report and counters.
- [ ] End-to-end integration test confirms the full loop, disk retention, restart reuse and fresh crash replay without mock target/mutator/coverage/corpus.

**Phase completion criterion:** one reproducible test passes seed file → real mutation → real harness/target → per-input coverage → successful discovery → durable + active corpus → mutation from discovered parent; a second run uses the same persisted input. The current audit already proved the internal part of this chain, so the next phase must preserve it and resolve the established gaps.
