# Persistent target merge validation (2026-10-30)

This follow-up applies to the review merge of `feat/persistent-target-stability`
with the documentation/harness and Erlamsa runtime chains. It extends, rather
than rewrites, the historical [persistent target validation](persistent-target-validation.md).
The feature remains **outside `dev`** until the gates below are resolved.

## New lifecycle fault checks

The review branch adds a synthetic `setsid -w sleep` child to the local
stateful fixture and reuses the test-only C NIF from
`fixtures/external/efz_native_fixture.c`. The NIF spins on its scheduler. It is
loaded only in the separate target VM; it is never loaded into EFZ's controller
VM. Tests assert that the OS process group of the spawned child differs from
the target VM's group, that the child is alive before cleanup, and that both
its PID and the target VM PID disappear from `/proc` after orderly close or
a NIF timeout. A combined case launches the detached child before entering
the hanging NIF. The timeout retires the epoch and a later input is refused.

On Linux the session owner records bounded `/proc/.../task/*/children` snapshots
after completed steps and before retirement. A PID is signalled only if its
kernel start time still matches the recorded value. Former child identities
that no longer exist are removed from the session state. This covers the
tested `setsid` process-group escape. It is not a cgroup/subreaper guarantee:
a double-forked child reparented before observation, or a tree larger than
1024 live descendants, is outside the verified boundary. Use an OS-level
supervisor for such targets.

## Checks on this review branch

Environment: Linux x86_64, OTP 27.0 / ERTS 15.0, Rebar3 3.25.0,
Python 3.12.3; commands use `ERL_FLAGS='+S 2:2'`.

| Command | Exit | Observed result |
| --- | ---: | --- |
| `rebar3 compile` | 0 | Target/session code compiled with warnings as errors |
| `rebar3 eunit --module=efz_persistent_target_tests` | 0 | 22 tests, including NIF timeout and detached child cleanup |
| `rebar3 eunit` | 0 | 438 tests on the final review code, repeated after the xref fixture adjustment |
| `rebar3 ct` | 0 | 3 tests |
| `rebar3 xref` | 0 | Initial run reported the test-only dynamic NIF call as undefined; fixed and re-run cleanly |
| `rebar3 dialyzer` | 0 | 110 project files analyzed |
| `rebar3 as erlamsa compile`, `rebar3 as gleam compile`, `rebar3 as erlamsa,gleam compile` | 0/0/0 | Pinned core and Gleam 1.10.0 built separately and together |
| Combined-profile focused EUnit for target, feature stability, Erlamsa and Gleam | 0 | 44 tests |
| `python3 -m unittest discover -s test -p 'pyefz_persistent_target_test.py'` | 0 | SDK sequence campaign and raw prefix replay |

The full EUnit run and focused rerun required local Unix socket and OS process
access. A restricted sandbox can fail provider setup before the target is run.
No target crash was fabricated from such setup failures.

## Short before/after cost check

Both runs used the same `benchmark_persistent_target.py` script, 80 exact inputs
per campaign, fixed seeds 17/29/43/61/89, `+S 2:2` in the controller and
`+S 1:1` in the target peer, one full warm-up campaign per mode/seed, and at
least one second per mode/seed. Runs were rotated by seed index. All recorded
campaigns completed. The first run used the committed pre-cleanup merge
`eb86db051b2f74f5ac11080622114d354d7f1047`; the second had the new
cleanup code as an uncommitted diff recorded by `git_diff_sha256` in its raw
metadata. The later test-only xref adjustment does not change the cleanup
algorithm, but this is not a byte-identical benchmark of the final commit.

| Mode | Before median of five seed medians, primary/s | After | Scope |
| --- | ---: | ---: | --- |
| Isolated stateless | 129.1 | 114.0 | Control; changed with ambient noise |
| Persistent stateless | 125.6 | 115.0 | Includes session lifecycle |
| Persistent stateful | 96.9 | 103.7 | Includes target state accumulation |
| Persistent stateful + audit | 54.5 | 48.9 | Includes prefix replay |

The one-second windows produced only one or two measured campaigns per
mode/seed. The isolated control shifted substantially, so these numbers do not
establish a precise overhead or speedup from descendant tracking. Raw samples,
warm-ups, statuses, build hashes, order and RSS method are retained in
[before](persistent-target-evidence/os-cleanup-before.json) and
[after](persistent-target-evidence/os-cleanup-after.json). No historical
Erlamsa benchmark is re-labelled as this result.

## Publication gate

GitHub API confirmed the pinned Erlamsa fork commit and exact merge objects.
Direct Git HTTPS still returned `Proxy CONNECT aborted`, so a fresh remote
recursive checkout of the final EFZ commit has **not run**. The localized
RU/ES/zh-CN persistent-target pages are quick references, not full translations
of the English technical contract. These limits keep the integration status
PARTIAL even though the new fault fixtures pass.
