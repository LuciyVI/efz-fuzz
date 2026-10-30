%% Functional payload-to-library fixture. See docs/xmlrpc-harness-suite.md.
-module(efz_xmlrpc_roundtrip_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_xmlrpc_flow:run(roundtrip, Input).
seeds() -> efz_xmlrpc_flow:seeds(roundtrip).
sample(Index) -> efz_xmlrpc_flow:sample(roundtrip, Index).
modules() -> efz_xmlrpc_flow:modules(roundtrip).
surface() -> roundtrip.
