-module(efz_engine_profile_tests).
-behaviour(efz_target).
-include_lib("eunit/include/eunit.hrl").
-export([run/1]).

run(_Input) -> ok.

none_context_test() ->
    C=efz_coverage:open(none,presence),
    ok=efz_coverage:attach(C),
    ?assertEqual({ok,[]},efz_coverage:snapshot(C)),
    ?assertError({efz_infrastructure,hit_in_no_coverage_mode},
                 efz_coverage:hit({m,b,1},C)),
    ok=efz_cov:detach(),
    ok=efz_coverage:close(C).

none_config_test() ->
    Base=#{target=>?MODULE,seeds=>[<<"A">>],coverage_backend=>none},
    ?assertMatch({ok,#{manifests:=[]}},efz_config:prepare(Base)),
    ?assertEqual({error,none_requires_automatic_presence},
                 efz_config:prepare(Base#{coverage_feedback=>hit_count})),
    ?assertEqual({error,none_requires_automatic_presence},
                 efz_config:prepare(Base#{coverage=>manual})),
    ?assertEqual(false,maps:get(performance_profile,efz_config:defaults())),
    ?assertMatch({ok,#{benchmark_replay_inputs:=[<<"A">>,<<"A">>]}},
        efz_config:prepare(Base#{benchmark_replay_inputs=>[<<"A">>,<<"A">>]})),
    ?assertEqual({error,{invalid_campaign_option,benchmark_replay_inputs}},
        efz_config:prepare(Base#{benchmark_replay_inputs=>[]})).

fixed_replay_test_() ->
    {timeout,30,fun() ->
        Inputs=[<<"A">>,<<"B">>,<<"A">>,<<"C">>],
        Config=#{target=>?MODULE,seeds=>[<<"seed">>],coverage_backend=>none,
            benchmark_replay_inputs=>Inputs,performance_profile=>true,
            runtime_oracles=>#{enabled=>false}},
        {ok,_}=efz:start(Config),
        Report=try efz:await(20000) after efz:stop() end,
        ?assertEqual(completed,maps:get(status,Report)),
        ?assertEqual(4,maps:get(executions,maps:get(stats,Report))),
        ?assertEqual(0,maps:get(calibrations,maps:get(stats,Report))),
        ?assertEqual(1,length(maps:get(corpus,Report))),
        ?assertEqual(4,maps:get(calls,maps:get(iteration_total,
                                  maps:get(performance_profile,Report)))),
        ?assertEqual(4,maps:get(calls,maps:get(corpus_store,
                                  maps:get(performance_profile,Report)))),
        ?assertEqual(4,maps:get(count,maps:get('0_64',
                                  maps:get(input_size_buckets,Report))))
    end}.

profile_opt_in_test_() ->
    {timeout,30,fun() ->
        Plain=campaign(false),
        Profiled=campaign(true),
        ?assertEqual([],maps:get(coverage,Plain)),
        ?assertEqual([],maps:get(coverage,Profiled)),
        ?assertEqual(error,maps:find(performance_profile,Plain)),
        P=maps:get(performance_profile,Profiled),
        ?assert(maps:get(calls,maps:get(iteration_total,P)) >= 4),
        ?assert(maps:get(calls,maps:get(guardian_total_us,P)) >= 4),
        ?assertEqual([maps:get(input_id,D) || D <- maps:get(decisions,Plain)],
                     [maps:get(input_id,D) || D <- maps:get(decisions,Profiled)]),
        ?assertEqual([maps:get(retention_reason,D) || D <- maps:get(decisions,Plain)],
                     [maps:get(retention_reason,D) || D <- maps:get(decisions,Profiled)]),
        ?assertEqual(0,maps:get(infrastructure_failures,maps:get(stats,Profiled))),
        ?assertEqual(0,maps:get(infrastructure_failures,maps:get(stats,Plain)))
    end}.

campaign(Profile) ->
    Config=#{target=>?MODULE,seeds=>[<<"A">>],coverage_backend=>none,
        random_seed=>{2,3,5},selection_seed=>{7,11,13},
        max_iterations=>3,timeout=>1000,performance_profile=>Profile,
        runtime_oracles=>#{enabled=>false}},
    {ok,_}=efz:start(Config),
    try efz:await(20000) after efz:stop() end.
