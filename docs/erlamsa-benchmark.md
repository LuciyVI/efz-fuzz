# Erlamsa integration benchmark

## Published fork rerun (2026-10-28)

This is the authoritative measurement for the pinned fork core
`191f3d9d30d8932319b98f4af25d3dff9ddc5824` and the EFZ build at
`f0768323ca746476adf34aac8d5af8ac2c4a3cc5`. The older matrix below used an
unpublished core revision and does not describe this gitlink.

The accepted matrix contains baseline, native, Erlamsa, and hybrid modes: five
fixed seeds (`17,29,43,61,89`), 30 mutation seconds per run, fresh VM per run,
ten discarded warm-up mutations, identical six initial byte inputs and
instrumented Cowlib `cow_qs` artifact, CPU affinity `[0,1]`, and
`ERL_FLAGS='+S 2:2'`. The baseline source is the actual EFZ main commit
`db1add0bc47bc1011d55a4cb528b741a0b870f97`; its Cowboy/Cowlib/Ranch source
checkouts match the locked revisions recorded in the environment evidence.
The driver shuffled all 20 mode/seed pairs with order seed `20261027`. Every
trial exited 0 and retained unchanged build identities.

The table reports median and observed min–max across five runs. “Decode” is the
harness's direct parser-acceptance fraction; it is not coverage.

| Mode | Target executions/s | Target lines | Parser accepts | Provider request p50/p95 | Core call p50/p95 | Sampled process-tree RSS median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Baseline | 345.00 [256.86–420.86] | 48 [48–48] | 69.07% | — | — | 108.9 MB |
| Native | 345.10 [243.26–385.04] | 48 [48–48] | 68.59% | — | — | 108.3 MB |
| Erlamsa | 4.33 [3.76–4.86] | 45 [44–47] | 69.08% | 224 / 252 ms | 87 / 134 µs | 195.5 MB |
| Hybrid, native 70 / Erlamsa 30 | 12.56 [10.29–15.29] | 48 [46–48] | 63.49% | 228 / 262 ms | 90 / 159 µs | 195.3 MB |

Across the five trials, provider mode produced zero provider errors and zero
timeouts. Erlamsa mode made 660 requests, changed 517 candidates, skipped 138,
and used native fallback for those 138 skips; hybrid made 583 requests,
changed 454, skipped 125, and fell back 125 times. Five and four requests,
respectively, were cancelled at orderly stop. The 31 Erlamsa-source and 11
Erlamsa-source discoveries retained in the hybrid corpus are descriptive
counts, not independent-defect or coverage claims.

The core operator call itself is around 0.1 ms, while the complete isolated
request is around 0.2 seconds because each request starts and reaps a disposable
Erlang VM. That startup cost explains the large throughput loss in Erlamsa
mode and the smaller, still substantial loss in hybrid mode. The target lines
are limited to the small parser harness. RSS is sampled aggregate process-tree
RSS and may count shared pages repeatedly; it is neither PSS nor a hard memory
bound.

The paired native-off median change was +0.03%, but individual primary pairs
ranged from −35.92% to +30.67%. Three disputed pairs were repeated: changes were
−4.31%, −1.77%, and +4.17% (median −1.77%). These repeats are supplemental
three-seed probes, not a new accepted five-seed matrix. Their median is within
the predeclared 5% budget, but noise prevents claiming a strict 5% upper bound.

The semantic/Gleam measurement was **NOT RUN**. The probe stopped before target
execution because `efz_qs_adapter` requires `efz_qs_model`, and Gleam is not
installed in this environment. The historical semantic row below used the
older unpublished core and is not evidence for the published gitlink.

Raw evidence for this run:

- [Primary manifest, source/build hashes and shuffled run order](erlamsa-evidence/benchmark-published-191f3d9-manifest.json)
- [Raw primary trial summaries](erlamsa-evidence/benchmark-published-191f3d9-runs.json)
- [Primary aggregate statistics](erlamsa-evidence/benchmark-published-191f3d9-summary.json)
- [Environment and baseline dependency identities](erlamsa-evidence/benchmark-published-191f3d9-environment.json)
- [Native-off repeat manifest](erlamsa-evidence/benchmark-published-191f3d9-off-repeat-manifest.json)
- [Raw native-off repeat trials](erlamsa-evidence/benchmark-published-191f3d9-off-repeat-runs.json)
- [Native-off repeat statistics](erlamsa-evidence/benchmark-published-191f3d9-off-repeat-summary.json)

This measures local candidate generation and execution of the ordinary Cowlib
query-string parser. It does not search for vulnerabilities or claim that one
mutation source discovers more independent defects.

## Protocol

The accepted run uses five fixed RNG triples `(s,s+1,s+2)`, for
`s = 17,29,43,61,89`, and a 30-second mutation interval for each mode. Every run
starts in a fresh VM. A separate ten-mutation warm-up campaign is discarded;
its corpus and RNG position are not inherited. Execution order is shuffled with
the fixed driver seed `20261027` and recorded in the manifest.

The modes are the pristine `db1add0` baseline, native EFZ in the integration
build, Erlamsa, hybrid with source weights native 70 / Erlamsa 30, and that
hybrid with the existing `efz_qs_adapter`, ten-percent structured opportunities,
guided semantic retention, and the oracle disabled. All modes use the same six
initial byte strings, target artifact, ordinary parser rejection contract,
4096-byte input limit, staged havoc scheduler, target timeout, persistent corpus,
performance profiling, and diagnostic sampling. The Erlamsa operator profile is
`bytes`; separate regression tests exercise tree and wrapper families.

Only `cow_qs` contributes target coverage. The harness, semantic model, EFZ,
Erlamsa, and decompression helpers do not contribute coverage. The diagnostic
harness sends a small message recording whether the ordinary parser returned
accepted pairs or its documented rejection value, and the input size. The
driver verifies that these diagnostic calls equal mutation executions plus
calibrations. This acceptance fraction is not a coverage measure.
`decode.rejected` counts parser rejection values. The existing EFZ
`stats.rejections` counter counts corpus admission decisions, so it must not be
used as the number of parser failures or unsuccessful target executions.

The native-off regression comparison has a predeclared five-percent throughput
regression tolerance. Both baseline and current native mode appear in the same
paired run matrix. Any inconclusive result requires a separately labelled repeat;
failed or inconvenient results are not removed from the evidence.

## Measurements

The runner records final target coverage, a one-second coverage/execution series,
target executions per second, parser acceptance fraction, total calls including
calibration, input sizes, provider skips by reason, fallbacks, errors, cancellation,
timeouts, and retained inputs by source. Child-reported core generation time and
the full request latency, which includes cold VM startup, transport, and cleanup,
have separate p50/p95 values. Native generation percentiles use the planner's
bounded wall-time samples. Target execution timings remain separate in the
existing performance profile.

Memory measurements include sampled VM memory. An erratum applies to the
primary matrix: the field named `sampled_process_tree_rss_peak_bytes` measured
only the root process, because this kernel omits `/proc/PID/task/TID/children`.
Child-inclusive RSS is **NOT MEASURED** in that matrix. The values are retained
unchanged with an [explicit erratum](erlamsa-evidence/benchmark-memory-erratum.json).
The corrected sampler uses PPID from `/proc/PID/stat`; a real 32-MiB child
allocation raised its measured total from 14.4 to 54.5 MB. Separate supplemental
measurements use that sampler. Aggregate RSS can count shared pages several
times, and 100-ms sampling can miss short peaks. These values are not hard
memory limits, private memory, or proportional-set-size measurements.
All measured VMs use `+S 2:2` and CPU affinity `[0,1]`. This shared environment
has five available CPUs but a four-CPU cgroup quota; concurrent validation and
ordinary host scheduling can introduce noise. Executable hashes, target artifact,
RNG seeds, CPU affinity, run commands, order, exit codes, and warm-up are retained
with the raw measurements.

## Reproduction

Build the integration and a pristine baseline first. The core argument is a
trusted, clean, already-built checkout; the benchmark never fetches or compiles
the provider during mutation.

```sh
export ERL_FLAGS='+S 2:2'
python3 scripts/benchmark_erlamsa.py \
  --engine _build/erlamsa+gleam \
  --baseline /absolute/baseline/_build/default \
  --core /absolute/erlamsa \
  --out /absolute/new-results-directory
```

The output directory must not exist. A short `--seconds 1 --seeds 17` probe is
explicitly labelled `probe_only` and is not accepted benchmark evidence. Each
accepted mode needs at least five seeds and a 30-second interval.

## Results

The frozen matrix completed **25/25 trials**, five seeds and 30 seconds per
mode, with unchanged executable identities and zero provider errors, timeouts,
target crashes, or infrastructure failures. It used local clean core commit
`86dd745aafb8ebe78f578c51f783132800b89238`. The fork publication criterion remains
separate from this successful local measurement. Cowlib is pinned at
`c768a804565ff5b8178ed968a5921e469d6bd7b2`; only its `parse_qs` surface is exercised.

Values are medians across five trials; brackets show the observed minimum and
maximum. Acceptance includes the six calibration calls in each trial.

| Mode | Target executions/s | Reached target lines | Parser acceptance |
| --- | ---: | ---: | ---: |
| Baseline main | 349.70 [337.88–374.65] | 48 [48–48] | 69.00% |
| Native, integration build | 367.73 [322.11–380.26] | 48 [48–48] | 68.95% |
| Erlamsa | 4.90 [4.53–4.93] | 46 [41–47] | 68.63% |
| Hybrid | 15.75 [14.40–17.55] | 48 [46–48] | 68.66% |
| Hybrid + semantic adapter | 16.19 [15.26–18.22] | 48 [48–48] | 64.33% |

Reached line counts are scoped to this harness. They do not mean full Cowlib
coverage. The semantic mode did not establish a coverage advantage.

| Mode | Generation p50/p95, µs | Full provider request p50/p95, ms | Main VM sampled peak, MB |
| --- | ---: | ---: | ---: |
| Baseline main | 35 / 78 | — | 47.91 |
| Native, integration build | 35 / 76 | — | 47.01 |
| Erlamsa | 123 / 202 | 195.22 / 230.77 | 39.78 |
| Hybrid | 120 / 174 | 193.77 / 223.24 | 40.22 |
| Hybrid + semantic adapter | 126 / 198 | 202.24 / 234.70 | 40.77 |

These are medians of each trial's percentiles. Native generation includes the
ordinary planner/corpus snapshot; provider generation is the child's timed core
call. The target body's median was 5–7 µs across modes. Cold worker startup,
transport, identity checks, and cleanup dominate the approximately 0.2-second
full provider request. This implementation therefore has a substantial
throughput cost on this small parser. The lower main-VM memory in slower modes
is not evidence of lower total provider memory; the child is excluded there.

| Mode | Mutation executions, sum | Skips | Native fallbacks | Cancelled at stop |
| --- | ---: | ---: | ---: | ---: |
| Erlamsa | 726 | 87 | 87 | 5 |
| Hybrid | 2353 | 87 | 87 | 5 |
| Hybrid + semantic adapter | 2449 | 79 | 79 | 5 |

Each cancellation stops a pending provider request at the wall-time boundary.
It is not a target timeout or crash. Across the measured matrix there were
111956 mutation calls and 150 calibration calls: 112106 target calls in total.
The separate warm-ups requested ten mutations plus six calibrations per trial
and are outside that measured total.

The paired native-off throughput changes were −0.99%, +12.54%, −2.34%, −9.20%,
and +7.63% for seeds 17, 29, 43, 61, and 89. Their median is **−0.99%**, within
the predeclared five-percent budget. The opposing large individual changes
show meaningful run variability; this does not establish a rigorous five-percent
upper bound. Separate repeats of the disputed 29/61/89 pairs retain every
original measurement and do not replace the primary results.

All six repeat trials completed with stable identities. Repeat changes were
−5.97%, −0.84%, and +5.16% for seeds 29, 61, and 89 (paired median −0.84%). The
large positive original change for seed 29 reversed sign. The observed paired
medians are inside the five-percent budget, but the variability means that a
strict five-percent regression upper bound remains **unproven**. The repeat
runner labels these fewer-than-five-seed supplemental trials `probe_only`;
they are not substituted for the accepted five-seed primary comparison.

The corrected RSS sampler was also run for one separate 30-second seed-17
campaign in each provider mode. Observed child-inclusive sampled RSS peaks were
146.26 MB for Erlamsa, 148.71 MB for hybrid, and 151.54 MB for hybrid plus the
semantic adapter. All three campaigns completed without errors. These are
single-seed memory diagnostics, labelled `probe_only`, and are not pooled with
the primary performance matrix. Shared pages are counted repeatedly in aggregate
RSS; these values are neither private memory nor a hard resource bound.

The first attempt stopped during warm-up while a core correctness fix changed
the checkout/build identity. Its three older-build completed trials and the
`provider_transport` failure are retained in
[interrupted evidence](erlamsa-evidence/benchmark-interrupted.json) and excluded
from the frozen comparison. The failure did not recur in the clean final matrix.

## Evidence and limits

- [Raw trials](erlamsa-evidence/benchmark-runs.json)
- [Manifest, hashes, order, and exact commands](erlamsa-evidence/benchmark-manifest.json)
- [Aggregate statistics](erlamsa-evidence/benchmark-summary.json)
- [Environment and executable hashes](erlamsa-evidence/benchmark-environment.json)
- [RSS correction](erlamsa-evidence/benchmark-rss-fix.patch)
- [Disputed-pair repeat trials](erlamsa-evidence/benchmark-off-repeat-runs.json)
- [Repeat manifest](erlamsa-evidence/benchmark-off-repeat-manifest.json)
- [Repeat statistics](erlamsa-evidence/benchmark-off-repeat-summary.json)
- [Supplemental memory trials](erlamsa-evidence/benchmark-memory-runs.json)
- [Memory manifest](erlamsa-evidence/benchmark-memory-manifest.json)
- [Memory statistics](erlamsa-evidence/benchmark-memory-summary.json)
- [Actual child-allocation sampler check](erlamsa-evidence/benchmark-sampler-validation.json)

The environment evidence hashes the actual `erl` launcher, `beam.smp`, and
`zlib.beam`, and records native dependencies. Although the initial `ldd` VM
dependency list omitted zlib, a real Erlang compression call followed by
`/proc/self/maps` inspection confirms the dynamically loaded
`/usr/lib/x86_64-linux-gnu/libz.so.1.3.1` (zlib 1.3.1). Its actual file hash is
recorded; the VM executable hash alone does not cover it. Compression
regeneration is scoped to the identical OTP installation, mapped zlib native
build, and core BEAM identity. OTP/ERTS version strings
alone do not prove cross-build compression equality; candidate hashes must
still match. Raw replay is independent of the generator and compression build.

The scope is one ordinary local query-string workload and one pinned OTP/ERTS
build. It does not establish discovery superiority, format-wide performance,
cross-OTP determinism, or production server throughput. An expected parser
rejection is a diagnostic outcome and never a finding. Corpus size and crash
count are not substitutes for target coverage.

The manifest's `efz_commit` is the checkout base at the start of measurement,
when the integration edits were still uncommitted. The actual integration
executables are identified by all recorded BEAM SHA-256 hashes; they are not
the unmodified main build. Final commits also contain later contract/type
corrections and SDK cancellation/reporting changes. The numbers describe that
frozen measured build, not a claim of byte-identical final EFZ binaries. The
core commit and target build stayed unchanged throughout all accepted trials.
