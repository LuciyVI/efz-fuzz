# Feature stability in the existing campaign TUI

Localized quick references: [Русский](i18n/ru/feature-stability.md) · [Español](i18n/es/feature-stability.md) · [简体中文](i18n/zh-CN/feature-stability.md).

`feature_stability` is an EFZ presence metric for audited inputs. For each
fixed input group, let `F_r` be the **full** set of features observed in valid
execution `r`. The worker updates `U = union(F_r)` and
`I = intersection(F_r)` after each valid execution. It reports
`100 * |I| / |U|` when at least two valid executions exist and `U` is nonempty.
The variable count is `|U| - |I|`. The campaign aggregate is
`100 * sum(|I_x|) / sum(|U_x|)` over measured input groups, counting each
group/feature pair separately. An active group contributes provisionally from
its second valid observation; each update replaces its previous contribution.
The worker retains exact bounded union/intersection sets, not all traces for
this calculation. A group can receive later observations until its 256
execution identities are filled; duplicate execution identities are ignored.
When the same group is calibrated again, its requested total also grows, so
the live `valid_runs/requested_runs` counters retain their cumulative meaning.

The group key hashes the exact input bytes, target and execution identities,
coverage backend/schema fingerprint, coverage mode, feedback, validation mode,
and timeout. The feature identity contains the backend, schema/build context,
and original feature ID. `feature_kind` is `probe_presence` for instrumented
ETS/bitmap, `line_presence` for OTP native line coverage, and
`manual_unit_presence` for manual coverage. Hit count values are not included.
For bitmap, full features come from the sealed diagnostic snapshot after a
completed coverage window, even when ordinary feedback has no novelty.
Diagnostic executions do not update corpus admission, campaign coverage,
mutation RNG, or parent selection.

`feature_stability` is distinct from overall coverage, `coverage_repeatability`
of full traces, and `outcome_repeatability`. A measured 100% means no feature
presence difference was observed in these repetitions. It is not a probability
of target outcome reproduction or proof of full determinism.

The value is `null` with `insufficient_samples` before two valid observations,
`no_observed_features` when valid observations have an empty union, `disabled`
when runtime stability is off, and `unsupported_backend` for backend `none`.
Invalid/missing coverage is excluded and counted in `invalid_attempts`; a
bounded `invalid_reasons` breakdown is included in snapshots and reports. A
valid empty trace remains a valid observation. `collection_status` separately
reports `collecting`, `complete`, `partial`, `budget_exhausted`, `capped`, or
`stopped`. A partial group with two valid observations retains a provisional
number. Existing `stable_probe_ratio` remains in historical diagnostic checks
with its old empty-union convention; the new object is authoritative. Old
snapshots without it display `Stability: unavailable`.

The default runtime oracle is off. To enable only stability in a campaign map:

```erlang
runtime_oracles => #{enabled => true,
    resources => #{enabled => false}, hangs => #{enabled => false},
    stability => #{enabled => true, seed_runs => 20,
        interesting_runs => 3, suspicious_runs => 3, failure_runs => 3,
        max_extra_executions => 1000, max_groups => 128,
        max_features_per_group => 8192}}
```

`seed_runs => 20` requests **20 total observations**, normally the initial
execution plus 19 diagnostic calls. All four run counts accept 1..256; the
extra-execution budget remains global to the campaign. New groups stop at the
configured group cap. A group whose exact union exceeds its feature cap is
excluded rather than assigned a percentage from truncated data. The aggregate
is scoped to `audited_inputs`, not all corpus entries. The worker stores at
most 256 execution identities per group and no unbounded trace list for this
metric. Diagnostic evidence in `runtime_checks` has a separate byte cap and
may be dropped without altering the aggregate.

Build and start the bundled demo in an interactive terminal:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
python3 scripts/tui.py --demo --out /tmp/efz-stability-demo
```

The demo explicitly enables stability with 20 seed observations. The main
screen displays the measured percent, state, audited group count, age, and
stable/observed/variable counts. The line remains visible on the provider
panel. `s` requests orderly stop and saves `snapshot.json`, `report.term`, and
`report.json`;
`q` detaches while the campaign continues. Reattach with
`python3 scripts/tui.py --attach /tmp/efz-stability-demo`. The bridge writes
the complete snapshot atomically every ~500 ms. The coordinator accepts
revisioned progress messages between synchronous verification calls; polling
never executes a target. The viewer computes age from its local read time and
the snapshot's elapsed values, without mixing Erlang and Python monotonic
timestamps.

The isolated executor retains the `audited_inputs` behavior above. The opt-in
stateful target VM uses `scope=audited_sequence_steps`. It never inserts the
same-input verification loop into a live primary epoch. Instead, deferred
audit (and optional preflight) start fresh sessions sequentially and replay
the exact same ordered bytes from init through the measured step. The group
key adds the init identity, step index, prefix hash and input hash, and never
contains epoch/PID, outcome or observed coverage. The same formula and
weighted aggregate in `efz_stability` remain authoritative. Audit progress
updates the existing nested snapshot object between steps; during a long
primary epoch the latest audit value retains its age and scope. A current
primary step with no comparable replay is pending, not newly measured.

An audited step after `k` prefix inputs costs up to `repeats * (k + 1)` extra
target calls with this implementation because primary results are excluded.
For `repeats=20`, that is 20 full prefix replays, not 19 single-input calls.
One pass observes all reached step positions. Preflight and deferred phases
each have an explicit `max_calls`/`max_elapsed_ms` budget. Missing suffix
steps after a crash are not inserted as empty traces. At `budget_exhausted` or
stop, a measured partial aggregate is retained. The journal and same-sequence
contract are described in [persistent-target.md](persistent-target.md).

`history_sensitivity` is separate: it compares the same bytes seen after
different primary prefixes. A difference can be the expected consequence of
accumulated state. It is not merged into the feature stability percentage.
Both metrics describe observations, not a probability or proof of total
determinism. Extra diagnostic calls are counted separately and do not enter
the TUI primary executions/second numerator.

## Local validation

From the repository root, the focused checks are:

```sh
ERL_FLAGS='+S 2:2' rebar3 eunit --module=efz_feature_stability_tests,efz_feature_stability_live_tests
python3 test/tui_test.py
python3 test/pyefz_tui_test.py
```

In the local native demo, `snapshot.json` progressed from revision 0 with
`status=insufficient_samples` and `percent=null` to a measured value while the
campaign was still running. After orderly stop, both the snapshot and final
report contained `status=measured`, `collection_status=stopped`, `percent=100.0`,
`stable_feature_pairs=32`, `observed_feature_pairs=32`, and
`groups_measured=30`; the current group showed 9/9 cumulative observations.
This is evidence for those thirty audited groups only.
The controlled test target independently verifies a live transition from
100% after two identical observations to a lower value after a differing
third observation, before the fourth execution and campaign complete.
