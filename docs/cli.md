# Universal fuzz launcher

`scripts/fuzz.escript` loads the compiled EFZ application relative to the script
location, so it can be invoked from another working directory. Argument paths are
relative to the caller's working directory. Run `rebar3 compile` first.

The launcher calls `efz:start/1` once, waits with `efz:await/1`, saves the report,
and stops EFZ in an `after` block. Configuration, instrumentation preflight,
calibration, mutation, scheduling, execution, coverage, retention and crash
classification all use the existing core. `efz_instrument:discover/1` builds
artifact descriptors from the directory; `preflight/1` validates their embedded
manifests, paired sidecars and loaded code identities before any input executes.

## Minimal external harness

Create `my_parser.erl`:

```erlang
-module(my_parser).
-export([parse/1]).
parse(<<128, Rest/binary>>) -> {high, Rest};
parse(Input) -> {low, Input}.
```

Create `my_harness.erl`:

```erlang
-module(my_harness).
-export([run/1]).
run(Input) when is_binary(Input) -> my_parser:parse(Input).
```

From the EFZ root, prepare and launch:

```sh
rebar3 compile
mkdir -p harness-ebin corpus
erlc -o harness-ebin my_harness.erl
printf '\000' > corpus/seed
erl -noshell -pa _build/default/lib/efz/ebin -eval '
  {ok, _} = efz_instrument:compile("my_parser.erl",
      #{modules => [my_parser], source_root => ".", outdir => "instrumented"}),
  halt().'

escript scripts/fuzz.escript \
  --target my_harness --code-path ./harness-ebin \
  --seeds ./corpus --out ./findings --artifacts ./instrumented \
  --mutation staged --timeout 1000 --max-input-bytes 4096 --max-iterations 100
```

Keep ordinary harness/dependency BEAMs separate from the instrumented artifacts.
All `.beam` files in `--artifacts` are selected and must have valid matching
`.efz-manifest` sidecars. An ordinary BEAM there is an error. Use repeated
`--code-path DIR` options for ordinary dependencies; those paths are appended to
the VM's code path. Loading and export checks happen after instrumented modules
have been preflighted, so `--target` can also name an instrumented `run/1` module.

Seeds are read nonrecursively in sorted filename order. Directories are ignored;
unreadable files or unsupported file types fail the launch. There is no text
decoding, newline trimming, term parsing or truncation. An empty file yields
`<<>>`; a directory without files is an invalid corpus.

`--out` is created if necessary and checked with a temporary write before the
campaign. Crash groups are atomically published under `OUT/crashes/SIGNATURE_SHA256/OCCURRENCE_ID/`
with `artifact.input`, `artifact.term`, `artifact.replay`, optional `artifact.recipe` and an integrity
manifest. A per-signature `summary` stores the durable count and representative index;
legacy groups without it reject further writes. `OUT/report.term` is an
Erlang external term containing the full final core report, including in-memory
corpus entries and their metadata; it replaces a previous report at that path.
Add `--corpus-dir DIR` to persist and reuse successful corpus inputs. The next
invocation may omit `--seeds` when that store is nonempty. `--seeds` and
`--corpus-dir` can also be combined; duplicate contents are merged. The default
build mismatch policy is `reject`; `--corpus-build-policy recalibrate` explicitly
allows reuse across changed target/build identities. Both policies recalibrate
all loaded inputs. This does not restore a campaign checkpoint. See
[durable corpus](corpus.md) for storage, integrity errors and diagnostics.

CLI defaults are staged mode, timeout 100 ms, and 1,000 mutation executions.
Calibration executions are counted separately. `--mutation random` selects the
existing random mutator. Both modes enforce campaign `--max-input-bytes`
(default 4096, inclusive 0..1048576), including bounded raw seed ingestion.
There is no CLI support for arbitrary MFA, manual coverage, or evaluating a
configuration file as Erlang code. `--help` lists all accepted flags. Unknown or
duplicate single-value flags and missing/invalid values fail explicitly.

`--coverage-policy diagnostic` is the default: `report.term` explicitly lists
unobserved artifacts and the CLI prints coverage diagnostics. `--coverage-policy
strict` returns exit **1** if the campaign finishes without any instrumented
probe. One valid empty input does not fail the campaign immediately. This policy
is separate from instrumentation syntax strictness. See [coverage integrity](coverage-integrity.md).

| Exit code | Meaning |
|---|---|
| 0 | `completed`, true mutation exhaustion or an idle guard stop; target crashes/timeouts are findings |
| 2 | Invalid arguments, inaccessible seed/output paths, bad artifacts, unavailable module/callback or invalid campaign config |
| 1 | Campaign infrastructure failure, unexpected launcher/runtime exception or final report-storage failure |

## Campaign map schema

`efz_config:prepare/1`, also used by `efz:start/1`, requires a map and rejects
unknown top-level keys with `{error,{unknown_campaign_keys,Keys}}` **before**
loading artifacts or targets. The input schema is:

| Key | Accepted value |
|---|---|
| `target` | Required module atom exporting `run/1` |
| `seeds` | Required list of binaries; may be empty when `corpus_dir` restores a nonempty corpus |
| `timeout` | Nonnegative integer milliseconds; default 100 |
| `workers` | `1` |
| `mutator` | Module exporting `mutate/2`; default `efz_mutator_random`; custom callbacks require random mode |
| `mutation_mode` | `random` (API default) or `staged` |
| `max_iterations` | Nonnegative integer or `infinity` in random mode; 0..1,000,000 in staged mode; omitted staged value becomes 1,000 |
| `max_input_bytes` | Campaign binary limit, inclusive 0..1,048,576; default 4,096; applies to both modes, ingestion, restore and execution |
| `mutation` | Staged-only map validated by `efz_mutation_plan:prepare/2`; see [mutation limits](mutations.md) |
| `coverage` | `automatic` (default) or explicit API-only `manual` compatibility mode |
| `coverage_backend` | `ets` (default) or `ets_member` |
| `coverage_validation` | `prepared` (default) or `per_execution` |
| `coverage_policy` | `diagnostic` (default) or `strict`: fail a campaign with no observed automatic probes |
| `artifacts` | List of artifact descriptor maps; automatic mode requires nonempty, valid artifacts |
| `crash_policy` | Strict map: `reason` = `category` (default), `exact`, or `ignore`; `max_frames` = 1..32 (default 5); `max_representatives` = 1..32 (default 3), bounds disk and report per signature across restarts. API option; see [crash/replay/report](replay.md) |
| `crash_dir` | Nonempty list/binary filesystem path; default `_build/efz-crashes` |
| `random_seed` | Optional tuple of three nonnegative integers for the legacy worker PRNG |
| `selection_seed` | Optional tuple of three nonnegative integers or `undefined` for legacy corpus selection |
| `corpus_dir` | Optional nonempty filesystem path; load and durably store reusable corpus inputs |
| `corpus_build_policy` | `reject` (default) or `recalibrate`; requires `corpus_dir` |

Staged mutation RNG settings belong inside `mutation.seed`. CLI `--code-path`,
seed-directory and output-directory arguments are resolved by the launcher;
they are not extra campaign-map keys. Derived `manifests`, coverage plans and
coordinator state are also not accepted as user campaign options.

`function` and `arity` are rejected even when set to `run` and `1`: the callback
contract is fixed. Put any adaptation inside `Module:run(Input)`.
`corpus_dir` now selects the dedicated persistent format; the `--seeds` directory
still contains ordinary raw seed files. `max_input_bytes => N` is a top-level
campaign option; `mutation => #{max_input_bytes => N}` is rejected with
`{campaign_level_option,max_input_bytes}`. The CLI maps `--max-input-bytes` directly
to the campaign option. See [input/storage contract](input-and-storage.md).

```sh
rebar3 eunit --module=efz_cli_tests,efz_config_tests
```

The black-box suite runs the production launcher in fresh Erlang VMs, packages
the current build to avoid stale default-profile BEAMs, and uses an external
ordinary harness with an automatically instrumented parser. It verifies raw
input delivery, real coverage retention, both mutation modes, invalid paths and
artifacts, callback errors, crash/timeout findings, and failure exit codes.
