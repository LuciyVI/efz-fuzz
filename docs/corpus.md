# Reusable durable corpus, schema 1

Persistence is opt-in through `corpus_dir` in the campaign map or `--corpus-dir`
in the launcher. Without it the existing in-memory campaign path remains in use.
The store preserves initial inputs and successful new-coverage discoveries across
`efz:stop/0`, process termination and VM restarts. Mutated crashes and timeouts
continue to go only to the existing crash storage. Initial seeds are saved before
calibration, including seeds that subsequently turn out to crash.

```erlang
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [<<>>], corpus_dir => "findings/corpus",
    mutation_mode => staged, max_iterations => 1000}).
First = efz:await(infinity),
ok = efz:stop().

%% A later VM loads the same compatible harness and artifacts.
{ok, _} = efz:start(#{target => my_harness, artifacts => Artifacts,
    seeds => [], corpus_dir => "findings/corpus",
    mutation_mode => staged, max_iterations => 1000}).
Second = efz:await(infinity).
```

From the CLI, add `--corpus-dir ./findings/corpus` to the initial launch. Later:

```sh
escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin \
  --artifacts ./instrumented --out ./findings \
  --corpus-dir ./findings/corpus --mutation staged --max-iterations 1000
```

## Storage and publication

```text
CORPUS_DIR/
  <64 lowercase hex SHA-256 of input>/
    input       exact raw binary, including zero-length inputs
    metadata    checksummed EFZC envelope containing schema-1 metadata
  .tmp-<random transaction suffix>/   unpublished transaction, if interrupted
```

The content hash is the identity. Committed entries are immutable and a duplicate
keeps its first recorded provenance. A save validates any existing entry before
deduplicating; it never repairs or overwrites corrupt committed data silently.
New integer corpus IDs belong to the current campaign. Historical IDs in metadata
are only provenance, not instructions for queue reconstruction.

Metadata contains:

| Field | Meaning |
|---|---|
| `schema_version` | `1` |
| `content_hash`, `input_size` | SHA-256 and exact byte length |
| `queue_id` | Historical source-campaign queue ID |
| `origin` | `initial` or successful new-coverage `discovery` |
| `parent` | `none` for initial seeds; parent content SHA-256 and historical queue ID for discoveries |
| `discovery` | Phase and newly observed probe identities; empty probe list for pre-calibration initial seeds |
| `identity` | Harness module name, canonical `run/1`, loaded harness code MD5, coverage mode and selected module/build SHA-256 identities |
| `recipe` | Encoded EFZR recipe when available, otherwise `none` |

Automatic probe and build module names are stored as binaries so loading metadata
cannot create arbitrary atoms. Manual coverage IDs are opaque ETF binaries for
historical inspection and are never decoded during restore. Runtime execution
references, target return values, PIDs, ETS handles and process dictionaries are
not part of the durable metadata. Recipe RNG seeds and probe deltas are historical
provenance; neither initializes the new scheduler or its global coverage.

An EFZC file contains magic `EFZC`, envelope version 1, a 32-bit payload length,
a 32-byte SHA-256 of the payload, and uncompressed ETF metadata. Loading checks
envelope size/checksum, a bounded data-only ETF grammar, schema, required fields,
input size/hash, directory content identity and recipe consistency with the input,
parent and recorded builds. Raw inputs are limited to 1 MiB and metadata to 64 MiB
per entry. Unsupported schema versions are errors, not attempted migrations.

Publication order is:

1. Create a unique staging directory inside the corpus directory.
2. Write the raw input using exclusive creation; fsync and close it.
3. Write the complete metadata file; fsync and close it.
4. Fsync the staging directory, then atomically rename it to the content hash.
5. Fsync the corpus directory before acknowledging the save.

Newly created ancestor directories are also synced through their parent. Files
and the staging directory are on the same filesystem, so readers see a complete
entry at publication. A second publisher of the same content validates the
already-published entry instead of replacing it. The native Erlang implementation
uses `file:sync/1`, including directory handles opened with `[read,raw,directory]`.
This has been tested on the current Linux filesystem/OTP 27 environment. A
filesystem that cannot provide directory fsync fails explicitly; durability is
not silently downgraded. Actual power-cut recovery has not been tested here.

The corpus gen_server serializes persistence and insertion. A successful discovery
is committed before it enters the active queue or increments `discoveries`.
On a write/fsync error, the input is not inserted and the worker reports a corpus
persistence infrastructure failure. If rename succeeded but the final fsync failed,
the entry can already be visible; the campaign still reports the failure and a
later restore validates that entry. No success is acknowledged before the sync.

## Restore and build policy

`efz_config` restores entries only after validating the current target/artifacts.
It merges supplied seeds (in insertion order) with persisted inputs (in hash order)
and deduplicates by SHA-256. The corpus owner assigns fresh IDs and exposes restored
entries through the ordinary `mutation_entries/0` and `select/0` paths. Historical
metadata is available under each entry's `metadata.persistence`; restored entries
also carry `metadata.restored => true`.

The existing worker calibrates **every** starting input, including restored ones.
It creates a fresh global coverage set, RNG and lazy mutation plan. No scheduler
cursor, PRNG state, old global coverage, exact queue IDs or scheduling order is
resumed. This is input reuse, not exact campaign resume or a checkpoint.

Restored inputs must fit the current campaign `max_input_bytes` (both mutation modes); oversized entries
fail configuration with their content-addressed path, size lower bound and active limit. Nothing is truncated
or silently excluded. The existing 4,096 supplied-initial-seed bound still applies
after durable-mode deduplication; the restored active queue can be larger because
it may have grown through earlier campaigns. The store is loaded eagerly, so its
total inputs/metadata must fit available VM memory.

| `corpus_build_policy` | Behavior |
|---|---|
| `reject` (default) | Fail restore if the harness name/code, callback, coverage mode or selected build identities differ |
| `recalibrate` | Reuse exact inputs across changed identities; retain historical provenance, emit diagnostics and calibrate with the current build |

In both modes old coverage deltas are never merged into the new campaign. Schema,
checksum, input and recipe errors remain fatal even with `recalibrate`.

## Partial entries and diagnostics

A corrupt committed entry, missing `input` or `metadata`, truncation, invalid
content hash/directory name or incompatible schema makes restore fail with a
path and reason. No partial subset is silently accepted. Filesystem entries that
do not match the dedicated store format also cause an error.

`.tmp-*` entries are unpublished writes. They are never loaded as inputs and are
left in place for inspection. Restore reports each as
`{interrupted_corpus_write,Path}` while loading valid committed entries. This
diagnostic, and any allowed build mismatch, appears in startup warnings and in
the final `corpus_restore.diagnostics` report. `corpus_restore` also reports the
directory, selected build policy and restored input count. Remove an abandoned
staging entry only after confirming that no writer is using it.

## Evidence

```sh
rebar3 eunit --module=efz_corpus_store_tests,efz_durable_tests,efz_cli_tests
```

The integration test executes real staged dictionary mutations and automatic
instrumentation in separate Erlang VMs:

- VM 1: initial `<<>>` ID 1 produces `<<"A">>` ID 2, opens new coverage and commits it.
- VM 1 exits. A separate invocation verifies initial/persisted content deduplication.
- VM 2: with `seeds => []`, restores and calibrates both inputs. `<<"A">>` now has
  ID 1 and becomes the actual primary/parent of a mutation producing `<<"AB">>`.
- Further fresh VMs verify default build rejection, explicit cross-build
  recalibration, input bounds and exclusion of mutated crashes from this store.

The test checks parent IDs/hashes, exact recipe regeneration, target results,
new probes and stored provenance. Logs and reports are retained under the path
recorded in `_build/durable-e2e-latest.txt`. Unit tests cover duplicate publication,
corrupt/missing/truncated files, schema versions, content names, build policy and
write failure without queue insertion. The interrupted-write test kills a real
process after writing/fsyncing the staging input but before publication; it
verifies that the partial transaction is diagnosed and not restored.
