%% Identical payload entrypoints and corpus settings for all feedback modes.
-module(efz_xmlrpc_suite).
-export([surfaces/0, target/1, modules/1, seeds/1, setup/1, teardown/1,
    counters/1, config/4]).

surfaces() -> [call, response, fault, roundtrip, dispatch, encoder_validation].
target(call) -> efz_xmlrpc_call_target;
target(response) -> efz_xmlrpc_response_target;
target(fault) -> efz_xmlrpc_fault_target;
target(roundtrip) -> efz_xmlrpc_roundtrip_target;
target(dispatch) -> efz_xmlrpc_dispatch_target;
target(encoder_validation) -> efz_xmlrpc_encoder_validation_target.
modules(Surface) -> efz_xmlrpc_flow:modules(Surface).
seeds(Surface) -> efz_xmlrpc_flow:seeds(Surface).
setup(Surface) -> efz_xmlrpc_flow:setup(Surface).
teardown(Surface) -> efz_xmlrpc_flow:teardown(Surface).
counters(Surface) -> efz_xmlrpc_flow:counters(Surface).

config(Surface, Mode, Budget, Seed) when is_integer(Seed), Seed >= 0 ->
    true = lists:member(Surface, surfaces()),
    true = lists:member(Mode, [off, observation_only, guided]),
    true = Budget =:= infinity orelse (is_integer(Budget) andalso Budget > 0),
    Rng = {Seed + 1, Seed + 3, Seed + 7},
    Layer = case Mode of
        off -> false;
        _ -> #{adapter => efz_xmlrpc_flow_adapter,
            adapter_options => #{surface => Surface},
            structured_fraction => case Mode of observation_only -> 0; guided -> 30 end,
            feedback => Mode, oracle => disabled,
            limits => #{bytes => 512, depth => 8, nodes => 128,
                collection => 32, operations => 1}}
    end,
    #{target => target(Surface), artifacts => [], seeds => seeds(Surface),
      timeout => 1000, max_iterations => Budget, max_input_bytes => 512,
      coverage_backend => none, mutation_mode => staged,
      mutation => #{seed => Rng, stages => [bitflip, byteflip, havoc, splice]},
      random_seed => Rng, selection_seed => Rng, monitoring => true,
      runtime_oracles => #{enabled => false}, gleam_layer => Layer}.
