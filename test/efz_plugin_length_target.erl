%% Independent benign wire format. No EFZ dispatch code knows this module.
-module(efz_plugin_length_target).
-export([run/1,semantic_contract/0]).
semantic_contract() -> #{kind=>length_prefix_fixture,outcome=>payload_size}.
run(<<Size:16,Payload:Size/binary>>) -> {payload,byte_size(Payload)};
run(_) -> {rejected,malformed_length_prefix}.
