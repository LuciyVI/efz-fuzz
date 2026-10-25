# Documentation languages

English is the canonical language of the [project README](../../README.md) and
[documentation index](../README.md). Full Russian, Spanish and Simplified Chinese
editions are kept in language-specific directories, including architecture,
contracts, historical audits, benchmark reports and example READMEs.

Technical identifiers, commands, file names and raw program output retain their
source form. Recorded measurements retain their values; dates and numbers in
prose may use local formatting conventions. Code examples run from the repository
root unless a page says otherwise. Evidence files are shared by all
editions; historical temporary paths are preserved as provenance and may be
unavailable in a fresh checkout.

## Complete translation coverage

| Document | English | Русский | Español | 简体中文 |
| --- | --- | --- | --- | --- |
| EFZ (Erlang fuzzer) | [English](../../README.md) | [Русский](ru/README.md) | [Español](es/README.md) | [简体中文](zh-CN/README.md) |
| EFZ documentation | [English](../README.md) | [Русский](ru/index.md) | [Español](es/index.md) | [简体中文](zh-CN/index.md) |
| ADR 0002: source clause/outcome probes with execution-owned ETS | [English](../adr/0002-automatic-coverage.md) | [Русский](ru/adr/0002-automatic-coverage.md) | [Español](es/adr/0002-automatic-coverage.md) | [简体中文](zh-CN/adr/0002-automatic-coverage.md) |
| EFZ architecture | [English](../architecture.md) | [Русский](ru/architecture.md) | [Español](es/architecture.md) | [简体中文](zh-CN/architecture.md) |
| EFZ readiness audit for calibration and feature_stability | [English](../calibration-readiness.md) | [Русский](ru/calibration-readiness.md) | [Español](es/calibration-readiness.md) | [简体中文](zh-CN/calibration-readiness.md) |
| Universal fuzz launcher | [English](../cli.md) | [Русский](ru/cli.md) | [Español](es/cli.md) | [简体中文](zh-CN/cli.md) |
| Continuous fuzzing | [English](../continuous.md) | [Русский](ru/continuous.md) | [Español](es/continuous.md) | [简体中文](zh-CN/continuous.md) |
| Reusable durable corpus | [English](../corpus.md) | [Русский](ru/corpus.md) | [Español](es/corpus.md) | [简体中文](zh-CN/corpus.md) |
| Bitmap backend for EFZ coverage | [English](../coverage-bitmap-architecture.md) | [Русский](ru/coverage-bitmap-architecture.md) | [Español](es/coverage-bitmap-architecture.md) | [简体中文](zh-CN/coverage-bitmap-architecture.md) |
| Technical audit of the EFZ bitmap coverage backend | [English](../coverage-bitmap-audit.md) | [Русский](ru/coverage-bitmap-audit.md) | [Español](es/coverage-bitmap-audit.md) | [简体中文](zh-CN/coverage-bitmap-audit.md) |
| Bitmap coverage backend: implementation report | [English](../coverage-bitmap-implementation-report.md) | [Русский](ru/coverage-bitmap-implementation-report.md) | [Español](es/coverage-bitmap-implementation-report.md) | [简体中文](zh-CN/coverage-bitmap-implementation-report.md) |
| Bitmap coverage v2: implementation and measured result | [English](../coverage-bitmap-v2-results.md) | [Русский](ru/coverage-bitmap-v2-results.md) | [Español](es/coverage-bitmap-v2-results.md) | [简体中文](zh-CN/coverage-bitmap-v2-results.md) |
| Automatic coverage integrity | [English](../coverage-integrity.md) | [Русский](ru/coverage-integrity.md) | [Español](es/coverage-integrity.md) | [简体中文](zh-CN/coverage-integrity.md) |
| EFZ coverage tracking: audit and comparison with AFL++ | [English](../coverage-tracking-audit.md) | [Русский](ru/coverage-tracking-audit.md) | [Español](es/coverage-tracking-audit.md) | [简体中文](zh-CN/coverage-tracking-audit.md) |
| Automatic coverage contract | [English](../coverage.md) | [Русский](ru/coverage.md) | [Español](es/coverage.md) | [简体中文](zh-CN/coverage.md) |
| Long Cowboy benchmark: ETS, bitmap-v2 and OTP-public | [English](../cowboy-long-benchmark.md) | [Русский](ru/cowboy-long-benchmark.md) | [Español](es/cowboy-long-benchmark.md) | [简体中文](zh-CN/cowboy-long-benchmark.md) |
| Cowboy data-flow harnesses | [English](../cowboy-harness-suite.md) | [Русский](ru/cowboy-harness-suite.md) | [Español](es/cowboy-harness-suite.md) | [简体中文](zh-CN/cowboy-harness-suite.md) |
| EFZ UML diagrams | [English](../diagrams/README.md) | [Русский](ru/diagrams/README.md) | [Español](es/diagrams/README.md) | [简体中文](zh-CN/diagrams/README.md) |
| DWARF/native coverage results | [English](../dwarf-native-coverage-results.md) | [Русский](ru/dwarf-native-coverage-results.md) | [Español](es/dwarf-native-coverage-results.md) | [简体中文](zh-CN/dwarf-native-coverage-results.md) |
| DWARF/native coverage: feasibility checkpoint | [English](../dwarf-native-coverage.md) | [Русский](ru/dwarf-native-coverage.md) | [Español](es/dwarf-native-coverage.md) | [简体中文](zh-CN/dwarf-native-coverage.md) |
| EFZ: engine performance profile v2 (2026-10-04) | [English](../engine-performance-profile-v2.md) | [Русский](ru/engine-performance-profile-v2.md) | [Español](es/engine-performance-profile-v2.md) | [简体中文](zh-CN/engine-performance-profile-v2.md) |
| EFZ: cost profile of one iteration | [English](../engine-performance-profile.md) | [Русский](ru/engine-performance-profile.md) | [Español](es/engine-performance-profile.md) | [简体中文](zh-CN/engine-performance-profile.md) |
| Execution model: synchronous binary harness with controlled descendants | [English](../execution-isolation.md) | [Русский](ru/execution-isolation.md) | [Español](es/execution-isolation.md) | [简体中文](zh-CN/execution-isolation.md) |
| Semantic adapter API 1 | [English](../gleam-layer/adapter-contract.md) | [Русский](ru/gleam-layer/adapter-contract.md) | [Español](es/gleam-layer/adapter-contract.md) | [简体中文](zh-CN/gleam-layer/adapter-contract.md) |
| Ownership and gate order | [English](../gleam-layer/agent-plan.md) | [Русский](ru/gleam-layer/agent-plan.md) | [Español](es/gleam-layer/agent-plan.md) | [简体中文](zh-CN/gleam-layer/agent-plan.md) |
| Native Gleam architecture — contract v1 | [English](../gleam-layer/architecture.md) | [Русский](ru/gleam-layer/architecture.md) | [Español](es/gleam-layer/architecture.md) | [简体中文](zh-CN/gleam-layer/architecture.md) |
| P0 baseline | [English](../gleam-layer/baseline.md) | [Русский](ru/gleam-layer/baseline.md) | [Español](es/gleam-layer/baseline.md) | [简体中文](zh-CN/gleam-layer/baseline.md) |
| Connecting an Erlang library to Gleam Layer | [English](../gleam-layer/connecting-erlang-libraries.md) | [Русский](ru/gleam-layer/connecting-erlang-libraries.md) | [Español](es/gleam-layer/connecting-erlang-libraries.md) | [简体中文](zh-CN/gleam-layer/connecting-erlang-libraries.md) |
| Generating a connector from an Erlang spec | [English](../gleam-layer/connector-generation.md) | [Русский](ru/gleam-layer/connector-generation.md) | [Español](es/gleam-layer/connector-generation.md) | [简体中文](zh-CN/gleam-layer/connector-generation.md) |
| Native Erlang/Gleam contract v1 | [English](../gleam-layer/contracts.md) | [Русский](ru/gleam-layer/contracts.md) | [Español](es/gleam-layer/contracts.md) | [简体中文](zh-CN/gleam-layer/contracts.md) |
| Decisions | [English](../gleam-layer/decision-log.md) | [Русский](ru/gleam-layer/decision-log.md) | [Español](es/gleam-layer/decision-log.md) | [简体中文](zh-CN/gleam-layer/decision-log.md) |
| Actual source map | [English](../gleam-layer/execution-path.md) | [Русский](ru/gleam-layer/execution-path.md) | [Español](es/gleam-layer/execution-path.md) | [简体中文](zh-CN/gleam-layer/execution-path.md) |
| P1 contract validation and handoff | [English](../gleam-layer/p1-validation.md) | [Русский](ru/gleam-layer/p1-validation.md) | [Español](es/gleam-layer/p1-validation.md) | [简体中文](zh-CN/gleam-layer/p1-validation.md) |
| P2 optional native BEAM integration | [English](../gleam-layer/p2-integration.md) | [Русский](ru/gleam-layer/p2-integration.md) | [Español](es/gleam-layer/p2-integration.md) | [简体中文](zh-CN/gleam-layer/p2-integration.md) |
| P3 structured provider — PASS | [English](../gleam-layer/p3-provider.md) | [Русский](ru/gleam-layer/p3-provider.md) | [Español](es/gleam-layer/p3-provider.md) | [简体中文](zh-CN/gleam-layer/p3-provider.md) |
| P4 oracle and corpus feedback — PASS | [English](../gleam-layer/p4-feedback.md) | [Русский](ru/gleam-layer/p4-feedback.md) | [Español](es/gleam-layer/p4-feedback.md) | [简体中文](zh-CN/gleam-layer/p4-feedback.md) |
| P5: final replay, regression and same-engine acceptance | [English](../gleam-layer/p5-validation.md) | [Русский](ru/gleam-layer/p5-validation.md) | [Español](es/gleam-layer/p5-validation.md) | [简体中文](zh-CN/gleam-layer/p5-validation.md) |
| Gleam Layer: implementation and verifiable results | [English](../gleam-layer/universal-validation.md) | [Русский](ru/gleam-layer/universal-validation.md) | [Español](es/gleam-layer/universal-validation.md) | [简体中文](zh-CN/gleam-layer/universal-validation.md) |
| > This document describes the historical QS compatibility interface. The current | [English](../gleam-layer/user-guide.md) | [Русский](ru/gleam-layer/user-guide.md) | [Español](es/gleam-layer/user-guide.md) | [简体中文](zh-CN/gleam-layer/user-guide.md) |
| EFZ: experimental hit-count feedback | [English](../hit-count-experiment.md) | [Русский](ru/hit-count-experiment.md) | [Español](es/hit-count-experiment.md) | [简体中文](zh-CN/hit-count-experiment.md) |
| Input limits and storage failures | [English](../input-and-storage.md) | [Русский](ru/input-and-storage.md) | [Español](es/input-and-storage.md) | [简体中文](zh-CN/input-and-storage.md) |
| Native staged mutation (engine version 1) | [English](../mutations.md) | [Русский](ru/mutations.md) | [Español](es/mutations.md) | [简体中文](zh-CN/mutations.md) |
| Experimental OTP-public line coverage (2026-10-03) | [English](../otp-native-public-results.md) | [Русский](ru/otp-native-public-results.md) | [Español](es/otp-native-public-results.md) | [简体中文](zh-CN/otp-native-public-results.md) |
| P1-01 External supervisor | [English](../p1-01-external-supervisor.md) | [Русский](ru/p1-01-external-supervisor.md) | [Español](es/p1-01-external-supervisor.md) | [简体中文](zh-CN/p1-01-external-supervisor.md) |
| Phase 2 validation record | [English](../phase2-validation.md) | [Русский](ru/phase2-validation.md) | [Español](es/phase2-validation.md) | [简体中文](zh-CN/phase2-validation.md) |
| Phase 2.1 performance and closeout record | [English](../phase2.1-performance.md) | [Русский](ru/phase2.1-performance.md) | [Español](es/phase2.1-performance.md) | [简体中文](zh-CN/phase2.1-performance.md) |
| Phase 3 validation: staged mutation and exact replay | [English](../phase3-validation.md) | [Русский](ru/phase3-validation.md) | [Español](es/phase3-validation.md) | [简体中文](zh-CN/phase3-validation.md) |
| Bitmap coverage backend implementation plan | [English](../plans/coverage-bitmap-implementation-plan.md) | [Русский](ru/plans/coverage-bitmap-implementation-plan.md) | [Español](es/plans/coverage-bitmap-implementation-plan.md) | [简体中文](zh-CN/plans/coverage-bitmap-implementation-plan.md) |
| Preparing and running EFZ | [English](../quickstart.md) | [Русский](ru/quickstart.md) | [Español](es/quickstart.md) | [简体中文](zh-CN/quickstart.md) |
| Crash occurrences, signatures and verified replay | [English](../replay.md) | [Русский](ru/replay.md) | [Español](es/replay.md) | [简体中文](zh-CN/replay.md) |
| EFZ repository map: directories and files | [English](../repository-map.md) | [Русский](ru/repository-map.md) | [Español](es/repository-map.md) | [简体中文](zh-CN/repository-map.md) |
| P0 acceptance fixes — 2026-09-21 | [English](../runtime-diagnostics-acceptance-fixes.md) | [Русский](ru/runtime-diagnostics-acceptance-fixes.md) | [Español](es/runtime-diagnostics-acceptance-fixes.md) | [简体中文](zh-CN/runtime-diagnostics-acceptance-fixes.md) |
| P0 validation — 2026-09-16 | [English](../runtime-diagnostics-validation.md) | [Русский](ru/runtime-diagnostics-validation.md) | [Español](es/runtime-diagnostics-validation.md) | [简体中文](zh-CN/runtime-diagnostics-validation.md) |
| Automatic Runtime Diagnostics (P0) | [English](../runtime-diagnostics.md) | [Русский](ru/runtime-diagnostics.md) | [Español](es/runtime-diagnostics.md) | [简体中文](zh-CN/runtime-diagnostics.md) |
| EFZ Technical Audit — September 12, 2026 | [English](../technical-audit-2026-09-12.md) | [Русский](ru/technical-audit-2026-09-12.md) | [Español](es/technical-audit-2026-09-12.md) | [简体中文](zh-CN/technical-audit-2026-09-12.md) |
| EFZ terminal dashboard | [English](../tui.md) | [Русский](ru/tui.md) | [Español](es/tui.md) | [简体中文](zh-CN/tui.md) |
| Cowboy: a small target for EFZ | [English](../../examples/cowboy/README.md) | [Русский](ru/examples/cowboy/README.md) | [Español](es/examples/cowboy/README.md) | [简体中文](zh-CN/examples/cowboy/README.md) |
| Campaign configuration examples | [English](../../examples/semantic_configs/README.md) | [Русский](ru/examples/semantic_configs/README.md) | [Español](es/examples/semantic_configs/README.md) | [简体中文](zh-CN/examples/semantic_configs/README.md) |
| XML-RPC decoder plugin | [English](../../examples/xmlrpc/README.md) | [Русский](ru/examples/xmlrpc/README.md) | [Español](es/examples/xmlrpc/README.md) | [简体中文](zh-CN/examples/xmlrpc/README.md) |

## Updating translations

1. Update the English source first. Retain all sections, technical claims,
   recorded dates, results and limitations.
2. Update the corresponding pages in every language listed in
   [translations.json](translations.json). Preserve executable commands, code
   literals and raw output; translate explanatory text and comments.
3. Link to the corresponding localized page whenever it exists. Share source
   files and evidence with the canonical edition. Check section fragments after
   changing headings.
4. Keep page language selectors and the coverage table in sync. Add new sources
   to the manifest and create a full translation in each language.

The editions document the same EFZ interfaces and guarantees. Translations do not
introduce separate engines or language-specific behavior. Historical reports keep
their original scope; translating them does not rerun or extend their validation.
