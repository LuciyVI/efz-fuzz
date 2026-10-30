-module(efz_semantic_limit_tests).
-include_lib("eunit/include/eunit.hrl").

config(Options) ->
    #{target=>efz_plugin_length_target,seeds=>[<<4:16,"abcd">>],
      coverage_backend=>none,max_iterations=>0,max_input_bytes=>4096,
      gleam_layer=>#{adapter=>efz_plugin_oracle_adapter,
        adapter_options=>Options,structured_fraction=>0,
        oracle=>inline,limits=>#{bytes=>2}}}.

oracle_boundary_test() ->
    {ok,C}=efz_config:prepare(config(#{})),P=maps:get(gleam_layer,C),
    ?assertEqual({pass,{fixture_property,1}},efz_gleam_adapter:oracle(<<0:16>>,{ok,anything},P)),
    ?assertEqual({inconclusive,limit},efz_gleam_adapter:oracle(<<4:16,"abcd">>,{ok,anything},P)).

invalid_oracle_skip_test() ->
    {ok,C}=efz_config:prepare(config(#{skip=>true})),
    ?assertEqual({error,{semantic_layer_error,error,invalid_callback_result}},
        efz_gleam_adapter:oracle(<<0:16>>,{ok,anything},maps:get(gleam_layer,C))).

campaign_limit_test() ->
    try
        {ok,_}=efz:start(config(#{})),R=efz:await(5000),
        ?assertEqual(completed,maps:get(status,R)),
        ?assertEqual(1,maps:get(calibrations,maps:get(stats,R))),
        ?assertEqual(0,maps:get(infrastructure_failures,maps:get(stats,R))),
        ?assertEqual(1,maps:get(oracle_inconclusive,maps:get(gleam_stats,R))),
        ?assertEqual(0,maps:get(oracle_extra_executions,R))
    after efz:stop() end.

replay_limit_test() ->
    Raw= <<4:16,"abcd">>,Target=efz_plugin_length_target,
    {ok,C}=efz_config:prepare(config(#{})),P=maps:get(gleam_layer,C),
    {ok,H}=efz_replay:harness_identity(Target),
    Expected=#{schema_version=>2,property=>{<<"fixture_property">>,1},
        adapter_identity=>efz_gleam_adapter:identity(P),
        input_hash=>crypto:hash(sha256,Raw),max_input_bytes=>4096,
        harness=>H,target_builds=>[]},
    Options=#{coverage_backend=>none,max_input_bytes=>4096,
        gleam_layer=>efz_gleam_adapter:configuration(P)},
    ?assertMatch({ok,#{status:=inconclusive,reason:=limit,target_executions:=1}},
        efz_semantic_replay:run(Raw,Target,[],Expected,Options)).
