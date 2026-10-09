# P3 structured provider — PASS

Requirements **2.0-native**; contract/model/codec/mutator/feature/property vector
**{1,1,1,1,1,1}**. Cold generator **2**, package **1.1.0**. New structured
recipe schema **3**, operation version **2**, EFZR envelope **1**; legacy recipe
schemas **1/2** remain readable. Date: 2026-10-08.

Evidence: `artifacts/gleam-layer/20261008-p3-provider/`. HEAD remains
`79d76221c6bc5df30b80e6b0de947f3860f4fa4b`. `head.txt`, `status-before.txt`,
`dirty-before.patch`, `dirty-index-before.patch`, `inputs.json` and `before-files/`
preserve the starting checkout. This pass extends the provider already present
at P2; it does not claim all earlier package phases were accepted then.
[P0](baseline.md), [execution path](execution-path.md), [P1 contract](contracts.md)
and [P2](p2-integration.md) were reviewed before edits.

## Actual execution and ownership

| Responsibility | Actual file:function |
| --- | --- |
| Existing loop/lifecycle | `src/efz_worker.erl:staged_iteration/1`, `src/efz_fuzzer.erl:handle_info/2` |
| Working corpus / parents | `src/efz_corpus.erl:mutation_entries/0`, `src/efz_mutation_plan.erl:next/2`, `visit/2` |
| Existing lane, budget, RNG and family dispatch | `src/efz_mutation_plan.erl:attempts/6`, `structured/3`, `ordinary_attempts/6`, `uniform/2` |
| Native boundary | `src/efz_gleam_adapter.erl:mutate/3`, `decode/2`, `encode/2` |
| Real compiled typed core | `gleam/efz_semantic/src/efz_qs_model.gleam`; BEAM `efz_qs_model:decode/2`, `mutate/3`, `encode/2`, `generate/2` |
| Unchanged real target | `examples/query_string/efz_qs_target.erl:run/1` → pinned `cow_qs:parse_qs/1` |
| Execution / target snapshot | `src/efz_executor.erl:run/4`, `src/efz_guardian.erl:finish/2`, `src/efz_cov_native_public.erl:collect/1` |
| Structural admission / persistence | `src/efz_feedback.erl:evaluate/3`, `src/efz_corpus.erl:add_checked/3`, `src/efz_corpus_store.erl:save/4` |
| Seed preparation / normal import | `scripts/gleam_seeds.escript:main/1`, `src/efz_cli.erl:read_seeds/2`, `src/efz_corpus.erl:init/1` |
| Bounded recipe / raw regeneration | `src/efz_recipe.erl:make/4`, `validate_structured/2`, `regenerate/1` |

EFZ first visits a corpus parent and existing stage, then selects the family.
Ordinary calls its existing mutation functions. Structured invokes direct BEAM
decode → mutate → encode; pure callbacks neither execute the target nor choose
parents. Unsupported/limit/unchanged uses `ordinary_attempts/6` once, without
recursing into structured selection. Layer error returns a separate diagnostic,
increments `errors` and stops the campaign through EFZ's infrastructure channel.
The controller remains available to report/stop. No target defect is inferred.

Off/fraction-zero skips branch RNG and decode. Positive fraction consumes one
`uniform_s(100)` draw, and selection adds `uniform_s(6)` for operation. Success
returns R2; fallback starts ordinary at R2; error records R2 without retry.
Structured-only provenance records exact exsplus words before/after these draws,
fraction, operation, versions and limits. Ordinary candidates/recipes keep their
prior shape. Raw binary is canonical persistent input; models stay transient.

Target, executor, corpus, energy, admission, coverage, findings and replay owners
were not replaced. No external engine, fuzzer callback, new NIF/C bridge,
transport, per-mutation VM, cache, asynchronous learner or new worker was added.
Existing unrelated native launcher/backends remain. Module-scoped OTP counters
retain EFZ guardian serialization; unmanaged parallel target calls remain outside
the isolation contract. P3 campaigns disable semantic feedback and oracle.

## Model, limits, operations and seeds

Concrete ADTs: `Query(List(Field),Canonical|BadEscape)` and
`Field(BitArray,BitArray)`. Supported subset: nonempty binary names, explicit
`=`, ordered/duplicate fields, `&` delimiters, percent escaping and plus-as-space.
Values may be empty/NUL/non-UTF8. Name-only fields, empty names, redundant
separators and malformed escapes are unsupported by the model; raw target access
remains available. This is a subset of the real parser's accepted language.

Limits: 4096 wire bytes, 32 fields, 128 bytes/component, fixed nesting 2 and one
operation/candidate. Capacity guards precede prepend/append/catalogue allocation.
Mutator uses a size preflight instead of allocating a discarded encoded value;
encoder independently checks output size. The archived P2 BEAM and current BEAM
give identical results for **264** model/operation/limit cases.

| Operation ID | Effect |
| --- | --- |
| 0 | Prepend field `x={0,255}` within field/component/byte limits |
| 1 | Set first value to zero bytes; empty query creates `a=` |
| 2 | Remove first field, including transition to empty query |
| 3 | Reverse fields, preserving pair identity and duplicate-name order semantics |
| 4 | Append byte 255 to first value, or create `a=%FF`; limit prevents overflow |
| 5 | Deliberate invalid percent escape suffix `&x=%`; encoder preserves it |

Codec tests cover `decode(encode(M)) == normalize(M)` for canonical supported
models, idempotent normalization, an explicit field/value grid, all six expected
wire fixtures and actual Cowlib results. Invalid `BadEscape` is excluded from
the valid-model round-trip law. No arbitrary raw byte-identical law is claimed.

The deterministic catalogue now has 12 distinct slots: empty query/value,
binary bytes, duplicates/reserved bytes, named field variant, invalid escape,
127/128-byte values, 31/32 fields, exact 4096-byte wire and maximum-length key.
Default output is **12 files / 5349 bytes**, with **11 accepted / 1 expected
rejection** by the unchanged parser. Preparation caps 64 files and 65536 total
bytes, refuses existing outputs and records catalogue indices, generator/runtime
versions, limits and per-file SHA-256 in manifest schema 2 outside the seed folder.
It checks cold generator version before creating the output directory.

`seed-import-r2/proof.json` verifies manifest hashes, ordinary CLI import and raw
identity in the working corpus. The compiler/package-free build performs 12
calibrations, then a separate ordinary campaign executes 50 mutations. Gleam
remains unloaded and layer counters absent. Twelve independent parser probes
are explicitly additional cold checks, outside campaign coverage intervals.
No original seed corpus is modified in place.

## Commands and executed checks

Pinned toolchain: OTP **27.0**, ERTS **15.0**, Rebar3 **3.25.0**, Gleam **1.10.0**;
`+S 2:2`. Normal dependency commits/locks remain unchanged. `runtime.json`
records real module path, exports and package 1.1.0; optional app is not loaded.
Each command has a sibling `.json` with arguments, cwd, selected tool settings,
exit and elapsed time, plus `.log`. The runner is `run_command.py` in the run.

| Gate | Command / evidence stem | Exit / result |
| --- | --- | --- |
| Real on-build | `GLEAM_BIN=/tmp/efz-gleam-toolchain/gleam rebar3 as gleam compile` / `on-compile-final` | 0 |
| Focused callback/contract/recipe/provider suite | `rebar3 as gleam eunit --module=efz_gleam_provider_tests,efz_gleam_layer_tests,efz_gleam_contract_tests,efz_gleam_beam_tests,efz_recipe_tests` / `focused-tests-r4` | 0 / 46 passed |
| Full regression | `rebar3 as gleam eunit` / `full-on-tests` | 0 / 302 passed, including term targets and old staged operations |
| Final fresh fixture names | `rebar3 as gleam eunit --module=efz_gleam_provider_tests` / `provider-tests-final` | 0 / 10 passed |
| Source-only off | `PATH=/home/fbogoslavskii/.asdf/installs/erlang/27.0/bin:/usr/bin:/bin GLEAM_BIN=/nonexistent/gleam rebar3 compile` in `/tmp/efz-p3-off-0c0joh3_` / `clean-off-compile` | 0 |
| Off compatibility | `rebar3 eunit --module=efz_gleam_provider_tests,efz_gleam_layer_tests,efz_gleam_contract_tests,efz_gleam_beam_tests,efz_recipe_tests,efz_mutation_tests,efz_phase2_tests,efz_smoke_tests` there / `clean-off-tests` | 0 / 57 passed |
| Coverage regression | `rebar3 as gleam ct` / `ct-regression` | 0 / 3 passed |
| Static calls | `rebar3 as gleam xref` / `on-xref` | 0 |
| Root ordinary build | `GLEAM_BIN=/nonexistent/gleam rebar3 compile` / `root-off-compile` | 0 |
| Seed preparation/import | `escript scripts/gleam_seeds.escript RUN/generated-seeds`; `escript scripts/gleam_seed_import_check.escript OFF_BUILD RUN/generated-seeds RUN/seed-import-r2 ROOT` | 0 / raw identities, 12 calibrations, 50 subsequent mutations |
| Real loop wiring | `real-loop/proof.term`, emitted by final provider tests | 200 mutations + 3 calibrations; actual Gleam calls on EFZ worker; target calls equal counted executions; no observe/check calls or semantic state |
| Off/zero sequence | `python3 RUN/run_campaigns.py` / `raw-{baseline,off,fraction0}-{17,43}` | All six exit 0; 100-candidate hash/stage/parent traces match P0 per seed |
| Replay without Gleam | `escript /tmp/efz-p3-off-0c0joh3_/scripts/replay.escript RUN/real-recipes/{current,old}.recipe RUN/replayed-{current,old}.input` | Both 0; schema 3/2 raw results match expected bytes |
| Recorded-state reproduction | `escript RUN/verify_recipe.escript BUILD RUN/real-recipes/current.recipe RUN/recipe-state-proof-result.json` | 0; native callback and EFZ plan from recorded R0 reproduce bytes, operation and R2; zero target executions |
| Separate components | `escript scripts/gleam_provider_probe.escript BUILD RUN/p2-model-original.beam RUN/provider-samples.json` | 0 / 264 equivalent cases, 40 batches, 36 ordinal samples |
| Disabled dispatch | `escript scripts/gleam_dispatch_bench.escript RUN/dispatch-samples.json` | 0 / 5 trials × 1M calls per dispatch |

`RUN` abbreviates the evidence directory; `BUILD` is `_build/gleam`, `OFF_BUILD`
is the private `_build/default`, and `ROOT` is this repository. The off copy
contains normal pinned dependency **sources**, with zero initial BEAM files, no
Gleam directory or compiler on PATH. `clean-off-final-isolation.json` confirms
its production sources match the final tree and no layer BEAM/app exists;
`off-runtime.json` additionally proves neither is discoverable on the VM path.
Rebar rewrites only the scratch lock for checkout overrides.

Executed fixtures include malformed boundary/results/version mismatch, limit and
unsupported rejection, success/fallback/error next-state, repeated deterministic
mutation, off/fraction-zero exact state, operation/byte counters, recipe tampering,
old schema 2, normal corpus persistence/restart and callback fault separation.
Controlled stubs prove error contracts; real loop/campaign/codec checks use the
compiled Gleam and unchanged Cowlib parser. No mock closes the integration gate.

Initial failures are retained: new tests compared configuration maps rather than
runtime state, misstated one fixture length, assumed an attempt at 1% over only
100 visits, used the wrong trace API arity, expected no rejection counter, compared
restart order, and kept tracing past the barrier. Corrected tests pass. The first
seed-import diagnostic reloaded an already loaded harness twice and returned
`not_purged` (exit 127); remove that unnecessary preload and purge its old version
between stopped campaigns in the driver. The rerun passes. Production CLI is
unchanged. Final fixture directories include time and unique ID to avoid reuse.

## Fraction diagnostics and cost

Each percentage uses two explicit seeds (17 and 43), the same engine/backend,
initial raw `a=1`, 2000 mutation executions per seed, one calibration, and a
separate 20-execution warm-up campaign. Trace is disabled. No semantic/oracle
callbacks or extra target executions occur. Existing corpus evolution is allowed.

| Fraction | Attempts | Successes | Unsupported | Unchanged | Bytes generated | Callback µs | Wall main exec/s, seeds 17 / 43 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1% | 41 | 11 | 29 | 1 | 335 | 607 | 229.9 / 231.5 |
| 5% | 224 | 80 | 130 | 14 | 4962 | 4357 | 173.5 / 183.0 |
| 10% | 391 | 168 | 194 | 29 | 7952 | 7345 | 199.3 / 179.7 |
| 20% | 794 | 324 | 415 | 55 | 15400 | 14568 | 177.5 / 198.1 |

Counts sum the two measured campaigns per row. All limits/errors are zero in
this series; explicit limit/error fixtures cover those paths separately. Per-op
0..5 counts are in each `fractions/SEED/fractionN/summary.json`; their sum equals
attempts. Selected percentage is a branch probability, not success percentage.
All 16000 measured mutation executions complete without layer/infrastructure
failures. Structural units are reported separately; no semantic coverage sum is
introduced. One 20% run ends with fewer structural lines; no guidance benefit is
inferred from these samples.

Separate five-trial median batch deltas, including validated boundary work:

| Input / operation | Decode µs | Core mutate µs | Encode µs | Complete provider µs |
| --- | ---: | ---: | ---: | ---: |
| 8 bytes / append 255 | 1.310 | 0.380 | 0.512 | 2.322 |
| 4096 bytes / empty first value | 363.530 | 52.238 | 165.260 | 488.940 |

Independent batches are not additive timing identities. Production reports retain
aggregate callback time; the diagnostic driver supplies finite per-stage and
ordinal samples without RNG sampling or target execution. Disabled dispatch
median delta is **+0.941 ns** for planner and **−0.657 ns** for worker relative to
their diagnostic controls. Negative delta is measurement/code-layout noise,
not an optimization result. Temporary export_all stays in the diagnostic VM.
No zero-overhead, speedup, optimal fraction or final P5 performance claim is made.

## Changed files, decisions and handoff

P3-only `p3-changes.patch` and `p3-changed-files.json` compare against the saved
P3 starting tree, including untracked source files. Production edits are the
typed catalogue/size preflight and package version, planner provenance/counters,
recipe schema 3, seed producer, and one fraction-zero benchmark mode. New files
are provider tests, component/import evidence drivers and this report. Contracts,
guide, ownership/decision documentation are updated. No shared build/config,
adapter, corpus, executor, target or dependency lock changes are made in P3.
`preserved-inputs.json` records checks of those files, AGENTS.md and user prompt
directory/zip; no original corpus is deleted, and no Git write/publication occurs.
Review is by the author, not an independent reviewer or delegated subagent.

P4: use the unchanged normalized-outcome/finite feature contract and existing
serialized corpus admission; independently close guided working-corpus selection,
failed persistence retry, historical seen/restart/schema policy and oracle/finding
isolation. P3 proves mutation wiring with feedback disabled, not full guidance.

P5: validate full replay/minimization predicates and representative preservation,
then perform longer same-engine controlled seed/budget/backend comparisons with
durable finalization and repeated trials. Preserve the off/zero traces and schemas
1/2 fixtures. Current RNG metadata reproduces a concrete mutation; corpus restart
is reuse/calibration rather than a campaign PRNG checkpoint. Direct bounded calls
have no arbitrary hang cancellation guarantee. No production cache is justified
by the present measurements.
