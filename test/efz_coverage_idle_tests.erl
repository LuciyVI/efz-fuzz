-module(efz_coverage_idle_tests).
-include_lib("eunit/include/eunit.hrl").
-export([run/1]).

run(_) -> efz_cov:hit(always), ok.

clock_contract_test() ->
    Off=efz_coverage_idle:new(disabled),
    ?assertEqual(false,efz_coverage_idle:expired(Off,100000)),
    ?assertEqual(#{schema_version=>1,enabled=>false},efz_coverage_idle:public(Off,100000)),
    S0=efz_coverage_idle:new(2),
    ?assertEqual(false,efz_coverage_idle:expired(S0,9000)),
    S1=efz_coverage_idle:start(S0,1000),
    ?assertEqual(false,efz_coverage_idle:expired(S1,2999)),
    ?assertEqual(true,efz_coverage_idle:expired(S1,3000)),
    ?assertEqual(S1,efz_coverage_idle:observe(S1,[late_probe],{3000,3})),
    ?assertEqual(S1,efz_coverage_idle:observe(S1,[],{3000,4})),
    S2=efz_coverage_idle:observe(S1,[{build,probe}],{2500,4}),
    ?assertEqual(false,efz_coverage_idle:expired(S2,3000)),
    ?assertEqual(true,efz_coverage_idle:expired(S2,4500)),
    Public=efz_coverage_idle:public(S2,3000),
    ?assertEqual(500,maps:get(elapsed_ms,Public)),
    ?assertEqual(4,maps:get(last_new_coverage_iteration,Public)),
    ?assertEqual(1,maps:get(new_coverage_events,Public)),
    ?assertEqual(false,maps:is_key(since_ms,Public)).

configuration_test() ->
    Base=#{target=>?MODULE,seeds=>[<<0>>],coverage=>manual,max_iterations=>0},
    {ok,C}=efz_config:prepare(Base),
    ?assertEqual(disabled,maps:get(stop_after_no_new_coverage_seconds,C)),
    {ok,_}=efz_config:prepare(Base#{stop_after_no_new_coverage_seconds=>1}),
    lists:foreach(fun(V)->
        ?assertEqual({error,{invalid_campaign_option,stop_after_no_new_coverage_seconds}},
            efz_config:prepare(Base#{stop_after_no_new_coverage_seconds=>V}))
    end,[0,-1,86401,1.0,<<"1">>,infinity]),
    ?assertEqual({error,coverage_idle_requires_coverage},
        efz_config:prepare((maps:remove(coverage,Base))#{coverage_backend=>none,
            stop_after_no_new_coverage_seconds=>1})).

stops_real_campaign_test_() -> {timeout,15,fun() ->
    C=#{target=>?MODULE,seeds=>[<<0>>],coverage=>manual,
        max_iterations=>infinity,mutation_mode=>random,timeout=>1000,
        stop_after_no_new_coverage_seconds=>1,max_input_bytes=>16},
    try
        {ok,_}=efz:start(C),
        Report=efz:await(10000),
        ?assertEqual({stopped,no_new_coverage},maps:get(status,Report)),
        ?assertEqual(1,length(maps:get(coverage,Report))),
        ?assert(maps:get(executions,maps:get(stats,Report))>0),
        Idle=maps:get(coverage_idle,Report),
        ?assertEqual(expired,maps:get(status,Idle)),
        ?assert(maps:get(elapsed_ms,Idle)>=1000),
        ?assertEqual(0,maps:get(new_coverage_events,Idle))
    after efz:stop() end
end}.

new_coverage_resets_real_campaign_test_() -> {timeout,15,fun() ->
    C=#{target=>efz_coverage_idle_target,seeds=>[<<0>>],coverage=>manual,
        mutator=>efz_coverage_idle_mutator,max_iterations=>infinity,
        mutation_mode=>random,timeout=>1000,
        stop_after_no_new_coverage_seconds=>1,max_input_bytes=>16},
    try
        {ok,_}=efz:start(C),
        Report=efz:await(10000),
        ?assertEqual({stopped,no_new_coverage},maps:get(status,Report)),
        ?assertEqual(2,length(maps:get(coverage,Report))),
        Idle=maps:get(coverage_idle,Report),
        ?assertEqual(1,maps:get(new_coverage_events,Idle)),
        ?assertEqual(5,maps:get(last_new_coverage_iteration,Idle)),
        ?assert(maps:get(executions,maps:get(stats,Report))>=5)
    after efz:stop() end
end}.

cli_flag_and_report_test_() -> {timeout,15,fun() ->
    Dir=filename:absname("_build/coverage-idle-cli-"++
        integer_to_list(erlang:unique_integer([positive]))),
    Config=Dir++"/campaign.term",
    ok=filelib:ensure_dir(Config),
    Base=#{target=>?MODULE,seeds=>[<<0>>],coverage=>manual,
        mutation_mode=>random,max_iterations=>infinity,max_input_bytes=>16},
    ok=file:write_file(Config,io_lib:format("~tp.~n",[Base])),
    try
        ?assertEqual(0,efz_cli:main(["--config",Config,"--out",Dir,
            "--stop-after-no-new-coverage-seconds","1"])),
        {ok,B}=file:read_file(Dir++"/report.term"),
        Report=binary_to_term(B),
        ?assertEqual({stopped,no_new_coverage},maps:get(status,Report)),
        ?assertEqual(1,maps:get(limit_seconds,maps:get(coverage_idle,Report))),
        ?assertEqual(undefined,whereis(efz_fuzzer))
    after file:del_dir_r(Dir) end
end}.
