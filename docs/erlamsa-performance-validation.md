# Erlamsa persistent-worker validation

## Build identity and environment

Performance implementation branch: `perf/erlamsa-persistent-worker`.
The persistent lifecycle fix was built from EFZ commit
`f8fd5acea09b06248f1824dccbce2a18155e4db6`; the original no-recycle
comparison matrix used `e22346d8de9fd7eef732b8410c9be0bdb1eb3218`. The latter
predates the rapid-recycle handoff fix. That fix only changes requests arriving
while a worker is recycling; both matrices and the fixed-recycle matrix below
are reported separately. The Erlamsa core was unchanged: fork/gitlink
`191f3d9d30d8932319b98f4af25d3dff9ddc5824`, upstream base
`4a844bcd1083e3278c10405bb415a32871b216c3`.

The baseline was built from the exact EFZ source tree at
`a42c2c504401562efb35442a01c8bbe16da0ab2e` using `git archive`. Network access
prevented fetching Rebar dependencies in that temporary baseline build; the
existing Cowboy, Cowlib, and Ranch checkouts were reused only after comparing
their source revisions with the baseline lock file. The benchmark manifests
record those dependency BEAM hashes and lock SHAs. This is an exact source
baseline with verified locked dependencies, not a claim that dependencies were
downloaded again.

Environment: Linux 6.8.0-nyx+, x86_64, 12th Gen Intel Core i7-1260P, OTP 27 / ERTS
15.0, Rebar3 3.25.0, Python 3.12.3. All runs used `ERL_FLAGS='+S 2:2'`, CPU
affinity `[0,1]`, ten warmup mutations, fixed seeds `[17,29,43,61,89]`, a
shuffled order from `20261027`, 30 seconds of measured wall time per
mode/seed, and the same instrumented `cow_qs` target artifact
(`b8acd6177dd782e520c995cfdcea3494d2d48c993337fee3eafbc9cda1f2ef71`). Stage
profiling was disabled for acceptance throughput. Startup, recycle, and orderly
shutdown remain inside full campaign throughput. Warm request percentiles
exclude startup/recycle. Target coverage and parser acceptance were counted
separately.

The benchmark driver produced these matrices:

- `performance-persistent-acceptance-20261028`: 8 modes × 5 seeds, persistent
  `max_requests=10000`, no recycling occurred during the 30-second samples.
- `performance-persistent-recycle-fixed-20261028`: persistent Erlamsa, hybrid,
  and hybrid with Gleam observer; 3 modes × 5 seeds, `max_requests=1000`.
- `performance-persistent-profile-diagnostic-retry-20261028` and
  `performance-persistent-instrumentation-control-20261028`: the same five
  persistent seeds with stage profiling on and off, respectively. These are a
  paired instrumentation diagnostic, not acceptance runs.
- `performance-persistent-native-overhead-repeat-20261028`: a repeated native
  versus pristine-baseline pair because the initial five-seed comparison had
  high between-seed noise.

Each manifest records full BEAM identities, target artifact SHA-256, core
commit, command arguments, seed order, sampling interval, and per-run exit
codes. `runs.json.gz` keeps every machine-readable per-run sample. Summary
values are medians across the five runs; timing percentiles within each run
retain their sample counts and p50/p95/p99. Aggregate RSS is a sampled process
tree RSS and can double-count shared pages; it is not a memory cap or peak
private-memory measurement.

## Throughput and behavior

The original paired matrix measured the following medians (ranges are the five
per-seed campaign throughputs):

| Mode | Target executions/s | Target coverage lines | Parser accepted fraction | Notes |
|---|---:|---:|---:|---|
| Pristine baseline | 280.90 [254.33, 399.21] | 48 | 69.14% | Exact A42 source baseline |
| Native, integration | 328.82 [254.21, 404.04] | 48 | 69.15% | Native provider remains default |
| Disposable Erlamsa | 3.99 [3.72, 4.32] | 45 [44, 47] | 68.91% | One external VM per request |
| Persistent Erlamsa, no recycle in sample | 245.49 [226.80, 286.53] | 48 [48, 49] | 63.41% | One VM per campaign; 6,900–8,705 requests/VM |
| Disposable hybrid 70/30 | 13.80 [10.71, 14.74] | 48 [46, 48] | 64.24% | Disposable Erlamsa requests dominate cost |
| Persistent hybrid 70/30, no recycle in sample | 286.92 [273.79, 386.06] | 48 | 64.27% | One VM per campaign |
| Native + semantic adapter | 307.43 [275.02, 385.27] | 48 | 65.52% | Existing semantic observer |
| Persistent hybrid + semantic adapter, no recycle | 350.39 [202.52, 363.18] | 48 | 68.08% | High per-seed spread; no causal advantage claimed |

The fixed-recycle matrix ran the final lifecycle code with `max_requests=1000`.
Its Erlamsa-only median was 212.67 executions/s [151.44, 275.55], with 48–49
coverage lines. Persistent hybrid was 138.05/s [117.30, 177.63], and persistent
hybrid plus semantic observer was 263.21/s [158.22, 308.86]. All 15 runs exited
0. The provider started 5–9 VMs and recycled 4–8 times per Erlamsa-only run;
hybrid started twice and recycled once; semantic hybrid started 2–3 times and
recycled 1–2 times. These full-campaign rates include every restart and
shutdown. Compared with the disposable medians in the paired matrix, they are
about 53× faster for Erlamsa-only and 10× faster for hybrid. The ranges still
show substantial machine and seed variation.

In the final fixed-recycle Erlamsa-only runs, warm request latency was p50
434 µs, p95 1,490 µs, p99 2,621 µs (1,024 bounded samples per run). Direct core
mutation was p50 28 µs, p95 57 µs, p99 87 µs; the per-request live identity
check was 31/66/95 µs. The historical `core_us` wrapper remains separately
available and measured 59 µs median p50 across those five runs. The old
published 87–90 µs value is not directly comparable because it used a
different build and wrapped identity checking with the core call.

Across the 30 actual recycle events in the fixed Erlamsa-only matrix, worker
restart startup was p50/p95/p99 254,878/373,801/403,414 µs; cleanup was
19,864/33,192/37,015 µs. The full-campaign throughput above includes these
costs. The no-recycle matrix observed exactly one VM start and zero restarts in
all five runs. `recycle-lifecycle.json` is derived from the per-run arrays in
`runs.json.gz`; a first version of the benchmark's roll-up read those integer
arrays as maps, so the original roll-up omitted recycle percentiles. The raw
events were retained and the driver was corrected.

The initial recycle experiment stopped on a `busy` error during the first
semantic-hybrid worker restart. The submitted next request had arrived during
cleanup/startup and previously received a transient rejection. The fix keeps
at most one request under its original absolute deadline through recycle. The
regression test now submits three requests with `max_requests=1`, observes
three VM starts/two restarts, and all 15 30-second recycle trials pass. The
failed first experiment is retained as separate evidence.

Native-off overhead was budgeted at 5%. The repeated five-seed baseline/native
pair measured 415.80/s baseline and 417.87/s native, a +2.32% paired median.
Per-seed changes ranged from -6.08% to +31.63%, while absolute rates also moved
substantially between benchmark rounds. The median is within the predeclared
budget, but the noise does not establish a per-seed overhead bound of 5%. The
stage-profiling diagnostic measured medians of 310.50/s with profiling and
309.14/s without it (about +0.4% apparent difference, within run noise).

## Direct core and request breakdown

`benchmark_erlamsa_core.escript` prepares the core before timing and then times
batches of 1,000 direct `erlamsa_core:mutate/3` calls. It consumes outputs,
records outcome counts and candidate hashes, and reports wrapper identity time
separately. No core source or gitlink change was justified by these results.

| Input / operator | 64 B | 4 KiB | 64 KiB |
|---|---:|---:|---:|
| Byte flip | 1.46 µs | 3.63 µs | 38.76 µs |
| Line repeat | 1.72 µs | 25.93 µs | 476.76 µs |
| CRC32 field | 11.18 µs | 59.47 µs | 804.20 µs |
| JSON tree | 5.28 µs | 66.77 µs | 1,006.68 µs |
| gzip wrapper | 8.38 µs (78 B compressed) | 32.67 µs (662 B) | 186.39 µs (1,012 B) |

All 1,000 timed requests in each operator fixture succeeded. The benchmark
shows that large line/checksum/JSON inputs can become core-bound, while the
small query-string workload's direct core p50 is only 28 µs out of 434 µs warm
request time; changing core algorithms without an old/new differential proof
would add risk without addressing the dominant startup overhead found here.

The detailed request phases are in each raw run: request validation, per-request
identity check, direct core, provider and parent encoding, socket send, request
decode, result validation, and end-to-end request. Their intervals overlap at
the IPC boundary, so they do not add to request total. Startup identity and
prepare are measured once per VM; the warm path no longer performs Git, app
file, or full BEAM SHA reads.

## Commands and checks

Rebuild the current code and run the application checks from the repository
root:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
EFZ_ERLAMSA_CORE_PATH="$PWD/vendor/erlamsa" ERL_FLAGS='+S 2:2' rebar3 eunit
ERL_FLAGS='+S 2:2' rebar3 ct
ERL_FLAGS='+S 2:2' rebar3 xref
ERL_FLAGS='+S 2:2' rebar3 dialyzer
ERL_FLAGS='+S 2:2' rebar3 as erlamsa compile
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
EFZ_ERLAMSA_CORE_PATH="$PWD/vendor/erlamsa" GLEAM_BIN=/path/to/gleam-1.10.0 \
  ERL_FLAGS='+S 2:2' rebar3 as gleam eunit
```

Reproduce the direct-core microbench after building EFZ and the pinned submodule:

```sh
ERL_FLAGS='+S 2:2' escript scripts/benchmark_erlamsa_core.escript \
  _build/default vendor/erlamsa /tmp/erlamsa-core.json
```

The full benchmark command, including the separately prepared A42 baseline,
is recorded in each evidence manifest. `--profile` is for a separate
diagnostic run; omit it for acceptance throughput. Output directories are
created exclusively and never overwritten.

The final validation matrix on this performance branch was:

| Check | Result |
|---|---|
| `rebar3 compile` | PASS, exit 0 |
| `rebar3 eunit` | PASS, 400 passed, exit 0 |
| `rebar3 ct` | PASS, 3 passed, exit 0 |
| `rebar3 xref` / `rebar3 dialyzer` | PASS, exit 0 / 0 |
| `rebar3 as erlamsa compile` | PASS, exit 0 |
| Gleam 1.10.0 compile, EUnit, CT, xref, Dialyzer | PASS; 457 EUnit and 3 CT passed; all exit 0 |
| Installed `pyefz` local IPC tests | PASS, 3 tests |
| Python runtime/control end-to-end | PASS, 5 passed, 1 skipped |
| Python syntax checks and CLI `--help` | PASS, 13 Python files compiled; exit 0 |
| Direct-core batch microbench | PASS, 1,000 calls per fixture, outputs checked |

The skipped Python case is raw replay of the synthetic `simple_parser` fixture;
that run deliberately used the separate `cow_qs` benchmark target artifact.
Machine-readable results are in `erlamsa-evidence/performance-persistent/validation-results.json`.
One intermediate full-suite retry returned `provider_setup_failed` in 22 tests;
the two affected provider lifecycle modules passed individually, and the final
full retry passed all 400 tests. Its transient cause was not established. An
earlier run inside the restricted sandbox also returned `eperm` for the local
launcher/socket path; rerunning with local IPC permissions passed.

## Results and limitations

The CPU and OTP results apply to this one local `cow_qs` workload. They do not
predict throughput for large compressed inputs or prove additional bug
discovery. A separate external VM raises sampled process-tree RSS from roughly
108 MB native to about 200 MB for Erlamsa modes. Memory sampling can miss peaks
and RSS double-counts shared pages. Count-based recycle adds roughly 0.3 seconds
per VM restart on this host, but the 1,000-request recycle runs retain a large
end-to-end advantage over disposable transport.

The broader Erlamsa integration remains PARTIAL for the previously documented
operator catalogue and Gleam limitations. This performance branch does not
change the core, add formats, or change that integration status.
