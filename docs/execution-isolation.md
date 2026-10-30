# Execution model: synchronous binary harness with controlled descendants

**English** · [Русский](i18n/ru/execution-isolation.md) · [Español](i18n/es/execution-isolation.md) · [简体中文](i18n/zh-CN/execution-isolation.md) · [All languages](i18n/README.md)

The supported backend runs in one local Erlang VM with OTP 27 and one concurrent
execution. Contract: **synchronous binary harness with controlled descendant
lifecycle**. The root implements `Module:run(binary()) -> term()` and calls
ordinary instrumented functions. Child processes use the lifecycle API:

```erlang
run(Input) ->
    Parent = self(),
    Child = efz_target:spawn(fun() ->
        Parent ! {parsed, self(), my_parser:parse(Input)}
    end),
    receive {parsed, Child, Value} -> Value end.
```

`efz_target:spawn_link/1` creates the same kind of owned child with a link to the
calling target process. Both functions accept `fun(() -> term())`, return a PID
and are available only inside an execution. Nested children use the same API.
The guardian creates the process with a closed start gate, installs monitoring
and tracing, records ownership, and then returns the PID to the parent. Only
then does the helper open the gate. The coverage context and lifecycle capability
are passed to the child; the rest of its process dictionary and mailbox are new.

The root return determines the case outcome. If the result or exception of an
unlinked child matters, the harness must wait for it and reflect it in its own
result. EFZ does not replace that protocol: live descendants are forcibly stopped
when the root finishes, and already recorded probes are included in the snapshot
for that execution.

## Independent lifecycle owner

```text
worker / executor caller
  └─ monitor ─ guardian (efz_guardian)
                  ├─ monitor caller
                  ├─ monitor ─ coordinator (root result + DOWN classification)
                  ├─ owns ─ observation ETS and trace session
                  ├─ monitor ─ gated root
                  └─ monitor ─ all controlled descendants
```

The guardian is not linked to the caller or coordinator and uses a stable `user`
group leader. This is also necessary for `application:stop(efz)`: the application
master may terminate processes in its I/O group independently of links. A local
`user` process exists in the supported environment; target stdout goes through it.

The coordinator reports `coordinator_ready` after installing the root monitor.
The root does not execute user code before that. The coordinator waits for
`target_result` and root `DOWN`; the guardian owns the timeout independently.
Coordinator death produces an infrastructure outcome and starts the same cleanup.

The guardian moves through these states:

```text
running
  ├─ root completed/crashed
  ├─ timeout
  ├─ caller DOWN (including campaign cancellation)
  ├─ coordinator DOWN
  └─ unsupported spawn / exceeded admission bound
       ↓
cleaning: new admissions forbidden
       ↓
kill root + descendants + coordinator
       ↓
DOWN for every owned process + trace delivery barriers
       ↓
global loader trace barrier + pinned code/context integrity
       ↓
snapshot / validation / close ETS / destroy trace session
       ↓
check available evidence of VM contamination
       ↓
final result → caller also waits for guardian DOWN
```

`kill` works independently of `trap_exit`. The cleanup deadline is 1000 ms; at most
4096 controlled processes are admitted per case, including the root. The clock
is checked even with a nonempty mailbox so that continuous spawn requests cannot
starve the timeout. These are lifecycle bounds, not new mutation/campaign config.

The trace session uses `procs` and `set_on_spawn`. Ordinary local `erlang:spawn`
is detected as an **uncontrolled spawn**: context is not injected retrospectively,
and the case stops with a dirty-runner outcome. The guardian tracks and kills
local descendants it discovers, including nested descendants. Their `DOWN` may
arrive before a delayed spawn trace, so `trace:delivered(Session,Pid)` is called
after every `DOWN`. Return is permitted after all live monitors and delivery
barriers have cleared; a child discovered late adds another monitor/barrier.
This does not rely on a simple traversal of links or a single snapshot of PIDs.

Trace-session and delivery-barrier semantics were checked against the installed
OTP 27.0 and the [official trace documentation](https://www.erlang.org/docs/27/apps/kernel/trace.html)
and [trace_delivered documentation](https://www.erlang.org/docs/27/apps/erts/erlang.html#trace_delivered/1).
Real monitors and start gates are used for the main control paths; tracing adds
checks of the model's boundaries.

## Result and prohibition on reuse

The following are added to the existing `outcome`, `coverage`, `coverage_status`
and `builds`:

```erlang
#{execution_model => controlled_descendants,
  cleanup => #{status => confirmed,
               processes => [RootPid, ChildPid],
               survivors => [], violations => []},
  runner_reusable => true}.
```

`confirmed` confirms termination of known processes and trace closure, not complete
cleanup of an arbitrary OTP application. When a global change is detected, all
processes may have terminated while the runner is still dirty.

If the cleanup deadline expires or the guardian itself dies, the result is
`{infrastructure, #{kind => dirty_runner, ...}}`, `runner_reusable => false` and
`cleanup.status => unconfirmed`. Guardian failure is not declared a clean run.
Processes that may remain alive after guardian loss require destroying the VM.
If the caller dies, no result is delivered to it, but the guardian independently
finishes cleanup and marks the VM dirty if necessary.

The dirty marker is stored in `persistent_term` under `{efz_guardian, dirty_runner}`.
`efz_executor:runner_status/0` returns `ready` or `{dirty, Reason}`. The marker
survives `efz:stop/0` and has no public reset: a new VM is required. A subsequent
`run/4` in a dirty VM returns an infrastructure result with
`cleanup.status => not_started` without creating a new target. A second concurrent
execution is rejected as `runner_busy`; shared VM state cannot be checked as
isolated while cases run in parallel.

The worker stops the campaign, increments `infrastructure_failures` and preserves
the exact input, recipe and execution result in `failure_context`. Such
observations do not pass successful feedback and do not expand global
coverage/the corpus.

## Shared-state policy

| Resource | Supported policy | EFZ check / action |
|---|---|---|
| Process dictionary, mailbox | Only the root's/controlled child's own state | Destroyed with the processes; the next case gets fresh state. |
| Coverage ETS | Owned by the guardian | Snapshot only after cleanup; the table is closed before the result. |
| Target-owned ETS | No heir or transfer of ownership outside the execution | Disappears with its owner; new surviving tables mark the runner dirty. |
| Existing shared ETS | Writes are forbidden in this model | Contents are not copied/rolled back automatically. For an effect known to require this, the harness calls `efz_target:dirty(Reason)`; a disposable VM is required. |
| Registered names | Only for owned processes | Owned names are released after `DOWN`. New/changed surviving registrations mark the runner dirty; an external process is not killed arbitrarily. |
| `persistent_term` | The target must not change VM-global values | Before/after keys/values are compared; a change sets the dirty marker. There is no automatic restoration. |
| Application env | The target must not change shared env | The env of loaded applications is compared; a change produces dirty status. A new application without env is not itself considered an env mutation. |
| Ports, remote spawn, timers/messages to external processes, external services, files | Outside the supported shared-VM scope | No promise of cleanup/rollback or cancellation of remote work. The next backend is required. |

Snapshots diagnose violations of a cooperative contract; they are **not a
security sandbox**. They do not detect every write to existing ETS, transient
changes followed by restoration, removal of someone else's registration,
messages to external services or deliberate forging of tracing/protocol data.
[Coverage integrity](coverage-integrity.md) additionally checks damage to EFZ
coverage context and hot reload. Concurrent VM changes by unrelated code may
produce a conservative dirty result. Restoring a `persistent_term`/env snapshot
over someone else's changes would be unsafe, so it is not done.

`A → dirty → A` is checked in two ways. For process-local dictionary/mailbox,
owned ETS and registrations, the third `A` actually executes and returns the same
outcome and probes. For VM-global mutation, the second run returns dirty and the
third `A` **does not execute**. Contaminated values are deliberately not “repaired”;
the VM is retired. For test isolation, these cases run in separate OS processes.

## Next backend for the asynchronous OTP scope

Arbitrary OTP applications, background servers, NIFs/ports, remote calls and
shared services require a **disposable Erlang VM**, with an external owner of
the OS process and confirmation of its termination. This backend is not yet
implemented. Even a VM backend must separately specify filesystem/network side
effects and remote cleanup. The current guardian does not follow links to other
processes and does not present that isolation as an already solved problem.

## Regression evidence

[efz_isolation_tests](../test/efz_isolation_tests.erl) compiles a real
[instrumented target](../fixtures/efz_isolation_target.erl). It checks normal,
crash, timeout, trap_exit, linked/unlinked/nested children, caller/coordinator death,
spawns near the deadline, registration/ETS cleanup and matching child coverage
context. After a supported case, all PIDs in the ownership report must be dead,
including processes that died while still at the start gate.

Separate fresh VMs check persistent_term/env/shared ETS, escaped ETS/names,
ordinary/nested unmanaged spawn, guardian loss and the campaign dirty report.
The guardian-failure test first proves `unconfirmed` and the reuse prohibition,
then terminates the remaining test processes itself: this is not represented as
cleanup by the executor. Logs of these runs are in `_build/isolation-test/`.
General regression tests for coverage, crash/replay and `A → AB → ABC` continue
to verify the existing pipeline.

When a primary infrastructure failure (for example, `coordinator_down`) coincides
with dirty cleanup, `outcome` preserves the first reason. `coverage_status`,
`cleanup` and `runner_reusable => false` record that the VM cannot be reused;
the next input is rejected as a dirty runner. The `coordinator_dirty` regression
checks this combination in a separate VM.

Late guardian loss after an actual reply is checked separately in
`efz_crash_retention_tests`: a test-only AST transform of the guardian adds a gate
after sending the message in a private VM. Following coordinator death, the reply
contains the original error; the guardian then terminates abnormally. Report/stats
preserve the original reason, `guardian_failure` describes the secondary reason,
and `execution_evidence` preserves the original cleanup/coverage. The runner is
retired and the next target does not start. Production has no fault-injection
option.

## Optional runtime observations

P0 samples only guardian-admitted processes and their ETS owners. It adds a bounded
sampler monitor/lifecycle to this guardian; ownership/start gates/trace barriers
and dirty-runner rules remain authoritative. Sampler failure is partial diagnostic
evidence; guardian or unconfirmed lifecycle failure still retires the VM. Cleanup
kills do not constitute process leaks. See [runtime diagnostics](runtime-diagnostics.md).
