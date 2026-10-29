# Persistent target and sequence audit validation — 29 October 2026

Implementation commit: `c1b5df1` on `feat/persistent-target-stability`, based on
the local feature-stability commit `3fd3dd826d9f4c34197cff3114b663d377d677fa`.
The `vendor/erlamsa` gitlink remains
`191f3d9d30d8932319b98f4af25d3dff9ddc5824`. No fork change, push, or
merge was performed. Machine-readable per-campaign measurements are in
[benchmark-c1b5df1.json](persistent-target-evidence/benchmark-c1b5df1.json)
(SHA-256 `3b35d9a9f170ed736106d09bea68331b9af390770bd7ba88f2c204191ab63924`).

Environment: Linux `6.8.0-nyx+` x86_64, OTP 27 / ERTS 15.0, Python 3.12.3,
`ERL_FLAGS='+S 2:2'`; the child target VM uses `+S 1:1`. Rebar3 is 3.25.0.
Gleam was not installed. The code is local and unmerged.

## Verification

| Command / check | Result | Evidence |
| --- | --- | --- |
| `ERL_FLAGS='+S 2:2' rebar3 compile` | PASS, exit 0 | warnings as errors retained |
| `ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_feature_stability_tests,efz_feature_stability_live_tests,efz_persistent_target_tests` | PASS, exit 0 | 31 focused tests, including the first-stage math/live tests |
| `ERL_FLAGS='+S 2:2' rebar3 eunit` | PASS, exit 0 with local Unix sockets permitted | 417 tests |
| `ERL_FLAGS='+S 2:2' rebar3 ct` | PASS, exit 0 | 3 Common Test cases |
| `ERL_FLAGS='+S 2:2' rebar3 xref` | PASS, exit 0 | no unresolved calls |
| `ERL_FLAGS='+S 2:2' rebar3 dialyzer` | PASS, exit 0 | 87 project files analysed |
| `PYTHONPATH=packages/pyefz/src python3 -m unittest discover -s test -p '*tui*test.py' -v` | PASS, exit 0 | 8 presentation tests |
| `PYTHONPATH=packages/pyefz/src python3 -m unittest discover -s test -p 'pyefz_persistent_target_test.py' -v` | PASS, exit 0 | real campaign, exact bytes and prefix replay |
| `PYTHONPATH=packages/pyefz/src python3 -m unittest discover -s test -p '*test.py' -v` | PASS on repeat with local process/socket access, exit 0 | 40 tests, 8 optional-runtime skips; the preceding full run had 2 native-supervisor timing failures |
| `PYEFZ_EFZ_ROOT=$PWD PYEFZ_ARTIFACTS=$PWD/_build/persistent-target-benchmark-c1b5df1/stateless PYEFZ_CORE_PATH=$PWD/vendor/erlamsa PYTHONPATH=test:packages/pyefz/src python3 -m unittest pyefz_e2e_test -v` | PASS with local process/socket access, exit 0 | all 6 compiled-runtime SDK tests, no skips |
| Native/erlamsa/hybrid with persistent target via Python `Client.start` | PASS, exit 0 with local Unix socket permitted | all completed; each had 3 mutations, 5 journaled target steps and 1 target VM start |
| Erlamsa `transport=persistent` with persistent target | PASS, exit 0 with local Unix socket permitted | 1 provider VM start and 1 independent target VM start |
| `escript scripts/prepare_stateful.escript` | PASS, exit 0 | instrumented fixture build `6925673dd87dfe6dde247296acc73a19973358bfee4bbf1dd443c4364edd28e7` |
| `escript scripts/fuzz.escript --help` | PASS, exit 0 | working persistent config and sequence replay examples appear |
| `escript scripts/fuzz.escript --config examples/stateful/persistent.config --out _build/persistent-target-cli-c1b5df1` | PASS, exit 0 | 2 primary calibration steps, 6 diagnostic calls, completed report |
| `escript scripts/sequence_replay.escript examples/stateful/persistent.config _build/persistent-target-demo _build/persistent-target-cli-c1b5df1/crashes/sequences/46c76b5d5244ee0c7be72a7aba2695f5.jsonl 2` | PASS, exit 0 | both steps used OS PID 136 and driver `<0.84.0>`; second result `armed_path` |
| `escript scripts/tui_bridge.escript examples/stateful/persistent_live.config /tmp/efz-persistent-tui-live` | PASS, exit 0 | final snapshot and report both showed `audited_sequence_steps`, 2 groups, 100%, revision 82; 20 deferred repetitions, 40 audit calls |
| Gleam profile | NOT RUN | Gleam binary absent; optional layer independent of this target mode |
| Native NIF that cannot yield, detached OS descendants | NOT RUN | the timeout test uses a blocked Erlang receive; these failure modes need dedicated fixtures |

The full EUnit run initially failed 8 pre-existing Unix socket tests under
the restricted sandbox. The same failures reproduced on a clean checkout of
`3fd3dd8`; the module passed when local socket access was permitted. The
complete 417-test final run used that access.

The first unrestricted Python discovery run failed 2 subcases in the existing
native supervisor SEGV/ABRT test (`worker_hard_timeout` instead of expected
crash; replay count 0 instead of 2). A focused rerun of the test passed, then
the full discovery rerun passed 40 tests with 8 environment-gated skips. This
timing sensitivity remains visible in the validation record; the independent
compiled-runtime SDK set was then run with its fixture/core variables and all
6 tests passed.

## Observable behavior

The real session test executes 1,000 inputs with one OS VM PID and one Erlang
driver PID. It observes process dictionary and OTP service counters increasing
to 1,000, no driver mailbox buildup, and bounded process/ETS counts. A separate
sequence `[fire, arm, fire]` produces a changed result for the second `fire`
after its prefix, while two independent replays of each full history yield
100% presence-feature stability in three distinct step groups. This records
history sensitivity separately from same-sequence variation.

The controlled-variable fixture has different coverage in independent
repetitions of the *same* sequence. A live test pauses repetition 3: the
cached snapshot is already 100% after two valid observations; releasing the
third step changes it to less than 100% before repetition 4 or campaign
completion. Stop during audit retains that measured value and reports a
stopped collection. A second synchronized test requests stop while the
primary target is blocked: after releasing that step the report is
`stopped_by_user`, the journal contains exactly one dispatched input, the
target VM is down, and no deferred audit starts. Crash and timeout retire the
epoch; the dispatch row for the failing input remains in the complete journal.
A capped journal reserves
space for its end row and replays the fully recorded prefix.
An OS-killed child VM returns a session error, marks the session down and does
not produce a successful target step or silently restart the epoch.

Automatic `ets`/`ets_member` coverage is supported. Other persistent/backend
combinations fail during configuration. The helper fixture uses a linked
covered process and explicit `step_barrier/1`; arbitrary background target
work without such a barrier has no validated full per-step window. The
presence score is not hitcount stability or a probability of deterministic
behavior.

## Performance experiment

The script was run exactly as follows from the repository root:

```sh
python3 scripts/benchmark_persistent_target.py \
  --out _build/persistent-target-benchmark-c1b5df1 --seconds 3 --cases 80
```

Each mode/seed received one uncounted complete-campaign warm-up and at least
three seconds of completed 80-input campaigns. Seeds were 17, 29, 43, 61, 89;
mode order rotated by seed. Inputs, target BEAM hash, OS, scheduler flags, each
sample's campaign status, target calls, startup, latencies, journal bytes and
sampled process-tree RSS are in the raw JSON. The 3-second windows are short;
the wide seed spread below prevents a strong throughput conclusion. The
isolated and persistent *stateless* rows use identical parser inputs and
build. The stateful rows use the separate counter fixture and must not be
compared to the parser as a speedup claim.

| Mode | Measured campaigns | Median of five seed medians, primary calls/s | Seed-median range | Warm request p50, median of campaigns | Child step p50 | Median target startup | Median sampled tree RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Isolated stateless | 24 | 117.8 | 92.1–144.2 | N/A | N/A | N/A | 83,824 KiB |
| Persistent stateless | 21 | 103.5 | 86.5–111.0 | 1,638 µs | 92 µs | 183,409 µs | 83,484 KiB |
| Persistent accumulate, stateful | 21 | 90.6 | 81.2–104.9 | 2,158 µs | 261 µs | 200,101 µs | 84,080 KiB |
| Persistent accumulate + 2 deferred audits | 12 | 44.9 | 43.4–60.3 | 2,028 µs | 240 µs | 183,168 µs | 85,264 KiB |

All 80 primary calls completed per campaign. The audited mode performed 160
additional diagnostic calls and started two sequential audit VMs after its
single primary target VM. It measured 100% presence stability on the
deterministic fixture. The measured stateful primary rate falls from 90.6 to
44.9 calls/s when full audit startup and prefix replay are included; the
reported total target-call rate also includes the 160 audit calls. Median
journal size was 49,156 bytes for 80 stateful steps. RSS is a sampled lower
bound from `/proc`, not a hard memory cap.

This implementation establishes state persistence and exact sequence audit,
but does **not** demonstrate a throughput advantage for short epochs. The
stateless 80-input persistent campaign was slower than isolated execution in
this measurement. Startup and parent/peer IPC are visible costs; the child
step time and parent roundtrip overlap and must not be summed. More workload
sizes and longer steady-state runs are needed before recommending a default
change. The default remains isolated.

## Reproduce the stateful path

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
escript scripts/prepare_stateful.escript
escript scripts/fuzz.escript --config examples/stateful/persistent.config \
  --out _build/persistent-target-run
escript scripts/sequence_replay.escript examples/stateful/persistent.config \
  _build/persistent-target-demo \
  _build/persistent-target-run/crashes/sequences/EPOCH.jsonl 2
python3 scripts/tui.py --config examples/stateful/persistent_live.config \
  --out /tmp/efz-target-tui
```

Replace `EPOCH.jsonl` with the file produced in that run. In TUI, `s` requests
stop and saves the report; `q` detaches without stopping the campaign. The
sequence replay executes `arm` and then `fire` in one new VM and returns
`armed_path`. For SDK use, see [persistent-target.md](persistent-target.md).

## Limits of this first implementation

There is no generic BEAM snapshot or state reset between steps. Target memory,
process/ETS/port/mailbox budgets are sampled after completed steps, and the
step timeout triggers external VM termination. VM memory sampling does not
bound native allocations or RSS. Independent repetitions are sequential;
continuous primary execution and replay audit cannot run simultaneously with
the one-target-VM policy. The isolated guardian intentionally rejects the
stateful fixture's long-lived OTP service, so the isolated control uses a
stateless parser harness. Optional Gleam and Erlamsa catalog completeness
remain separate from this target-mode work.
