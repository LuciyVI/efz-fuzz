# P5: final replay, regression and same-engine acceptance

This report supersedes the historical P5 handoff notes in P1–P4 and the
10 October universal-validation report. The gate covers the supported bounded,
synchronous Linux workflow. Performance superiority and discovery of an
independent vulnerability are separate questions, not conditions for completing
the implementation gate.

## Changes made during final acceptance

- Safe schema-1 loading now registers the fixed legacy vocabulary before ETF
  decoding. `[safe]` remains enabled; artifacts cannot introduce atoms or select
  executable modules.
- Legacy replay uses the raw `.input` and checksummed `.semantic` as its required
  inputs. VM-local diagnostic `.term` is an optional path, not a prerequisite.
- The generic replay CLI's unavailable-escript diagnostic has the correct format
  call. The subprocess tests cover generic replay, minimization, exact execution
  budgets, invalid arguments, corrupt input, refusal to replace existing output,
  forwarding and successful native legacy replay without a diagnostic `.term`.
- Comparison drivers accept multiple RNG seeds/repeats, measure durable corpus
  admission, and record source/runtime/target identities.
- Stateful counts are verified through actual guarded target outcomes in a
  separate fresh VM, outside campaign timing. Completed operation counts equal
  the returned trace length. Packet rejection is distinct from an accepted
  scenario; a primary input execution is not labelled a library operation.

## Reproduction

Use OTP 27, Rebar3 3.25.0, Gleam 1.10.0 and `ERL_FLAGS='+S 2:2'`.
Run default and optional compile/tests/CT/xref/Dialyzer before measurements.
Prepare the pinned XML-RPC dependency following `examples/xmlrpc/README.md`.
The optional full EUnit run needs its dependency ebin directory on the code path.

Prepare two source archives without modifying the active checkout: main at
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b` (default build) and the historical
QS layer at `e4c0244c403d74b041df7e0e2f0dd4465a977453` (Gleam build).
Build them using the same toolchain and locked dependency commits. Each cloud
task already has an isolated checkout; no Git worktree is needed.

```sh
python3 scripts/run_semantic_bench.py --out /workspace/scratch/p5-semantic-verified
python3 scripts/run_qs_semantic_bench.py \
  --baseline /workspace/scratch/p5-legacy-baseline/_build/gleam \
  --raw-baseline /workspace/scratch/p5-main-baseline/_build/default \
  --out /workspace/scratch/p5-qs-verified
python3 scripts/verify_p5_evidence.py \
  /workspace/scratch/p5-semantic-verified /workspace/scratch/p5-qs-verified
```

Each output directory must be new. Preparation, campaigns and callback/stateful
diagnostics run serially. No test suite or compilation overlaps the measured
series. Three seeds (17, 29, 43), two repeats, 500 mutations, fresh VMs/corpora,
two CPU schedulers and fixed target timeout apply to the canonical gate.
QS uses one shared native target artifact for every engine/mode. Its measured
campaign follows a separate 20-mutation warmup with a fresh measured corpus.
The API/XML/stateful series has no campaign warmup.

Campaign wall includes setup/calibration and durable admission writes; VM/driver
wall is recorded separately. Cold stateful diagnostics include executor and
scenario setup/cleanup and do not claim isolated per-operation latency.

Final status: **P5 PASS, 13 October 2026.** Preliminary attempts are retained
outside the checkout and are not used as final PASS evidence.

## Acceptance scope and review

The final review rechecked the callback boundary, raw authoritative inputs,
explicit adapter/target selection, finite budgets, off-path RNG neutrality,
observer neutrality, durable identity/recalibration and semantic predicate
preservation. The new tests reproduce two cold legacy failures rather than
relying on earlier author's PASS notes. No separate reviewer or subagent was
used, and no independent external audit is claimed.

Arbitrary native callback cancellation, unmanaged parallel target calls,
external resources without a dedicated harness, globally minimal inputs,
exact campaign PRNG checkpoints and deferred oracles remain outside the v1
contract. These are documented scope exclusions, not unexecuted P5 checks.

## Executed final gates

| Check | Result |
| --- | --- |
| Default compile / EUnit | PASS / 308 passed |
| Gleam compile / full EUnit with pinned XML-RPC | PASS / 374 passed |
| Common Test | 3 passed |
| Default and Gleam xref / Dialyzer | PASS for both builds |
| Fresh-VM generic and native legacy replay CLI | 2 passed in optional suite; generic path also passed in default suite |
| Serial API/XML/stateful off/on campaigns | 36/36 completed, 500 mutations each |
| Serial QS main / legacy / disabled / seeds / structured / observation / explicit guided / oracle | 48/48 completed, 500 mutations each |
| Raw disabled trace and structural coverage equivalence with main | 6/6 seed/repeat pairs |
| Observation-only mutation trace neutrality | 6/6 seed/repeat pairs |
| Actual stateful workload diagnostics | 12/12 completed, 501 guarded input executions each |
| Source hashes / campaign budgets / no infrastructure errors / durable corpus presence | PASS |

The comparison series performed 42,000 measured mutations. Every measured
campaign used a new durable corpus. Existing full regression tests separately
verify restoration/recalibration, identity mismatch rejection, semantic-only
admission and representative preservation. Corpus persistence is input reuse,
not a PRNG checkpoint.

### Measurement summary

Each row has six samples (three RNG seeds, two repeats). Rates include measured
calibration and admission costs. They are finite measurements, not significance
claims or performance superiority acceptance thresholds.

| Series/mode | Median primary executions/s | Semantic-only entries, sample range |
| --- | ---: | ---: |
| QS baseline | 398.4 | 0–0 |
| QS old | 388.7 | 0–1 |
| QS new | 380.3 | 1–1 |
| QS off | 405.0 | 0–0 |
| QS seeds | 412.3 | 0–0 |
| QS structured | 385.9 | 0–0 |
| QS observation | 374.8 | 0–0 |
| QS oracle | 377.9 | 0–1 |
| API generic-off | 388.7 | 0–0 |
| API generic-on | 390.3 | 1–1 |
| API xmlrpc-off | 320.0 | 0–0 |
| API xmlrpc-on | 303.0 | 3–4 |
| API stateful-off | 382.7 | 0–0 |
| API stateful-on | 390.8 | 1–1 |

The disabled path preserves deterministic raw behavior and does not load the
Gleam model. On modes achieve actual semantic-only admissions; this confirms
integration rather than independent bug discovery. These samples do not establish
speedup, optimal structured fraction or zero overhead.

### Actual stateful operations

These counts are obtained from completed guarded executions of the recorded
packet workload in separate diagnostic VMs. They agree with canonical packet
reconstruction. Scenario wall includes executor plus child setup/cleanup; it is
not an isolated gen_server-call latency benchmark.

| Mode | Accepted scenarios, six workloads | Completed library operations | Rejected packets |
| --- | ---: | ---: | ---: |
| off | 12 | 36 | 2994 |
| on | 178 | 562 | 2828 |

### Controlled discovery trials

Three additional fresh-VM 1,000-mutation runs used the explicitly artificial
`efz_qs_defect_target`, identical `abc=1` initial bytes, the existing `bug`
dictionary and seeds 17, 29 and 43. Seeds 17 and 29 found the injected property
failure; seed 43 completed without a finding (censored at its execution budget).
All completed without infrastructure errors. The separate legacy CLI test
reproduces and minimizes that property in a new VM. No result is presented as a
new vulnerability or as discovery superiority on a real library.

## Evidence and conclusion

[validation.json](p5-evidence/validation.json) records toolchains, source and log
hashes, raw artifact hashes and discovery outcomes.
[gates.json](p5-evidence/gates.json) records budget/trace/stateful checks and final
measurement summaries. Both series' manifests are retained beside them.
Full logs, inputs, recipes, reports and durable corpora remain under the raw
evidence roots listed in validation.json; generated BEAMs are not committed.

All previously open executable P5 items are now closed for the stated contract.
There is no outstanding required P5 command. A merge review can use the retained
checks and reproduction instructions; performance superiority remains unclaimed.
