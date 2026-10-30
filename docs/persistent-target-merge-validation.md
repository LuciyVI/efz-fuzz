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
tested `setsid` process-group escape. A snapshot that reaches its 1024-child
bound returns an explicit infrastructure error and retires the epoch, rather
than reporting an ordinary target result. It is not a cgroup/subreaper
guarantee: a double-forked child reparented before observation, or descendants
omitted after the cap, are outside the verified cleanup boundary. Use an
OS-level supervisor for such targets.

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
| `PYTHONPATH=packages/pyefz/src PYEFZ_CORE_PATH="$PWD/vendor/erlamsa" python3 -m unittest discover -s test -p 'pyefz_persistent_target_test.py' -v` | 0 | 3 real-runtime SDK tests: sequence replay, four provider/transport combinations with one target VM each, continuous stop and corpus restart in a new client |

The full EUnit run and focused rerun required local Unix socket and OS process
access. A restricted sandbox can fail provider setup before the target is run.
No target crash was fabricated from such setup failures.

The new SDK matrix used the actual pinned Erlamsa core, 10 mutation iterations
per mode and a stateful target. Native, Erlamsa disposable, Erlamsa persistent
and hybrid persistent each completed 12 target steps (two seed calibrations and
10 mutations), with one target VM and a complete journal. Erlamsa modes made
real provider requests; persistent transport reported one separate provider VM.
The continuous run stopped by request, saved corpus entries, and a new client
restarted from the same corpus with an empty explicit seed list for two more
iterations in a new epoch. An initial test attempt reused the same SDK Client
for a second campaign and failed with `BadConfig`; the corrected test opens a
new Client, as required by its campaign lifecycle contract.

## Independent checkout and final-code measurement

The review commit `bc29c4758a433fe5af651bdef04483eef359cde7` was cloned
locally with `git clone --no-local` into a new object store with no Git
alternates. Recursive submodule initialization resolved the declared HTTPS URL
through a local URL rewrite to the pinned fork mirror; the checkout gitlink
was `191f3d9d30d8932319b98f4af25d3dff9ddc5824`. Standard and Erlamsa
profile builds both exited 0. This verifies independent Git objects and the
recorded gitlink.

The previously blocked **remote** checkout was subsequently reproduced from
GitHub for both published `dev` at `eceef451eca37ab7fa9c99c20165d47d087683d1`
and review commit `4fcaa4832e41d34ddc27c8353aa19c3a2a0288b9`. Each fresh
clone used the repository HTTPS URL and `--recurse-submodules`; Git fetched the
submodule object directly from `LuciyVI/erlamsa`. No local Git alternates or
URL rewrite were used. Both clones reported gitlink and checked-out submodule
`191f3d9d30d8932319b98f4af25d3dff9ddc5824`; `rebar3 compile` and
`rebar3 as erlamsa compile` both exited 0 in each clone. Pinned Cowboy,
Cowlib and Ranch commits were fetched through the normal Rebar3 dependency
configuration. The working network path was to unset proxy variables for the
Git process in the authorized network context:

```sh
env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
    -u ALL_PROXY -u all_proxy GIT_TERMINAL_PROMPT=0 \
    git clone --branch integrate/dev-persistent-target-review \
      --single-branch --recurse-submodules \
      https://github.com/LuciyVI/efz-fuzz.git /tmp/efz-remote-review
cd /tmp/efz-remote-review
env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
    -u ALL_PROXY -u all_proxy ERL_FLAGS='+S 2:2' rebar3 compile
env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
    -u ALL_PROXY -u all_proxy ERL_FLAGS='+S 2:2' rebar3 as erlamsa compile
```

The two build commands above ran with the same six proxy variables unset for
dependency fetching. This is a command-local environment setting; no global
Git or proxy configuration was changed.

The same clean checkout ran a short final-code benchmark:

```sh
PYTHONPATH=packages/pyefz/src ERL_FLAGS='+S 2:2' \
  python3 scripts/benchmark_persistent_target.py \
  --out _build/final-target-benchmark --seconds 1 --cases 80
```

It used the five fixed seeds 17/29/43/61/89, one full warm-up campaign per
mode/seed, rotating mode order, and exactly 80 primary inputs per campaign.
All 56 measured campaigns completed. The median of each seed's median
primary executions/s was:

| Mode | Primary executions/s | Measured campaigns | Target VM starts per campaign |
| --- | ---: | ---: | ---: |
| Isolated stateless | 144.3 | 16 | 0 persistent session starts |
| Persistent stateless | 128.1 | 15 | 1 |
| Persistent stateful | 98.6 | 15 | 1 |
| Persistent stateful with sequence audit | 47.9 | 10 | 1 primary, 2 audit |

The one-second windows are too short for a precise throughput comparison.
The audit mode replays full prefixes, so its primary rate also includes
diagnostic work. Every raw campaign, timing, RSS sample, status, and build
identity is retained in [final review data](persistent-target-evidence/final-review-raw.json)
(SHA-256 `0489bffce90b5f159870a2c62af9b6065615e2a8289664a04d46b5c14e8302b2`).
The input/harness build and seed are fixed within each corresponding mode;
stateless and stateful modes intentionally use different harnesses, so their
rates are not a controlled comparison of execution mode alone.

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

GitHub API confirmed the pinned Erlamsa fork commit and exact merge objects,
and the remote recursive checkout gate above now passes. The localized
RU/ES/zh-CN persistent-target pages are quick references, not full translations
of the English technical contract. The tested OS cleanup boundary still
excludes descendants reparented before observation and those beyond the 1024
snapshot cap. The wider integration therefore remains PARTIAL; the review
branch stays outside `dev` pending an explicit acceptance decision on these
remaining limits.
