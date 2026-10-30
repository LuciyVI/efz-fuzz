# Automatic coverage integrity

**English** · [Русский](i18n/ru/coverage-integrity.md) · [Español](i18n/es/coverage-integrity.md) · [简体中文](i18n/zh-CN/coverage-integrity.md) · [All languages](i18n/README.md)

The contract applies to the executor with a [controlled descendant lifecycle](execution-isolation.md).
An empty probe list alone does not prove that observation worked. EFZ checks the
loaded code, attachment context, hook errors and preservation of already published
probes independently of a successful harness return value.

## Pinned identities

`efz_config:prepare/1` constructs `execution_identities`:

```erlang
#{harness => #{module => my_harness, beam_md5 => <<...>>,
               build_id => undefined, attributes_sha256 => <<...>>,
               compile => [...]},
  modules => #{my_parser => #{module => my_parser, beam_md5 => <<...>>,
                             build_id => <<...>>, attributes_sha256 => <<...>>,
                             compile => [...]}}}.
```

The harness is pinned separately, even when it is not instrumented and is not
included in `artifacts`. `build_id => undefined` is expected for an ordinary
harness. Identity comes from the **loaded code** through
`erlang:get_module_info/1`, not from a file found on the code path. `beam_md5` is
the OTP checksum of executable code, not the SHA-256 of the whole BEAM file;
attributes and compile metadata are checked separately.
[OTP describes the difference between the code checksum and compilation attributes](https://www.erlang.org/doc/apps/stdlib/beam_lib#md5/1).

Preflight checks the manifest sidecar against the embedded manifest, then checks
the artifact BEAM code checksum and manifest against the loaded module. Copying
an old manifest into a different implementation no longer lets it pass validation.
`efz_cov_manifest:prepare/2` stores the loaded identities of selected modules in
a protected validation plan.

The worker passes campaign pins to both validation modes: `prepared` and
`per_execution`. Pins are included in execution results, retained metadata and
the final report. The `builds` field denotes the **expected selected builds**;
when an identity check fails, it cannot be interpreted as confirmation that the
previous code executed.

Standalone `efz_executor:run/4` without `execution_identities` pins the harness
for one call; the plan preserves selected-module identities across calls.
Campaigns use the pins created by `efz_config:prepare/1`. Replay compares explicitly
supplied target/artifacts with the saved build IDs and harness identity from
`artifact.replay`, then creates execution pins. Low-level
`efz_recipe:execute/5` requires `expected_harness`; a mutation recipe alone does
not prove the old harness version. The attributes hash uses deterministic ETF
to match across VMs. Details: [replay](replay.md).

## Replacement checks

The guardian compares pins before starting the target and after its termination.
During execution, a separate OTP trace session observes requests to load/delete
selected modules through `code_server`, including batch `code:finish_loading/1`
with code prepared before execution. An attempt to load a selected module makes
the result untrustworthy even if the loader later restores the original BEAM.
This is a conservative rule: reloading identical bytes or an unsuccessful attempt
to replace a selected module is also rejected. Loading ordinary new dependencies
through the code server is allowed if they are not included in the pins.

ERTS `delete_module/1` and `finish_after_on_load/2` for selected modules, and
`finish_loading/1` outside the code server, are also tracked. A direct ERTS commit
conservatively produces `unsupported_direct_code_loading`: opaque prepared-code
handles do not permit reliable filtering of selected modules. This covers
replacement through ERTS followed by restoration of the original build.

Before the final result, the guardian waits for DOWN and trace barriers for all
owned processes, then a global delivery barrier for loader traces, checks the
snapshot and identities, and removes execution resources. An invalid or destroyed
prepared plan also produces an infrastructure failure, including when the
snapshot is empty.

## Context and observation states

`efz_coverage_observers` is a named **protected ETS** table owned by the guardian.
Before the start gate opens, `PID → expected context` is recorded in it; execution
pins are stored there too. The table does not store global coverage and is not
a global “current input”: a hook looks up only the record for its own PID. The
guardian lifecycle already limits the VM to one local execution.

The hook checks the process dictionary against this record. Therefore, `erase()`
or a malformed value does not turn an active hook inactive. The error is sent
to the guardian before the exception; the target cannot hide it with its own
`catch`. Tracing `put/erase` preserves evidence of context changes even if the
target restores the key or is killed before the exit check. Errors are sticky:
a later valid hit does not clear them. Controlled descendants are checked in
the same way as the root.

Each new probe is first inserted synchronously into observation ETS and then
reported to the guardian. At the end, every such message must match a preserved
ETS row. Erasing published observations without rewriting them produces
`coverage_observations_lost`. Duplicates do not create a stream of identical
messages.

| `coverage_observation.classification` | `state` | Meaning |
|---|---|---|
| `observed_coverage` | `observed` | Intact observation containing probes |
| `valid_empty_coverage` | `attached` | Root attachment confirmed, no errors, no probes |
| `broken_coverage_observation` | `failed`, `detached` or `invalid` | Hook, context, identity or validation error, or lost observations |
| `unstarted_coverage_observation` | `unattached` | Target did not attach in time, for example a timeout before the gate opened; this is not a successful empty execution |

The map contains `attached_processes`, `probe_count`, and `reason` when an error
occurs. A successful outcome without confirmed root attachment is forbidden.
A violation produces `outcome = {infrastructure, Reason}` and
`coverage_status = {error, Reason}`; `target_outcome` preserves the target's
separate result if it was obtained. The worker increments
`infrastructure_failures`, stores the exact input/result in `failure_context`,
and stops the campaign. Partially recorded probes can be diagnosed, but do not
participate in successful feedback.

## Real zero-hit and disconnected campaigns

Calling an instrumented function may end in `function_clause` before entering
any clause body. An ordinary harness can catch the exception and return `zero`.
This is real `valid_empty_coverage`. A harness that skips the target for a
particular input can also produce a valid empty result. One such execution alone
cannot prove that the harness is connected incorrectly.

The campaign counts observed modules **across all intact execution observations**,
including target crashes, separately from successful global coverage. The report
contains:

```erlang
#{coverage_diagnostics => #{policy => diagnostic,
    status => no_probes_observed, % or observed / manual
    observed_modules => [],
    unused_artifacts => [#{module => my_parser, build_id => <<...>>}],
    empty_executions => 1, unstarted_executions => 0, broken_observations => 0}}.
```

- `coverage_policy => diagnostic` is the default: the absence of probes is
  explicit in the report, and the CLI prints a diagnostic. The campaign may
  finish with a normal status.
- `coverage_policy => strict`: if the campaign ends without any trustworthy
  instrumented probe, it returns `{infrastructure_failure, #{kind =>
  coverage_not_observed, ...}}`, increments the infrastructure-failure count,
  and the CLI returns **1**. An existing primary infrastructure error is not
  replaced.
- Each unused artifact is listed even when other artifacts emitted probes.
  Strict requires at least one probe in total, not hits from every selected
  artifact.
- Zero-hit calibration triggers a warning but does not stop mutation: the first
  useful input may appear later. This also provides early diagnostics for an
  infinite campaign. The `coverage_*_executions` and
  `coverage_broken_observations` counters are available through `efz:stats/0`
  while the campaign is running.

```sh
escript scripts/fuzz.escript --target my_harness --code-path ./ebin \
  --seeds ./corpus --out ./findings --artifacts ./instrumented \
  --coverage-policy strict --max-iterations 1000
```

Campaign policy is independent of the `strict` parse transform, which checks
Erlang syntax support during instrumentation. Neither check changes novelty:

```text
New = Current - Global
successful valid execution: Global := Global union Current
broken observation: error, no merge and no retain
```

## Boundaries and validation

This is a correctness check in a trusted shared VM, not protection against
arbitrary hostile Erlang code. Replacing EFZ itself, disabling tracing, forging
protocol messages/ETS rows, and remote execution are outside the supported model.
The full asynchronous OTP scope requires a separate disposable VM backend.
The code-server trace adapter was verified on OTP 27.0; its regression tests
are required when supporting other OTP versions. Identity/trace checks add
execution cost; old benchmark numbers do not characterize this backend after
the integrity checks were strengthened.

[efz_integrity_tests](../test/efz_integrity_tests.erl) covers normal/zero-hit,
disconnected/unused artifacts, strict policy, unchanged novelty, dictionary
erase/malformed/restore, caught hook exceptions, lost ETS rows, child context,
kill, pre-execution/during-execution/transient reload, a separate harness pin,
prepared plans, copied manifests, public atomic loads and direct ERTS commits.
[efz_cli_tests](../test/efz_cli_tests.erl) checks diagnostic/strict/invalid policy
in separate fresh Erlang VMs.
