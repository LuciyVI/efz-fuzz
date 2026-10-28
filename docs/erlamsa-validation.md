# Erlamsa integration validation

Historical status on 2026-10-27: **PARTIAL; remote fork/submodule acceptance
was BLOCKED at that time**. The final 2026-10-28 verification section below
supersedes earlier fork, gitlink, and clean-checkout status statements. This
report records execution evidence; installed tools and implemented test files
do not count as completed checks. Main's completed P5 semantic-adapter
acceptance is not repeated and does not establish Erlamsa acceptance.

## Source and environment audit

| Item | Observed value |
| --- | --- |
| EFZ integration worktree | `/workspace/efz-erlamsa` |
| EFZ branch | `feat/erlamsa-integration` |
| EFZ starting/default-main HEAD | `db1add0bc47bc1011d55a4cb528b741a0b870f97` |
| Published EFZ checkpoint | `d5dc25ecd1f61fc8c4e1fc9ba97219b79363ab60`; implementation updates through `ff50194`, followed by evidence/test commits on the same branch |
| Preserved original checkout | `/workspace/efz-fuzz`, clean `feat/xmlrpc-harness-suite` at `199f564017ae389f25963b0cbc170105fde02511` |
| Initial submodules | None |
| Upstream | `https://github.com/Darkkey/erlamsa`, default branch `master` |
| Verified upstream base | `4a844bcd1083e3278c10405bb415a32871b216c3` |
| Required fork | `https://github.com/LuciyVI/erlamsa`, existence/parent relationship UNVERIFIED |
| Local core checkout | `/workspace/erlamsa-core`, `efz-integration`; upstream history retained |
| Fork origin / upstream remotes | `https://github.com/LuciyVI/erlamsa.git` / `https://github.com/Darkkey/erlamsa.git` |
| Local integration HEAD | `86dd745aafb8ebe78f578c51f783132800b89238` (clean, not published) |
| Published fork integration SHA | BLOCKED; no published object verified |
| Accepted EFZ gitlink SHA | BLOCKED; no unpublished object substituted |
| Runtime | Erlang/OTP 27, ERTS 15.2.7 |
| Tools | Rebar3 3.25.0; Python 3.12.14; Gleam 1.10.0 |
| OS / architecture | Linux 6.18.55, x86_64 |
| CPU flags | `ERL_FLAGS='+S 2:2'`; disposable child uses `+S 1:1 +A 1` |

The audit is also saved as [audit.json](erlamsa-evidence/audit.json). No user
worktree was reset, cleaned, or force-pushed. The EFZ integration branch starts
at actual remote main, preserving unrelated feature work in its own checkout.
Local core changes are split into build/API, pure tree ports, bounded formats/
fields, regression tests, and explicit disabled-name validation: `277b5b4`,
`cb5f742`, `12eedde`, `92ebefd`, `86dd745`.

## Before/after checks

Baseline checks ran in a pristine EFZ worktree at the starting SHA. Commands use
OTP27 and `ERL_FLAGS='+S 2:2'`. Times are observed wall time. The final results below come from completed commands; earlier failures and
their corrections are recorded separately.

| Check | Baseline exit / result / seconds | Integration result |
| --- | --- | --- |
| `rebar3 compile` | 0 / PASS / 16.555 | Exit0 / PASS |
| `rebar3 eunit` | 0 / PASS, 341 tests / 81.782 | Exit0 / PASS, 386 tests / 101.777; no core environment override |
| `rebar3 ct` | 0 / PASS / 7.299 | Exit0 / PASS / 9.552 |
| `rebar3 xref` | 0 / PASS / 0.443 | Exit0 / PASS / 1.019 |
| `rebar3 dialyzer` | 0 / PASS / 90.632 | Final exit0 / PASS, no warnings / 10.595; initial failure resolved |
| Fork `core/`: `rebar3 compile` | Not applicable | Exit0 / PASS |
| Fork `core/`: `rebar3 eunit` | Not applicable | Exit0 / PASS, 61 tests |
| `rebar3 as erlamsa,gleam compile` | Outside baseline matrix | Exit0 / PASS with explicit local core override |
| `rebar3 as gleam eunit` with real core enabled | Outside baseline matrix | Final exit0 / PASS, 448 tests / 134.860; initial failures resolved |
| Standalone `rebar3 as gleam compile` | Outside baseline matrix | Exit0 / PASS; restores the legacy helper's expected build path |
| Focused legacy/Gleam/backend rerun | Outside baseline matrix | Exit0 / PASS, 18 tests |
| Focused provider/recipe/control checks | Not applicable | Exit0 / PASS, 39 tests |
| Focused request isolation checks | Not applicable | Exit0 / PASS, 12 tests, including native hang termination |
| SDK unit/protocol/real-runtime/CLI/TUI matrix | Not applicable | Exit0 / PASS, 21 tests / 5.816, including saved raw replay, target-call count, actual TUI counters and active-provider close/reaping |
| Real Erlamsa/Gleam end-to-end checks | Not applicable | Exit0 / PASS, six scenarios: bytes/limits, regeneration, wrappers, continuous stop/restart, semantic adapter, compiled Gleam |
| Independent clean core clone/build | Not applicable | Exit0 / PASS; local `--no-local` clone, all nine BEAM SHA-256 hashes identical; not remote acceptance |
| Independent GitHub EFZ clone, native build without core/Gleam | Not applicable | Exit0 / PASS / 21.030, checkpoint `d5dc25e`; unavailable optional-tool paths supplied |
| Enabled profile without core, same clean clone | Not applicable | Expected exit1 / PASS / 3.632; clear missing-core error |
| Clean EFZ clone plus independent local core clone | Not applicable | PASS, real isolated mutation; not remote gitlink acceptance |
| Fresh recursive EFZ checkout | Not applicable | BLOCKED by unpublished/unverified fork |

Baseline logs/timings remain at `/workspace/scratch/erlamsa-baseline/` in the
execution workspace. Final check argv, exit codes, and timings are recorded in
`/workspace/scratch/erlamsa-final-checks.json`. Portable evidence includes
[final EFZ checks](erlamsa-evidence/checks.json),
[Python/CLI/TUI checks](erlamsa-evidence/python-checks.json),
[baseline checks](erlamsa-evidence/baseline-checks.json),
[optional builds and SDK install](erlamsa-evidence/builds.json),
[clean native checkout](erlamsa-evidence/efz-clean-native.json), and
[core rebuild hashes](erlamsa-evidence/core-clean-rebuild.json). Generated
BEAMs, full build logs, and temporary corpora are not source artifacts.

## Core observations

The standalone core compiles with `warnings_as_errors` and `deps => []`. Its
61 tests cover explicit RNG vectors, repeated requests with unrelated process
randomness, byte extremes including NUL, bounds, weights, disabled operations,
tree grammar/preflights, wrappers, nested budgets, deflate preflight, ZIP content,
and field preserve/perturb behavior. The implemented catalogue and supported
subsets are documented in [integration](erlamsa-integration.md).

An initial run found a limit error: decoded inner payloads were incorrectly
constrained by the external compressed-output limit. The dispatcher now uses
the intermediate bound for inner transformations while retaining the final
external output bound. The complete 60-test suite passed after correction.
This was an integration implementation defect, not an external-target finding.
The final additional regression rejects explicit requests for zero-weight
operators or patterns instead of bypassing their disabled configuration.

The 386-test default EFZ run passes without enabling the optional core. It
includes native sequence/configuration compatibility, provider scheduling and
skip/error policy, recipe schemas1–5, cold raw recipe replay, and missing-core
configuration rejection. Separate isolation tests exercise correlated replies,
request deadlines, repeated cancellation, owner/guardian death, late replies,
bounded wire decoding, arbitrary binary data, and a deliberately nonreturning
native fixture. Success is delivered only after confirmed process cleanup.

The first optional full-suite run overlapped other CPU-intensive checks. The
existing `efz_backend_tests` caller-death cleanup assertion failed, and a later
real-core test hit its EUnit case deadline. After corrections, all six real-core
integration scenarios passed. A full retry passed 447 tests but failed one
legacy helper that expected `_build/gleam` after only the combined profile had
been built. Building the standalone Gleam profile succeeded, a focused
18-test legacy/Gleam/backend rerun passed, and the final complete real-core
Gleam run passed all 448 tests. The earlier failures remain recorded as
before/after evidence.

The SDK's extended raw-replay check exposed an actual protocol defect: changing
the logger's configured output device in place was rejected by OTP, so shutdown
diagnostics could contaminate reserved stdout. Control startup now creates the
stderr logger explicitly before target work. The final 21-test SDK/CLI/TUI
matrix passed, including saved raw replay and close during active mutation with
cancellation and descendant reaping. Raw replay explicitly reports its single target call; that assertion and
rendering actual runtime counters through the TUI also pass.

The initial Dialyzer run failed on 17 new warnings (unreachable clauses,
unmatched results, and intentional exception helpers). Narrow code/spec
corrections resolved those warnings, and the final Dialyzer run exited0 with no
warnings. Project-wide warnings remain enabled.

The clean core reproducibility check used `git clone --no-local` to build the
clean local integration commit in an independent checkout. All nine compiled
BEAM SHA-256 hashes matched. [Evidence](erlamsa-evidence/core-clean-rebuild.json)
proves the measured local rebuild result, not the required remote fork fetch or
EFZ recursive-submodule checkout, which remain blocked.

An independent GitHub clone of published EFZ checkpoint `d5dc25e` compiled in
native mode with the core absent and `GLEAM_BIN`/`ERLAMSA_SOURCE` deliberately
set to nonexistent paths. Explicitly enabling the Erlamsa build profile then
failed as expected with the missing-core diagnostic. Adding an independent
clone of the local clean core enabled a real isolated mutation. No local object
sharing was counted as fork publication or recursive gitlink acceptance.

A verified local Git bundle preserves the five unpublished core commits at
`/workspace/scratch/erlamsa-integration.bundle`. Its SHA-256 is recorded in
[build evidence](erlamsa-evidence/builds.json). It is a source-history handoff,
not a dependency/submodule replacement and not an accepted remote object.

The local handoff can be reconstructed without sharing the first checkout's
object database. These commands were verified with a fresh upstream clone and
the bundle. They do not satisfy the blocked GitHub fork/submodule criterion:

```sh
git clone --branch feat/erlamsa-integration https://github.com/LuciyVI/efz-fuzz.git
git clone --single-branch --branch master https://github.com/Darkkey/erlamsa.git erlamsa-local
git -C erlamsa-local fetch /workspace/scratch/erlamsa-integration.bundle efz-integration
git -C erlamsa-local switch -c efz-integration FETCH_HEAD
export ERL_FLAGS='+S 2:2'
cd efz-fuzz
rebar3 compile
ERLAMSA_SOURCE="$(cd ../erlamsa-local && pwd)" rebar3 as erlamsa compile
```

The final published implementation/evidence checkpoint `dd7c361` was also
fetched into the independent EFZ clone and compiled successfully with both
optional-tool paths deliberately unavailable. Its sources contain no prepared
Erlamsa checkout. Later documentation-only commits do not establish the missing
fork acceptance.

Additional developer probes exercised 160 compressor variants and 12,000
malformed wrapper inputs without unbounded results or exceptions. They
supplement committed regression tests; they do not establish a hard bound for
every native allocation or compression-runtime version.

## Acceptance requiring final evidence

| Requirement | Current evidence / remaining acceptance |
| --- | --- |
| Actual fork and expected parent | BLOCKED: API `Forbidden`, including approved escalated retry |
| Published commit; independent fetch | BLOCKED: fork access not established |
| Real HTTPS gitlink; recursive checkout | BLOCKED; copied sources/local symlinks are not counted |
| Native without core; missing-core preflight | PASS in default 386-test suite |
| Native sequence; deterministic requests | Core/planner contracts and real-core binary request scenarios PASS |
| All local families and resource bounds | Core 61-test suite PASS; supported subsets documented |
| Error/timeout/cancel cleanup, no target finding pollution | Scheduling contracts PASS; 12 request-isolation checks PASS, including native hang |
| Hybrid and existing semantic/Gleam adapter | Combined/standalone builds PASS; real existing-adapter and compiled-Gleam scenarios PASS |
| Provenance, old recipes, cold raw replay, identity mismatch | Contract/cold replay checks and real-core regeneration end-to-end PASS |
| Continuous stop/save/restart | Real-core continuous stop and persisted corpus restart scenario PASS |
| CLI/TUI/Python binary and lifecycle behavior | SDK/CLI/TUI 21-test matrix PASS, including raw replay target-call count, actual TUI counters and in-flight close/reaping |
| Five-seed equal-time measurements and off-mode overhead | PASS: 25/25 primary trials, six disputed off-mode repeats and three supplemental memory diagnostics; noise prevents a rigorous 5% overhead upper bound; see benchmark report |

HTTPS Git to upstream works. The requested fork endpoint returns `Repository
not found`; absence and insufficient access cannot be distinguished. The
environment domain policy excludes `api.github.com`. A draft adding it was
saved and requires review/save/publication before activation. That is a
network-policy blocker, not proof of fork creation or successful authentication.
No token was copied into commands, URLs, or reports.

After API access is available, verify parent/source, create the fork if absent,
publish local commits, independently fetch the exact object, add the real
submodule/gitlink, commit EFZ, and run a fresh recursive checkout. No automatic
merge to main is part of this work.

## Final publication and clean-checkout recheck (2026-10-28)

Status: **PARTIAL**. This section supersedes the historical remote-blocked
statements above. The fork and submodule acceptance now pass. The remaining
limits are the deliberately selected core operator subset and the unavailable
Gleam tool/profile; those prevent the requested full-catalogue COMPLETE claim.

### Repositories and pinned source

| Item | Verified value |
| --- | --- |
| EFZ worktree | `/home/fbogoslavskii/test/efz-fuzz` |
| EFZ branch | `feat/erlamsa-integration` |
| EFZ upstream default/main | `db1add0bc47bc1011d55a4cb528b741a0b870f97` (`main`) |
| Published EFZ provider/gitlink commit | `f0768323ca746476adf34aac8d5af8ac2c4a3cc5` |
| Fork | [LuciyVI/erlamsa](https://github.com/LuciyVI/erlamsa), API reports `fork: true`, parent `Darkkey/erlamsa` |
| Fork default branch | `master` at upstream base `4a844bcd1083e3278c10405bb415a32871b216c3` |
| Published fork integration branch | `efz-integration` at `191f3d9d30d8932319b98f4af25d3dff9ddc5824` |
| EFZ submodule | `vendor/erlamsa`, mode `160000`, exact SHA `191f3d9d30d8932319b98f4af25d3dff9ddc5824` |
| `.gitmodules` URL | `https://github.com/LuciyVI/erlamsa.git` |
| Environment | Linux x86_64, kernel `6.8.0-nyx+`, OTP 27 / ERTS 15.0, Rebar3 3.25.0, Python 3.12.3, Gleam absent |

GitHub API verified the fork parent and default branch. Independent
`git ls-remote` returned the integration SHA from the public fork. A new
`--single-branch --recurse-submodules` clone checked out EFZ commit `f076832`
and the exact published fork object; it had no tracked or submodule changes.
EFZ was pushed only to `feat/erlamsa-integration`; no merge to `main` occurred.
The fork commits, in order, are `760ff8f`, `c8700d7`, `e4919d1`, `90d3333`, and
`191f3d9`. The standalone profile adds no nested submodules and no Rebar
dependencies.

### Verification commands

| Command/check | Result |
| --- | --- |
| EFZ `ERL_FLAGS='+S 2:2' rebar3 compile` | PASS, exit 0 |
| EFZ `ERL_FLAGS='+S 2:2' rebar3 eunit` with no core override | PASS, exit 0, 386 tests |
| EFZ `EFZ_ERLAMSA_CORE_PATH="$PWD/vendor/erlamsa" ERL_FLAGS='+S 2:2' rebar3 eunit` | PASS, exit 0, 391 tests, including five real-core scenarios |
| EFZ `ERL_FLAGS='+S 2:2' rebar3 ct` | PASS, exit 0, 3 tests |
| EFZ `ERL_FLAGS='+S 2:2' rebar3 xref` | PASS, exit 0 |
| EFZ `ERL_FLAGS='+S 2:2' rebar3 dialyzer` | PASS, exit 0, no EFZ warnings |
| EFZ `ERL_FLAGS='+S 2:2' rebar3 as erlamsa compile` | PASS, exit 0 |
| Fresh recursive clone: `rebar3 compile` | PASS, exit 0 |
| Fresh recursive clone: `sh scripts/build_erlamsa.sh` and `rebar3 as erlamsa compile` | PASS, exit 0; reports core SHA `191f3d9` |
| Fresh clone without initialized submodule: ordinary `rebar3 compile` | PASS, exit 0 |
| Same no-submodule clone: `rebar3 as erlamsa compile` | Expected failure, exit 1, before any target: “Missing Erlamsa library. Initialize the pinned submodule…” |
| Fork core on current checkout and independent fresh HTTPS fork clone: `rebar3 compile`, `eunit`, `xref`, `dialyzer` | PASS, exit 0 for all; 12 EUnit tests in each checkout |
| Fork root upstream `ERL_FLAGS='+S 2:2' make compile` and `make test` | PASS, exit 0; 28 EUnit tests. Existing upstream deprecation/unused-code warnings remain. |
| Direct fork-root `rebar3 compile` without generating `src/version.hrl` | FAIL as expected for the unsupported shortcut; upstream's `Makefile` generates that header, and its documented `make compile` passed. |
| `python3 -m pip install --no-build-isolation --no-deps --target /tmp/pyefz-install-final packages/pyefz` | PASS; installed `pyefz-0.1.0` |
| Python SDK/CLI/TUI suite with pinned core and instrumented synthetic parser | PASS, exit 0, 21 tests; includes binary and batch mutation, campaign stop, saved raw replay, cancellation/reap, and runtime TUI counters |
| `escript scripts/fuzz.escript --help`, `escript scripts/mutate.escript --help`, `escript scripts/prepare.escript` | PASS, exit 0 |
| `ERL_FLAGS='+S 2:2' rebar3 as gleam compile` | NOT RUN to completion / BLOCKED, exit 1: Gleam executable is not installed |
| Combined Erlamsa+Gleam build and semantic/Gleam benchmark mode | NOT RUN; requires the unavailable Gleam build |

The initial clean recursive build used a configured proxy and failed while
fetching Cowboy. Repeating with that proxy unset fetched all three lock-pinned
EFZ dependencies and the clean recursive default and provider builds passed.
This was an environment proxy issue; no dependency version was changed.

### Measurements and remaining scope

The accepted four-mode benchmark completed 20/20 trials: five seeds, 30 seconds
per trial, baseline/native/Erlamsa/hybrid, same instrumented Cowlib target,
`+S 2:2`, CPUs 0 and 1. Native median was 345.10 target executions/s versus
345.00 for the pristine baseline. Erlamsa was 4.33/s and hybrid 12.56/s. The
core call median was 87–90 microseconds, while the isolated full provider
request median was 224–228 milliseconds. The paired native-off median was
within 5%; high per-seed variance means the upper-bound guarantee is
unproven. Full measurements and the semantic-mode limitation are in
[benchmark results](erlamsa-benchmark.md).

The new core profile is not a complete copy or implementation of every
upstream operator. It supports bounded byte/block/line/number/delimiter/Unicode
operations, JSON primitive-value edits, simple balanced-tag SGML comment
insertion, Base64, gzip/zlib, stored ZIP entries, selected length/XOR8/CRC32
fields, and bounded once/many/burst/skip patterns. ZIP Deflate and advanced
JSON/SGML tree operations are excluded and explicitly documented. The
heuristics do not infer arbitrary protocols. The provider has disposable OS
worker isolation and bounded streaming decompression, but no whole-VM hard
memory guarantee. Raw replay uses stored bytes and does not need the core;
regeneration checks the recorded build/config identity.

Therefore the fork, published commit, gitlink, core builds, EFZ provider,
native/erlamsa/hybrid scheduling, Python SDK, persistence/replay, and tested
synthetic end-to-end path are implemented. Full upstream catalogue parity,
the Gleam-enabled build/run, and the corresponding semantic benchmark remain
open acceptance criteria; this is **PARTIAL**, not COMPLETE.

## Recheck in the active checkout (2026-10-28)

This recheck used `/home/fbogoslavskii/test/efz-fuzz`, branch
`feat/erlamsa-integration`, starting HEAD `73a65d77657d6a23f5e4e9cdf4e15291648abba2`.
The worktree was clean at the start. It has only the EFZ `origin` remote, no
`.gitmodules`, no `vendor/erlamsa`, and no Erlamsa source checkout. The
environment is Linux x86_64, kernel `6.8.0-nyx+`, OTP 27 / ERTS 15.0,
Rebar3 3.25.0, Python 3.12.3; Gleam is not installed.

| Command or check | Result in this checkout |
| --- | --- |
| `ERL_FLAGS='+S 2:2' rebar3 compile` | PASS, exit 0 |
| `ERL_FLAGS='+S 2:2' rebar3 eunit` | PASS, 386 tests; run outside the restricted sandbox because its AF_UNIX bind returns `EPERM` inside it |
| `ERL_FLAGS='+S 2:2' rebar3 ct` | PASS, 3 tests |
| `ERL_FLAGS='+S 2:2' rebar3 xref` | PASS, exit 0 |
| `ERL_FLAGS='+S 2:2' rebar3 dialyzer` | PASS, exit 0, no warnings |
| `ERL_FLAGS='+S 2:2' rebar3 as erlamsa compile` | BLOCKED as expected, exit 1: pinned submodule is absent |
| `ERL_FLAGS='+S 2:2' rebar3 as gleam compile` | BLOCKED, exit 1: `gleam` is not installed |
| `python3 -m pip install --no-build-isolation --no-deps --target /tmp/pyefz-install-efz packages/pyefz` | PASS; built and installed `pyefz-0.1.0` locally |
| Python SDK/CLI/TUI suite with a real local simple-parser fixture | PASS, 21 tests; 4 core-dependent provider checks skipped because no core checkout exists |
| `escript scripts/fuzz.escript --help` and `escript scripts/prepare.escript` | PASS, exit 0 |

The local SDK run exercised native binary mutation, a real short campaign and
saved results, and raw replay in a fresh client. It did not exercise Erlamsa
mutation, provider campaign scheduling, or provider cancellation; those four
checks require the missing core. The four core-dependent skips are not counted
as Erlamsa acceptance.

The provider fault fixture was adjusted so lifecycle tests do not prepare an
optional core just to test request correlation, timeout, cancellation, or
reaping. The production provider and separate real-core integration tests are
unchanged by that test-only adjustment. The focused lifecycle suite passed
12/12, and the complete default EUnit suite passed 386/386.

For the remote check, the connected GitHub account was `LuciyVI` and the
upstream repository metadata confirmed `Darkkey/erlamsa` default branch
`master`. The same API returned 404 for `LuciyVI/erlamsa`; this does not prove
whether it is absent or hidden from the account. Local `gh auth status` reports
an invalid stored token. Git transport failed with `Proxy CONNECT aborted`,
including an escalated read-only `git ls-remote`. No fork was created and no
submodule/gitlink was added. The connected GitHub tools in this session expose
repository reads and ref/commit operations but no fork-creation operation, so
there is no safe path here to create the requested fork and publish its core
commits. The fork, clean recursive checkout, real-core build, and final
gitlink acceptance remain BLOCKED.
