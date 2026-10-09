# Repository Guidelines

## Project Structure & Module Organization

`src/` contains the Erlang application, campaign loop, mutation planner, coverage collectors, corpus storage, and replay APIs. `test/` holds EUnit modules, Common Test suites, and target fixtures. `examples/` contains runnable parser and Cowboy harnesses. `scripts/` provides preparation, fuzzing, replay, and benchmark drivers. Architecture and operational notes live in `docs/`; generated builds belong in `_build/`.

`c_src/` builds the existing Linux VM launcher into `priv/`. The optional Gleam package lives in `gleam/efz_semantic/`; its integration contracts are documented in `docs/gleam-layer/`.

## Build, Test, and Development Commands

Use Erlang/OTP 27 or newer and Rebar3; the verified baseline is OTP 27.0. Run commands from the repository root. Set `ERL_FLAGS='+S 2:2'` for reproducible local runs.

- `rebar3 compile`: compile the application and Linux launcher.
- `rebar3 eunit`: run unit and integration tests.
- `rebar3 ct`: run Common Test coverage checks.
- `rebar3 xref` and `rebar3 dialyzer`: check calls and inferred types.
- `rebar3 shell`: start an interactive development session.
- `escript scripts/fuzz.escript --help`: inspect campaign CLI options.
- `GLEAM_BIN=/path/to/gleam-1.10.0 rebar3 as gleam compile`: build the optional layer; default builds require no Gleam.

## Coding Style & Naming Conventions

Use lowercase snake_case and the `efz_` module prefix. Match surrounding Erlang formatting; use four spaces for expanded clauses and avoid tabs in new code. Keep exports explicit and validate external terms before use. Compilation treats warnings as errors; no repository-wide formatter is configured.

## Testing Guidelines

Name EUnit files `efz_*_tests.erl` and Common Test suites `*_SUITE.erl`. Run focused checks with `rebar3 eunit --module=efz_recipe_tests`, then relevant regressions. Test timeout, cleanup, coverage, persistence, and deterministic replay contracts when affected. No percentage coverage threshold is configured. Test optional Gleam builds separately from ordinary builds and runtime-off behavior.

## Commit & Pull Request Guidelines

History uses concise imperative subjects, often with `feat:`, `docs:`, or `chore:` prefixes. Describe the concrete change. PRs should explain behavior, relevant compatibility changes, and validation commands with results; link related issues when available.

Preserve existing worktree changes, seed corpora, and findings. Version artifact schema changes, keep defaults conservative, and record benchmark inputs, seeds, build identities, and limitations. Do not commit generated BEAM files or secrets.
