-module(efz_monitor_tests).
-include_lib("eunit/include/eunit.hrl").

monitor_test_()->{timeout,30,fun integration/0}.
integration()->
    D="_build/monitor-tests-"++integer_to_list(erlang:system_time(microsecond)),
    code:purge(efz_monitor_fixture),code:delete(efz_monitor_fixture),code:purge(efz_monitor_fixture),
    {ok,A}=efz_instrument:compile("test/efz_monitor_fixture.erl",
        #{modules=>[efz_monitor_fixture],source_root=>".",outdir=>D}),
    C=#{target=>efz_monitor_fixture,seeds=>[<<0>>],artifacts=>[A],max_iterations=>20,
        mutation_mode=>staged,mutation=>#{seed=>{17,23,41},stages=>[havoc],trace_limit=>20},
        random_seed=>{17,23,41},selection_seed=>{17,23,41},crash_dir=>D++"/crashes"},
    {Off,_}=campaign(C#{monitoring=>false}),
    {On,S}=campaign(C#{monitoring=>true}),
    ?assertEqual(maps:get(mutation_trace,Off),maps:get(mutation_trace,On)),
    ?assertEqual(maps:get(coverage,Off),maps:get(coverage,On)),
    ?assertEqual(completed,maps:get(status,S)),
    ?assert(maps:get(coverage_total,S)>0),
    Last=maps:get(last,S),?assertEqual(mutation,maps:get(phase,Last)),
    ?assert(byte_size(maps:get(preview_hex,Last))=<1024),
    ?assert(length(maps:get(covered_functions,S))>0),
    Counts=maps:get(outcomes,S),?assertEqual(21,lists:sum(maps:values(Counts))).
campaign(C)->
    try {ok,_}=efz:start(C),R=efz:await(10000),{R,efz_fuzzer:monitor_snapshot()}
    after efz:stop() end.

bounded_preview_test()->
    S=#{monitoring=>true,monitor_index=>#{}},
    Meta=#{phase=>mutation,parent=>1},
    R=#{outcome=>{ok,binary:copy(<<65>>,100000)}},
    Next=efz_monitor:record(binary:copy(<<0>>,100000),R,Meta,S),
    Last=maps:get(monitor_last,Next),
    ?assertEqual(1024,byte_size(maps:get(preview_hex,Last))),
    ?assert(maps:get(truncated,Last)),
    ?assert(byte_size(maps:get(outcome,Last))<1024),
    ?assertEqual(#{monitoring=>false},efz_monitor:record(<<>>,R,Meta,#{monitoring=>false})).

slow_target_does_not_block_monitor_test()->
    persistent_term:put({efz_monitor_wait_target,owner},self()),
    try
        {ok,_}=efz:start(#{target=>efz_monitor_wait_target,seeds=>[<<>>],
            coverage_backend=>none,max_iterations=>0,timeout=>5000,monitoring=>true}),
        Target=receive {target_entered,P}->P after 2000->error(target_not_started) end,
        Owner=self(),{Caller,Ref}=spawn_monitor(fun()->Owner!{monitor_response,efz_fuzzer:monitor_snapshot()} end),
        receive {monitor_response,#{schema_version:=1}}->ok
        after 1000->exit(Caller,kill),error(monitor_blocked_by_target) end,
        receive {'DOWN',Ref,process,Caller,normal}->ok after 1000->error(caller_not_finished) end,
        Target!monitor_continue,
        ?assertMatch(#{status:=completed},efz:await(5000))
    after efz:stop(),persistent_term:erase({efz_monitor_wait_target,owner}) end.
