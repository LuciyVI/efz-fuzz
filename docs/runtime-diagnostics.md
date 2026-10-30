# Automatic Runtime Diagnostics (P0)

**English** · [Русский](i18n/ru/runtime-diagnostics.md) · [Español](i18n/es/runtime-diagnostics.md) · [简体中文](i18n/zh-CN/runtime-diagnostics.md) · [All languages](i18n/README.md)

P0 is enabled through EFZ settings. The existing
`Target:run(Input) when is_binary(Input)` and instrumented target need no changes.
The default is `enabled=false`. `run/3` preserves the previous tuple API;
`run/4` receives an additional `runtime_observations` schema v1. The campaign
worker organizes repetitions, while standalone `run/4` executes one input.

The supported model remains **synchronous binary harness with controlled descendants**.
Monitoring does not make arbitrary `spawn`, background OTP applications, external
messages, shared-state mutation or I/O supported. The
[guardian/isolation](execution-isolation.md) rules remain in force. There is no
production disposable-VM backend here.

## Configuration

Complete defaults (only overridden fields need to be supplied):

```erlang
runtime_oracles => #{
  enabled => false,
  stability => #{enabled => true, seed_runs => 3, interesting_runs => 3,
    suspicious_runs => 3, failure_runs => 3, compare_return => false,
    max_extra_executions => 1000},
  resources => #{enabled => true, sample_interval_ms => 20, max_samples => 64,
    max_sampled_processes => 128, ets_interval_ms => 100, max_ets_tables => 256,
    memory_bytes => 67108864, mailbox_messages => 1000,
    ets_memory_bytes => 16777216, residual_memory_bytes => 67108864,
    quiescence_ms => 1, memory_observation_timeout_ms => 50},
  hangs => #{enabled => true, max_stack_frames => 8,
    busy_reductions => 1000, max_sample_age_ms => 100},
  storage => #{max_groups => 128, max_representatives => 3,
    max_metadata_bytes => 1048576, max_total_metadata_bytes => 16777216}}
```

`efz_runtime_config:prepare/1` is the shared validator for the API, executor, CLI
and replay. All unknown fields and invalid types are rejected, including in
disabled sections.

| Field | Range / unit |
|---|---|
| `*_runs` | 1..16, **including the initial run** |
| `max_extra_executions` | 0..1 000 000 for the entire campaign, including seed verification |
| `sample_interval_ms` | 1..10 000 ms; interval after the preceding poll ends |
| `max_samples` | 2..256, the latest samples, not the first |
| `max_sampled_processes` | 1..256; product with `max_samples` ≤32768 |
| `ets_interval_ms` | 10..60 000 ms; the first ETS scan occurs only after the interval elapses |
| `max_ets_tables` | 1..4096 VM table IDs checked per scan |
| Resource thresholds | 1..2^40; process/ETS memory in bytes, mailbox in messages |
| `residual_memory_bytes` | 1..2^40 bytes, threshold for the VM-global binary-memory delta after cleanup |
| `quiescence_ms` | 0..100 ms, fixed wait after guardian DOWN |
| `memory_observation_timeout_ms` | 1..1000 ms, greater than quiescence; total deadline for one measurement, including the wait |
| `max_stack_frames` | 0..32, MFA only, without arguments/locals |
| `busy_reductions` | 1..10^9 in the latest interval, not CPU utilization |
| `max_sample_age_ms` | 1..60 000, at least the sample interval when hangs are enabled |
| `max_groups` / `max_representatives` | 1..1024 / 1..16 |
| `max_metadata_bytes` | 4096..4 MiB per finding payload |
| `max_total_metadata_bytes` | 4096..64 MiB, at least the individual quota |

The hangs section may collect process samples with `resources.enabled=false`.
Threshold-based resource findings are then disabled. If both sections are
disabled, there are no resource samples; lifecycle evidence remains available.

CLI:

```sh
escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin --artifacts ./instrumented \
  --seeds ./corpus --out ./findings --max-iterations 1000 --timeout 1000 \
  --runtime-diagnostics --runtime-runs 3 --verification-budget 1000 \
  --sample-interval 20
```

`--runtime-runs` sets all four repeat counts. Other runtime flags require
`--runtime-diagnostics`. The core validates numeric limits; the CLI does not
create atoms from module-name text: the target is resolved only from selected
artifacts or a local BEAM on the code path. The CLI still does not execute
Erlang expressions from arguments.

## Calibration and verification

Seeds, new successful coverage/count discoveries, target failures and suspicious
runtime inputs are repeated. `descendant_activity` alone does not trigger
additional checks. Every repetition is a **new standard executor/guardian/root**
with complete cleanup. There is no recursive verification. Repetitions do not
invoke the mutator, corpus selection, staged planner, feedback or retention.
The initial result passes through the existing feedback and remains the sole
source of retention for that candidate.

If `M` mutation executions and `S` seed executions are performed, the total number
of executions is at most `M + S + max_extra_executions`. A tighter bound on
additional runs is `min(budget, sum(requested_runs_for_selected_input - 1))`.
`max_iterations` does not include verification. Timeout and cleanup bounds apply
separately to each run; this bounds executions, not the campaign wall-clock time.

Any infrastructure failure immediately stops repetitions and the campaign. The
original reason remains in the failure context, including dirty-runner and
guardian failure. A crash, exit or timeout first seen on a repetition is saved
through ordinary crash storage with `metadata.origin=verification` and a new
occurrence. Each execution is counted exactly once. A runtime category does not
increment crash counters.

The outcome signature compares `ok`, exception class and bounded reason category,
exit category, or timeout. Arbitrary successful returns are **not compared**.
The optional return comparator accepts atoms, signed 64-bit integers, binaries,
lists, tuples/maps with independent budgets of 1024 nodes, 1024 binary bytes,
1024 container elements and depth 64. Maps are traversed with an unordered
iterator without sorting/copying keys; byte_size is checked before reading binary
content. Only a term that passes complete validation is serialized as deterministic
ETF. PIDs, refs, ports, functions, floats and large/deep terms receive
`not_comparable`. It does not infer the semantics of integer timestamps: when
compare_return is explicitly enabled, such values may differ.

EFZ's own metrics, **not equivalent to AFL++ stability**:

- Outcome repeatability = `100 * max_frequency(normalized_outcome) / completed`.
- Coverage repeatability = `100 * max_frequency({builds, exact_probe_set}) / valid`.
  For a fully usable series, `valid=completed`. An invalid/unstarted snapshot
  is excluded, not replaced by an empty set.
- Stable probes = intersection of valid sets. Variable probes = union − intersection.
- Stable-probe ratio = `100 * |intersection| / |union|`.
- Multiple valid empty sets: both coverage metrics are 100%, `valid_empty_coverage=true`.
- Fewer than two usable runs: `insufficient_samples`, even if the only run succeeded.

`requested` includes the initial run; `attempted=completed+failed`; `completed`
means runs without infrastructure failure; `valid` additionally excludes unstarted
coverage; `failed` means infrastructure failures; `skipped=requested-attempted`.
Each row includes duration, coverage/build identity, cleanup status and a runtime
summary. Verification has separate requested/executions/completed/valid/failed/skipped
counters. Coverage-integrity errors never become `unstable_coverage`.

## Observations and scope

| Category | What is measured / inferred | What it does not prove |
|---|---|---|
| `unstable_outcome` | Normalized outcomes differ in the series | A security vulnerability |
| `unstable_coverage` | Exact valid coverage set/build differs | A target bug or the cause of instability |
| `unstable_return` | Different comparable successful values, opt-in only | A semantic defect |
| `memory_pressure` | Observed sum of process memory ≥ threshold bytes | A leak; total VM/binary-resource memory |
| `memory_growth_suspected` | Growth between the first and last retained sample ≥ threshold | Residual growth across inputs / a memory leak |
| `vm_memory_growth_suspected` | VM-global binary memory after cleanup/quiescence minus baseline ≥ residual threshold | Target attribution or a confirmed leak |
| `mailbox_pressure` | Observed sum of message_queue_len ≥ threshold | Lost messages |
| `ets_growth_suspected` | Observed owned ETS memory peak ≥ threshold | A table leak after cleanup |
| `descendant_activity` | Guardian admission count and observed peak live count | A process leak |
| `child_abnormal_exit` | Abnormal child DOWN received by the guardian in the running phase | An unconditional defect or a change to root outcome |
| `timeout_busy` | Substantial reductions delta for matched owned PIDs | CPU utilization, livelock or lack of progress |
| `timeout_waiting` | Complete fresh samples: waiting and a small delta | Deadlock |
| `timeout_unknown` | Insufficient, stale, incomplete or ambiguous data | The cause of a timeout |

All resource thresholds are diagnostic: heap limits are unchanged and no extra
reasons to kill a process are introduced. `thresholds` stores baseline, observed,
threshold, interpretation and `defect=unproven`. `reproductions` shows the number
of runs with the category. The first failure is not hidden as warmup. There is
no forced GC of other processes or rollback of persistent_term/env/shared ETS.

The sampler receives only guardian-admitted PIDs through a separate bounded
table. `processes()` is not used to determine ownership. Guardian/coordinator,
sampler and coverage/corpus/reporting ETS are excluded. Memory, mailbox length,
reductions, status, current_function and a bounded stack are available during
execution. Mailbox/ETS/process-dictionary contents are not read. Process IDs in
the persisted summary are replaced with portable placeholders;
`process_id`/`owner_id` are admission ordinals.

The baseline is captured **before admission**: target-owned processes/ETS are
zero; VM counters have `scope=vm_global`. This is not a memory snapshot of an
already-running target.

A separate post-execution path measures `erlang:memory(binary)` before execution
and after confirmed cleanup **and normal guardian DOWN**, with bounded quiescence.
Measurements run in short-lived monitored helpers with their own deadline; they
do not run inside the guardian and do not delay kill/cleanup. A failed measurement
produces `incomplete`, not zero. Failed cleanup preserves the infrastructure
failure and does not proceed to residual observation. P0 off and resources off
do not invoke this path.

`post_execution_memory` contains scope=vm_global, metric=binary_memory, units=bytes,
baseline_memory, sampled peak_memory (or not_sampled), post_execution_memory,
residual_delta, threshold, completeness, cleanup_status, quiescence and deadline.
`owned_memory` separately preserves the target-owned peak; after the owners are
destroyed, post memory/residual are marked not_applicable rather than invented
exact measurements. GC of other processes, shared-state writes and ownership
changes are not used.

Attribution is explicitly limited: the VM delta includes EFZ-retained returns
and other VM activity. An ordinary return of a large reference-counted binary
is a supported fixture for residual VM allocation after root cleanup. This is
not a target leak. Verification stores the actual M/N; replay may produce a
different M/N because release of previous EFZ-held returns/VM activity offsets
new growth. The absence of a residual finding for a temporary allocation is
checked separately from the peak. Such findings also have scope=vm_global in
the artifact/signature; old schema-v1 artifacts remain readable, and missing
policy fields receive defaults. Snapshots during execution measure observed
peaks; the latest available samples are stored separately from after-cleanup
lifecycle evidence. If no live PID was polled, the result is `not_sampled`, not
zero consumption.

ETS `memory` in OTP 27 is measured in words and multiplied by
`erlang:system_info(wordsize)`:
[official ETS info documentation](https://www.erlang.org/docs/27/apps/stdlib/ets.html#info/2).
The ETS scan runs in the sampler at a separate frequency and with a cap. It
lists VM table IDs through `ets:all()`, but checks only the first
`max_ets_tables`, filtering by owner. It shows known VM tables / scanned VM tables /
observed owned tables, and `partial=true` if traversal is incomplete or a resource
disappears. The total number of owned tables is unknown when a scan is truncated.
This does not claim that a partial sum equals target consumption. Disappearance
checks request only `ets:info(Tab, owner)`, without constructing a complete list
of table metadata. `ets:all()` itself remains O(number of VM tables); the cap
bounds subsequent checks, not that enumeration. The guardian's previous
shared-state snapshots (`ets:all()` before/after a case) remain part of the
cleanup contract; the new sampler does not add an ETS scan to every fast iteration.

The sampler stores a ring of the latest `max_samples`; the peak is preserved
independently of the ring. It monitors the guardian, and the guardian monitors
the sampler. Cleanup first destroys target processes, then the sampler. The
guardian does not request one final `process_info` or wait for an “ideal” snapshot
before killing processes. Sampler DOWN is part of the bounded cleanup lifecycle.
Independent sampler death is marked failed/partial and does not replace the
outcome. Loss of the guardian itself preserves the dirty-runner policy.

Child DOWN during running records the reason category and phase; the initiator
is usually unknown: a monitor does not prove that the parent stopped the child.
Cleanup marks kill_requested; DOWN received in the cleaning phase has
classification=unknown because of the race with natural death. Cleanup kills
do not create child_abnormal_exit. `after_cleanup` reports confirmed owner
termination and known survivors; escaped ETS/shared state still produces the
existing infrastructure failure, not a resource finding.

Timeout preserves the original outcome/deadline. Classification uses the last
two samples, matches PIDs and records age, interval, matched/observed process
counts, reductions delta, statuses, mailbox and bounded stacks. Partial activity
may prove observed busy activity; waiting requires complete samples. Information
about every process that completed between samples cannot be reconstructed.

## Storage, report and replay

Storage sits beside `crash_dir`: `dirname(crash_dir)/runtime-findings/`;
for the CLI, this is `OUT/runtime-findings/`. It is independent of crash groups.

```text
runtime-findings/
  index                       checksummed EFZO v1 index
  SIGNATURE_HASH-INPUT_HASH/
    artifact.input            exact raw bytes
    artifact.term             bounded ETF schema v1
    manifest                  hashes and sizes of both files
```

The record contains the input SHA-256, category/scope/origin, portable harness/build
identity, normalized original outcome, policy/thresholds, bounded evidence with
all checks, and the **original exact mutation recipe**, if present. Raw input is
always preserved for a selected representative, regardless of recipe availability.

Signature = SHA-256 of version/category/scope/harness/builds. PIDs, refs, timestamps
and specific memory deltas do not participate. This grouping may combine distinct
causes. `max_representatives` limits distinct inputs per group; `max_groups` limits
groups in the store; suppressions and drops are counted separately. The metadata
quota includes payloads, manifests and the index; raw bytes are additionally
bounded by `max_groups * max_representatives * max_input_bytes`. An oversized
payload causes a representative drop, not unbounded serialization/writing.
There is a fixed limit of 128 report checks and a byte quota; `checks_dropped`
records truncation. The store preserves counters/caps across campaigns.

A group is published atomically with fsync/manifest, followed by an atomic index
update. An interrupted interval, corrupt committed entry, stale writer/index or
remaining `.writer-lock` is an explicit storage failure that stops the campaign.
There is no automatic deletion/“repair”; use a new output directory after
investigating the error. The single-writer lock does not permit different
campaigns to run concurrently with stale in-memory indexes.

Example report fragment (schema, not a promise of particular measurements):

```erlang
#{runtime_diagnostics => #{
    verification_executions => 2,
    checks => [#{requested => 3, completed => 3, valid => 3, failed => 0,
                 skipped => 0, origin => calibration,
                 outcome_repeatability => 100.0,
                 reproductions => #{timeout_waiting => 3}}],
    findings => #{groups => #{}, suppressed => 0, dropped => 0}},
  stats => #{executions => 0, calibrations => 1, verification_executions => 2}}.
```

Check a selected representative directory, **with an explicit local target**:

```sh
escript scripts/replay.escript \
  --runtime-finding ./findings/runtime-findings/SIGNATURE_HASH-INPUT_HASH \
  --target my_harness --code-path ./harness-ebin --artifacts ./instrumented --runs 3
```

API: `efz_replay:runtime(Directory, LocalTarget, Artifacts, #{runs=>3})`.
Policy/timeout/input limit come from the finding; `runs` is 1..16 and defaults
to the saved interesting_runs. Target/artifacts come only from the caller.
Raw SHA-256, manifest, build and harness are checked before execution. Safe ETF
decoding does not create target-derived atoms. `observed` gives exit 0;
`not_observed` or `inconclusive` gives exit 3; incompatibility/invalid invocation
gives exit 2; infrastructure failure gives exit 1. Old crash `.replay`, recipes
and raw-input CLI remain supported.

For unstable categories, one run gives inconclusive; the report shows sample
count, repeatability and variable fraction. Even `not_observed` describes only
the result of a finite sample. For resources, a lack of complete samples gives
inconclusive, not proof that no problem exists. Repetition uses the same executor
and stops on infrastructure failure. Replay does not write new campaign crash
groups: a failure found during repetition is included in the returned summary.
Campaign verification saves it to disk.

## Cost and limitations

`stats` separates mutation executions, calibrations and verification. There are
separate measurements for verification elapsed time, post-execution
`runtime_diagnostic_us` (worker wall time including verification and storage,
excluding the initial executor), sampler work time, sampled/missed executions,
and the maximum bytes of the ETS diagnostic buffer measured at run completion.
The last metric **does not include sampler/guardian/report heap**; sample slots,
child records, the report and disk metadata have separate bounds. Snapshot
copying/worker comparison/storage also take time; `sampling_us` is not the total
P0 cost. These are cooperative BEAM diagnostics, not a real-time scheduling
guarantee.

P0 does not prove memory safety, arbitrary resource leaks, race conditions,
deadlock/livelock as a cause, native failures, semantic correctness or external
side effects. There is no FD/socket leak detector, NIF/ASan/UBSan/LSan, scheduler
perturbation, stateful/sequence fuzzing, distribution, power scheduling or
unstable-probe masking. The full off-heap binary footprint is not measured.
Samples miss fast peaks and quickly terminated children/tables. State-dependent
growth may require an input history or a fresh VM; a single raw input is not
guaranteed to reproduce such growth.

Actual commands, results and measurement limitations: [validation report](runtime-diagnostics-validation.md).
