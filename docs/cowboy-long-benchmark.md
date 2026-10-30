# Long Cowboy benchmark: ETS, bitmap-v2 and OTP-public

**English** · [Русский](i18n/ru/cowboy-long-benchmark.md) · [Español](i18n/es/cowboy-long-benchmark.md) · [简体中文](i18n/zh-CN/cowboy-long-benchmark.md) · [All languages](i18n/README.md)

## Purpose and target boundary

The benchmark runs an ordinary EFZ campaign for 900 seconds. The input is the
bytes of one HTTP/1.x request. `efz_cowboy_long_target:run/1` feeds them into real
`cowboy_http:init/6` through the in-memory `efz_cowboy_transport`;
`cowboy_http:loop/1` and its internal `parse_request/3`, `parse_header/4`,
`request/*`, `parse_body/2` parse the request line, method, URI, version, headers,
`Content-Length` and chunked transfer encoding. `efz_cowboy_stream:init/3`
calls `cowboy_router:execute/2` and `cowboy_req:parse_qs/1`; for the body, it
accepts `cowboy_stream:data/4` until `fin`. There is no network listener, Ranch
acceptor or TCP. This is Cowboy's real parser/stream path, but not the full HTTP
handler pipeline or a network benchmark.

Parser errors and incomplete requests return the normal `{ok,rejected}`.
The stream sink passes unexpected exceptions to EFZ's standard crash
classification. Each input executes in one target process; the in-memory
transport is closed and the result marker cleaned up in `after`.
The harness does not call the coverage API.

The Cowboy dependency is pinned in `rebar.config`/`rebar.lock`: Cowboy 2.19.0,
Cowlib 2.20.0, Ranch 1.8.1. The project supports OTP 27+. Each run automatically
compiles and instruments only this allowlist:

| Module | Probes |
| --- | ---: |
| `cowboy_http` | 485 |
| `cowboy_req` | 282 |
| `cowboy_router` | 101 |
| `cowboy_stream` | 19 |
| **Total** | **887** |

These counts were verified on OTP 27.0 with the specified Cowboy version; the
runner prints and saves the actual count. The bitmap has 65,536 **bits**.
Exceeding capacity stops the run before the campaign. `strict => false` is
required because of several record defaults/list comprehensions that the
existing `efz_instrument_pt` preserves without internal probes. Their list is
printed during compilation and stored in each target module's `.efz-manifest`.
This instrumentation limitation applies to both backends.

Experimental `otp_native_public` compiles the same Cowboy allowlist with
`line_coverage` and reads coverage through `code:get_coverage(line, Module)`.
For Cowboy 2.19.0, this environment produced 1089 native line slots. These are
OTP executable lines, so 1089 cannot be compared to EFZ's 887 structural probes
as equivalent coverage units. The mode is selected before loading the target.

Seeds are in `test/targets/cowboy/seeds/`: 12 small requests with CRLF,
including GET, query, POST with a length, multiple headers, HEAD, OPTIONS,
absolute URI, HTTP/1.0, a chunked body and two malformed requests.

## Running

From the `efz/` root:

```sh
./scripts/run_cowboy_long_bench.sh --backend ets --duration 900 --seed 424242
./scripts/run_cowboy_long_bench.sh --backend bitmap --duration 900 --seed 424242
./scripts/run_cowboy_long_bench.sh --backend otp_native_public --duration 900 --seed 424242
```

Experimental modes for profiling engine cost include `--backend none` (Cowboy
without instrumentation), `--backend none_instrumented` (Cowboy with OTP line
instrumentation but no reset/read/feedback), plus `--target noop` and `--profile`.
Short measurements, overhead interpretation and commands for viewing
`profile.term` are described in the
[engine profile](engine-performance-profile.md). `none` is not coverage-guided
and does not change the ETS default.
Results of the next stage with 15-minute runs, identical input sequences
(`--fixed-replay`) and a time profile:
[engine-performance-profile-v2.md](engine-performance-profile-v2.md).

Each command starts a fresh Erlang VM. For an additional pair in reverse order,
then run bitmap → ETS with the same arguments. To use another initial corpus,
specify `--corpus DIR` (a flat directory of regular files); for an explicit new
result directory, use `--out DIR`. An existing `--out` is not overwritten.
`--duration` is in seconds. `--seed` is used for EFZ random mutation and corpus
parent selection. Matching seeds mean identical initial state, not guaranteed
identical histories: different backend speeds over a fixed duration produce
different mutation counts and can lead to different corpora. For strict
coverage-semantic checks, use differential tests with the same EFZ event history.

Machines where Rebar3 cannot download dependencies need GitHub access or a
prepopulated Rebar3 cache. In the restricted local environment, Rebar3 could not
resolve the configured proxy; the pinned repositories were cloned manually into
`_build/default/lib/` for validation. This does not change the version lock.

Results are written to a new directory:

```text
artifacts/cowboy-long-bench/<UTC timestamp>-ets/
artifacts/cowboy-long-bench/<UTC timestamp>-bitmap/
```

Each contains `config.term`, `environment.txt`, `samples.csv`, `summary.term`,
`summary.csv`, `coverage.term`, `cleanup.term`, `corpus/`, `crashes/` and
`target-beams/`. Result directories are ignored by Git. `environment.txt`
contains the git commit/status, OTP/ERTS, Cowboy, OS/CPU/architecture, schedulers,
backend, bitmap size, EFZ config, duration and seed.

Compare a completed pair:

```sh
python3 scripts/compare_cowboy_long_bench.py \
  artifacts/cowboy-long-bench/<ETS_RUN> \
  artifacts/cowboy-long-bench/<BITMAP_RUN> \
  artifacts/cowboy-long-bench/<OTP_PUBLIC_RUN>
```

The script accepts 2–4 directories, checks the initial configuration, and prints
exec/s and its spread, first/last 60s, coverage/corpus, memory and processes; for a
long run, it also prints RSS/VM/ETS memory around 0/5/10/15 minutes. Absolute EFZ
point and OTP line counts are displayed with a warning about different units.
Differences between independent fuzz runs are descriptive: they do not by
themselves prove a change in backend semantics.

## Separate experiment: `erlang-fuzzer(1)`

`./scripts/run_cowboy_long_bench.sh --backend erlang_fuzzer` invokes the separate
`scripts/run_erlang_fuzzer_cowboy_bench.py`. It runs the provided
`erlang-fuzzer(1)` source against **the same Cowboy 2.19.0, the same four target
modules, the same harness path and the same seed files**. It compiles Cowboy with
`line_coverage`, while the external `fuzzer.erl` selects OTP `line_counters` and
registers counters with libFuzzer through the `core.c` NIF. Source comes from
`~/test/erlang-fuzzer(1)/erlang-fuzzer/fuzzer` (or `--source DIR`), is not copied
into Git and does not change EFZ. A copy is built in a separate `/tmp`
directory: the original Makefile uses GDB to obtain offsets in the current
`beam.smp`; the wrapper only disables user GDB init (`gdb -nx`), without
substituting precomputed offsets. SHA256 hashes of `core.c`, the driver and
`beam.smp` are saved in `environment.txt`.

```sh
./scripts/run_cowboy_long_bench.sh --backend erlang_fuzzer \
  --source "$HOME/test/erlang-fuzzer(1)/erlang-fuzzer/fuzzer" \
  --duration 900 --seed 424242
```

The run uses a separate Erlang VM. The runner rejects the result if any Cowboy
module is not registered in native coverage or libFuzzer receives no features.
`--corpus DIR` and `--out NEW_DIR` are available. Results are written to
`artifacts/cowboy-long-bench/<timestamp>-erlang_fuzzer/`:
`samples.csv`, `summary.csv`, `environment.txt`, `fuzzer.log`, a corpus copy,
crash artifacts and build logs. After the run, compare it with the three EFZ modes:

```sh
python3 scripts/compare_cowboy_long_bench.py \
  artifacts/cowboy-long-bench/<ETS_RUN> \
  artifacts/cowboy-long-bench/<BITMAP_RUN> \
  artifacts/cowboy-long-bench/<OTP_PUBLIC_RUN> \
  artifacts/cowboy-long-bench/<ERLANG_FUZZER_RUN>
```

This is a **comparison of complete fuzzing engines**, not a measurement of a
single coverage-collection operation: libFuzzer executes input in one process
without the EFZ guardian, uses different mutation and its own corpus-retention
rules. Input sequences diverge even with the same seed. libFuzzer's `ft` and
`cov` equal neither EFZ structural probes nor unique OTP lines. In the provided
`core.c`, the NIF registers `line_counters` bytes and constructs a synthetic PC
table from indices, so its feature count cannot be compared to
`code:get_coverage/2`. In the shared table, external coverage counts, discoveries
and unavailable VM/process metrics appear as `n/a`; `ft` and `NEW/REDUCE` are
shown separately. Exec/s does not prove the speed of the coverage collector
itself. That requires isolated replay of identical inputs with comparable
execution lifecycles.

This NIF uses private ERTS structures and a coverage-buffer pointer without
proven lifetime protection during reload/purge. Run it only in a disposable VM;
it is a research mode, not an EFZ backend. A result is unusable if OTP changes,
DWARF/debug symbols are missing or registration fails. The script does not
reload modules or include the external NIF in EFZ's main runtime.

Short check on 2026-10-03: `--duration 2 --seed 424242` exited with code 0, the
log confirmed `coverage on` for all four Cowboy modules, `ft` grew from its
initial value and the corpus increased. Raw output:
`artifacts/cowboy-long-bench/20261003T172502Z-erlang_fuzzer/` (local, not in Git).
`rebar3 eunit`: 256 PASS. The 900-second external run was **NOT RUN**;
the short check does not estimate sustained throughput.

## Sampling and summary

`samples.csv` contains a starting sample and then one every 10 seconds, without
collecting telemetry on every iteration. EFZ counters, corpus size and global
coverage are read consistently through the read-only
`efz_fuzzer:benchmark_snapshot/0` / `efz_worker:handle_call/3`. Exact
`coverage.term` is created once after sampling ends. Columns:
elapsed, total/window exec/s, corpus, global coverage, discoveries,
crashes/timeouts/errors, process count, memory total/processes/binary/ETS,
Linux RSS, run queue, reductions, GC count, map arms/allocations and broken
coverage observations. `execution_maps_allocated` counts only the map
preallocated by the worker; it is not a count of all possible temporary maps.
`summary.term` and `summary.csv` contain total/mean,
median, p10/p90 window exec/s, first/last 60s, final coverage/corpus,
crashes/timeouts and changes in memory/process count.
`total_executions` includes calibration, while interval rates are measured from
the first sample after `efz:start/1`.

`cleanup.term` is written after `efz:stop/0`. The absence of EFZ processes is
checked by registered names; absolute process count and memory after stopping
are saved for manual diagnostics. Bitmap-v2 exposes an arms counter and one
preallocated execution map in the worker. Retired map count is not observable
through the current public API, so that metric is not claimed. All memory
conclusions require a full 15-minute time series and repeats.

## Checks before a long run

Completed on 2026-10-02 with OTP 27.0:

- `rebar3 compile` — PASS;
- `rebar3 eunit` — 255 PASS, including 12 Cowboy harness cases;
- `rebar3 ct` — 3 PASS;
- `./scripts/run_cowboy_long_bench.sh --backend ets --duration 30 --seed 424242`
  — 3582 executions, 119.36 exec/s, 266 final coverage points, 56 corpus
  inputs, 0 crashes/timeouts/errors;
- the same command with `--backend bitmap` — 1992 executions, 66.36 exec/s,
  259 final coverage points, 49 corpus inputs, 0 crashes/timeouts/errors.

The 30-second raw results are stored locally under
`artifacts/cowboy-long-bench/20261002T190436Z-ets/` and
`artifacts/cowboy-long-bench/20261002T190514Z-bitmap/`. Mean bitmap/ETS for
this pair is ≈0.556. Bitmap remains experimental opt-in; ETS remains the
default. These data do not replace four 15-minute runs in the order
ETS → bitmap → bitmap → ETS: 30 seconds is insufficient to conclude coverage
saturation, throughput stability or memory growth.
