# Decisions

1. Use installed Gleam 1.10.0 from /tmp/efz-gleam-toolchain/gleam after real
   build/BEAM verification; pin exact version. No automatic latest upgrade.
2. Use pinned Cowlib query-string parser, without rewriting it. Model contains
   binary keys/values, ordered duplicates and a deliberate malformed escape.
3. Keep existing native coverage and existing guardian isolation. Public OTP
   counters are module scoped; pure inline oracle makes no extra target calls.
4. Optional post_compile hook uses export erlang-shipment output's ebin, never
   assumes generated .erl. No stdlib package or external runtime is required.
5. Corpus-owned exact finite features are credited only after durable admission.
   Existing seed annotations are rebuilt by normal calibration on restart. No
   hidden campaign, scheduler, semantic ETS table, queue, cache or worker.
6. Record structured_replace as data-only operation v2. New structured recipe
   schema 3 adds validated RNG provenance; legacy schemas 1/2 still replay off.
7. Oracle failures use the existing immutable crash groups, independent of
   corpus admission. A checksummed .semantic sidecar needs manifest v2 (max five
   files); ordinary findings retain manifest v1. Corpus semantic discoveries use
   schema v3; old v1/v2 corpus records remain accepted. Schema mismatch fails.
8. Preserve last semantic representatives during conservative cover reduction.
   Existing corpus is append-only; no online pruning policy is added.
9. Correct the existing nested test source-dir conflict by relocating four
   unchanged harnesses to examples and updating source references. Keep all
   original generated test artifacts under _build/test-before-gleam-layout.
10. Full regression caught a missing zero-budget guard in the extracted ordinary
    attempts function; restore it and rerun planner tests. Repeated fixture
    directories now use unique timestamps to avoid stale-build collisions.

Sources checked: installed OTP 27 kernel code.erl and pinned cow_qs/cow_inline
sources. Online primary references: https://gleam.run/documentation/externals/,
https://www.erlang.org/doc/apps/kernel/code.html,
https://gleam.run/news/gleam-doesnt-compile-to-erlang-source-anymore/.
Current online docs/releases do not define the pinned compiler's artifacts;
Gleam 1.10.0 generated output and actual BEAM calls provide that evidence.

## P1 audit decisions (2026-10-08)

- Freeze actual contract v1 as `{Contract,Model,Codec,Mutator,FeatureSchema,Property}`,
  all version 1. Existing mutator/target behaviours plus staged dispatch suffice;
  add no plugin registry, C ABI, or dynamic adapter selection.
- Name corpus policy historical successfully committed seen, not active refcounts.
  Append-only entries retain representatives. `cover/1` proposes a subset and does
  not apply pruning; future deletion must rebuild consistent indexes atomically.
- Core receives operation ID/catalogue index; EFZ derives operations from explicit
  exsplus state. Document next-state on ordinary/success/fallback/error exactly.
- Reject deferred oracle at startup. The supported inline property is pure and
  has zero target reexecutions; a future expensive oracle needs a new bounded
  execution contract.
- Check prepend/append capacity before allocation, preserving existing outputs
  and limit verdicts. Keep version vector unchanged because semantics are unchanged.
- Gleam 1.10.0 generates an unused CLI module that references stdlib inspection.
  Ship only efz_qs_model and adjust optional .app modules accordingly; archive old
  generated CLI BEAM outside ebin. First xref failure and final passing rerun are
  preserved; no external package was introduced.
- Review is explicitly author self-review. Independent reviewer/subagents and
  completion of every package prompt are not claimed.

- Startup capability errors now name unsupported oracle policy/target, staged-mode
  requirement, unknown options, invalid limits/fraction/budget explicitly. Fixed
  bounded atoms replace opaque badmatch results; successful/off behavior is intact.

## P2 native integration decisions (2026-10-08)

- Retain pinned Gleam 1.10.0, OTP 27.0, Rebar3 3.25.0, and unchanged dependency
  locks. The existing opt-in Rebar profile consumes compiled BEAM and .app only.
  Two forced package builds in the same private workspace produce identical hashes.
- Validate all eight exported core callbacks at enabled startup, with a bounded
  missing-callback reason. No hot-path lookup, application start, or transport.
- Prove the real callback using fraction zero, disabled semantic feedback, and
  one pure inline oracle check. Trace orders target, native snapshot, adapter,
  compiled Gleam decode/check; no production structured/guidance policy is added.
- Build off from source without a Gleam directory/executable/artifacts. Private
  copies of pinned normal dependency sources avoid relying on dependency BEAM
  caches or network availability; Rebar's checkout override rewrites only the
  private lock, leaving the repository lock untouched.
- Keep fine-grained sampled counters/timings in a finite diagnostic driver,
  separate from production reports and batch performance measurement. It uses
  no RNG. Temporary export_all is restricted to the diagnostic VM.
- Hanging-callback fault injection uses a monitored test-only worker. The
  production layer remains bounded direct calls; arbitrary native cancellation
  and worker transport protocols are not claimed.
- Preserve initial failed logs: a test-stub variable warning; omitted scratch
  fixture sources; and a trace assertion on the profiled collector while the
  actual campaign used collect/1. Each was corrected and the affected gate rerun.
- Verify actual runtime roots as well as version strings: initial minimal-PATH
  off selected system OTP 27.3.4.13. Preserve it as extra compatibility evidence
  and repeat clean off on primary asdf OTP 27.0, still with no Gleam/compiler
  artifacts. Record the installed P0 coverage source's absolute path.

- Guard tagged semantic_layer_error reasons as well as generic exception tuples;
  only error/exit/throw classes with atomic reasons pass through. An 8192-byte
  tagged fault is reduced to invalid_boundary, preserving finite diagnostics.

## P3 provider decisions (2026-10-08)

- Keep EFZ's parent/lane selection, mutation budget, corpus and target execution.
  Decode only after structured selection; fallback calls ordinary_attempts
  directly once, with the post-selection RNG state. Errors stop with diagnostics.
- Keep the six operations/model/codec/mutator v1 semantics. Replace the mutator's
  discarded encoding with a size preflight; compare results against the archived
  P2 BEAM in a separate diagnostic VM. No cache, hint learner or worker is added.
- Expand only the cold catalogue to version 2 (package 1.1.0). Twelve distinct
  slots cover component/field/wire boundaries; preparation remains separate and
  all inputs enter the existing CLI/corpus as raw bytes.
- New structured recipe schema 3 retains exact proper-list exsplus state words,
  limits and fraction; ordinary recipes retain schema 1 and old structured schema
  2 remains readable. Operation v2 and EFZR envelope v1 are unchanged.
- Fine-grained component samples remain a bounded diagnostic driver; campaign
  counters add operation counts and generated bytes. Fractions 1/5/10/20 are
  exploratory same-engine samples, not an optimum or performance advantage.

## P4 feedback decisions (2026-10-08)

- Retain query_model_agreement v1: compare independently decoded supported query
  fields with the completed real Cowlib parser result. It is an expected-result
  property, not a differential check or a layer round-trip law. No target rerun
  or expensive/deferred online oracle is added.
- Keep exact namespace cow_qs/1 with 12 IDs and at most four per execution. Require
  canonical, precisely shaped persisted metadata. A corpus-owned read-only cold
  query derives one representative ID per feature, without a persistent index.
- Commit new raw bytes/metadata before semantic seen, using the existing serialized
  corpus owner. Concurrent duplicate features receive one credit; retry after a
  failed write retains novelty. Existing-input annotations rebuild on restart.
- Append-only online corpus needs no deletion/refcount transaction. Exercise the
  conservative cover subset by copying it to a fresh store and recalibrating;
  preserve original artifacts and reject schema mismatch. Between-campaign manual
  removal cannot leave a stale global seen index; online disk edits remain unsupported.
- Verify sealed native bits as well as nonempty decoded units. The initial trace
  assertion mistakenly compared empty diagnostic coverage lists; preserve those
  earlier proofs and replace acceptance evidence with the corrected native proof.
- Keep normal finding continuation and existing fingerprint/representative policy.
  Artificial defect wiring is not a real Cowlib finding or discovery experiment.
  Replay/minimization calls are counted separately; production oracle adds zero.
