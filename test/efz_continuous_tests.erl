-module(efz_continuous_tests).
-include_lib("eunit/include/eunit.hrl").

config()->#{target=>efz_continuous_fixture,seeds=>[<<0>>],coverage_backend=>none,
    max_iterations=>infinity,mutation_mode=>staged,
    mutation=>#{seed=>{17,23,41},stages=>[bitflip],trace_limit=>32},
    selection_seed=>{17,23,41}}.
configuration_test()->
    {ok,C}=efz_config:prepare(config()),
    ?assertEqual([bitflip,havoc],maps:get(stages,maps:get(mutation,C))),
    ?assertMatch({error,continuous_requires_nonzero_input_limit},
        efz_config:prepare((config())#{seeds=>[<<>>],max_input_bytes=>0})).

fallback_recipe_test()->
    {ok,C}=efz_mutation_plan:prepare(#{stages=>[dictionary_insert],seed=>{17,23,41}},[<<>>]),
    S=efz_mutation_plan:new(C),Entries=[#{id=>1,input=><<>>}],
    %% Empty dictionary has no finite work. Continuous planning must still
    %% execute real mutations, without inventing unreplayable provenance.
    {candidate,B,P,Next}=efz_mutation_plan:next_continuous(S,Entries),
    ?assertEqual(1,byte_size(B)),
    ?assertEqual({ok,B},efz_recipe:regenerate(efz_recipe:make(P,B,C,#{}))),
    ?assertEqual(1,maps:get(continuous_fallbacks,maps:get(counts,Next))),
    ?assertNotEqual(maps:get(rng,S),maps:get(rng,Next)),
    ?assertEqual({candidate,B,P,Next},efz_mutation_plan:next_continuous(S,Entries)),
    {candidate,Changed,P2,_}=efz_mutation_plan:next_continuous(S,[#{id=>1,input=><<0>>}]),
    ?assertNotEqual(<<0>>,Changed),
    ?assertEqual({ok,Changed},efz_recipe:regenerate(efz_recipe:make(P2,Changed,C,#{}))).

campaign_test_()->{timeout,30,fun()->
    C=config(),
    try
        {ok,_}=efz:start(C),wait_executions(100),
        Before=maps:get(executions,efz:stats()),wait_executions(Before+50),
        ?assertEqual(running,efz_fuzzer:status()),
        ok=efz:request_stop(),R=efz:await(5000),
        ?assertEqual(stopped_by_user,maps:get(status,R)),
        ?assert(maps:get(executions,maps:get(stats,R))>=150),
        ?assert(length(maps:get(mutation_trace,R))=<32),
        [Recipe|_]=maps:get(mutation_trace,R),?assertMatch({ok,_},efz_recipe:regenerate(Recipe)),
        ok=efz:request_stop(),?assertEqual(R,efz:await(1000)),
        Final=maps:get(executions,efz:stats()),
        receive after 30->ok end,
        ?assertEqual(Final,maps:get(executions,efz:stats()))
    after efz:stop() end
end}.
wait_executions(N)->wait_executions(N,erlang:monotonic_time(millisecond)+10000).
wait_executions(N,Deadline)->
    case maps:get(executions,efz:stats())>=N of
        true->ok;
        false->case erlang:monotonic_time(millisecond)<Deadline of
            true->receive after 10->wait_executions(N,Deadline) end;
            false->error(continuous_campaign_stalled)
        end
    end.

cli_stop_test_()->{timeout,30,fun()->
    D="_build/continuous-cli-"++integer_to_list(erlang:system_time(microsecond)),
    ok=filelib:ensure_dir(D++"/placeholder"),
    Path=D++"/config.term",ok=file:write_file(Path,io_lib:format("~tp.~n",[config()])),
    Owner=self(),{P,Ref}=spawn_monitor(fun()->
        Owner!{cli_status,efz_cli:main(["--config",Path,"--out",D,"--max-iterations","infinity"])} end),
    wait_cli_running(200),wait_executions(30),
    ok=file:write_file(D++"/stop.request",<<"stop">>),
    receive {cli_status,Status}->?assertEqual(0,Status) after 10000->error(cli_not_stopped) end,
    receive {'DOWN',Ref,process,P,normal}->ok after 1000->error(cli_not_finished) end,
    {ok,B}=file:read_file(D++"/report.term"),
    ?assertEqual(stopped_by_user,maps:get(status,binary_to_term(B))),
    ?assertEqual(undefined,whereis(efz_fuzzer))
end}.
wait_cli_running(0)->error(cli_not_started);
wait_cli_running(N)->case whereis(efz_stats) of
    undefined->receive after 10->wait_cli_running(N-1) end;
    _->ok end.

idle_fallback_test()->
    {ok,C}=efz_mutation_plan:prepare(#{stages=>[splice],max_idle_visits=>1,seed=>{17,23,41}},[<<0>>]),
    Es=[#{id=>1,input=><<0>>}],
    {skip,_,Idle}=efz_mutation_plan:next(efz_mutation_plan:new(C),Es),
    {candidate,B,P,Next}=efz_mutation_plan:next_continuous(Idle,Es),
    ?assertNotEqual(<<0>>,B),
    ?assertEqual(maps:get(cursors,Idle),maps:get(cursors,Next)),
    ?assertEqual({ok,B},efz_recipe:regenerate(efz_recipe:make(P,B,C,#{}))).

gleam_continuous_test_()->case code:which(efz_term_model) of
    non_existing->[];
    _->{timeout,30,fun()->
        O=efz_continuous_fixture:options(),
        {ok,Seed}=efz_term_codec:encode([<<"a">>],maps:get(arguments,O),#{}),
        C=(config())#{seeds=>[Seed],
            gleam_layer=>#{adapter=>efz_term_api_adapter,adapter_options=>O,structured_fraction=>100,
                feedback=>guided,oracle=>inline,oracle_budget=>64}},
        try
            {ok,_}=efz:start(C),wait_executions(100),
            ok=efz:request_stop(),R=efz:await(5000),
            ?assertEqual(stopped_by_user,maps:get(status,R)),
            ?assert(maps:get(successes,maps:get(structured_stats,R),0)>0),
            ?assertEqual(0,maps:get(infrastructure_failures,maps:get(stats,R))),
            ?assert(maps:get(oracle_checks,maps:get(gleam_stats,R))=<64)
        after efz:stop() end
    end}
end.

slow_stop_and_waiter_cleanup_test_()->{timeout,30,fun()->
    persistent_term:put({efz_monitor_wait_target,owner},self()),
    try
        {ok,F}=efz:start((config())#{target=>efz_monitor_wait_target,timeout=>10000}),
        Target=receive {target_entered,P}->P after 2000->error(target_not_started) end,
        lists:foreach(fun(_)->?assertMatch({'EXIT',{timeout,_}},catch efz:await(1)) end,
            lists:seq(1,50)),
        ?assertEqual(#{},maps:get(waiters,sys:get_state(F))),
        Caller=spawn(fun()->efz:await(infinity) end),
        wait_waiters(F,1,100),exit(Caller,kill),wait_waiters(F,0,100),
        Owner=self(),
        spawn(fun()->Owner!{waiting_report,efz:await(infinity)} end),
        wait_waiters(F,1,100),
        lists:foreach(fun(_)->ok=efz:request_stop() end,lists:seq(1,100)),
        ?assertEqual(running,efz_fuzzer:status()),
        W=maps:get(worker,sys:get_state(F)),
        {messages,Messages}=process_info(W,messages),
        ?assertEqual(1,length([stop||{'$gen_cast',request_stop}<-Messages])),
        Target!monitor_continue,
        R=efz:await(5000),?assertEqual(stopped_by_user,maps:get(status,R)),
        receive {waiting_report,Other}->?assertEqual(R,Other)
        after 1000->error(waiter_not_replied) end,
        ?assertEqual(0,maps:get(executions,maps:get(stats,R))),
        ?assertEqual(#{},maps:get(waiters,sys:get_state(F)))
    after efz:stop(),persistent_term:erase({efz_monitor_wait_target,owner}) end
end}.
wait_waiters(F,N,Attempts)->
    case map_size(maps:get(waiters,sys:get_state(F))) of
        N->ok;
        _ when Attempts>0->receive after 5->wait_waiters(F,N,Attempts-1) end;
        _->error(waiters_not_cleaned)
    end.

durable_restart_test_()->{timeout,30,fun()->
    D="_build/continuous-restart-"++integer_to_list(erlang:system_time(microsecond)),
    C=(config())#{corpus_dir=>D},
    try
        {ok,_}=efz:start(C),wait_executions(100),ok=efz:request_stop(),
        First=efz:await(5000),ok=efz:stop(),
        {ok,_}=efz:start(C#{seeds=>[]}),wait_executions(100),ok=efz:request_stop(),
        Second=efz:await(5000),
        ?assertEqual(stopped_by_user,maps:get(status,Second)),
        Inputs=fun(R)->lists:sort([maps:get(input,E)||E<-maps:get(corpus,R)]) end,
        ?assertEqual(Inputs(First),Inputs(Second)),
        ?assertEqual(length(maps:get(corpus,First)),
            maps:get(restored_inputs,maps:get(corpus_restore,Second))),
        ?assertEqual(0,maps:get(infrastructure_failures,maps:get(stats,Second)))
    after efz:stop() end
end}.

failure_after_stop_request_test_()->{timeout,30,fun()->
    persistent_term:put({efz_monitor_wait_target,owner},self()),
    try
        {ok,F}=efz:start((config())#{target=>efz_monitor_wait_target,timeout=>10000}),
        Target=receive {target_entered,P}->P after 2000->error(target_not_started) end,
        TargetRef=monitor(process,Target),
        Guardian=whereis(efz_execution_guardian),GuardianRef=monitor(process,Guardian),
        ok=efz:request_stop(),
        exit(maps:get(worker,sys:get_state(F)),kill),
        R=efz:await(5000),
        ?assertEqual({infrastructure_failure,{worker_down,killed}},maps:get(status,R)),
        ?assertEqual(1,maps:get(infrastructure_failures,maps:get(stats,R))),
        ok=efz:request_stop(),?assertEqual(R,efz:await(1000)),
        receive {'DOWN',TargetRef,process,Target,_}->ok after 2000->error(target_alive) end,
        receive {'DOWN',GuardianRef,process,Guardian,_}->ok after 2000->error(guardian_alive) end
    after efz:stop(),persistent_term:erase({efz_monitor_wait_target,owner}) end
end}.
