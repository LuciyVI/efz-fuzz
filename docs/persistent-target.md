# Stateful persistent target VM (first implementation)

Localized quick references: [Русский](i18n/ru/persistent-target.md) · [Español](i18n/es/persistent-target.md) · [简体中文](i18n/zh-CN/persistent-target.md).

`execution => #{mode => persistent_vm, state_policy => accumulate}` starts one
separate OTP VM for the target epoch. The target driver PID survives successive
inputs. Its process dictionary, mailbox, callback state and target-owned OTP
services/ETS can persist. A fresh ETS coverage table is created for each
input, so an already visited probe remains visible in every step. The ordinary
`isolated` executor and its per-case cleanup remain the default.

The child VM is launched through OTP `peer` under `setsid`; the parent owns its
stdio connection and monitors the campaign worker. Each step has an absolute
timeout in the child controller and a bounded parent RPC timeout. On timeout,
crash, invalid window, contract error or unexpected VM exit, the epoch is
retired. The parent sends an OS process-group kill on forced retirement and
stops the peer. It does not resume a partly interrupted target state or start
another primary VM automatically. `target_epoch_terminated` is distinct from
provider or EFZ infrastructure failure. A normal returned target error does
not retire the epoch.

On Linux, the session owner also records a bounded `/proc` descendant snapshot
after each completed step and immediately before retirement. It checks each
recorded PID's kernel start time before signalling it, so a target child that
entered a new process group with `setsid` is still terminated. The synthetic
tests cover orderly close and an external timeout while a native NIF blocks the
target VM. This is not an OS container: a child that double-forks and is
reparented before any snapshot, or more than 1024 live descendants, exceeds
the proven cleanup boundary. Run such targets under a dedicated OS supervisor
or cgroup and keep the epoch resource budgets conservative.

Target callbacks can use the existing `run(Binary)` contract; it is invoked
repeatedly in the same driver process. For explicit state, export all three:

```erlang
init_session(InitConfig) -> State.
handle_input(Binary, State) -> {ReturnValue, NextState}.
finish_session(State) -> ok.
```

The callbacks are trusted local code. Only one synchronous input is in flight.
The driver handles EFZ control messages after a callback returns; ordinary
target messages remain in its mailbox. `finish_session/1` runs once during
orderly shutdown. The separate target VM is never the Erlamsa provider VM.

## Coverage and supported contexts

Automatic instrumented `ets` and `ets_member` backends with presence or hit
count feedback are accepted. Other backend/mode combinations fail during
configuration. Hit count feedback continues to work, but `feature_stability`
still compares **presence** only. A step snapshots its own full coverage
table, never the novelty delta or cumulative epoch union. The selected BEAM
identities are checked before and after each step. The driver must finish its
synchronous work before returning. An instrumented helper lacking the current
window token raises `persistent_window_unattached`; no helper can write into a
later table through its stale token. A target may use
`efz_target_vm:spawn_covered(Context, Module, Function, Args)` to attach a
linked helper before its first instrumented call, then export
`step_barrier(State) -> {ok, NextState}` to wait for all helpers before closing
the window. The fixture exercises this path. Arbitrary asynchronous background
work without an explicit barrier is outside the measured coverage contract;
do not interpret a reported percentage as full application stability for
those targets.

The tested stateful fixture keeps a process dictionary counter, a private ETS
table, a linked OTP service and a queued mailbox message. `arm` changes the
result of later `fire`; `fire` alone after init takes a different path.

## Sequence audit

With `runtime_oracles.enabled=true` and
`runtime_oracles.stability.sequence.policy=deferred`, EFZ closes the primary
epoch and replays its exact input journal in fresh sequential target VMs.
`preflight_and_deferred` also audits configured seeds or exact
`benchmark_replay_inputs` before the primary VM starts. At most one target VM
is active at a time. Primary results are **not** reused as audit samples.
Each replay repetition invokes the same init, then the same full prefix and
step bytes. The first and second valid observations make a group measured;
each following observation updates the existing `efz_stability` accumulator.
Audit inputs do not enter primary feedback, corpus admission or mutation RNG.

The comparison key includes the pinned target/build, init config, backend,
coverage mode and feedback, timeout, step number, length-delimited ordered
prefix hash and exact current input hash. It excludes epoch/PID/repetition and
observed outcome. The scope is `audited_sequence_steps`. Two identical inputs
under different prefixes are two groups. `history_sensitivity` separately
records when the same bytes produced different coverage/return under distinct
primary prefixes. This is state drift, not evidence of nondeterminism.

For each group `g`, the existing metric computes
`100 * |intersection(F_g)| / |union(F_g)|`; the campaign value is
`100 * sum_g |intersection(F_g)| / sum_g |union(F_g)|`. Groups need at least two
valid full windows and a nonempty union. An empty or missing window never
becomes 100%. The bounded `variable_examples` list includes presence counts
for sampled variable feature IDs. A measured 100% only describes the observed
replays and selected presence features.

With `repeats=20` and prefix length `k`, the audit can consume
`20 * (k + 1)` additional target calls for one step because primary samples
are excluded. One pass can audit every reached step, so an entire sequence of
`L` inputs consumes at most `20 * L` replay calls. The `max_calls` and
`max_elapsed_ms` limits apply to each audit phase; the cumulative diagnostic
call count appears in `stats.verification_executions`. Stop is checked between
audit steps; an in-flight target step remains bounded by its timeout.

## Journal and replay

`crash_dir/sequences/EPOCH.jsonl` uses schema version 1. A header pins target,
build, init and backend identity. Each dispatch row contains exact Base64
bytes, input SHA-256, step index, previous and next prefix hashes and bounded
recipe seed/hash metadata when available. It is written **before** delivery to
the target. Completion and end rows record the result and termination reason.
The chain starts at `SHA256("EFZ_SEQUENCE_1")` and advances with
`SHA256(previous_hash || unsigned_64_bit_length || input_bytes)`. A replay
requires a complete end row and the same prepared build and init identity.
The default 16 MiB journal cap can be set from 4 KiB to 64 MiB. At the cap,
EFZ ends the epoch; it never silently truncates a prefix. `buffered` records
are closed at normal stop but lack power-loss durability. `fsynced` calls
`file:sync` for each row. A controller crash before the end row leaves
`replay_incomplete`; the dispatch row still preserves the last sent input.

`sequence_replay.escript` and the Python `Client.sequence_replay` method replay
a full prefix in one fresh target VM without regenerating mutations. A legacy
single-input raw replay can still run without this history, but it cannot
claim to reproduce a state-dependent outcome. No arbitrary BEAM snapshot or
automatic epoch restart is implemented.

## Configuration and runnable example

`examples/stateful/persistent.config` enables three deferred repetitions.
Supported execution keys are `mode`, `state_policy`, `target_init`,
`max_iterations_per_epoch` (or `infinity`), `max_result_bytes` (1 KiB to 8 MiB),
`max_journal_bytes` (4 KiB to 64 MiB), and `durability` (`buffered` or
`fsynced`). The default per-step deadline is the campaign `timeout`.
`max_epoch_ms`, `max_vm_memory_bytes`, `max_processes`, `max_ets_tables`,
`max_ports`, and `max_driver_mailbox` are optional sampled step-boundary
limits. A crossed limit ends the epoch with `epoch_end_reason`; it does not
discard the completed target result. The VM memory sample is
`erlang:memory(total)`, not a hard RSS/native allocation quota. `target_session`
also reports observed memory, process, ETS, port and driver mailbox counts at
shutdown. Limits are checked between completed steps; the step deadline and
external process-group kill handle a stuck step.

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
escript scripts/prepare_stateful.escript
escript scripts/fuzz.escript --config examples/stateful/persistent.config --out _build/persistent-target-run
ls _build/persistent-target-run/crashes/sequences
escript scripts/sequence_replay.escript examples/stateful/persistent.config \
  _build/persistent-target-demo PATH_FROM_PREVIOUS_LS 2
```

For a live view in an interactive terminal, use the 20-repetition preflight
example and a new output directory:

```sh
python3 scripts/tui.py --config examples/stateful/persistent_live.config --out /tmp/efz-target-tui
```

`s` requests stop and saves the report, `q` detaches. The main line shows
Feature stability and the target phase. JSON/report include `target_execution`,
`target_session`, `target_timing`, `sequence_journal`, `target_audit`,
`preflight_audit`, `history_sensitivity` and the existing nested
`feature_stability`. Old isolated snapshots remain readable and display
`Stability: unavailable` if the object is absent.

The Python SDK accepts an explicit ordered sequence, including repeated and
non-UTF-8 bytes:

```python
from pyefz import Client

config = {
    "target": "efz_persistent_fixture",
    "artifacts": "_build/persistent-target-demo",
    "execution": {"mode": "persistent_vm", "state_policy": "accumulate"},
    "timeout": 3000,
}
with Client("/absolute/path/to/efz-fuzz") as client:
    campaign = client.start_sequence(config, [b"arm", b"fire", b"fire"],
                                     out="/tmp/efz-sequence-sdk")
    report = campaign.await_result(30)
    journal = report["sequence_journal"]["path"]
with Client("/absolute/path/to/efz-fuzz") as client:
    replay = client.sequence_replay(journal, config=config, step=3)
```

`Client` resolves the EFZ checkout explicitly; it never evaluates user input
as Erlang code. The JSON control protocol transports bytes as Base64.
