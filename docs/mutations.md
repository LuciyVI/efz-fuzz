# Native staged mutation (engine version 1)

Staged mutation is opt-in. Existing campaigns still use `efz_mutator_random`
and its `mutate/2` behaviour. Coverage defaults remain prepared validation and
the original ETS hook; `coverage_backend => ets_member` remains available.
No mutation mode changes probe identities, exception handling, seed calibration
or the policy of merging only successful coverage.

```erlang
{ok, Artifact} = efz_instrument:compile("examples/staged/efz_staged_parser.erl",
    #{modules => [efz_staged_parser], source_root => ".",
      outdir => "_build/my-staged-target"}),
{ok, _} = efz:start(#{target => efz_staged_parser, artifacts => [Artifact],
    seeds => [<<0>>], mutation_mode => staged, max_iterations => 200,
    max_input_bytes => 64,
    mutation => #{seed => {17,23,41},
        dictionary => [<<"TOKEN">>, <<"BOOM!">>],
        stages => [dictionary_insert,boundary,arithmetic,havoc,splice],
        max_block_bytes => 16, max_token_bytes => 16,
        attempts_per_visit => 8, havoc_depth => 4, random_retries => 4,
        max_idle_visits => 256, trace_limit => 0}}),
Report = efz:await(30000),
ok = efz:stop().
```

Run `escript examples/staged/run.escript` after `rebar3 compile` for a complete
build, campaign, saved crash recipe and execution replay. Its dictionary comes
from `examples/staged/tokens.hex` instead of the inline option above.

## Responsibilities and state

* `efz_mutation:apply_operation/3` applies a concrete operation without random
  choices, corpus reads, clocks, coverage or process state. `apply_operations/3`
  applies an ordered realized sequence to intermediate binaries.
* `efz_dictionary` parses/normalizes tokens once during configuration validation.
* `efz_mutation_plan` owns explicit RNG state, lazy deterministic cursors and
  scheduling. Its `prepare/2` accepts mutation options and initial seed binaries;
  `new/1` takes that normalized configuration. Treat returned state as opaque.
* `efz_corpus:mutation_entries/0` supplies IDs and bytes in insertion order.
  `efz_worker` asks the planner for a candidate and invokes the **existing**
  executor and feedback loop. The old random mode keeps its old selector.
* `efz_recipe` packages concrete operations and bytes for independent regeneration
  and creates fresh validated execution contexts for replay. See [replay.md](replay.md).

The low-level planner interface is `next(State, Entries)`, where entries contain
`id` and `input`. It returns `{candidate, Binary, Provenance, NextState}`,
`{skip, Reason, NextState}`, `{done, Reason, NextState}`, or
`{error, Reason, NextState}`. Inputs/configuration must come from validation;
there is no supported setter to alter an active state's configuration. Errors
in planning/application are infrastructure failures, not target crashes.

Configuration and dictionary are frozen in the worker for the campaign lifetime.
Each cursor is keyed by `{SHA256(SeedBytes), ConfigurationId}`. Duplicate-content
initial entries share deterministic work, even if their numeric corpus IDs differ.
New content gets new cursors. There is no whole-campaign checkpoint format.

## Defaults and bounds

`mutation_mode => random` is the public default. Staged mode uses the new
`mutation` map and requires the default `mutator` setting; it rejects a custom
legacy callback rather than silently ignoring it. Supplying `mutation` options
in random mode is an error. In staged mode, omitted `max_iterations` becomes
1,000; explicit `infinity` is rejected. Random mode retains its previous budget
semantics and does not acquire the staged limits implicitly.

| Planner setting (inside `mutation` except campaign `max_input_bytes`) | Default | Accepted bound |
|---|---:|---:|
| `max_input_bytes` (derived from campaign; direct planner API also accepts it) | 4,096 | 0–1,048,576 |
| `max_block_bytes` | 128 | 1–65,536 |
| `max_token_bytes` | 128 | 1–65,536; actual tokens also obey block limit |
| `max_tokens` | 256 | 0–4,096 |
| `max_dictionary_bytes` | 16,384 | 0–1,048,576 |
| `max_delta` | 8 | 1–128 |
| `attempts_per_visit` | 8 | 1–1,024 |
| `havoc_depth` | 8 | 1–32 |
| `random_retries` | 4 | 1–128 |
| `max_idle_visits` | 256 | 1–100,000 |
| `trace_limit` | 0 | 0–10,000 generated recipes |
| `prng` | `exsplus` | Only `exsplus` in engine v1 |
| `seed` | Generated once | Tuple of three integers, each 0–2^64−1 |
| `dictionary` | `[]` | List of nonempty binary tokens |

The top-level staged `max_iterations` permits 0–1,000,000 mutation target
executions. At most 4,096 initial seeds are accepted; each must fit the input
limit. Oversized seeds fail validation, never truncate. Calibration executions
are separately counted, so the total target-execution bound is seed count plus
`max_iterations`. Invalid limits, stage names, duplicate stage names, unknown
mutation options or unsupported algorithms fail before target execution.

A havoc attempt may apply up to `havoc_depth` constituent operations. The attempt
limit bounds candidate/stack attempts, not individual stack operations; therefore
per-visit work is still explicitly bounded by their product. Operation planners
check available sizes before constructing literal blocks. Primitive operations
check final concatenation sizes before allocating candidate binaries. Dictionary
parsing and configuration work occur before the mutation loop.

## EFZ hex dictionaries

Inline tokens are binary literals, for example `dictionary => [<<"TOKEN">>, <<0,255>>]`.
Alternatively set `dictionary_file => "examples/staged/tokens.hex"` inside
`mutation`. Both options can be supplied: their normalized tokens are combined.
The path is read once during configuration; it is replaced by the normalized
bytes and their identity in the report, and later file edits have no effect.

The **EFZ hex dictionary format** is one even-length hexadecimal token per line:

```text
# TOKEN and the artificial crash token
544f4b454e
424f4f4d21

00ff
```

Upper/lowercase hex is accepted. Leading/trailing whitespace and CRLF are
trimmed; blank lines and trimmed lines starting with `#` are ignored. Inline
comments, odd-length hex and nonhex bytes reject with a line number. This is
not AFL dictionary syntax and does not evaluate source code or create atoms.

Empty tokens are rejected inline (blank file lines are simply ignored).
Duplicates are removed and tokens sorted by binary term order. Normalization
checks token count and total bytes before deduplication for each source; the
combined normalized lists are checked again before final deduplication. Token
bytes must fit both token and block limits. SHA-256 of the normalized token-list
encoding gives the dictionary identity, independent of original order/path.
The file reader also imposes a physical byte bound of
`2*max_dictionary_bytes + 128*max_tokens + 4096`, including comments/whitespace.
No token is silently truncated. An empty normalized dictionary is valid;
dictionary stages then finish or report `dictionary_unavailable` in havoc.

## Scheduling and lazy enumeration

The default ordered stages are:

```erlang
[bitflip,byteflip,arithmetic,boundary,
 dictionary_insert,dictionary_overwrite,havoc,splice]
```

Any nonempty, duplicate-free subset in an explicitly supplied order is allowed.
There is no automatic power schedule or learning. The scheduler snapshots corpus
IDs at the beginning of each round and visits them in insertion order. New
entries join the next round, so continual growth cannot starve older entries.
For each selected content identity, its stage lane advances round-robin, with
**at most one executed candidate per visit**. A long deterministic sweep therefore
does not block other entries or enabled random stages.

Within a deterministic visit, skip/no-change advances the cursor and tries again
up to `attempts_per_visit`; a produced candidate ends the visit. Finished stages
stay finished. Only an integer cursor per stage is stored; the candidate space
is never materialized as a list. Width/field/value tables are small bounded lists.

The stable enumeration order is:

| Stage | Order |
|---|---|
| `bitflip` | Width 1, 2, 4 bits; then every fitting bit offset ascending |
| `byteflip` | Width 1, 2, 4 bytes; then every fitting byte offset ascending |
| `arithmetic` | Fields `(8,big)`, `(16,little)`, `(16,big)`, `(32,little)`, `(32,big)`; fitting byte offset; deltas `+1,-1,+2,-2,...,+max_delta,-max_delta` |
| `boundary` | Same fields and offsets; the nine boundary patterns below |
| `dictionary_insert` | Insertion boundary ascending, then normalized token order |
| `dictionary_overwrite` | Normalized token order, then each fitting offset ascending |

Progress means either producing a candidate or advancing a deterministic operation
cursor, including a no-op or size-limited operation. Both reset the idle counter
and the record of lanes visited without progress. Visiting an unavailable/finished
lane or exhausting random retries increments idle. Such a visit returns `skip`;
the worker schedules another visit without consuming target-execution budget.

While any deterministic cursor has remaining operations in the current corpus,
the idle guard cannot stop the planner. Once all finite work is consumed, there
are two distinct stop conditions:

| Condition | Planner `done` reason | Campaign `status` |
|---|---|---|
| All deterministic cursors exhausted, no random stages enabled | `mutation_exhausted` | `{mutation_exhausted, mutation_exhausted}` |
| Random stages enabled; idle budget reached **and** every content has visited every enabled lane since the last progress | `idle_budget_exhausted` | `{mutation_stopped, idle_budget_exhausted}` |
| No corpus entries (low-level API) | `empty_corpus` | `{mutation_exhausted, empty_corpus}` |

The second condition is a progress guard, not a proof that no theoretical random
candidate exists. `max_idle_visits` is a minimum number of consecutive visits
without progress before that guard may stop; it is not a hard cap on visits that
advance finite cursors or are needed to complete a lane sweep. Even a budget of
one allows a later productive lane to run. For example, with 256 one-byte seeds,
`[dictionary_overwrite,bitflip]` and token `<<"AB">>`, the 256 unavailable overwrite
visits are followed by bitflip candidates rather than premature exhaustion.

For a fixed corpus, finite cursors terminate after a finite number of bounded
visits; a zero-count deterministic space stops immediately. If random stages then
remain without progress, the idle threshold and one full lane sweep bound the
remaining visits. Sweep bookkeeping stores one count per content/configuration
identity, using the existing cyclic lane order; it never enumerates mutations.
Appending corpus entries resets idle/sweep accounting because new primary inputs
or donors change the search space. Existing cursors, RNG state and the pending
round are preserved; resuming with the same corpus preserves idle accounting too.
The planner expects the append-only entries supplied by `efz_corpus`.

The worker still stops with `completed` at `max_iterations` target executions.
Empty binary candidates are ordinary candidates, not exhaustion sentinels.

## Exact operation semantics (operation version 1)

All byte offsets are zero-based. For an input of size `N`, insertion boundaries
are `0..N`; a fitting range is `0 <= Offset`, `Length >= 0`,
`Offset + Length <= N`. Offset `N` appends; deleting `[0,N)` yields `<<>>`.
Primitive calls take normalized limits and return `{ok, Candidate}` only when
bytes change, otherwise `{skip, Reason}` or `{error, Reason}`.

| Concrete operation | Meaning and restrictions |
|---|---|
| `{flip_bits, Offset, Width}` | Bit 0 is the most significant bit of byte 0. XOR exactly 1, 2 or 4 consecutive bits; range must fit `8*N`. Cross-byte flips are supported. |
| `{invert_bytes, Offset, Length}` | XOR each byte with 255; length is exactly 1, 2 or 4 and range must fit. |
| `{add, Offset, Width, Endian, Delta}` | Read a complete 8/16/32-bit unsigned field; `little` or `big`; write `(Old + Delta) band ((1 bsl Width)-1)`. `abs(Delta) <= max_delta`. Delta zero is a no-op. |
| `{set_integer, Offset, Width, Endian, Value}` | Write an exact unsigned bit pattern `0..2^Width-1` into a fitting 8/16/32-bit field. The planner uses the versioned boundary table, while the primitive accepts any fitting pattern. |
| `{overwrite, Offset, Bytes}` | Replace exactly `byte_size(Bytes)` fitting bytes, with no resizing. Literal length obeys block limit. |
| `{insert, Offset, Bytes}` | Insert full literal bytes at a valid boundary. No truncation. Empty source is supported. |
| `{delete, Offset, Length}` | Delete a nonempty fitting range. The planner chooses at most a block-limit range; the primitive permits any fitting nonempty deletion. |
| `{duplicate, Offset, Length, At}` | Copy a nonempty fitting source range, then insert at a boundary in the **original** input. Overlap is allowed; length obeys block limit. |
| `{dictionary_insert, Offset, Token}` | Insert the full nonempty token, with token/block/result-size limits. |
| `{dictionary_overwrite, Offset, Token}` | Replace a fitting token-sized range without resizing; same limits. |
| `{splice, CutA, CutB, DonorBytes, DonorSHA256}` | `Primary[0:CutA] ++ Donor[CutB:DonorSize]`. Both cuts are boundaries. Verify donor hash and input bound before concatenation. Enforce final size. |

For boundary width `W`, let `H = 2^(W-1)` and `U = 2^W-1`. Version 1 order is:
`[0,1,2,H-2,H-1,H,H+1,U-1,U]`. For eight bits this is
`[0,1,2,126,127,128,129,254,255]`. These are bit patterns, including values around
signed interpretation boundaries; no accidental signed overflow is used.

Nonfitting fields/ranges skip with `insufficient_length`; no partial field is
read. Oversized resulting inputs/literals skip with `size_limit`. Identical output
or an empty ordinary literal skips with `no_change`; empty dictionary tokens are
unavailable at primitive level and invalid at dictionary configuration level.
Malformed operations, invalid donor hashes, oversized source inputs and deltas
outside the configured bound are errors. Some nonfitting offsets yield a skip
rather than a shape error; recipe regeneration rejects **either** result.
All operators requiring bytes skip on empty inputs; literal/dictionary insertion
and suitable splicing can produce candidates from empty inputs.

Donors come from the existing corpus snapshot, excluding content equal to the
primary seed. Distinct donor contents are deduplicated and sorted by binary term
order before a uniform choice. Duplicate queue entries do not bias donor choice.
A one-content corpus reports `donor_unavailable`. The operation carries donor
bytes and content hash, and provenance carries primary bytes/hash and corpus ID;
replay never looks up a donor queue index. A donor equal to the current intermediate
binary also skips; cuts producing unchanged output skip. No corpus entry is modified.

## Havoc and reproducibility

Havoc chooses a uniform depth in `1..havoc_depth`, then uniformly chooses one of
11 operation families: bit flip, byte inversion, arithmetic, integer boundary,
overwrite, insert, delete, duplicate, dictionary insertion, dictionary overwrite,
splice. This simple fixed weighting is not claimed to be optimal. Each operation's
parameters are chosen against the preceding intermediate result. Missing dictionary
or donor data and other inapplicable choices consume a stack slot, rather than
retrying an operator without bound.

Each attempted stack consumes a depth draw (standalone splice has fixed depth 1).
Havoc consumes a family draw per slot. Parameter draws are consumed in code order;
prerequisite failures return immediately without drawing unavailable parameters.
All consumed RNG state is retained on skips. At most
`min(attempts_per_visit, random_retries)` random candidate attempts occur per visit.
A final binary equal to the primary input is a no-op even if intermediate
operations changed bytes. It may retry within that same bound. Only successfully
changed constituent operations appear in a realized recipe; skipped operations
need not be replayed because they did not alter intermediate bytes.

All new choices use `rand:seed_s(exsplus, Seed)` and `rand:uniform_s/2`; no implicit
`rand:uniform()` is used in the staged engine. The private state belongs to the
planner in the worker. Target randomness, legacy corpus-selection randomness,
logging and statistics do not draw from it. Without `mutation.seed`, 24 random
bytes generate the three seed integers **once** during initialization; the actual
seed and algorithm are reported in `Report.mutation` and recipes.

Under the tested OTP 27.0 environment, choice reproduction requires engine version,
normalized configuration, algorithm/seed, initial corpus bytes/order and dictionary,
and deterministic outcomes/retention. `Report.mutation_initial_corpus` records the
ordered content hashes; the corpus report retains initial bytes. Configuration
identity is SHA-256 of sorted normalized setting pairs, including engine version,
seed and dictionary identity. `trace_limit` is excluded because it is observational.
Changing configuration/dictionary requires a new campaign. Internal handler-bearing
rand state is not written to recipes. No cross-OTP PRNG compatibility promise is made.

Reproducing choices, regenerating a specific binary, and reproducing a target
outcome are separate claims. Recipes reconstruct bytes without RNG or the corpus;
time-sensitive targets may still behave differently on execution replay.

## Provenance and accounting

Retained entries expose full recipes at `Entry.metadata.mutation`; unique crash
records use `Crash.metadata.mutation`, and crash storage writes `.recipe` beside
`.input` and the existing `.term` result file. Decisions retain a short mutation
summary (stage, primary/config/candidate hashes), avoiding full recipes for every
failed decision. Equivalent rejected candidates are not retained. Optional
`trace_limit` keeps only the first bounded number of generated recipes, including
those later rejected, and does not consume RNG state.

Existing `Report.stats` retains calibration, mutation execution, discovery,
rejection, crash/timeout, unique fingerprint and infrastructure counters.
`Report.mutation_stats` adds:

* `visits`: scheduling visits, including completed/inapplicable lanes.
* `mutation_attempts`: deterministic operation attempts or random stack attempts.
* `operation_attempts`: constituent attempts, including unavailable choices.
* `skipped_operations` and `skip_reasons`: operation skips; reasons also count
  final no-op stacks, so those totals need not equal each other.
* `skipped_candidates`: visits ending without a candidate.
* `generated_candidates`: candidates actually handed to execution in normal runs.

The live `efz:stats/0` API remains the existing target/campaign counters; detailed
mutation counters and bounded trace are in the final report. A stack is one
candidate/retention decision, not proof that each operation independently caused
a discovery. Crash fingerprint groups are not a count of proven independent bugs.
Crashes/timeouts retain execution observations but never merge crash-only coverage
into successful-corpus novelty. The one-worker, one-target-process and fixed-build
coverage/isolation restrictions in [coverage.md](coverage.md) still apply.
