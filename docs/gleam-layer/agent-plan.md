# Ownership and gate order

Contract v1, requirements 2.0-native (2026-10-07).
Single lead owns all changes in this session. No subagents were launched: the
user supplied COMMON_CONTEXT, without explicitly invoking the package's separate
orchestration prompt. Do not describe this implementation as delegated work or
an independent subagent review. Baseline was archived before implementation.

P0 -> baseline and target/coverage source audit.
P1 -> freeze contracts.md and actual source map.
P2 -> dependency-free pinned Gleam package, checked adapter, optional build.
P3 -> typed raw seeds, bounded provider in existing staged plan, recipe schema 3
with operation v2; legacy recipe schemas 1/2 remain supported.
P4 -> pure bounded observer/oracle and serialized corpus semantic admission.
P5 -> raw/property replay, finite minimizer, regression, A/B/B2 and short
same-engine series; performance superiority is a separate unanswered question.

No user requirements, original seed corpora or global toolchains are edited.
No commits, branches, push, PR or publication are performed.

## P1 contract audit (2026-10-08)

The lead owns `architecture.md`, `contracts.md`, `p1-validation.md`, shared
`agent-plan.md`/`decision-log.md`, the narrow model capacity/build packaging/startup diagnostic fixes,
and `efz_gleam_contract_tests.erl`. No workers are active; no independent reviewer
is claimed. Contract remains v1. Refer to p1-validation.md and the separate
20261008-p1-contract artifact run for commands, exits, review scope, and handoff.
The full orchestration prompt and final P5 gate remain unfinished.

## P2 integration audit (2026-10-08)

The lead owns the package/build/configuration, checked adapter, P2 BEAM tests,
diagnostic driver, and documentation. No concurrent workers or independent
reviewer were used. Package representation and contract v1 remain unchanged.
Production code changes in this pass validate all core exports at startup and
bound tagged layer-error diagnostics; existing P3/P4 policy files are unchanged. P2 functional gates pass;
see p2-integration.md and 20261008-p2-native/gates.json. P3/P4 phase acceptance
and final P5 remain separate work, not completion of every package prompt.

## P3 provider ownership (2026-10-08)

The lead owns the Gleam package/catalogue, staged planner and recipe extensions,
seed/probe drivers, focused provider tests, and contract/report documentation.
No workers or independent reviewer are claimed. Shared build/configuration,
target harness, corpus, admission, executor and coverage backends are unchanged
in this pass. P3 acceptance is tracked in p3-provider.md and its own artifact run;
P4 semantic guidance and final P5 remain separate gates.

## P4 feedback ownership (2026-10-08)

The lead owns the exact metadata boundary, cold representative query, feedback
fixtures/tests, finite feedback probe, benchmark mode additions and documentation.
No subagents or independent reviewer are claimed. Existing loop, snapshot,
observer/oracle, admission/persistence and finding/replay paths were audited and
exercised; no scheduler, worker, build/package/version or target changes are added
in this pass. P4 acceptance and limitations are recorded in p4-feedback.md and
20261008-p4-feedback/gates.json. P5 final regression, discovery experiments and
same-engine performance conclusions remain open.
