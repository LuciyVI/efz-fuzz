# Generating a connector from an Erlang spec

The existing generic adapter can connect an API without a new Gleam model or
library-specific adapter. The scaffold now reads a trusted local BEAM's
`-spec` and local `-type` declarations to generate its argument schema:

```sh
ERL_FLAGS='+S 2:2' rebar3 compile
mkdir -p _build/my_library
ERL_FLAGS='+S 2:2' erlc +debug_info -o _build/my_library path/to/my_library.erl
ERL_FLAGS='+S 2:2' escript scripts/semantic_scaffold.escript from-beam \
  _build/my_connector efz_my_target \
  _build/my_library/my_library.beam function_name 2
```

`from-beam OUTDIR HARNESS_MODULE BEAM FUNCTION ARITY` requires a single,
unconstrained function spec and a matching export. It reads metadata without
loading the library or running its `on_load` callback. Use trusted BEAMs only:
this is a local development helper, not an untrusted artifact upload service.

The output contains a small `run/1` harness, `campaign.term`, an encoded seed,
compile/run instructions and `inference.term`. The evidence records the input
BEAM's SHA-256, entrypoint, inferred schema, common bounds and limitations.
Existing output files are never replaced. Add the library's ebin directory with
`--code-path` when running the generated campaign, as well as the generated
harness directory. The generic adapter requires the optional Gleam build for
semantic callbacks; the generated raw harness uses only the model-free codec.

Supported argument types are bounded integers and integer ranges, finite floats,
booleans, binaries, strings, typed proper lists, fixed tuples, singleton atoms,
finite unions of atoms and nonrecursive local type aliases (including type
parameters). Container lengths default to at most 32 and integers/floats default
to the codec's bounded range of ±1,000,000. Explicit integer ranges retain their
bounds within the codec's signed 64-bit envelope. The whole argument tree must
also fit the codec's depth, node and byte limits. Large or deeply nested valid
specs can therefore be rejected rather than silently weakened.

A type spec does **not** identify a binary's format, relationships between
arguments, valid state transitions or the meaning of a returned value. Review
the generated schema before treating inputs as valid under the library's
contract. In particular, the generated bounded domain is only a test envelope;
it is not a complete enumeration of the type and does not establish semantic
preconditions. A `binary()` may be JSON, UTF-8, a digest or arbitrary bytes.

Overloaded or constrained specs, recursive types, remote/opaque types,
heterogeneous unions, broad `term()`/`any()`, unbounded atoms, maps, resources and
unsupported expressions stop generation with an explicit error. Use an explicit
options file instead of guessing:

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

Validation on OTP 27.3.4.1: the unchanged generated Cowlib harness completed
100 mutation executions in each of off, observation-only and guided modes, with
no target crashes or infrastructure failures. This is a connector integration
check, not evidence of a real defect or a performance/discovery comparison.
Regression tests also compile generated source, execute it, check seed decoding,
local aliases and provenance, and verify rejection of unsupported types, missing
debug info, existing output and conflicting module names. Extraction is checked
against an `on_load` fixture to ensure the API module is not loaded.
