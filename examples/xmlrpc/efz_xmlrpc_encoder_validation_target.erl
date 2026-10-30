%% Functional payload-to-library fixture. See docs/xmlrpc-harness-suite.md.
-module(efz_xmlrpc_encoder_validation_target).
-export([run/1, seeds/0, sample/1, modules/0, surface/0]).
run(Input) -> efz_xmlrpc_flow:run(encoder_validation, Input).
seeds() -> efz_xmlrpc_flow:seeds(encoder_validation).
sample(Index) -> efz_xmlrpc_flow:sample(encoder_validation, Index).
modules() -> efz_xmlrpc_flow:modules(encoder_validation).
surface() -> encoder_validation.
