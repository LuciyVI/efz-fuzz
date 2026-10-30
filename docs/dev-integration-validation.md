# Dev integration validation (2026-10-30)

This is evidence for the integration branches in this change. Historical reports
under `docs/*validation*` retain the SHA and environment of their original runs.
No historical benchmark was repeated or re-labelled as a measurement of this
merged build.

## Inputs and merge order

| Stage | Input refs | Merge commits | Result |
| --- | --- | --- | --- |
| Synchronize `dev` | `ae18e8e12ae80cb9c37ec62715f75d3d6a4f572b`, `db1add0bc47bc1011d55a4cb528b741a0b870f97` | `b3fadb66b33658308a3ea03b34cd7167309c5abb` | Published to `dev`; no conflict |
| English documentation and harnesses | `fd888053a1eb22a93cdf45805e40af756c52ced1`, `70df349daef9c662581642c6438ff30ecb373fae`, `199f564017ae389f25963b0cbc170105fde02511` | `618b33737b165aeb7f6c3a70cfa9dc0fc2040c40`, `f42eaa8f150792e7540cae5430a5d11fc9e3d716`, `4f66aee3b7116cb5c3c12c60b12de019349fa618` | Published to `dev`; `connecting-erlang-libraries.md` conflict translated and merged manually |
| Runtime candidate | `a42c2c504401562efb35442a01c8bbe16da0ab2e`, `0f64704c581c3abf3b7a4e248f8bf483848c3a49`, `3fd3dd826d9f4c34197cff3114b663d377d677fa` | `044a588b3ac6df9a5248714f299aeb1bd1f0fcc2`, `746840610fc53bc390d38d2bcfa208487538cafb`, `4cdcafd216f349794069e0c5de1ce2bd91df682b` | Review branch pending remote recursive checkout; `README.md` conflict merged manually |
| Persistent target review | `6004a38a21a74ec7549c723c22d0ea1cdc012b07` | `d576809e82682db3f9868a2b38b2ba5a108b931a` | Not accepted into `dev`; native NIF hang and detached OS descendant cleanup are open gates |

The five earlier branches `feat/p0-runtime-diagnostics`, `feat/gleam-layer`,
`feat/automatic-connectors`, `feat/tui-dashboard`, and
`integrate/features-to-main` are ancestors of `main`; they were not cherry-picked.

## Environment and dependency identities

Linux x86_64; OTP 27.0 / ERTS 15.0; Rebar3 3.25.0; Python 3.12.3;
Gleam 1.10.0 from the cached pinned toolchain. Commands used
`ERL_FLAGS='+S 2:2'`. The candidate's `vendor/erlamsa` gitlink is
`191f3d9d30d8932319b98f4af25d3dff9ddc5824`; GitHub API returned that
commit from `LuciyVI/erlamsa`. The pinned XML-RPC checkout was
`fb46463b2acadf164ec534d9e2033e194341c507`, clean for the source files
used by `examples/xmlrpc/prepare_flows.escript`.

## New checks and exit codes

| Candidate / command | Exit | Result |
| --- | ---: | --- |
| `dev`+`main`: `rebar3 compile` | 0 | Standard build |
| `dev`+`main`: `rebar3 eunit` | 0 | 341 tests |
| Docs/harnesses: `rebar3 compile` | 0 | Standard build |
| Docs/harnesses: `rebar3 eunit` | 0 | 359 tests |
| Docs/harnesses: `rebar3 ct` | 0 | 3 tests |
| Docs/harnesses: `rebar3 eunit --module=efz_cowboy_flow_tests,efz_xmlrpc_flow_tests` | 0 | 18 tests |
| Docs/harnesses: `GLEAM_BIN=... rebar3 as gleam compile` | 0 | Gleam 1.10.0 shipment |
| Docs/harnesses: Cowboy/XML-RPC `--surface all --mode all --iterations 3 --seed 17 --profile gleam` | 0/0 | All surfaces exercised in off, observation_only and guided modes; pinned XML-RPC source prepared |
| Runtime candidate: `rebar3 compile` | 0 | Standard native build without prepared submodule |
| Runtime candidate: `rebar3 eunit` with local Unix sockets allowed | 0 | 416 tests |
| Runtime candidate: `rebar3 ct` | 0 | 3 tests |
| Runtime candidate: `rebar3 xref` | 0 | No reported undefined calls |
| Runtime candidate: `rebar3 dialyzer` | 0 | 105 project files analyzed |
| Runtime candidate: `rebar3 as erlamsa compile` | 0 | Pinned core built |
| Runtime candidate: `GLEAM_BIN=... rebar3 as gleam compile` | 0 | Gleam shipment built |
| Runtime candidate: `GLEAM_BIN=... rebar3 as erlamsa,gleam compile` | 0 | Both optional layers built |
| Runtime candidate: combined-profile EUnit for Erlamsa integration, Gleam provider and live feature stability | 0 | 22 tests |
| Runtime candidate: Python discovery under `test/` | 0 | 38 tests, 8 opt-in fixture skips |
| Runtime candidate: Python `pyefz_e2e_test.py` with real core and instrumented parser | 0 | 6 tests, no skips |
| Runtime candidate: `packages/pyefz/test` | 0 | 3 tests |

The first unprivileged runtime EUnit run failed eight provider request tests
because the sandbox denied local Unix-socket setup (`provider_setup_failed`).
The focused 12-test request suite and then the full 416-test suite passed when
local socket creation was allowed. No test result was converted from FAIL to
PASS without a new execution.

The Git HTTPS transport returned `Proxy CONNECT aborted` for both `git fetch`
and `git ls-remote`, including an escalated HTTP/1.1 attempt. GitHub API
verified current refs and the pinned fork commit, but a new recursive checkout
from remote was **not run**. A local-source checkout and cached pinned
dependencies were used for the above builds; this is not remote checkout proof.

## Remaining gates

The persistent target branch requires a controlled native NIF hang and detached
OS descendant cleanup/reaping test before merging. The new RU/ES/zh-CN pages in
this candidate are localized quick references with links to the English full
contracts; full translations of the new technical guides are still pending.
The remote recursive checkout gate also remains open while Git transport is
unavailable. `main` was not changed.

The later [persistent-target review validation](persistent-target-merge-validation.md)
records the added native NIF and detached-child tests, final local independent
checkout, and SDK mode matrix. This paragraph records the earlier `dev` stage;
the persistent-target review branch has not been merged into `dev`.
The same review validation now also records a successful fresh remote recursive
checkout and standard/Erlamsa builds of both published `dev` and the review
commit; the earlier `Proxy CONNECT aborted` result remains historical evidence.
