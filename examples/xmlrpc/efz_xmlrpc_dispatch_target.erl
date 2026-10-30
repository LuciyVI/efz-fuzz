%% Functional payload-to-library fixture. See docs/xmlrpc-harness-suite.md.
-module(efz_xmlrpc_dispatch_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_xmlrpc_flow:run(dispatch, Input).
seeds() -> efz_xmlrpc_flow:seeds(dispatch).
sample(Index) -> efz_xmlrpc_flow:sample(dispatch, Index).
modules() -> efz_xmlrpc_flow:modules(dispatch).
surface() -> dispatch.
