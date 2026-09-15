# Crash occurrences, signatures and verified replay

Raw `.input` is the authoritative triggering binary. A recipe reconstructs bytes;
a signature groups failures; neither replaces raw input or the complete diagnostic
Reason/stack. Replay executes the existing instrumented executor with the explicit
`Module:run(binary())` contract. It does not create a second fuzzing engine.

## Identities and report bounds

| Field | Identity / purpose |
|---|---|
| `occurrence_id` | Fresh random 128-bit ID for each detected target failure, including repeats of the same input |
| `input_hash` | SHA-256 of exact triggering bytes, independent of failure classification |
| `signature_id` | SHA-256 of the normalized, versioned crash signature |
| `group_id` | Unique crash group, currently equal to `signature_id` |
| `id` | Compatibility alias for the group signature; **not an occurrence ID** |
| `crash_signature` | Readable normalized descriptor; does not replace raw diagnostics |

Campaign configuration through `efz:start/1`:

```erlang
crash_policy => #{reason => category, max_frames => 5, max_representatives => 3}
```

Unknown policy keys reject. `max_frames` and `max_representatives` accept 1..32.
The default `category` Reason policy keeps an atom reason or the leading atom of
a tuple (for example `{badmatch, Bytes}` becomes `{tag,badmatch}`); otherwise it
keeps the term type. `exact` retains data values but replaces pid/reference/port/fun
identities with typed placeholders. `ignore` omits Reason from classification.
These are grouping heuristics: `category`/`ignore` can merge distinct bugs at the
same stack, while `exact` deliberately separates data-dependent reasons. Paths
inside an `exact` Reason are data and are not rewritten.

Signature schema v2 includes class, reason policy, normalized Reason and at most
`max_frames` target frames. Frames are `{Module,Function,Arity}`: argument lists
become arity; file/line/column and executor/guardian/coverage frames are excluded.
The signature hash uses an explicit tuple field order, and Reason maps become
sorted pairs. It does not hash VM-dependent default ETF map order. The original
source paths, argument lists and **full raw Reason** stay in `artifact.term`.
Old fingerprint artifacts are left untouched, without automatic regrouping.

`Report.crashes` contains one entry per signature with `occurrences`,
`first_occurrence_id`, `last_occurrence_id`, and `representatives`. It keeps the
first representative's input/result/metadata/path as compatibility fields. Only
the first N **distinct input hashes** enter the representative list and crash
`decisions`; repeated occurrences increment counters without appending decisions.
`crash_occurrences` includes crashes, exits and timeouts; `crashes` and `timeouts`
remain separate counters. `unique_crashes` counts groups, including unsaved ones.
These counters describe the current campaign. Each group also exposes
`durable_occurrences`, `disk_representatives` and `group_path`, obtained from disk.

The same `max_representatives` cap applies to **disk and report per signature**.
Disk keeps the first N distinct input hashes across campaigns/VM restarts. A new
occurrence of a selected input returns `storage => duplicate`, increments the
counter and reuses its immutable artifact. `path` then names that representative;
`representative_occurrence_id` identifies the occurrence actually saved there,
while `occurrence_id` identifies the current event. Its raw input bytes match;
its saved Reason/recipe/build metadata belongs to the original representative.

A new input beyond the disk cap returns `storage => limit_reached`, increments the
durable counter and has **no artifact path**. No file for that input is written.
The current campaign can still keep it among its bounded in-memory representatives
with exact bytes/Reason and the explicit storage disposition. Reducing the cap
below the number already stored fails; existing findings are not silently deleted.
Increasing the cap allows subsequent new inputs to become representatives.

This is a count limit per signature, not a global byte quota or a bound on the
number of distinct signatures. Full raw Reason is retained for selected artifacts;
nonselected occurrences are counted, not archived individually. A requested
mutation trace has its independent `trace_limit`.

## Atomic artifact layout and interruption policy

```text
CRASH_DIR/SIGNATURE_SHA256/
  summary               EFZG v1 durable counter and representative IDs/hashes
  OCCURRENCE_ID/         only for selected representatives
    artifact.input      exact binary, no term encoding
    artifact.term       schema v2 complete raw result/Reason, metadata and policy
    artifact.replay     EFZX v1 compatibility expectation
    artifact.recipe     optional EFZR v1 concrete mutation provenance
    manifest            file sizes and SHA-256 hashes
  .lock/                exclusive writer; absence required before another save
  .tmp-*                uncommitted writes; not findings
```

`efz_crash_store` serializes writers with an exclusive directory lock, including
writers in independent VMs. It validates the existing summary and all selected
artifact manifests before accepting another occurrence. Selected artifacts are
committed first by file fsync/close, directory sync and atomic rename. A synced
atomic-file replacement then publishes `summary`; removing the lock is also
followed by a directory sync. There is no append-only event log or per-occurrence
file for discarded inputs. Repeating the **last committed occurrence ID** is
idempotent; ordinary calls always allocate a fresh ID.

EFZG v1 uses a 41-byte `EFZG`/version/length/SHA-256 envelope and safe uncompressed
ETF, bounded to 16 KiB. The seven-key schema contains version, signature, unsigned
64-bit occurrence count, first/last occurrence IDs, last input hash, and at most
32 distinct representative ID/hash pairs. No target-derived atom or raw Reason
needs decoding. `efz_crash_store:read(GroupDirectory)` returns the validated index.

An interrupted writer may leave a lock, temporary files, or a committed artifact
not yet referenced by summary. These cause **explicit infrastructure errors**, not
a reset to an empty index. A lock is reported as `writer_active_or_interrupted`;
EFZ does not guess whether another VM is dead. A failure after artifact publication
preserves the raw artifact and reports `saved_artifact` when known. Counters reflect
committed summary updates; an interrupted, unacknowledged event has no exact-resume
guarantee. Raw triggering bytes stay in runtime failure context on storage errors.

Legacy groups without `summary` are rejected as `unindexed_crash_group` when writing.
They remain replayable and are not deleted or automatically migrated. Use a fresh
output directory for a new bounded store and retain the old directory as an archive.
For interrupted stores, first establish that no writer remains and inspect the
committed artifacts before recovery; removing a lock alone does not bypass index
validation. These guards prevent restarts from silently exceeding the disk cap.

Raw replay still requires only `.input` plus trusted `.replay`; corrupt/missing
optional `.recipe`/`.term` do not block raw recovery. Further **writes** to that
store reject corrupt representatives. `efz_fs:validate_group/1` remains available
for explicit complete-artifact validation.

A malformed recipe cannot prevent saving a selected raw representative: EFZ stores
input/result/expectation without recipe and returns `operation => encode_recipe`.
At the cap, it reports the recipe error plus the explicit retention disposition;
there is no claim that a discarded input was saved. `saved_artifact` is included
when an exact-input representative exists. Primary filesystem/recipe failures are
not replaced by lock-release or subsequent report-write errors.

For a late guardian failure **after** its reply, executor keeps a prior infrastructure
outcome and records the secondary `guardian_failure`. The reply's original outcome,
coverage diagnostics and cleanup evidence stay in `execution_evidence`; final cleanup
becomes `unconfirmed`, and the VM is retired. Feedback/report/stats preserve the
primary cause. `efz_crash_retention_tests` injects this failure after the real reply
in a private VM, without a production fault-injection option.

## Run the example and replay in a fresh VM

From the repository root:

```sh
rebar3 compile
escript examples/staged/run.escript
escript scripts/replay.escript --input _build/staged-example.input \
  --target efz_staged_parser --artifacts _build/staged-targets
escript scripts/replay.escript --recipe _build/staged-example.recipe \
  --target efz_staged_parser --artifacts _build/staged-targets
```

The example copies its saved expectation to `_build/staged-example.replay`.
For an external adapter add `--code-path /path/to/harness/ebin` (repeatable).
`--expect FILE.replay` overrides the default sibling expectation file.
`--timeout MS` defaults to 100; `--max-input-bytes N` defaults to the recorded
campaign limit for execution. `--help` lists both execution and reconstruction.

| Exit | Meaning |
|---|---|
| 0 | `reproduced`: compatible harness/build and same normalized failure signature |
| 3 | `not-reproduced`: compatible execution returned normally or failed differently |
| 2 | Invalid arguments/data, input hash mismatch, missing expected identity, or build/harness incompatibility |
| 1 | Filesystem/executor infrastructure failure; never reported as an ordinary non-reproduction |

Execution first checks the exact input SHA-256, preflights the supplied artifacts,
and compares the **complete** expected target build set. It compares saved harness
module name, BEAM MD5, deterministic attributes SHA-256 and optional instrumented
build ID. Compile-source paths are excluded from the portable harness record;
BEAM code, attributes, and instrumented build identity must still match. New
execution pins then guard against replacement between preflight and execution.
Raw replay does **not** load `.term` or `.recipe`; corrupt/missing diagnostics or
recipe therefore do not block recovery of a valid raw input. Recipe replay checks
regenerated bytes against the same expected input hash. Mismatches reject before
calling the target; there is no unchecked fallback or force-mismatch option.

Reproduction means equal normalized signature, not equality of nondeterministic
raw Reason terms or stack source paths. A nondeterministic target can legitimately
return `not-reproduced`. Failures of the runner are infrastructure errors.

## Replay expectation (EFZX v1)

`artifact.replay` has a 41-byte header: `EFZX`, version byte 1, big-endian 32-bit
payload length, SHA-256, followed by exact-length uncompressed ETF. Reads are
bounded to 2 MiB. Safe decoding cannot create target-derived atoms: module names
are binaries, and only fixed EFZ schema atoms are required. The ready schema has
exactly eight keys: `schema_version`, `status`, `harness`, `target_builds`,
`input_hash`, `signature_id`, `crash_policy`, `max_input_bytes`. Builds contain
unique binary module names and 32-byte hashes; harness fields and sizes are
validated before execution. No callable target is chosen from this data.

Low-level/manual results without pinned harness plus selected instrumented builds
write `status => unavailable`. Strong execution replay rejects these expectations.
A legacy recipe alone cannot prove the original harness identity. The caller must
supply a separately trusted expectation; selecting the current harness and claiming
it was the old one is not a compatibility check. Checksums detect corruption,
not intentional tampering or authenticity.

## Erlang APIs and byte reconstruction

```erlang
[Crash | _] = maps:get(crashes, Report),
Path = maps:get(path, Crash),
{ok, Expected} = efz_replay:load(Path ++ ".replay"),
{ok, Verdict} = efz_replay:run(raw, Path ++ ".input", my_harness,
    Artifacts, Expected, #{timeout => 1000}),
maps:get(status, Verdict).
```

`efz_recipe:execute/5` and `execute_file/5` remain the lower-level execution APIs.
Their Options now **require `expected_harness`**, obtained from trusted saved
metadata, in addition to the explicit target/artifacts/expected builds. They
return the executor result, without deciding signature reproduction. They accept
`timeout`, `coverage_backend`, `max_input_bytes`; prepared plan handles reject.
A fresh plan is created and released for every replay. `efz_replay:run/6` uses that
same path and compares the resulting signature. `harness_identity/1` captures a
portable identity at discovery time; `pin/3` verifies it before execution.

Byte reconstruction remains independent of compatible code:

```sh
escript scripts/replay.escript _build/staged-example.recipe _build/regenerated.input
cmp _build/staged-example.input _build/regenerated.input
escript scripts/replay.escript docs/examples/staged-crash.recipe _build/from-docs.input
cmp docs/examples/staged-crash.input _build/from-docs.input
```

The historical positional CLI only regenerates bytes (default limit 4096,
optional `--max-input-bytes N`). It does not verify target compatibility or claim
to reproduce a crash. Calibration inputs and random mutations may lack a recipe.
For staged inputs `efz_recipe:load/1` + `regenerate/1` reconstruct exact bytes from
primary/donor bytes and concrete operations, without corpus, RNG or live plan.
Retained corpus entries keep their recipe at `metadata.mutation`.

## EFZR artifact format, version 1

All multibyte envelope integers use big-endian byte order:

```text
"EFZR" (4 bytes)
format version = 1 (1 byte)
payload length (4 bytes)
SHA-256 of payload (32 bytes)
uncompressed Erlang external-term payload (exact length)
```

The payload is a validated data map, with exactly these fields:

| Field | Meaning |
|---|---|
| `schema_version`, `engine_version`, `operation_version` | All 1 in this phase; unknown versions reject |
| `primary`, `primary_id`, `parent` | Original input bytes, SHA-256 and diagnostic corpus entry ID |
| `operations` | Ordered concrete tuples, at most 32; donor bytes/hash and actual dictionary/literal bytes are inside operations |
| `stage` | Stage responsible for this candidate |
| `config_id`, `dictionary_id` | Original normalized configuration/dictionary SHA-256 identities |
| `limits` | Input, block, token and arithmetic bounds needed to validate operation application |
| `output_size`, `output_hash` | Expected candidate byte length and SHA-256 |
| `target_builds` | Binary module names and pinned build IDs; no callable module reference |
| `rng` | Diagnostic `exsplus` algorithm and initial integer seed tuple; no internal state/handlers |

The recipe does not need the original dictionary, corpus, files, queue indexes,
RNG checkpoints or active plan. Configuration identity names the original choices;
the concrete operation list, not a rerun of the planner, determines replay bytes.
Skipped attempts are omitted because they did not alter intermediate bytes.
Offsets are applied sequentially against the intermediate result, with semantics
specified in [mutations.md](mutations.md).

Recipe files are bounded to 40 MiB. Inputs/donors must fit the recorded campaign
limit, whose maximum is 1 MiB. `regenerate/1` uses that recorded limit;
`regenerate/2` additionally accepts the current campaign limit (for example
`#{max_input_bytes => 4096}`) and checks intermediate sizes too. The replay
escript defaults to 4096 and accepts `--max-input-bytes N`. The decoder checks the
length/hash envelope, then scans ETF structure **before** decoding. It permits
bounded integers, existing atom tags, binaries, lists, tuples and maps. It rejects
compression, process/reference/port/fun objects, trailing data, excessive nesting
(depth above 24), over 20,000 terms, lists above 4,096 entries and oversized binary
fields. Safe decoding cannot create token-derived atoms. Operation/schema
validation then checks the allowed fields, versions, primary/donor hashes,
limits, realized operation results and final length/hash.

Malformed encodings return `{error,invalid_recipe_encoding}`; other failures
include `incompatible_recipe`, `recipe_size_limit`, `output_hash_mismatch`,
`output_size_mismatch`, `{invalid_recipe,Reason}`, and `{recipe_operation,Reason}`.
An operation that would skip, including a nonfitting offset, is invalid in a
realized recipe. No operation tuple is evaluated as Erlang source or dispatched
to an arbitrary module. File parsing does not use an expression evaluator.

Checksums detect corruption; they are not an authentication scheme. The existing
crash `.term` result format is separate and can contain runtime diagnostic
references; it is not the bounded EFZR import format and is not a replay dependency.
## Verification

`efz_crash_tests` uses a real instrumented parser, normal binary harness, staged
mutations and fresh CLI VMs. It proves separate occurrences for different inputs,
stable signatures after source relocation, configurable data-dependent reasons,
raw and recipe reproduction, build/harness mismatch rejection, corruption handling,
and distinct non-reproduction/infrastructure exits (including unreadable input
and missing artifact directories). A 1000-occurrence campaign
keeps one group, three representatives and three crash decisions while preserving
three raw input artifacts and a summary with count 1000. Real coordinator/worker death tests verify primary
failure reporting, statistics and cleanup. Existing limits, recipe, coverage,
durable corpus and staged parent-reuse tests cover the shared runtime path.

Validated on the project's OTP 27 toolchain. Rebuilding with different target
source/options/toolchain can change build identity and intentionally reject old
execution expectations. Recipe byte reconstruction has its own versioned contract.
