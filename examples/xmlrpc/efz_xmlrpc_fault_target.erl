%% Functional payload-to-library fixture. See docs/xmlrpc-harness-suite.md.
-module(efz_xmlrpc_fault_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_xmlrpc_flow:run(fault, Input).
seeds() -> efz_xmlrpc_flow:seeds(fault).
sample(Index) -> efz_xmlrpc_flow:sample(fault, Index).
modules() -> efz_xmlrpc_flow:modules(fault).
surface() -> fault.
