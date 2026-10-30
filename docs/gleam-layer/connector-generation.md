# Generating a connector from an Erlang spec

**English** · [Русский](../i18n/ru/gleam-layer/connector-generation.md) · [Español](../i18n/es/gleam-layer/connector-generation.md) · [简体中文](../i18n/zh-CN/gleam-layer/connector-generation.md) · [All languages](../i18n/README.md)

The existing generic adapter can connect an API without a new Gleam model or
library-specific adapter. The scaffold now reads a trusted local BEAM's
`-spec` and local `-type` declarations to generate its argument schema. The
`inspect`, `spec` and compatibility `from-beam` commands share `efz_spec_schema`:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
mkdir -p _build/my_library
ERL_FLAGS='+S 2:2' erlc +debug_info -o _build/my_library path/to/my_library.erl
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript inspect \
  _build/my_library/my_library.beam
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript spec \
  _build/my_connector efz_my_target \
  _build/my_library/my_library.beam function_name 2
```

`spec OUTDIR HARNESS_MODULE BEAM FUNCTION ARITY` requires one function spec and
a matching export. Nonrecursive local aliases and unambiguous `when T :: Type`
bounds are expanded; overloads are rejected. `inspect BEAM` prints a versioned
Erlang map listing exported entrypoints, supported schemas and rejection reasons.
It reads standard Erlang debug metadata without loading the library, invoking a
custom debug backend or running an `on_load` callback. Use trusted BEAMs only:
this is a local development helper, not an untrusted artifact upload service.

The output contains a small `run/1` harness, `campaign.term`, an encoded seed,
compile/run instructions, `options.term` and `spec-report.term`. The report
records the input BEAM's SHA-256, source spec, entrypoint, inferred schema,
common bounds and diagnostics with argument paths and source locations.
`from-beam` accepts the same arguments and uses the same generator, additionally
writing the original `inference.term` schema for compatibility. Both commands
produce the same argument schemas and seed bytes. Error messages now use the
shared diagnostic codes, such as `missing_abstract_code` and `ambiguous_union`.
Regenerating a connector can change its normalized argument schema (including
the string representation), so rebuild its harness and config together. Existing
durable corpora remain subject to the normal build-identity checks; review a
schema change before explicitly choosing recalibration.
Existing output files are never replaced. Add the library's ebin directory with
`--code-path` when running the generated campaign, as well as the generated
harness directory. The generic adapter requires the optional Gleam build for
semantic callbacks; the generated raw harness uses only the model-free codec.

Supported argument types are bounded integers and integer ranges, finite floats,
booleans, binaries, strings, typed proper lists, fixed tuples, singleton atoms,
finite unions of atoms, empty maps and homogeneous `#{K => V}` maps. Local type
aliases may have parameters; unions can include aliases for finite atom sets.
Strings use lists of bounded `char()` integers, preserving Erlang's declared
character domain. Byte-aligned fixed-size and nonempty binaries are supported.
Container lengths default to at most 32 and integers/floats default
to the codec's bounded range of ±1,000,000. Explicit integer ranges retain their
bounds within the codec's signed 64-bit envelope. The whole argument tree must
also fit the codec's depth, node and byte limits. Large or deeply nested valid
specs can therefore be rejected rather than silently weakened. The initial seed
is chosen from the first 32 deterministic adapter indices, since an individual
index can be skipped by the generator.

A type spec does **not** identify a binary's format, relationships between
arguments, valid state transitions or the meaning of a returned value. Review
the generated schema before treating inputs as valid under the library's
contract. In particular, the generated bounded domain is only a test envelope;
it is not a complete enumeration of the type and does not establish semantic
preconditions. A `binary()` may be JSON, UTF-8, a digest or arbitrary bytes;
generation prints a `binary_semantics_unknown` warning instead of guessing.

Overloaded specs, unresolved or ambiguous variable constraints, recursive types,
remote/opaque types, heterogeneous unions, broad `term()`/`any()`, unbounded
atoms, required/multiple map fields, resources, non-byte-aligned/strided binary
sizes and unsupported integer expressions stop generation with an explicit
error. Literal bounds and unary `+`/`-` are supported. Use an explicit options
file instead of guessing:

```sh
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript generic \
  _build/my_connector efz_my_target reviewed-options.term
```

No correctness oracle or exception whitelist is inferred. The generated campaign
keeps its oracle disabled. Add a reviewed behavioral predicate and document
expected rejections before classifying library failures. Stateful APIs still
need explicit setup/reset/cleanup and command contracts.

The same generated harness works with `gleam_layer => false`,
`feedback => observation_only`, or `feedback => guided`; the mode is a campaign
setting. This removes the need for separate harness implementations for the
three modes. It does not remove callback runtime costs, which need measurement.

## Example with the bundled Cowlib dependency

After `rebar3 compile`, this generates a working connector without editing a
schema or harness (use a new output directory):

```sh
escript scripts/semantic_scaffold.escript from-beam \
  _build/auto-cow-qs efz_auto_cow_qs \
  _build/default/lib/cowlib/ebin/cow_qs.beam urlencode 1
```

Follow its generated README to compile the harness and optional Gleam layer.
Add `--code-path _build/default/lib/cowlib/ebin` to the campaign command. The
API's `binary()` argument becomes a binary schema bounded to 32 bytes. To switch
modes, change only `gleam_layer`/`feedback` in `campaign.term`, not the generated
source. The harness module name must differ from the library module name.

Earlier validation on OTP 27.3.4.1: the unchanged generated Cowlib harness completed
100 mutation executions in each of off, observation-only and guided modes, with
no target crashes or infrastructure failures. This is a connector integration
check, not evidence of a real defect or a performance/discovery comparison.
Regression tests also compile generated source, execute it, check seed decoding,
local aliases and provenance, and verify rejection of unsupported types, missing
debug info, existing output and conflicting module names. Extraction is checked
against an `on_load` fixture to ensure the API module is not loaded.

## Integration validation, 2026-10-22

The integration combines `automatic-connectors` at `d5383b0` and `gleam-layer`
at `eb67234` on `main` at `387fd09`. Checked on OTP 27.0 with a fresh official
Gleam 1.10.0 build (release archive SHA-256 verified) and XML-RPC pinned to
`fb46463b2acadf164ec534d9e2033e194341c507`:

- Ordinary compilation and all 341 default EUnit tests passed.
- Fresh optional compilation and all 408 Gleam-profile EUnit tests passed,
  including actual XML-RPC decoder integration.
- Common Test: 3 passed; xref and Dialyzer passed; Python TUI tests: 2 passed.
- `spec` and `from-beam` produced identical schemas, seed bytes and shared
  reports; `from-beam` retained its `inference.term` compatibility fields.
- The generated Cowlib `urlencode/1` harness passed pinned raw replay and 100
  mutation executions plus one seed calibration in each of off,
  observation-only and guided modes. Both enabled modes observed 101 outcomes
  and had successful structured mutations; all three had zero crashes and
  infrastructure failures. Structural coverage was disabled for this smoke.
- A pseudo-terminal continuous TUI demo stopped with `s` after 409 mutations,
  saved `report.term`, kept the final execution count unchanged and exited the
  viewer with status 0. Infrastructure failures remained zero. This demo uses
  the bundled parser with intentional example exceptions.
