# P1-01 External supervisor

Status: **DONE** on Linux. Validation date: 2026-09-21. Implementation baseline:
`9303c6e0734cc135700e62b0774f4a0011e97d48`.

The supervised backend is opt-in. Legacy execution and the public harness
contract `Module:run(binary())` are unchanged.

## Baseline and actual architecture

Environment: Linux 6.8.0 x86_64, OTP 27, ERTS 15.0, rebar3 3.25.0. The project
declares minimum OTP 27. The existing code supports its legacy mode wherever OTP
27 and its filesystem assumptions work; P1-01 lifecycle guarantees are explicitly
Linux-only because they use `pidfd`, `PR_SET_PDEATHSIG`, subreaping, Unix peer
credentials and `/proc` descendant enumeration.

The checkout was dirty before P1-01. The pre-existing hit-count/corpus changes are
listed in `_build/p1-validation/before.status` and were preserved separately. No
reset, clean, checkout, target harness change, or deletion was performed.

Real legacy call path:

```text
scripts/fuzz.escript
  -> efz_cli:main/1
  -> efz:start/1 -> efz_fuzzer:init/1
  -> efz_worker (seed calibration / mutation / feedback / corpus / P0 verification)
  -> efz_executor:run/4
  -> efz_guardian:run/6
  -> efz_executor:invoke/4 -> Harness:run(Binary)
  -> guardian cleanup/coverage/runtime result
  -> efz_feedback:evaluate/3 -> efz_corpus / crash and runtime stores
```

`efz_guardian` owns the target root and controlled descendants inside the worker
VM, the target deadline, cleanup and dirty-runner decision. `efz_runtime` samples
those owned processes. `efz_corpus_store` is the durable successful-corpus path;
`efz_runtime_store` and `efz_crash` publish findings. Replay is in
`efz_replay_cli`, `efz_replay` and `efz_runtime_replay`. There is recalibration of
restored corpus but no minimizer in this checkout. Target callback validation and
`on_load` occur through `efz_config`/`code:ensure_loaded` inside the campaign VM;
instrumented BEAM loading occurs through `efz_instrument`. Consequently the
complete campaign loop, not just `run/1`, must be placed in the external worker.

Canonical baseline before P1-01:

| Command (`ERL_FLAGS='+S 4:4'`) | Exit | Result |
|---|---:|---|
| `rebar3 compile` | 0 | PASS |
| `rebar3 eunit` | 0 | 223 tests PASS |
| `rebar3 ct` | 0 | 3 tests PASS |
| `rebar3 dialyzer` | 0 | PASS |
| `rebar3 xref` | 0 | PASS |

Raw logs are `_build/p1-validation/baseline-*.log`.

## Implemented process boundary

`--supervised` delegates in `efz_cli:main/1` before target lookup, application
startup, replay or callback validation. The original CLI process starts the
file-only Python controller with `open_port({spawn_executable, Python}, ...)` and
an explicit argument vector. The controller never imports, loads or calls target,
harness or NIF code. It hashes local EFZ, artifact, sidecar, harness and `.so`
files, and the bounded command configuration.

For each generation the controller starts `priv/efz_vm_launcher` using an argument
vector (no shell). The C launcher forks and `execv`s `erl`; the new BEAM invokes
`efz_external_worker:main/0`, which then runs the ordinary `efz_cli` and real
campaign. Target/harness/NIF loading is therefore confined to the worker address
space. The guardian remains unchanged inside that worker.

The launcher:

- obtains a `pidfd` for its controller and installs `PR_SET_PDEATHSIG` with a
  post-install parent check;
- makes the BEAM a new session/process-group leader with its own parent-death
  SIGKILL race check;
- is a child subreaper and kills/reaps adopted descendants before reporting
  `cleanup_confirmed=true`;
- returns the raw `waitpid` status, separate signal and exit code, and whether the
  launcher initiated the kill;
- drains worker stdout/stderr continuously, counts all bytes and retains only a
  4096-byte tail; crash dumps and cores are disabled for the worker;
- never starts a replacement until old-worker cleanup is confirmed.

The controller also holds a `pidfd` for the invoking CLI and performs a live ACK
challenge over the inherited port. Thus SIGKILL of either the CLI or controller
causes the launcher to kill and reap a worker stuck in a NIF. This is lifecycle
containment, not a security sandbox: native code can still access filesystem,
network and the host under the worker's credentials.

## Mandatory execution barrier

The one integration hook is the first operation in `efz_executor:run/4`:

```text
efz_worker selects/generates Input
  -> efz_executor:run/4
  -> efz_external_worker:execution/4
  -> PREPARE(Input, digest, phase, timeout, bounded recipe)
  -> controller validates the fixed schema
  -> fsync artifact.input, artifact.external.json, optional artifact.recipe,
     and manifest.json in a private staging directory
  -> fsync staging directory
  -> rename the whole directory to CAMPAIGN/RUN and fsync campaign directory
  -> atomically write/fsync authorized.json and fsync the run directory
  -> COMMITTED/RUN(RunId, digest)
  -> worker verifies generation, RunId and digest
  -> existing executor -> guardian -> Harness:run(Input)
  -> bounded RESULT -> atomic checksummed result.json -> RESULT ACK
```

The hook covers seed calibration, corpus recalibration, mutation executions and
P0 verification/reproduction because all of them use `efz_executor:run/4`.
External-finding reproduction is a one-input real campaign and passes the same
barrier. There is no minimization implementation to cover. In legacy mode the
gate is a direct call with no IPC or filesystem work.

No target execution is permitted after a failed write/fsync/rename/authorization.
The journal has one in-flight run, a 1 MiB input limit, 64 KiB recipe and metadata
limits, a configurable total byte budget, and at most 100000 scanned/run records.
The raw input is authoritative. The existing EFZR mutation recipe is included
when available and valid; absence or the metadata cap is explicit.

Publication makes the input and metadata group atomically visible on the same
filesystem. File and relevant directory fsyncs provide the strongest practical
local-filesystem guarantee used elsewhere in EFZ. This does not promise storage
hardware behavior beyond successful OS fsync. `authorized.json` distinguishes a
committed-but-not-issued PREPARED run from a run for which permission was durably
recorded. It cannot prove the worker reached target code. Therefore:

- uncommitted staging is not attributed to a target;
- PREPARED without authorization becomes `interrupted_prepared`;
- authorized without RESULT becomes `interrupted_unknown` unless the live
  launcher supplies stronger termination evidence;
- the implementation does not claim exactly-once execution across crashes.

Finalization is atomic, checksummed and idempotent by campaign/RunId. Startup
validates all bounded manifests/results and finalizes incomplete records without
inventing a native crash. A committed input remains replayable if later result or
index publication fails.

## Protocol and state machine

The Unix-domain control socket is separate from stdout/stderr. Linux
`SO_PEERCRED` must equal the launcher-reported worker PID and current uid. Frames
are `u32` big-endian length followed by a fixed primitive schema. Length is
rejected after the first four bytes and before payload accumulation. Maximum
frame size is input + 64 KiB recipe + 59 bytes. Reads are 4096 bytes, partial
frames have a one-second deadline, and the decoder handles multiple frames.

There is no ETF/JSON/compression on the control channel. RESULT is four bytes.
The optional recipe remains the existing checksummed EFZR data format; its size,
ETF version and compressed tag are checked before storage, and it is never
decoded by the controller.

Protocol v1 messages are HELLO, READY, PREPARE, RUN, RESULT, DONE/SHUTDOWN and
ACK. Every frame validates type, state, generation, RunId, identity and exact
payload length. HELLO contains protocol marker, combined file identity, worker
configuration identity, OS PID, OTP and ERTS. Unexpected, stale, duplicate and
post-terminal results are protocol failures.

States are STARTING, SETUP, READY, PREPARING, EXECUTING, FINALIZING, RECYCLING
and STOPPING. RESULT is durably accepted before its ACK, and clears the in-flight
record; a later process exit cannot rewrite that run as a native crash. If the
absolute hard deadline wins first, a later RESULT is ignored and the launcher
kill remains the single terminal classification. EOF and wait status are handled
independently so a final complete frame is drained before death classification.

Classification uses raw evidence:

| Observation | Classification |
|---|---|
| signal while authorized run is in flight, no controller kill | `native_vm_crash` |
| exit code without signal | `worker_unexpected_exit` |
| controller absolute deadline/kill | `worker_hard_timeout` |
| invalid IPC | `worker_protocol_failure` |
| finalized non-reusable guardian result | `dirty_recycle` |
| death before READY/while idle | startup/infrastructure, no testcase finding |
| user/parent stop | campaign stop, never native crash |

Signal evidence proves VM termination, not target culpability or root cause.
`exit(139)` is recorded as exit code 139 and signal 0. Launcher SIGKILL records
`launcher_kill=true` and is never called a native crash.

## Deadline, recycle and recovery

The external per-run deadline is monotonic and absolute:

```text
target timeout + guardian cleanup (1000 ms)
+ CLI P0 post-memory allowance (100 ms when enabled)
+ configured IPC grace (default 1000 ms)
```

Traffic and logs never extend it. Startup/idle is separately bounded (default
10000 ms), launcher termination is bounded to five seconds, and adopted-child
cleanup to two seconds. Unconfirmed cleanup aborts without restart.

Native crash, hard timeout and dirty result preserve/finalize the current run,
quarantine its digest, wait for old process death, increment generation, recheck
file identity, restore the existing durable corpus and recalibrate it. Every
recalibration execution uses the same barrier. Quarantined inputs are skipped,
preventing a crashing corpus seed loop. Restart budget (8), linear bounded
backoff, campaign deadline, execution cap, mutation execution remainder, P0
verification remainder and journal bytes are controller-owned. Startup/identity
failure before READY is not restarted endlessly.

Recovered state is the durable corpus and configured global budgets. Worker-local
coverage, feedback, RNG and staged cursors are reconstructed; exact campaign
resume is not claimed.

## CLI and artifacts

Example:

```sh
ERL_FLAGS='+S 4:4' rebar3 compile
ERL_FLAGS='+S 4:4' escript scripts/fuzz.escript \
  --supervised --target my_harness --code-path harness-ebin \
  --artifacts instrumented --seeds seeds --corpus-dir out/corpus \
  --out out --timeout 1000 --max-iterations 10000 \
  --restart-budget 8 --supervised-runs 20000 \
  --campaign-ms 3600000 --ipc-grace-ms 1000 --journal-bytes 268435456
```

`OUT/external-runs/CAMPAIGN/RUN/` contains `artifact.input`,
`artifact.external.json`, optional `artifact.recipe`, `manifest.json`,
`authorized.json` and checksummed `result.json`. Configuration identity and the
exact file list are stored under the campaign directory. External findings are
also indexed under the existing `OUT/crashes/external/` namespace. Worker reports
and normal crash/runtime findings remain in `OUT/worker-GENERATION/`.

Reproduction selects target code locally and verifies file/harness identity:

```sh
escript scripts/replay.escript \
  --external-finding OUT/external-runs/CAMPAIGN/RUN \
  --target my_harness --code-path harness-ebin --artifacts instrumented \
  --out recheck --reproduce-runs 3
```

It performs a bounded number of isolated generations and reports observed N/M,
not a one-run boolean.

## Native acceptance evidence

Final command:

```sh
python3 -m unittest discover -s test -p '*supervisor_test.py' -v
```

Exit 0, 13/13 tests. Raw log:
`_build/p1-validation/posthook-native.log`. Evidence root:
`_build/p1-native-68udkvqj`.

The real CLI SAFE -> SIGSEGV -> restart -> SAFE campaign recorded:

- campaign `119e4f3df348420e98488ed25bde3cc4`;
- supervisor PID 739219, CLI PID 738777;
- generation 1 worker PID 739271; RunId 1 SAFE completed;
- RunId 2 raw `SEGV`, SHA-256
  `8f243e33082126167daac18a24f576245ff332a18dc217093bc6cf9d6bbcdc1b`;
- authoritative `waitpid`: signal 11, exit code -1, raw status 139,
  `launcher_kill=false`, `cleanup_confirmed=true`;
- finding:
  `_build/p1-native-68udkvqj/SEGV-61938280703258/out/external-runs/119e4f3df348420e98488ed25bde3cc4/2`;
- generation 2 worker PID 740096; restored corpus reported 3 inputs,
  recalibrated SAFE1, and RunId 4 executed SAFE2 successfully;
- final status completed, two generations, four barriered executions.

SIGABRT independently produced signal 6 with `launcher_kill=false`, restarted and
completed. Two isolated rechecks of each native finding reported `observed 2/2`.
The fixture NIF was loaded only in child worker VMs; core and crash dumps were
disabled.

Additional final acceptance results:

- hung NIF: `worker_hard_timeout`, launcher signal 9,
  `launcher_kill=true`, cleanup confirmed, generation 2 reached SAFE2;
- DIRTY: original result stored as `dirty_recycle`; generation changed before
  SAFE2; no native finding;
- `exit(139)`: `worker_unexpected_exit`, exit 139, signal 0;
- internal WAIT/BUSY: guardian outcomes preserved with `timeout_waiting` and
  `timeout_busy` respectively;
- 8,389,639 bytes of target output drained without blocking; retained tail stayed
  at 4096 bytes;
- startup `on_load` SIGABRT before READY: zero executions and zero findings;
- durable write-budget failure: nonzero exit and marker proves target was not
  entered;
- withheld RUN test: real child BEAM emitted PREPARE but did not touch target
  until journal commit and digest-bound permission;
- malformed/oversized/compressed-looking frames, partial/multiple frames, stale
  generation, wrong identity and duplicate RESULT were rejected;
- finalization EIO left the committed raw input and was recovered exactly once;
- SIGKILL CLI evidence: worker 744649, launcher 744647, controller 744618 all
  disappeared from `/proc`; SIGKILL controller evidence: worker 744920, launcher
  744919, controller 744894 all disappeared; recovery classified uncertainty,
  not a native target crash;
- zero restart budget stopped after the first crash with
  `restart_budget_exhausted`; persistent startup failure stopped before READY.

## Regression and performance

Final canonical results (all with `ERL_FLAGS='+S 4:4'`):

| Command | Exit | Result |
|---|---:|---|
| `rebar3 compile` | 0 | PASS; Linux helper compiled by pre-hook |
| `rebar3 eunit` | 0 | 224 tests PASS (baseline 223) |
| `rebar3 ct` | 0 | 3 tests PASS |
| `rebar3 dialyzer` | 0 | PASS, no warnings |
| `rebar3 xref` | 0 | PASS |

Logs are `_build/p1-validation/release2-*.log`. A second canonical EUnit run also
completed with all 224 tests passing.

The exact staged P1-only tree was also exported with `git checkout-index` and
validated independently of the pre-existing hit-count work: compile, 211 EUnit,
3 Common Test, Dialyzer and Xref passed; the 13 native tests passed in 33.649 s.
The smaller EUnit count is expected because that snapshot deliberately excludes
the unrelated uncommitted tests.

The diagnostic benchmark ran three alternating repetitions of the same safe
target with 300 mutation executions plus one calibration. Fsync was enabled:

| Median | Legacy | Supervised |
|---|---:|---:|
| wall time | 2.246 s | 6.062 s |
| mutation throughput | 133.6/s | 49.5/s |
| total throughput | 134.0/s | 49.7/s |
| durable prepare total | n/a | 2.441 s |

Supervised wall time was 2.70x legacy; throughput was 62.9% lower. Durable
publication and authorization cost about 8.11 ms/input. Remaining cost includes
the extra VM, IPC and finalization. Raw rows are
`_build/p1-validation/benchmark-final.log`; per-run artifacts are under
`_build/p1-bench-i_u4wnm7/`.

## Limits

- Full guarantees are Linux-only. Non-Linux supervised launch fails explicitly;
  legacy mode remains available.
- This is crash containment and recovery, not a hostile-native-code sandbox.
- Filesystem/network/external-service side effects cannot be rolled back.
- Successful fsync/rename is relied on; power-loss behavior ultimately depends on
  the local filesystem and hardware honoring those operations.
- The journal proves preparation and permission, not exact entry into target
  code. No exactly-once claim is made.
- Corpus is restored and recalibrated. Exact RNG, staged cursor and global
  coverage checkpoint resume is intentionally not claimed.
- One worker and one in-flight testcase are supported; multi-worker/distributed
  scheduling is outside P1-01.
