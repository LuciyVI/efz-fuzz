%% Functional payload-to-library fixture. See docs/xmlrpc-harness-suite.md.
-module(efz_xmlrpc_response_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_xmlrpc_flow:run(response, Input).
seeds() -> efz_xmlrpc_flow:seeds(response).
sample(Index) -> efz_xmlrpc_flow:sample(response, Index).
modules() -> efz_xmlrpc_flow:modules(response).
surface() -> response.
