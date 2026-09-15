# Input limits and storage failures

`max_input_bytes` is one campaign option, default **4096**, inclusive range
**0..1048576**. Zero allows only `<<>>`. The maximum itself is allowed; maximum
plus one is rejected. No layer truncates or converts input bytes.

```erlang
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [<<>>], mutation_mode => staged, max_iterations => 100,
    max_input_bytes => 4096,
    mutation => #{stages => [dictionary_insert, bitflip], dictionary => [<<"A">>]}}).
```

The previous nested campaign option `mutation.max_input_bytes` now returns
`{error,{campaign_level_option,max_input_bytes}}`. The normalized internal mutation
plan and saved recipes still contain the derived limit for deterministic replay.
The standalone planner API retains its own explicit options map.

| Boundary | Behavior |
|---|---|
| Initial seeds | Config validates all binary sizes before calibration, in either mode |
| CLI seeds | Raw read of at most limit + 1 bytes; oversized files fail with path and size lower bound |
| Restored corpus | Bounded input read at the current campaign limit, before calibration; no silent skip |
| Active corpus insertion | Checks the same limit before insertion/persistence |
| Random mutation | Receives limit in callback options; built-in mutator substitutes overwrite for insertion at capacity; at zero it returns empty input |
| Worker / executor | Validate before invoking harness; a misbehaving custom random callback is an infrastructure failure with its exact candidate retained |
| Staged mutation | All operations, intermediate values and donors use the derived limit |
| Crash input | `save/4` validates against the campaign limit before filesystem work |
| Replay | Low-level raw execution uses `Opts.max_input_bytes`, default 4096; verified replay CLI defaults to the recorded campaign limit |

The historical low-level executor API still supports term-based instrumentation
experiments when no byte-limit option is supplied. Campaign and replay execution
always pass the limit explicitly and require binary input.

## Replay

`efz_recipe:regenerate(Recipe)` validates against the campaign limit recorded in
that recipe. `regenerate(Recipe, #{max_input_bytes => Max})` also enforces the current
campaign bound on primary, donors, all intermediate values and output; it does
not relax the recorded bound. `regenerate(Recipe, #{})` uses default 4096.

```erlang
{ok, Input} = efz_recipe:regenerate(Recipe, #{max_input_bytes => 4096}),
{ok, Expected} = efz_replay:load(ExpectationPath),
{ok, Result} = efz_recipe:execute_file(InputPath, my_harness, Artifacts, Builds,
    #{timeout => 1000, max_input_bytes => 4096,
      expected_harness => maps:get(harness, Expected)}).
```

```sh
escript scripts/replay.escript finding.recipe exact.input --max-input-bytes 4096
```

Recipe and corpus metadata envelopes retain separate *metadata* size limits;
these do not permit larger fuzz inputs. Oversized in-memory binaries report their
SHA-256 and exact size. Bounded file readers report a lower size bound and path,
without pretending that a prefix hash is the input's identity.

## Crash transaction and errors

`efz_crash:save(Input, Result, Metadata, #{crash_dir => Dir, max_input_bytes => Max})`
returns `{ok, Crash}` or `{error, ErrorMap}`. The directory-only fourth argument
uses default 4096. A filesystem error map includes:

```erlang
#{kind => filesystem, operation => open, path => Path, reason => eacces,
  input_hash => InputSHA256, signature_id => Signature, group_id => Signature,
  occurrence_id => Occurrence, crash_fingerprint => Signature,
  artifact_group => Group, staging_path => Staging}
```

`operation`, `path`, and `reason` describe the primary failure. Optional
`close_error` / `cleanup_error` preserve secondary failures without replacing it.

Published layout:

```text
crash_dir/
  SIGNATURE_SHA256/
    summary                  (bounded durable count / representative index)
    .lock/                   (exclusive writer; absent between saves)
    OCCURRENCE_ID/            (selected representative only)
      artifact.input
      artifact.term          (complete raw Reason/stack and metadata)
      artifact.replay        (expected build/harness/input/signature)
      artifact.recipe        (when valid staged provenance is available)
      manifest               (version, file sizes and SHA-256 hashes)
    .tmp-RANDOM/              (uncommitted staging after a killed writer)
```

Every file is written exclusively, fsynced and closed in a temporary directory.
After fsync of that directory, one rename publishes the whole group and the
parent directory is fsynced. Missing parent directories are created and synced.
On ordinary failure unpublished staging is removed; cleanup failure reports its
path. An interrupted writer can leave a recognizable `.tmp-*` directory; it has
no committed group identity and must not be used as a finding. Do not glob
`.input` files without excluding staging. If killed after rename, the published
group is complete. A parent fsync error after rename reports failure although a
complete group may exist. Artifact publication and the summary update are separate
commits: an orphan after interruption is diagnosed, never silently discarded or
counted as an empty store.

`efz_crash_store` applies `crash_policy.max_representatives` across campaigns and
VM restarts. It keeps the first N distinct input hashes, counts every committed
occurrence in a synced atomic `summary`, and excludes concurrent writers with a
directory lock. It validates the summary and representative manifests before saving.
Only the last committed occurrence ID can be retried idempotently. A killed writer
can leave `.lock`, `.tmp-*` or an unindexed artifact; all block further writes with
a structured error until inspected. This is not exact campaign resume.

`storage => saved` names a new immutable artifact; `duplicate` reuses an exact-input
representative identified by `representative_occurrence_id`. Its raw Reason/recipe
belong to that saved occurrence. `limit_reached` provides no path and writes no
individual artifact for that input. Report carries current campaign counts plus
`durable_occurrences` and `disk_representatives`. These are count bounds per signature,
not a global byte quota. Full raw Reason is preserved for selected representatives.

Missing/truncated/mismatching representative files fail validation. Legacy groups
without `summary` are explicitly rejected when writing and remain replayable;
use a new output directory for bounded storage, keeping the original archive.
Decreasing the cap below the stored representative count also rejects without
deleting findings. `Crash.path`, when present, remains a prefix ending in `artifact`.

A malformed/mismatching recipe does not prevent saving a selected raw input: it
is published without recipe, with the full diagnostic and `recipe_error`.
`save/4` then returns the primary recipe error, retention disposition and
`saved_artifact` when an exact-input representative exists. At the cap the error
still retains triggering bytes in runtime context; it does not claim disk storage.
Raw replay only needs `.input` and trusted `.replay`, independently of optional
recipe/raw diagnostics. See [crash/replay/report](replay.md).

A storage failure stops the campaign with `{infrastructure_failure, ErrorMap}`,
increments `infrastructure_failures` once, and keeps the target crash counter.
`unique_crashes` counts detected signatures, including unsaved ones.
`crash_occurrences` counts all target failures, including repeats and timeouts. The report
retains the crash result/stack and exact bytes in `crashes` and `failure_context`,
along with the recipe, hash and primary storage reason. No worker crash is needed
to communicate failure. A repeated-fingerprint failure is always available in
`failure_context`, even if `crashes` already contains an earlier representative.

The final CLI report and standalone recipe/output writes also use temporary-file
write/fsync/close/rename publication. If report storage itself fails, the CLI
increments the infrastructure counter and includes the in-memory report in its
error diagnostic, preserving any preceding primary campaign failure. Worker death also increments
`infrastructure_failures`; the fuzzer retains the last received exact input context.
`primary_infrastructure_failure` in stats is set by the first failure only.

This protocol assumes a filesystem supporting same-directory atomic rename and
file/directory fsync. Unsupported operations return infrastructure errors.

## Verification

`test/efz_limits_tests.erl` exercises real instrumented execution, random and
staged limits, retained/restored corpus, replay and raw crash boundaries. It
checks a regular-file ancestor (`/dev/null/invalid-dir` equivalent), real Unix
`eacces`, missing parents, failure on the second artifact after the first is
synced, corrupt committed data, and a killed staging writer. The permissions
case requires an unprivileged test process to exercise Unix mode denial.
Existing fresh-VM CLI, recipe replay, durable-corpus and staged-lineage tests
continue to validate integration.
