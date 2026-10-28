-module(efz_feature_stability_live_tests).
-include_lib("eunit/include/eunit.hrl").

live_between_repeats_test_() -> {timeout,30,fun live_between_repeats/0}.
bitmap_full_features_test_() -> {timeout,30,fun bitmap_full_features/0}.
stop_between_repeats_test_() -> {timeout,30,fun stop_between_repeats/0}.
live_numeric_change_test_() -> {timeout,30,fun live_numeric_change/0}.
live_between_repeats() ->
    Dir="_build/feature-stability-live-"++integer_to_list(erlang:unique_integer([positive])),
    unload_target(efz_monitor_wait_target),
    {ok,A}=efz_instrument:compile("test/efz_monitor_wait_target.erl",
        #{modules=>[efz_monitor_wait_target],source_root=>".",outdir=>Dir}),
    persistent_term:put({efz_monitor_wait_target,owner},self()),
    P=#{enabled=>true,resources=>#{enabled=>false},hangs=>#{enabled=>false},
        stability=>#{enabled=>true,seed_runs=>3,max_extra_executions=>2}},
    C=#{target=>efz_monitor_wait_target,artifacts=>[A],seeds=>[<<0>>],
        max_iterations=>0,monitoring=>true,timeout=>5000,runtime_oracles=>P,
        crash_dir=>Dir++"/crashes"},
    try
        {ok,_}=efz:start(C),
        First=entered(),First!monitor_continue,
        Second=entered(),
        One=await_valid(1,2000),
        ?assertMatch(#{status:=insufficient_samples,percent:=null,
            current:=#{valid_runs:=1,requested_runs:=3}},One),
        Second!monitor_continue,
        Third=entered(),
        Two=await_valid(2,2000),
        ?assertMatch(#{status:=measured,collection_status:=collecting,
            current:=#{valid_runs:=2,requested_runs:=3,provisional:=true}},Two),
        ?assert(maps:get(observed_feature_pairs,Two)>0),
        ?assertEqual(running,efz_fuzzer:status()),
        Coordinator=whereis(efz_fuzzer),
        Worker=maps:get(worker,sys:get_state(Coordinator)),
        Stale=(efz_fuzzer:monitor_snapshot())#{feature_stability=>One},
        Coordinator!{monitor_sample,Worker,Stale},
        _=sys:get_state(Coordinator),
        ?assertEqual(maps:get(revision,Two),
            maps:get(revision,maps:get(feature_stability,efz_fuzzer:monitor_snapshot()))),
        Third!monitor_continue,
        Report=efz:await(5000),
        Final=maps:get(feature_stability,Report),
        ?assertMatch(#{status:=measured,collection_status:=complete,
            current:=#{valid_runs:=3,provisional:=false}},Final),
        ?assertEqual(100.0,maps:get(percent,Final)),
        Summary=efz_control:report_summary(Report,Dir),
        ?assertEqual(100.0,maps:get(<<"percent">>,maps:get(<<"feature_stability">>,Summary))),
        ?assert(is_binary(efz_control_json:encode(Summary))),
        ?assertEqual(2,maps:get(verification_executions,maps:get(stats,Report))),
        ?assertEqual(Final,maps:get(feature_stability,efz_fuzzer:monitor_snapshot()))
    after efz:stop(),unload_target(efz_monitor_wait_target),
        persistent_term:erase({efz_monitor_wait_target,owner}) end.

entered() ->
    receive {target_entered,Pid}->Pid after 5000->error(target_not_entered) end.
await_valid(N,Remaining) when Remaining=<0->error({feature_progress_missing,N});
await_valid(N,Remaining)->
    F=maps:get(feature_stability,efz_fuzzer:monitor_snapshot()),
    Current=maps:get(current,F,null),
    case Current of
        #{valid_runs:=Valid} when Valid>=N->F;
        _->receive after 20->await_valid(N,Remaining-20) end
    end.

bitmap_full_features() ->
    Dir="_build/feature-stability-bitmap-"++integer_to_list(erlang:unique_integer([positive])),
    unload_target(efz_monitor_fixture),
    {ok,A}=efz_instrument:compile("test/efz_monitor_fixture.erl",
        #{modules=>[efz_monitor_fixture],source_root=>".",outdir=>Dir}),
    P=#{enabled=>true,resources=>#{enabled=>false},hangs=>#{enabled=>false},
        stability=>#{seed_runs=>3,max_extra_executions=>2}},
    C=#{target=>efz_monitor_fixture,artifacts=>[A],seeds=>[<<0>>],
        max_iterations=>0,coverage_backend=>bitmap,monitoring=>true,
        runtime_oracles=>P,crash_dir=>Dir++"/crashes"},
    try
        {ok,_}=efz:start(C#{runtime_oracles=>#{enabled=>false}}),
        Disabled=efz:await(5000),efz:stop(),
        ?assertEqual(0,maps:get(verification_executions,maps:get(stats,Disabled))),
        ?assertEqual(disabled,maps:get(status,maps:get(feature_stability,Disabled))),
        {ok,_}=efz:start(C),Report=efz:await(5000),
        FS=maps:get(feature_stability,Report),
        ?assertEqual(measured,maps:get(status,FS)),
        ?assertEqual(100.0,maps:get(percent,FS)),
        ?assert(maps:get(observed_feature_pairs,FS)>0),
        ?assertEqual(2,maps:get(verification_executions,maps:get(stats,Report))),
        efz:stop(),
        St=maps:get(stability,P),
        Limited=P#{stability=>St#{max_extra_executions=>1}},
        {ok,_}=efz:start(C#{runtime_oracles=>Limited}),
        BudgetReport=efz:await(5000),
        ?assertMatch(#{status:=measured,collection_status:=budget_exhausted,
            current:=#{valid_runs:=2,requested_runs:=3,provisional:=true}},
            maps:get(feature_stability,BudgetReport)),
        efz:stop(),
        Twenty=P#{stability=>St#{seed_runs=>20,max_extra_executions=>19}},
        {ok,_}=efz:start(C#{runtime_oracles=>Twenty}),
        TwentyReport=efz:await(5000),
        ?assertEqual(19,maps:get(verification_executions,maps:get(stats,TwentyReport))),
        ?assertMatch(#{status:=measured,current:=#{valid_runs:=20,requested_runs:=20}},
            maps:get(feature_stability,TwentyReport))
    after efz:stop(),unload_target(efz_monitor_fixture) end.

stop_between_repeats() ->
    Dir="_build/feature-stability-stop-"++integer_to_list(erlang:unique_integer([positive])),
    unload_target(efz_monitor_wait_target),
    {ok,A}=efz_instrument:compile("test/efz_monitor_wait_target.erl",
        #{modules=>[efz_monitor_wait_target],source_root=>".",outdir=>Dir}),
    persistent_term:put({efz_monitor_wait_target,owner},self()),
    C=#{target=>efz_monitor_wait_target,artifacts=>[A],seeds=>[<<0>>],
        max_iterations=>0,monitoring=>true,timeout=>5000,crash_dir=>Dir++"/crashes",
        runtime_oracles=>#{enabled=>true,resources=>#{enabled=>false},hangs=>#{enabled=>false},
            stability=>#{seed_runs=>3,max_extra_executions=>2}}},
    try
        {ok,_}=efz:start(C),First=entered(),First!monitor_continue,
        Second=entered(),BeforeStop=await_valid(1,2000),
        ok=efz:request_stop(),Second!monitor_continue,
        Report=efz:await(5000),
        FS=maps:get(feature_stability,Report),
        ?assertMatch(#{status:=measured,collection_status:=stopped,
            current:=#{valid_runs:=2,requested_runs:=3,provisional:=true}},FS),
        ?assert(maps:get(revision,FS)>maps:get(revision,BeforeStop)),
        ?assertEqual(1,maps:get(verification_executions,maps:get(stats,Report)))
    after efz:stop(),unload_target(efz_monitor_wait_target),
        persistent_term:erase({efz_monitor_wait_target,owner}) end.

unload_target(Module) ->
    code:purge(Module),code:delete(Module),code:purge(Module),ok.

live_numeric_change() ->
    Dir="_build/feature-stability-change-"++integer_to_list(erlang:unique_integer([positive])),
    unload_target(efz_feature_stability_target),
    {ok,A}=efz_instrument:compile("test/efz_feature_stability_target.erl",
        #{modules=>[efz_feature_stability_target],source_root=>".",outdir=>Dir}),
    persistent_term:put({efz_feature_stability_target,owner},self()),
    C=#{target=>efz_feature_stability_target,artifacts=>[A],seeds=>[<<0>>],
        max_iterations=>0,monitoring=>true,timeout=>5000,crash_dir=>Dir++"/crashes",
        runtime_oracles=>#{enabled=>true,resources=>#{enabled=>false},hangs=>#{enabled=>false},
            stability=>#{seed_runs=>4,max_extra_executions=>3}}},
    try
        {ok,_}=efz:start(C),First=entered(),First!{continue,a},
        Second=entered(),Second!{continue,a},
        Third=entered(),Two=await_valid(2,2000),
        ?assertEqual(100.0,maps:get(percent,Two)),
        Third!{continue,b},
        Fourth=entered(),Three=await_valid(3,2000),
        ?assert(maps:get(percent,Three)<100.0),
        ?assert(maps:get(variable_feature_pairs,Three)>0),
        ?assert(maps:get(revision,Three)>maps:get(revision,Two)),
        ?assertEqual(running,efz_fuzzer:status()),
        Fourth!{continue,b},
        Report=efz:await(5000),
        ?assert(maps:get(percent,maps:get(feature_stability,Report))<100.0)
    after efz:stop(),unload_target(efz_feature_stability_target),
        persistent_term:erase({efz_feature_stability_target,owner}) end.
