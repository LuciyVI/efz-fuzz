# Experimental OTP-public line coverage (2026-10-03)

## Implemented

The opt-in coverage_backend => otp_native_public uses documented OTP 27 native
line coverage. efz_cov_native_public:compile/2 compiles target modules with
line_coverage. preflight/1 selects code:set_coverage_mode(line) before load and
records each module's SHA256, BEAM MD5 and ordered executable-line list.
prepare/1 fixes {Module, BuildId, Line} to one slot per line and fingerprints
the schema. The integer line identity fits the existing corpus metadata format.

Before target admission, efz_guardian:start/6 calls efz_coverage:open/3, which
resets native coverage. After confirmed cleanup, efz_guardian:finish/2 reads
through code:get_coverage(line, Module) and immediately packs the term lists
into a bitset using the prepared line order. efz_feedback:native_success/5
checks novelty and merges only for successful results. Crash, timeout and
infrastructure outcomes do not update global coverage. Corpus acceptance
continues through efz_worker:retain/2. Harness and mutation code contain no
native coverage calls.

Line coverage is not EFZ structural point coverage. Persisted coverage is not
imported across backends or changed builds. The experimental backend requires
a dedicated VM with no unrelated callers of selected target modules: OTP
coverage storage belongs to each loaded module, not to an EFZ execution.
The guardian confirms its controlled descendants have exited before reading,
but cannot isolate arbitrary unrelated callers in the same VM. An incompatible
module MD5 or line list produces an explicit coverage failure. ETS is default.

## Correctness

The dedicated EUnit fixture passed. It checks empty/reset state, line A,
repeated A, new line B, exact agreement between raw code:get_coverage/2 reached
lines and the compact bitset, novelty and merge, crash/timeout no-commit
policy, and schema rejection after a changed module reload.
It also runs the real guardian/executor path with successful, crashing and
timed-out inputs, then checks that only the successful result changes global
feedback state.
Full validation on the final code: rebar3 compile PASS; rebar3 eunit 256 PASS;
rebar3 ct 3 PASS; rebar3 xref PASS; rebar3 dialyzer PASS. The Dialyzer PLT
includes Cowboy, and the deterministic in-memory transport has a narrow
annotation because Cowboy's socket type does not describe its reference token.
OTP 27.0's code.erl mode type names line_coverage while its documentation and
runtime use line; startup calls the documented mode through apply/3 to avoid
a false contract warning. No coverage read uses an undocumented API.

An initial Cowboy smoke exposed corpus_persistence invalid_probe: the native
identity had used {line,N} as its third member. The existing corpus format
requires a positive integer. It is now {Module,BuildId,Line}; the corrected
4-second run completed 707 executions with zero infrastructure errors.
No test expectation was changed to hide the failure.

## Short end-to-end Cowboy runs

Each mode ran once in a fresh VM for 30 seconds, with Cowboy 2.19.0, the same
four selected modules, 12 seeds and random seed 424242. These are exploratory
single runs, not a performance gate.

| Backend | Executions | Mean exec/s | Median window exec/s | Discoveries | Corpus final | Errors |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| ETS | 3911 | 130.33 | 131.49 | 45 | 57 | 0 |
| bitmap-v2 | 1997 | 66.53 | 65.99 | 37 | 49 | 0 |
| OTP-public | 5889 | 196.26 | 196.58 | 35 | 47 | 0 |

All modes reported zero crashes and timeouts. ETS/bitmap use 887 EFZ
structural probes; native uses 1089 executable-line slots. Final coverage
counts therefore have different units. Corpus and mutation histories diverge
because the runs complete different numbers of iterations. Raw directories:
 /tmp/efz-ets-smoke-30-compare
 /tmp/efz-bitmap-smoke-30-compare
 /tmp/efz-native-public-final2-smoke-30

## Component measurements

The synthetic fixture generated 1, 100 and 1000 executed calls on separate
source lines. Two warmup samples preceded ten timed samples; 100
iterations/sample for 1 and 100 lines, 20 for 1000. Values are median
microseconds per iteration, OTP 27.0 / ERTS 15.0, x86-64, 16 schedulers.
Raw data: docs/performance/otp-native-public-2026-10-03.term.

| Requested lines | Reset | get_coverage | Conversion | No novelty | Merge | Full direct-target cycle |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.046 | 0.050 | 0.147 | 0.047 | 0.104 | 0.476 |
| 100 | 0.034 | 0.167 | 1.271 | 0.166 | 0.232 | 2.363 |
| 1000 | 0.060 | 2.670 | 13.535 | 1.291 | 1.795 | 24.637 |

The compiler emits one extra executable line for run/0, so actual reached
lines were 2, 101 and 1001. This component benchmark excludes guardian,
schema checks, mutation and corpus IO. The paired ETS/bitmap-v2 cycle
benchmark was rerun with raw output at
docs/performance/bitmap-v2-cycle-2026-10-03.term. Its workload and
instrumentation differ, so its microsecond values are not a matched native
comparison.

A fixed real Cowboy GET path used two warmup samples and ten samples of 100
iterations. Median reset 0.50 us, public read 5.63 us, conversion 30.77 us,
no-novelty scan 3.37 us, merge 4.97 us, direct target execution 15.08 us,
complete local cycle 68.68 us. Raw data:
docs/performance/otp-native-public-cowboy-2026-10-03.term. Conversion is a
large part of this local cycle; get_coverage alone is not. The full EFZ run
averaged about 5.1 ms per execution. These results do not show public
materialization as the dominant full-campaign bottleneck. The measurements do
not isolate every cost in guardian, mutation or corpus. A safe direct reader
remains a separate gated study. No pointer reads, NIF or DWARF direct backend
were implemented.

## Reproduction

Run from efz/:

    rebar3 compile
    rebar3 eunit --module=efz_native_public_tests
    escript bench/otp_native_public_components.escript docs/performance/otp-native-public-repeat.term
    escript bench/otp_native_public_cowboy_profile.escript docs/performance/otp-native-public-cowboy-repeat.term
    ./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 30 --seed 424242

The 900-second run is reserved for manual execution after correctness gates.
