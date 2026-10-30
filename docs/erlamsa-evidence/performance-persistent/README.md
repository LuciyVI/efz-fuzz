# Persistent-worker performance evidence

Each run directory contains its exact `manifest.json`, aggregate `summary.json`,
and compressed raw `runs.json.gz`. Decompress a run list with:

```sh
gzip -dc performance-persistent-final-acceptance-gleam-20261028/runs.json.gz > /tmp/runs.json
```

The exact-final-commit matrices are `performance-persistent-final-acceptance-gleam-20261028`
(40 mode/seed runs, `max_requests=10000`) and
`performance-persistent-final-recycle-gleam-20261028` (15 runs,
`max_requests=1000`). Both were built from EFZ HEAD
`cbd92d121db949ea8be7b2656fafd15031cdf4ae`, used `_build/gleam`, and completed
with exit 0 for all runs. The five Erlamsa-only runs in the first matrix each
crossed 10,000 requests and recycled once; hybrid and semantic-hybrid runs did
not reach that threshold. The recycle matrix performed ten restarts per
Erlamsa-only run and three per hybrid run.

Earlier matrices remain under `performance-persistent-acceptance-20261028`
(commit `e22346d`), `performance-persistent-recycle-fixed-20261028` (commit
`f8fd5ac`), and the other timestamped directories. The repeated native-off
pair, profiling comparison, and diagnostic failed attempts are kept separately.
Failed runs remain in their own raw run lists and do not enter successful
summaries. The first recycle experiment includes its
`semantic_persistent-s29.log`; the first exact-final benchmark attempt also
includes its failed `semantic_persistent-s89.log`: it selected `_build/default`,
which has no `efz_qs_model`, then the accepted matrix was rerun with `_build/gleam`.

`recycle-lifecycle-final.json` is the exact-final-commit pooled nearest-rank
summary retaining all 80 startup and cleanup samples and per-seed VM/restart
counts. `recycle-lifecycle.json` retains the earlier 30-event recycle matrix.
The direct-core batch benchmark is in `direct-core-microbench.json`. Final check
outcomes are in `validation-results.json`.

Every manifest records the EFZ commit, source and BEAM hashes, target artifact
hash, core commit, command arguments, environment and per-run exit codes. The
core and gitlink are unchanged across these measurements.

`driver-recycle-smoke.json` records a separate one-second, one-seed probe of the
corrected benchmark driver's recycle percentile output (`max_requests=3`). It
validates the updated roll-up only and is not an acceptance throughput sample.

`final-default-eunit.log.gz` is the final 400-test successful run. The
validation JSON records an earlier sandbox `eperm` and one transient full-suite
retry with provider setup errors; the focused modules and final complete rerun
passed.
