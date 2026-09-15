# ADR 0002: source clause/outcome probes with execution-owned ETS

Status: accepted before transform implementation, 2026-09-08.

Baseline: OTP 27.0 / ERTS 15.0, x86_64-pc-linux-gnu; Rebar3 3.25.0.
The existing seven EUnit tests, compilation, and Dialyzer pass. Common Test
has no suites (zero tests). No repository formatter/linter or AGENTS.md exists.
Phase 1 is largely uncommitted; retain and adapt that implementation.

## Alternatives

* Abstract-form parse transformation: the installed compiler exposes clause
  bodies and nested case/if/receive/try/fun forms before lowering. Prepending
  calls inside bodies preserves guards, patterns, evaluation order, and tail
  position. Explicit expression traversal and diagnostics limit syntax risk.
  A hook can use the executing process's context and an external ETS owner.
* OTP cover and native coverage: OTP 27 has native coverage APIs (verified in
  the installed code module); cover uses native support when available. These
  facilities provide line/function coverage and cover analysis, but their
  module-oriented collection/reset API does not supply EFZ execution references
  or isolate unrelated processes. An adapter would require additional isolation
  and attribution design. We have not benchmarked cover and make no speed claim.
* Core Erlang or BEAM rewriting: lowering obscures some source outcomes and
  introduces compiler-version coupling and mapping work. Undocumented opcode
  editing adds verification risk without solving execution attribution.

Choose one abstract-form backend. Compile only allowlisted source modules,
independently of an application or campaign. Embed a manifest attribute in the
BEAM and write a sidecar in the explicit compilation facade. Use SHA-256 build
namespaces and deterministic structural probe paths. Do not edit source text.

Runtime: one public unnamed ETS set per execution, owned by the executor's
monitoring coordinator, outside the target. The coordinator also monitors the
caller and kills/drains the target on cancellation. Only after target DOWN may
it snapshot/delete storage. Runtime hooks use a namespaced process-dictionary
context; the dictionary is not the coverage store. Backend errors are sticky
infrastructure failures, including when target exception handlers catch them.

Campaign: one worker; calibrate seeds, merge only successful execution coverage,
retain exact set novelty, and store target crashes separately. Pin build IDs at
preflight and reject incompatible observations. Retain the manual hit API in a
separate identity namespace only for explicit compatibility mode.

Measure ordinary, instrumented inactive, and instrumented active paths with a
warmed repeated benchmark. ETS adds per-hit work; choose lifecycle correctness
before optimization. Record actual measurements in docs/coverage.md.

References: [OTP 27 cover](https://www.erlang.org/docs/27/apps/tools/cover.html)
and [OTP 27 code](https://www.erlang.org/docs/27/apps/kernel/code.html).
The online OTP 27 docs describe a later 27.x patch; installed exports and source
were also inspected. Native support was added in OTP 27.
