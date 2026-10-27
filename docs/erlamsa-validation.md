# Erlamsa integration validation

Status on 2026-10-27: **PARTIAL; remote fork/submodule acceptance BLOCKED**.
This report records execution evidence; installed tools and implemented test
files do not count as completed checks. Main's completed P5 semantic-adapter
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
