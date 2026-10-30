# Actual source map

- efz_config:prepare/1 validates configuration, efz_cov_native_public:preflight/1
  or efz_instrument:preflight/1 verifies selected target artifacts.
- efz_fuzzer:init/1 starts the existing corpus, statistics and worker supervisor.
- efz_worker:handle_info/2 calibrates seeds before mutation; staged_iteration/1
  calls efz_mutation_plan:next/2 with efz_corpus:mutation_entries/0.
- efz_mutation_plan:visit/2 visits insertion-order parents and existing lanes;
  attempts/6 dispatches an optional structured branch before decode, otherwise
  ordinary_attempts/6 retains deterministic/havoc/splice operations.
- efz_worker:execute_checked/4 calls efz_executor:run/4. efz_guardian owns timeout,
  managed descendants, cleanup and coverage completion. Coverage is already
  materialized/sealed before execute_result/6 evaluates novelty.
- efz_worker:semantic_callbacks/4 is after the target snapshot. Pure observer
  uses normalized result; pure model-agreement oracle has a finite check count
  and makes **zero** target calls. No queue, worker or extra execution interval.
- efz_feedback:evaluate/3 remains structural novelty authority.
- efz_corpus:semantic_admission/6 extends retention for guided mode, committing
  persistence before updating corpus-owned feature state. efz_corpus:select/0
  and the staged plan use these same entries. No independent semantic corpus.
- efz_worker:record_failure/4 -> efz_crash:save/4 preserves the original bytes.
  Target failures precede semantic callbacks; oracle failures are separate
  fingerprints in the same finding store, independent of novelty.
- efz_recipe:regenerate/1 regenerates versioned structured_replace data without
  Gleam; efz_replay and efz_recipe:execute/5 use the existing pinned executor.
  efz_semantic_replay checks the property separately and counts every minimizer
  execution. efz_semantic:cover/1 conservatively preserves recorded features.
