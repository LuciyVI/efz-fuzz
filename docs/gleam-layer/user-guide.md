> This document describes the historical QS compatibility interface. The current
> public plugin and generic API guide is [Connecting Erlang libraries](connecting-erlang-libraries.md).

# Optional native Gleam layer

Default `rebar3 compile` and all ordinary EFZ targets require no Gleam.

Build with the pinned compiler (does not install anything):

```sh
GLEAM_BIN=/path/to/gleam-1.10.0 ERL_FLAGS='+S 2:2' rebar3 as gleam compile
escript scripts/gleam_seeds.escript /tmp/new-qs-seeds
```

[P2 integration evidence](p2-integration.md) records compiler-free clean off-build,
reproducible on-build, runtime-off, direct BEAM traces, and boundary tests.
For component diagnostics in a separate VM:

```sh
escript scripts/gleam_beam_bench.escript "$PWD/_build/gleam" /tmp/gleam-beam-samples.json
escript scripts/gleam_dispatch_bench.escript /tmp/gleam-dispatch-samples.json
```

These drivers collect finite counters and timings without production logging or
telemetry state. Do not run them alongside campaign benchmarks.

The seed manifest is outside the raw seed directory, so EFZ cannot accidentally
fuzz the manifest. Seeds-only can subsequently run with the layer disabled.
Default generation produces 12 distinct seeds, including empty values/query,
duplicate names, arbitrary bytes, malformed percent escape, 31/32 fields,
127/128-byte values and a 4096-byte wire input. The command refuses an existing
output directory/manifest. The index catalogue is deterministic; schema 2 records
generator version 2, runtime versions, limits and each raw input's SHA-256.
For prepared ordinary ETS artifacts, import through the existing CLI:

```sh
escript scripts/fuzz.escript --target efz_qs_target --artifacts /tmp/qs-ets \
  --code-path _build/default/lib/efz/ebin --seeds /tmp/new-qs-seeds \
  --out /tmp/qs-seeds-only --max-iterations 100 --mutation staged
```

This command has no runtime layer flag. Independent target acceptance/import
evidence and structured smoke results are recorded in [p3-provider.md](p3-provider.md).

First target: `efz_qs_target:run/1`, wrapping pinned `cow_qs:parse_qs/1`. Supported
model: nonempty binary names, explicit `=`, ordered binary values, percent/plus
encoding, `&` separators. Unsupported and malformed bytes continue through the
ordinary path. Expected parser rejection returns `rejected`, without a finding.

Prepare target-only native artifacts from Erlang using:

```erlang
{ok,A}=efz_cov_native_public:compile(
  "_build/default/lib/cowlib/src/cow_qs.erl", "/tmp/qs-native",
  ["_build/default/lib/cowlib/include"]).
{ok,_}=efz:start(#{target=>efz_qs_target, seeds=>[<<"a=1">>], artifacts=>[A],
  coverage_backend=>otp_native_public, mutation_mode=>staged,
  mutation=>#{seed=>{17,23,41},stages=>[havoc]},
  timeout=>1000, max_iterations=>1000, crash_dir=>"/tmp/qs-findings",
  gleam_layer=>#{structured_fraction=>10}}).
Report=efz:await(30000).
ok=efz:stop().
```

Use the `_build/gleam/lib/efz/ebin` and Cowlib dependency code paths. Fraction 0
performs no structured branch draw/decode. `gleam_layer=>false` disables every
callback and semantic state, including in the on-build. Missing package or
unsupported target/configuration fails startup clearly. There is one supported
adapter and no deferred oracle policy. Default execution isolation is unchanged.

For the existing CLI with ordinary ETS artifacts, add
`--code-path _build/gleam/lib/efz/ebin --gleam-layer --structured-fraction 10
--semantic-feedback guided --semantic-oracle inline --oracle-budget 64`.
The API above is the native coverage preparation workflow; the CLI's existing
artifact discovery remains for paired source-instrumented ETS artifacts.

Checks: query_model_agreement v1 compares the supported model with the completed
primary parser output. Unsupported input, exhausted check budget, timeout or
exception is Inconclusive, with reason. It has zero extra target executions.
Observer features have an exact 12-ID namespace, independent of structural
coverage. Semantic-only discoveries use the ordinary EFZ corpus/scheduler.

[P4 feedback evidence](p4-feedback.md) records equal native snapshots, actual
semantic-only parent selection, write retry, restart/subset preservation and
finding replay. `efz_corpus:semantic_representatives/0` returns a cold read-only
feature-to-working-entry index in guided mode; off/observation-only returns
`disabled`. Restart recalibrates current raw corpus entries before mutation.
Deferred oracle and online corpus deletion are unsupported.

Measure bounded callback components separately from campaigns:

```sh
escript scripts/gleam_feedback_probe.escript "$PWD/_build/gleam" /tmp/feedback-costs.json
```

This finite diagnostic uses model-derived outcome fixtures and executes no target.
It measures callback cost, not parser correctness or campaign performance.

An oracle finding retains `.input`, `.term`, `.replay`, optional `.recipe`, and
checksummed `.semantic`. Property replay requires Gleam and explicit unchanged
target/native artifacts; recipe regeneration and ordinary raw replay need none.
Replay/minimize the artificial fixture used in tests (not a real Cowlib defect):

The following five-positional-argument command is the QS legacy helper. New
adapters use the explicit `--config` interface in the
[library connection guide](connecting-erlang-libraries.md#8-проверить-persistence-replay-и-минимизацию).

```sh
escript scripts/gleam_replay.escript ARTIFACT_PREFIX NATIVE_ARTIFACT_DIR \
  efz_qs_defect_target 64 /tmp/qs-minimized
```

It writes outputs outside the immutable finding group. The minimizer counts all
target executions, keeps the same property predicate, stops at its finite budget,
and reports whether single-byte deletion reached a fixed point. It does not
promise globally minimal input. Stop active campaigns before property replay.

`efz_semantic:cover/1` returns a conservative subset preserving recorded probe,
hit-count and semantic unions; it does not delete corpus files. Initial or
uncalibrated entries remain protected. Corpus restart rebuilds current features
by normal seed calibration, counted separately from mutation executions.

No performance advantage or optimal fraction is claimed. Final P5 campaign
benchmark acceptance is pending; P2 component samples do not close that gate.
P3 reports attempts/successes, operation IDs, unsupported/limit/unchanged fallback,
layer errors, generated bytes and aggregate callback microseconds. For separate
finite component samples (decode / core mutation / encode / whole provider):

```sh
escript scripts/gleam_provider_probe.escript "$PWD/_build/gleam" \
  artifacts/gleam-layer/20261008-p3-provider/p2-model-original.beam /tmp/provider.json
```

The P2 model BEAM is local evidence, not a shipped runtime dependency. Structured
recipes now use schema 3 with exact RNG provenance; old schemas 1/2 still replay
without Gleam. Neither recipes nor metadata change canonical corpus raw inputs.
