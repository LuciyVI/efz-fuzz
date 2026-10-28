# Persistent-worker performance evidence

Each run directory contains the exact `manifest.json`, aggregate `summary.json`,
and compressed raw `runs.json.gz`. Decompress a run list with:

```sh
gzip -dc performance-persistent-acceptance-20261028/runs.json.gz > /tmp/runs.json
```

The primary matrix is `performance-persistent-acceptance-20261028` (40
mode/seed runs); count-recycle acceptance is
`performance-persistent-recycle-fixed-20261028` (15 runs). The repeated
native-off pair, profiling comparison, and diagnostic failed attempts are kept
as separate directories. Failed runs remain in their own raw run lists and do
not enter the successful summaries. The first recycle attempt includes its
`semantic_persistent-s29.log`; after the handoff fix the separate fixed matrix
completed all 15 runs.

`recycle-lifecycle.json` is a derived nearest-rank summary retaining all 30
startup and cleanup samples and the per-seed VM/restart counts. The direct-core
batch benchmark is in `direct-core-microbench.json`. Final check outcomes are in
`validation-results.json`.

The acceptance matrices were recorded against the exact EFZ source commits
listed in their manifests: the primary matrix predates the recycle handoff fix,
and the count-recycle matrix uses `f8fd5acea09b06248f1824dccbce2a18155e4db6`.
The final branch adds a narrow SDK/control string-mode compatibility fix and
its regression coverage; neither change is on the campaign benchmark hot path.
The core and gitlink are unchanged. This source identity boundary is retained
rather than relabeling older samples as a byte-identical final build.

`driver-recycle-smoke.json` records a separate one-second, one-seed probe of the
corrected benchmark driver's recycle percentile output (`max_requests=3`). It
validates the updated roll-up code only and is explicitly not an acceptance
throughput sample.

`final-default-eunit.log.gz` is the final 400-test successful run. The validation
JSON records the earlier sandbox `eperm` and one transient suite retry that
returned provider setup errors before focused tests and the complete final retry
passed.
