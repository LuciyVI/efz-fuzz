%% Functional payload-to-library fixture. See docs/xmlrpc-harness-suite.md.
-module(efz_xmlrpc_call_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_xmlrpc_flow:run(call, Input).
seeds() -> efz_xmlrpc_flow:seeds(call).
sample(Index) -> efz_xmlrpc_flow:sample(call, Index).
modules() -> efz_xmlrpc_flow:modules(call).
surface() -> call.
