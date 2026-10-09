# P2 optional native BEAM integration

Requirements **2.0-native**; contract **v1**, vector `{1,1,1,1,1,1}`.
**P2 functional gate: PASS.** Evidence is under
`artifacts/gleam-layer/20261008-p2-native/`; `gates.json` indexes commands,
exit codes, source hashes, and retained failures. This does not close P3/P4
phase acceptance, independent review, or final P5 benchmarks.

## Scope and ownership

Read the common context, actual P0 baseline/execution-path, and P1 contracts.
HEAD remains `79d76221c6bc5df30b80e6b0de947f3860f4fa4b`; dirty state was recorded
before editing. The single lead owns package/API, adapter/tests, shared build
and configuration. No subagents or independent reviewer were used.

The optional profile, package, EFZ hook, and existing P3/P4 code were already
present at this pass's start. P2 adds complete startup export validation, bounded tagged-error diagnostics, real
BEAM reachability/lifecycle fixtures, a finite diagnostic driver, and evidence.
It adds no production structured policy or semantic guidance. Model/core,
mutation planner, worker, corpus, configuration, and build hook are unchanged
from the P2 input snapshot. User prompts, ZIP, AGENTS.md, and lockfiles retain
their hashes. No commits, push, PR, corpus deletion, or global changes occurred.

Current pass files: `src/efz_gleam_adapter.erl`,
`test/efz_gleam_beam_tests.erl`, `test/efz_gleam_layer_tests.erl` (fault stub exports),
`scripts/gleam_beam_bench.escript`, this report, `contracts.md`, `architecture.md`,
`user-guide.md`, `baseline.md` (toolchain paths), `agent-plan.md`, and `decision-log.md`. The scoped diff is
`p2-changes.patch`; generated artifacts are not source changes.

## Toolchain, profile, and artifacts

Actual tools: **OTP 27.0 / ERTS 15.0**, **Rebar3 3.25.0**, **Gleam 1.10.0**,
Linux x86_64, `+S 2:2`. The compiler is local:
`/tmp/efz-gleam-toolchain/gleam`, SHA-256
`5d86c226aad4fb32e501bc1a6c5c90394e3bd3e462476b1552f4b734e74f7906`.
No global install/update is required. `gleam.toml` pins `== 1.10.0`, target
`erlang`; `manifest.toml` has zero packages. Rebar/Cowboy/Cowlib/Ranch pins are
unchanged and actual dependency Git HEADs were checked (`toolchain.json`).
The primary runtime root is `/home/fbogoslavskii/.asdf/installs/erlang/27.0`.
An initial minimal-PATH off-build instead selected system OTP 27.3.4.13 / ERTS
15.2.7.9. That additional successful build/test is retained in `system-otp-off/`;
the final independent off gate explicitly selects the primary OTP 27.0 bin
directory, with no Gleam on PATH (`toolchain-paths.json`).

`rebar.config` enables `scripts/build_gleam.sh` only in profile `gleam`:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam ERL_FLAGS='+S 2:2' rebar3 as gleam compile
```

The hook invokes `gleam export erlang-shipment`, then copies
`efz_qs_model.beam` and normalized `efz_semantic.app` into
`_build/gleam/lib/efz/ebin/` (`gleam+test` for EUnit). Runtime app metadata lists
only `efz_qs_model`, with no application dependencies. The generated unused CLI
launcher is excluded. No optional application start/load is needed or observed.

Pinned 1.10.0 actually emits three generated Erlang sources in its build tree;
the Rebar integration consumes only BEAM/application artifacts. It does not
compile or search generated `.erl`. Two builds with the private Gleam cache
archived between them produced identical model and `.app` SHA-256 values
(`reproducibility.json`). Byte identity across different absolute source paths
is not claimed; compiler/debug paths can change file hashes.

Primary references were checked: [Gleam externals](https://gleam.run/documentation/externals/),
[OTP public coverage APIs](https://www.erlang.org/doc/apps/kernel/code.html), and
[Gleam 1.19 compiler announcement](https://gleam.run/news/gleam-doesnt-compile-to-erlang-source-anymore/).
Installed OTP 27 sources and actual pinned compiler output establish this gate;
the newer announcement is not proof of 1.10.0 artifacts or an instruction to upgrade.

## Actual runtime path and boundary

The traced chain is:

`efz_config:prepare/1 → efz_gleam_adapter:prepare/2 → existing EFZ lifecycle/worker`

`efz_qs_target:run/1 → efz_cov_native_public:collect/1 → efz_gleam_adapter:oracle/3`

`→ efz_gleam_adapter:decode/2 → efz_qs_model:decode/2 → efz_qs_model:check/2 → EFZ report`.

The native plugin is the P1 fixed adapter/dispatch, not a second plugin platform.
Actual compiled core exports are `versions/0`, `decode/2`, `encode/2`,
`normalize/1`, `generate/2`, `mutate/3`, `observe/4`, and `check/2`.
`prepare/2` loads/checks them once, checking versions first. A missing export
returns `{gleam_configuration,{gleam_callback_unavailable,Function,Arity}}`.
Hot callbacks use ordinary BEAM `apply(efz_qs_model,Function,Args)` with no module
lookup, dynamic loading, application start, or transport serialization.

`hook_trace/0` runs a real native-coverage EFZ campaign with fraction zero,
feedback disabled, one inline pure oracle check, and no mutation iterations.
Trace confirms target → primary snapshot → adapter → real compiled Gleam;
data callbacks run on the existing EFZ worker. Startup model lookup occurs once.
The result is one Pass, zero extra target calls, no structured counters or
semantic state. `beam-proofs-complete/hook/trace.json` records the checked
call sequence directly; adjacent `proof.term` retains its report without trace
arguments. `runtime-root.json` records actual exports/imports/layout.
The core imports only Erlang builtins; its sole declared FFI is `erlang:bit_size/1`.

The adapter validates aligned binary versus text/bitstring, tuple tags/arity,
proper lists, integers, bounded limits/models/results/features, and fixed error
tags. No unsafe Dynamic or input-derived atoms exist. Empty, non-UTF8, exactly
4096-byte inputs, oversized input, malformed results, wrong versions, and missing
exports are tested. Unsupported/limit is distinct from layer error. Diagnostic
reasons stay bounded; target findings are persisted before a later layer failure.

## Executed gates

Commands ran serially with `ERL_FLAGS='+S 2:2'`. Exact argv/cwd/env/exit are in
the corresponding `.json`; logs retain full test results.

| Command/check | Exit | Result / artifact |
| --- | --- | --- |
| Source-only private `rebar3 compile`, primary OTP bin + `/usr/bin:/bin`, nonexistent GLEAM_BIN | 0 | `pinned-off-build`: no Gleam directory/compiler/artifacts, zero BEAM before build |
| Private off EUnit: smoke, BEAM/contract/layer, phase2, mutation modules | 0 | **52 passed**, `pinned-off-tests-final` |
| Root off EUnit: BEAM/contract/layer modules | 0 | **9 passed**, `off-focused-final` |
| Private `rebar3 as gleam compile`, twice | 0 / 0 | `clean-on-first`, `clean-on-second`; identical package hashes |
| Root `rebar3 as gleam compile` | 0 | `on-build`; actual optional shipment |
| Root on EUnit: BEAM/contract/layer modules | 0 | **32 passed**, `on-focused-final` |
| On EUnit BEAM module after snapshot-trace/JSON refinement | 0 | **7 passed**, `beam-trace-json-corrected` |
| `rebar3 as gleam xref` | 0 | `on-xref-final`, no undefined runtime calls |
| Fresh-VM export/layout inspection, private twice and root | 0 | `runtime-first`, `runtime-second`, `runtime-root` |
| Fresh campaigns, baseline/off/on-runtime-off, seeds 17 and 43 | 0 each | 100 mutation candidates/mode/seed; exact traces equal, `complete-raw-equivalence/` compared with immutable P0 traces |
| Dispatch and BEAM diagnostic drivers | 0 | `dispatch-overhead`, `beam-overhead-complete`; samples below |

Private source-only builds use copies of the pinned **ordinary** dependency
sources, not cached dependency BEAMs, through Rebar `_checkouts`. Rebar rewrites
only that scratch lock; repository locks remain unchanged. No fresh network
dependency fetch is claimed. `prepare_scratch.py` / `prepare_on.py` and preparation
JSON record paths and source hashes. Off remains physically package/artifact-free
after all checks (`clean-off-final-isolation.json`). The existing unrelated C
launcher builds normally; it is not a Gleam bridge.

Runtime-off in on-build is separately traced by the contract fixture: zero data
callbacks and semantic state. Fresh raw campaigns also have no model/application
load or layer counters. Candidate/stage/parent hashes match P0 and clean off;
explicit plan RNG equivalence remains covered by `determinism/0` and `fallback_rng/0`.
Existing term executor semantics and ordinary raw mutation tests pass.

`repeated_calls/0` performs 1000 decode/encode pairs without process-dictionary
change, then two independent campaigns with fresh oracle budgets and owner
cleanup. Fault fixtures verify malformed/throwing callbacks leave the controlling
fuzzer alive under the defined stop policy, preserve an earlier target finding,
and allow a later healthy campaign. Mocks close only these error contracts.

Retained intermediate failures: stub-variable shadow warning (exit 1), missing
scratch `fixtures/` causing cancelled legacy setup (exit 1), and tracing
`collect_profiled/1` while the non-profiled campaign called `collect/1` (exit 1).
Both test-stub and trace-JSON comprehensions initially had shadowed variables;
warnings-as-errors rejected them before tests, and corrected runs pass. An
optional fresh-VM report-summary helper rejected unknown report atoms under safe
ETF decoding; it was abandoned without unsafe decoding, and the trace fixture
now writes JSON directly. `unused-proof-summary.json` marks this helper as
not a gate. These corrections do not turn failed commands into passing ones.
Corresponding final gate reruns above pass. Cancelled tests
and the incorrect trace assertion are not counted as evidence.

## Observability and measured costs

Production EFZ reports retain existing oracle/observer/structured/outcome counters
and aggregate times. Fine-grained call/reason/byte counters and sampled timings
are explicitly diagnostic-only, collected by `gleam_beam_bench.escript`, without
production state or PRNG draws. Its 48 actual adapter calls yield 16 success,
8 unsupported, 8 limit, 16 boundary rejection, zero layer exceptions; 32 decode /
16 encode calls, 32912 binary input bytes and 64 encoded output bytes. Six timing
samples use ordinal selection every seventh call, capped at six. Full payloads
are not logged; bounded failure tests separately exercise layer exceptions.

Five serial alternating trials: dispatch uses 1M calls/trial, small BEAM
components 20K, maximum-input decode 500. Median control-subtracted samples:

| Component | Median | Five-trial range |
| --- | --- | --- |
| Disabled plan dispatch increment | 0.546 ns | 0.189–0.622 ns |
| Disabled worker dispatch increment | −0.282 ns | −1.958–−0.022 ns |
| Input + model boundary validation, 8-byte input | 26.7 ns | 25.85–27.05 ns |
| Real core decode / adapter decode | 667.85 / 735.65 ns | 660.0–686.2 / 729.35–766.9 ns |
| Real core encode / adapter encode | 193.6 / 236.5 ns | 184.85–196.65 / 235.8–248.0 ns |
| Adapter pure oracle | 882.85 ns | 872.75–895.45 ns |
| Core / adapter decode, 4096-byte input | 171.974 / 173.088 μs | 170.902–173.252 / 172.176–174.044 μs |

The negative dispatch delta and tiny direct check delta are below a reliable
incremental-cost interpretation, not speedup or zero-overhead proof. Components
are measured independently; subtracting their medians is not an exact additive
cost split. Diagnostic clock samples include clock overhead and run separately
from batch measurement. Temporary export_all is confined to diagnostic VMs.
No layer worker/message overhead exists. No campaign performance advantage is claimed.

## Limits and handoff

Production callbacks remain direct bounded BEAM functions, with no extra semantic
workers, queue, cache, ETS, new NIF, port, socket/RPC, JSON/ETF transport, external
engine, JavaScript target, or OTP patch. Existing target isolation and VM-scoped
coverage serialization are unchanged; unmanaged concurrent target calls remain
outside the contract. No async response protocol is used.

The hang fixture kills a monitored **test-only** Erlang worker after 30 ms and
confirms DOWN/cleanup. It does not prove cancellation of arbitrary direct/native
callbacks, nor add a production worker/deadline mechanism. A future expensive
oracle requires a separately approved bounded EFZ supervision/execution contract.

P3 should audit the existing typed provider, seed preparation, recipes and RNG
transitions without changing core representation silently. P4 should audit the
existing semantic consumer/admission and separate finding channel against P1.
P5 must close final replay/minimization/regression and same-engine campaign
benchmarks. Neither all-package completion nor independent review is claimed.
