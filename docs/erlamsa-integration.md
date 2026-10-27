# Local Erlamsa mutation provider

This integration adds a byte mutation source alongside native EFZ mutations.
Semantic adapters remain a separate choice: the existing term, query-string,
XML-RPC, and stateful adapter contracts do not become Erlamsa callbacks. EFZ
still selects corpus entries, executes the target, collects target coverage,
applies semantic feedback, admits corpus entries, and saves findings.

The implementation is opt-in. Ordinary builds and native campaigns do not need
Erlamsa or Gleam. An enabled provider is prepared before target execution; a
missing, dirty, incompatible, or unbuilt core is a configuration error.

**Publication status:** the local implementation is under validation. Creation
and verification of `https://github.com/LuciyVI/erlamsa` are blocked by GitHub API
access in this environment. No published fork, gitlink, or recursive-checkout
acceptance is implied. See [validation](erlamsa-validation.md) for actual results.

## Build and version ownership

The intended dependency is a real Git submodule at `vendor/erlamsa`, using the
portable HTTPS URL `https://github.com/LuciyVI/erlamsa.git`. Its gitlink must name
a published commit on the fork's `efz-integration` branch. EFZ must not fetch the
same dependency through Rebar, follow a branch head during builds, or copy the
fork's sources into `src/`.

After publication and gitlink acceptance, the checkout procedure is:

```sh
git clone --branch feat/erlamsa-integration https://github.com/LuciyVI/efz-fuzz.git
cd efz-fuzz
git submodule update --init --recursive
export ERL_FLAGS='+S 2:2'
rebar3 compile
rebar3 as erlamsa compile
```

That remote procedure is currently **BLOCKED**, not a successful clean-checkout
result. For independent local development, the build hook accepts an explicit
`ERLAMSA_SOURCE=/absolute/path/to/clean/erlamsa`. This override is not a
replacement for the required published submodule. `sh scripts/build_erlamsa.sh`
builds the core directly without rebuilding EFZ.

The fork's standalone `core/` project builds and tests independently:

```sh
cd /absolute/path/to/erlamsa/core
ERL_FLAGS='+S 2:2' rebar3 compile
ERL_FLAGS='+S 2:2' rebar3 eunit
```

It has no external Rebar dependencies, application callback, services,
supervisor, named ETS tables, network modes, or testcase file writes. Upstream's
original source tree and entrypoints remain separate and unchanged. The full
upstream application and its native/network dependencies are outside the
validated core profile. OTP 27+ is required. Gleam builds separately with
`GLEAM_BIN=/path/to/gleam rebar3 as gleam compile`; a combined optional build is
`GLEAM_BIN=/path/to/gleam rebar3 as erlamsa,gleam compile`.

## Configuration

Campaigns use staged scheduling. `mutation_provider` selects bytes;
`gleam_layer` selects interpretation, observation, and optional guidance. A
trusted Erlang configuration file can contain the complete provider map:

```erlang
#{target => efz_staged_parser,
  seeds => [<<"local fixture">>],
  artifacts => "/absolute/path/to/instrumented",
  mutation_mode => staged,
  mutation => #{seed => {17,23,41}, stages => [havoc]},
  selection_seed => {17,23,41},
  max_iterations => 1000,
  max_input_bytes => 4096,
  mutation_provider => #{
    mode => hybrid,
    weights => [{native,70},{erlamsa,30}],
    core_path => "/absolute/path/to/vendor/erlamsa",
    timeout => 1000,
    on_skip => native,
    options => #{profile => balanced,
                 strategy => mixed,
                 operators => [{byte_flip,3},{json,1},{length,1}],
                 patterns => [{once,4},{many,2},{burst,1},{skip,1}]},
    limits => #{input_bytes => 4096, output_bytes => 4096,
                intermediate_bytes => 65536, depth => 4,
                nodes => 1024, entries => 16, entry_bytes => 16384,
                unpacked_bytes => 65536, expansion_ratio => 32,
                operations => 8, repeats => 4, block_bytes => 128}}}.
```

Omit `mutation_provider` for native behavior. The short values `native`,
`erlamsa`, and `hybrid` are accepted. `erlamsa` dispatches ordinary mutation
requests to the provider; `hybrid` uses source weights. Existing semantic
structured-generation opportunities remain independent and precede ordinary
source selection. Provider, operator, and pattern weights are three separate
distributions fixed for the campaign. Unknown/duplicate names, noninteger or
negative weights, and zero total mass reject. Zero-weight operators are
disabled. There is no coverage-driven weight learning.

Profiles supply default operators: `balanced` enables all listed families;
`bytes` enables the twelve byte/block/line/number/delimiter/Unicode operators;
`formats` enables JSON, SGML, and wrappers; `fields` enables length/XOR8/CRC32.
An explicit `operators` list replaces profile weights. `inner_operator` is
`auto` or `byte_flip`. Automatic inner wrapper detection recognizes gzip, zlib,
and ZIP; ordinary text is not silently treated as Base64.

CLI overrides take precedence over the trusted config file, then defaults.
The full map configures weights and limits; help lists the shortcut flags:

```sh
escript scripts/fuzz.escript --help
escript scripts/fuzz.escript --config campaign.term --out _build/provider-run
```

`escript scripts/prepare.escript` builds and instruments the bundled staged
parser and copies its seeds. That synthetic fixture has an intentional
demonstration crash; it is not a discovered library defect.

```sh
escript scripts/prepare.escript
escript scripts/fuzz.escript --target efz_staged_parser \
  --artifacts _build/quickstart/instrumented --seeds _build/quickstart/seeds \
  --out _build/hybrid-run --mutation-provider hybrid \
  --provider-core /absolute/path/to/erlamsa --max-iterations 1000
```

Use `--max-iterations infinity --corpus-dir /absolute/path/to/corpus` for a
continuous campaign. `touch OUTPUT/stop.request` requests orderly stop and
saves the final report. The Erlang API offers `efz:request_stop()` followed by
`efz:await(Timeout)`. Restarting from a persisted corpus retains input and
provenance; it does not restore an exact campaign RNG checkpoint.

## Core contract and determinism

```erlang
erlamsa_core:prepare(Options, Limits).
%% {ok, ImmutableContext} | {error, Reason}
erlamsa_core:mutate(Input, Request, ImmutableContext).
%% {ok, CandidateBinary, Metadata} | {skip, Reason} | {error, Reason}
```

A request contains `seed => {A,B,C}` (unsigned 64-bit integers), and optionally
`operator`, `pattern`, `strategy`, and `budget`. Budget cannot exceed the
prepared operations limit. `auto` selects enabled names using normalized
weights. A pattern may be a list of at most four bounded patterns. API,
catalogue, patterns, limits, and SplitMix64 PRNG have explicit versions.

The planner's state-threaded RNG chooses sources and assigns child seeds. Core
decisions use explicit child state. Target randomness, previous requests, and
request ordering do not alter repeated-request output. An omitted/native
provider adds no provider draws to the old campaign path. Contexts contain no
PID, port, reference, implicit RNG state, or adaptive score. Guardian-local
cleanup bookkeeping is not generator state or provenance.

Regeneration applies to identical bytes, normalized options, request, limits,
BEAM identity, and OTP/ERTS. No cross-runtime compressed-byte guarantee is
claimed. Gzip mtime is zero. ZIP entry names sort with a fixed DOS timestamp.
Deflate bytes still depend on the pinned runtime's compression implementation.

## Catalogue and upstream correspondence

This is a bounded library adaptation, not complete preservation of upstream
mutators or probability distributions. Most operators are explicit-state
equivalents of upstream families. JSON/SGML retain adapted pure parser code and
original notices. Tests below live in the fork's `core/test/`.

| Upstream operator/pattern | Core / EFZ name | Observable test | Scope and limits |
| --- | --- | --- | --- |
| `bf`, `bi`, `bd` | `byte_flip`, `byte_insert`, `byte_drop` | bytes: `all_operators_changed_and_deterministic_test`, `every_byte_including_nul_test` | Bounded bytes; explicit RNG |
| `br`, `sr`, `sd`, `sp` | `block_repeat`, `block_drop`, `block_swap` | bytes: `all_operators_changed_and_deterministic_test`, `limits_before_growth_test` | Bounded repeats/blocks; not all permutation variants |
| `ld`, `lds`, `lr2`, `lr`, `ls`, `lp` family | `line_drop`, `line_repeat`, `line_swap` | bytes: `line_semantics_and_no_change_test` | Bounded newline-delimited equivalents |
| `num` | `number` | bytes: `number_digit_bound_test` | Bounded decimal runs |
| `ad`, ASCII/string family | `delimiter` | bytes: `all_operators_changed_and_deterministic_test` | Finite local delimiter set |
| `ui`, `uw` family | `unicode` | bytes: `unicode_preserves_existing_utf8_boundaries_test` | Valid Unicode insertion; overlong UTF-8 operator excluded |
| `js`, JSON tree family | `json` | tree: `json_tree_operations_preserve_grammar_test`, `escaped_json_strings_roundtrip_test` | Pure parser port; bounded tree edits |
| `sgm`, SGML tree family | `sgml` | tree: `sgml_tree_operations_preserve_grammar_test`, `sgml_input_names_remain_data_test` | No entity resolution/declarations/processing instructions |
| `b64` | `base64` | pack: `wrappers_roundtrip_test`, `strict_base64_test` | Canonical padded whole-input Base64 |
| `cp` compressed pattern | `gzip`, `zlib` | pack: `wrappers_roundtrip_test`, `compressed_budgets_test`, `native_output_chunk_drain_test` | Deflate preflight; gzip CM8/flags0; no zlib preset dictionary |
| `ar` archive pattern | `zip` | pack: `zip_content_roundtrip_and_determinism_test`, `zip_entry_and_expansion_budgets_test` | In-memory content; methods0/8; single disk; no encryption/descriptors/Zip64/unsafe names |
| `len`, `sz` | `length` | fields: `length_preserve_test`, `length_widths_and_endians_test`, `length_perturb_test` | Explicit or unique supported heuristic; bounded field edits |
| `cs`, XOR8/CRC32 helpers | `xor8`, `crc32` | fields: `xor8_preserve_and_perturb_test`, `crc32_little_endian_before_payload_test` | Contiguous payload range; recorded interpretation |
| `od`, `nd`, `bu`, `sk` | `once`, `many`, `burst`, `skip` | core: `operation_budget_and_metadata_test`, `skip_pattern_preserves_prefix_test`, `pattern_combinations_are_bounded_test` | Bounded repeats/prefix variants; no unbounded decay recursion |

Excluded families include URI/network-specific transformations and specialized
payload catalogues; ZIP path manipulation; HTTP/cloud/proxy/scanning/monitoring
entrypoints; serial/socket/process-execution integrations; unbounded adaptive
fusion/history scores; and debug/no-mutation patterns. They are outside the
local library profile or violate its explicit-state/bounded contract.
`procket`, `erlserial`, and `erlexec` are not core dependencies. `pyerlamsa` is an
HTTP client and is not used as a mutation implementation.

## Fields and limits

`preserve` mutates payload and recomputes length/checksum. `perturb` changes the
selected field to disagree with payload. `mixed` deterministically chooses one
of those strategies. An explicit field is:

```erlang
#{offset => 0, width => 16, endian => big,
  payload_offset => 2, payload_length => 8}
```

Offsets/lengths are bytes; widths are bits (8/16/32/64). Field and payload ranges
must be valid and disjoint. Checksum widths match the algorithm. Metadata records
the interpretation and values. Heuristics examine limited contiguous layouts;
coincidental numeric matches are not protocol understanding. `field_not_found`,
`ambiguous_field`, and `field_overflow` are explicit skips.

Default core limits appear in the configuration example. Byte/block limits have
a 1MiB ceiling; maxima are depth16, nodes8192, entries256, ratio1024,
operations64, repeats16. Campaign/provider input and output bounds must agree.
Nested decoded data uses the intermediate limit; final candidates use output
limits. Wrappers and inner transformations both consume operation budget.

Compressed data is structurally walked to calculate expansion/work bounds
before inflation. ZIP limits apply per entry and cumulatively. Handles close
in `after` branches. Checking size only after unrestricted `gunzip` would not
provide these bounds. Neither these guards nor a disposable process are a hard
whole-VM/native-memory quota.

Each request runs in a disposable Erlang VM controlled by EFZ's Linux launcher.
Its guardian enforces an absolute deadline, correlates replies, handles
cancellation/owner death, and waits for cleanup before reporting completion.
The launcher owns descendant termination/reaping. A fixed Python bootstrap
preserves its actual-parent check. A private Unix-domain socket is local IPC,
not an Erlamsa network mode. Temporary socket directories are removed; testcase
contents are not written there. No compile/download occurs in the hot path.
Cold VM startup is included in measured request latency.

`skip` is an expected refusal (format mismatch, no change, limit).
`on_skip => native` permits an ordinary native fallback in campaign scheduling;
`skip` suppresses it. Errors, contract violations, and timeouts are infrastructure
outcomes, never silent fallbacks or target findings. Target crash/timeout
classification remains the executor's responsibility. A documented parser
rejection does not become a semantic finding because a provider generated it.

## Provenance and replay

Candidates use the normal executor, feedback, corpus, and crash stores. Recipe
schema5 / operation-version4 adds bounded provider data and concrete replacement
bytes. Schemas1–4 retain their validation rules. Provenance includes parent and
candidate hashes, child seed/request number, source, operator/pattern/strategy
details, effective limits, fallback reason, config hash, fork revision, API
versions, actual BEAM/app hashes, and OTP/ERTS. Dirty source is rejected; a
commit label alone is insufficient. Core metadata is bounded opaque bytes so
cold raw replay needs no optional core atoms/modules.

1. **Raw replay** reads saved bytes and executes a trusted caller-selected
   target. Erlamsa and the generating build are not required.
2. **Regeneration** uses `efz_recipe:regenerate_provider(Recipe, TrustedPrepared)`
   and checks build/config identity, metadata, and candidate hash. Mismatch is
   an error; artifact metadata never selects paths or executable code.
3. **Outcome replay** checks target results and records target instability
   independently of generator reproducibility.

```sh
escript scripts/replay.escript --input /absolute/path/to/artifact.input \
  --target efz_staged_parser --artifacts /absolute/path/to/instrumented
```

To verify the provider's generation separately, pass a trusted local provider
or campaign configuration containing the same normalized provider settings:

```sh
escript scripts/replay.escript --recipe /absolute/path/to/artifact.recipe \
  --provider-config /absolute/path/to/trusted-provider.term \
  --provider-regenerate /absolute/path/to/new-candidate.input \
  --max-input-bytes 4096
```

This command starts no target. It prepares the caller-selected core, requires
matching build/config identity, repeats the recorded request, compares bounded
core metadata and candidate hash, and writes verified bytes to a new output.
Identity or configuration mismatch fails explicitly. It accepts a provider map
or a campaign map with `mutation_provider`; the artifact never supplies the
executable location. Existing raw replay behavior is unchanged.

See [replay](replay.md), [corpus](corpus.md), and
[execution isolation](execution-isolation.md) for existing storage/executor rules.

## CLI, TUI, and Python

`scripts/mutate.escript --help` describes standalone mutation without a target.
The campaign CLI selects a provider separately from semantic settings. Runtime
reports expose effective profile, real requests/changes/skips/errors/timeouts/
fallbacks, bounded latency samples, and discoveries/retained inputs by source.
TUI reads those values; provider requests and target executions are separate.

```sh
python3 -m pip install ./packages/pyefz
```

```python
from pyefz import Client

provider = {"mode": "erlamsa", "core_path": "/trusted/erlamsa",
            "options": {"profile": "bytes"}, "on_skip": "skip"}
with Client("/absolute/path/to/efz", runtime="/absolute/path/to/erl") as efz:
    result = efz.mutate(b"one\x00\xff", provider=provider, seed=(17, 23, 41),
                        request={"operator": "byte_flip", "pattern": "once"})
    if result.changed:
        print(result.data)
```

The [SDK guide](../packages/pyefz/README.md) covers batch outcomes, campaign
start/stats/stop/await/close, findings, raw replay, and typed errors. IPC is an
argv-launched local process with versioned 32-bit length-prefixed JSON, Base64
bytes, bounded frames, reserved stdout, and stderr diagnostics. JSON accepts
neither eval code nor arbitrary Erlang terms. Context cleanup closes/reaps the
owned process. Runtime, EFZ, target, and core paths are trusted configuration.

## Updating the fork

Verify GitHub `parent`/`source` ancestry to Darkkey/erlamsa before publication.
Preserve history/licenses. Update upstream explicitly in the fork, review core
changes, run core/EFZ checks, publish the integration commit, then independently
fetch that exact object. Only then commit EFZ's gitlink. Finish with a new EFZ
checkout and recursive initialization. Never build with `submodule update
--remote`, silently switch to upstream HEAD, or accept an unpublished object.

Initial decisions are separate provider/semantic contracts, immutable request
state, fixed weights, OS isolation including native compression, independent
raw-byte replay, and explicit blocked remote acceptance. Results belong in
[validation](erlamsa-validation.md) and [benchmarks](erlamsa-benchmark.md).
