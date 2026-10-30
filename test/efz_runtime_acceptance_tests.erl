-module(efz_runtime_acceptance_tests).
-include_lib("eunit/include/eunit.hrl").

comparator_test()->
    ?assertMatch({comparable,_},efz_stability:bounded_return(#{a=>[1,2],b=><<"ok">>})),
    ?assertEqual(efz_stability:bounded_return(#{a=>1,b=>2}),
        efz_stability:bounded_return(maps:from_list([{b,2},{a,1}]))),
    Big=binary:copy(<<0>>,4*1024*1024),
    Cases=[make_ref(),self(),fun()->ok end,#{Big=>1},#{a=>Big},
        lists:foldl(fun(_,A)->{A} end,ok,lists:seq(1,1000)),
        maps:from_list([{N,N}||N<-lists:seq(1,1025)]),
        #{<<Big/binary,1>>=>1,<<Big/binary,2>>=>2},
        {binary:copy(<<0>>,600),binary:copy(<<1>>,600)}],
    [?assertEqual(not_comparable,efz_stability:bounded_return(T))||T<-Cases],
    %% Trace arities only: do not copy huge arguments into the tracer. This
    %% proves rejected terms never reach serialization or the former full sort.
    Parent=self(),Worker=spawn(fun()->receive go->
        [efz_stability:bounded_return(T)||T<-Cases],Parent!{done,self()}
    end end),
    Session=trace:session_create(return_budget,self(),[]),
    try
        [trace:function(Session,MFA,true,[local])||MFA<-[{erlang,term_to_binary,2},{lists,sort,1},{maps,to_list,1},{efz_stability,bound,3}]],
        1=trace:process(Session,Worker,true,[call,arity]),Worker!go,
        receive {done,Worker}->ok after 2000->error(comparator_hang) end,
        Barrier=trace:delivered(Session,Worker),
        receive {trace_delivered,Worker,Barrier}->ok after 2000->error(trace_hang) end,
        Visits=visits(Worker,0),?assert(Visits>0),?assert(Visits=<length(Cases)*1025)
    after trace:session_destroy(Session),exit(Worker,kill) end.
visits(P,N)->receive
    {trace,P,call,{efz_stability,bound,3}}->visits(P,N+1);
    {trace,P,call,MFA}->error({expensive_before_validation,MFA})
after 0->N end.

new_config_test()->
    [?assertEqual({error,invalid_runtime_oracles},efz_runtime_config:prepare(#{resources=>R}))||R<-[
        #{quiescence_ms=> -1},#{quiescence_ms=>101},#{memory_observation_timeout_ms=>0},
        #{quiescence_ms=>50,memory_observation_timeout_ms=>50},#{residual_memory_bytes=>0}]],
    {ok,P}=efz_runtime_config:prepare(#{}),
    ?assertEqual(false,maps:get(enabled,P)).

runtime_test_()->{setup,fun setup/0,fun(_)->efz:stop() end,fun(_)->[
    {"post cleanup residual and negative temporary allocation",{timeout,15,fun memory/0}},
    {"disabled, absent, stale and incomplete timeout samples",fun unknown/0},
    {"default return values are ignored",fun default_return/0}
] end}.
setup()->
    {ok,M,B}=compile:file("fixtures/runtime/efz_runtime_memory_fixture.erl",[binary,debug_info]),
    {module,M}=code:load_binary(M,"memory-fixture",B),ok.
policy()->#{enabled=>true,resources=>#{sample_interval_ms=>5,quiescence_ms=>2,
    memory_observation_timeout_ms=>200,residual_memory_bytes=>8*1024*1024}}.
run(Input,P,T)->efz_executor:run(efz_runtime_memory_fixture,Input,T,#{coverage=>manual,runtime_oracles=>P}).
default_return()->
    {ok,P}=efz_runtime_config:prepare(policy()),
    S=efz_stability:summarize([efz_stability:snapshot(run(<<"reference">>,P,100),P)||_<-[1,2,3]],3),
    ?assertEqual(100.0,maps:get(outcome_repeatability,S)),?assertEqual([],maps:get(categories,S)).
unknown()->
    P=policy(),R=maps:get(resources,P),
    [begin X=run(<<"waiting">>,C,20),
        ?assertEqual({timeout,20},maps:get(outcome,X)),
        ?assertEqual([timeout_unknown],maps:get(categories,maps:get(timeout,maps:get(runtime_observations,X))))
    end||C<-[P#{resources=>R#{enabled=>false},hangs=>#{enabled=>false}},
        P#{resources=>R#{sample_interval_ms=>100},hangs=>#{max_sample_age_ms=>100}}]],
    H=maps:get(hangs,efz_runtime_config:defaults()),
    S=fun(T,Red,Status,Partial)->#{at_ms=>T,partial=>Partial,processes=>[#{pid=>self(),reductions=>Red,status=>Status}]} end,
    [begin Out=efz_runtime:timeout(Samples,Now,H),?assertEqual([Cat],maps:get(categories,Out)) end||{Samples,Now,Cat}<-[
        {[],100,timeout_unknown},
        {[S(20,0,waiting,false),S(10,0,waiting,false)],999,timeout_unknown},
        {[S(20,0,waiting,true),S(10,0,waiting,true)],21,timeout_unknown},
        {[S(20,3000,running,false),S(10,0,running,false)],21,timeout_busy},
        {[S(20,0,waiting,false),S(10,0,waiting,false)],21,timeout_waiting}]].
memory()->
    %% Warm trusted code/loading before the measured runs. No target GC.
    _=run(<<>>,policy(),500),
    Temp=run(<<"temporary">>,policy(),500),TR=maps:get(runtime_observations,Temp),
    TP=maps:get(post_execution_memory,TR),
    ?assertEqual(complete,maps:get(completeness,TP)),
    ?assertEqual(confirmed,maps:get(cleanup_status,TP)),
    ?assert(maps:get(peak_memory,TP)>maps:get(baseline_memory,TP)+8*1024*1024),
    ?assertNot(lists:member(vm_memory_growth_suspected,efz_runtime:categories(Temp))),
    Dir="_build/runtime-acceptance-"++integer_to_list(erlang:unique_integer([positive])),
    {ok,_}=efz:start(#{target=>efz_runtime_memory_fixture,coverage=>manual,seeds=>[<<"residual">>],
        max_iterations=>0,timeout=>500,crash_dir=>filename:join(Dir,"crashes"),runtime_oracles=>policy()}),
    C=efz:await(5000),efz:stop(),?assertEqual(completed,maps:get(status,C)),
    D=maps:get(runtime_diagnostics,C),[Check]=maps:get(checks,D),
    ?assertEqual(3,maps:get(vm_memory_growth_suspected,maps:get(reproductions,Check),0)),
    ?assertEqual(0,maps:get(crashes,maps:get(stats,C))),
    [begin E=maps:get(post_execution_memory,maps:get(runtime,Row)),
        ?assertEqual(vm_global,maps:get(scope,E)),?assertEqual(confirmed,maps:get(cleanup_status,E)),
        ?assert(maps:get(residual_delta,E)>=maps:get(threshold,E))
    end||Row<-maps:get(samples,Check)],
    [G]=[X||X<-maps:values(maps:get(groups,maps:get(findings,D))),maps:get(category,X)=:=vm_memory_growth_suspected],
    [Rep|_]=maps:get(representatives,G),Path=maps:get(path,Rep),
    {ok,Artifact,<<"residual">>}=efz_runtime_store:load(Path),?assertEqual(vm_global,maps:get(scope,Artifact)),
    {ok,Replay}=efz_runtime_replay:run(Path,efz_runtime_memory_fixture,[],#{runs=>3}),
    %% Replay deliberately discards raw returns between runs. Collection of an
    %% older EFZ-held binary can offset a new VM-global allocation: report the
    %% actual M/N, never turn that lack of attribution into a target leak claim.
    RS=maps:get(samples,maps:get(summary,Replay)),
    Observed=length([ok||Row<-RS,lists:member(vm_memory_growth_suspected,
        maps:get(categories,maps:get(runtime,Row)))]),
    ?assertEqual(3,maps:get(sample_count,Replay)),?assertEqual(Observed,maps:get(observed,Replay)),
    ?assert(Observed>0),?assertEqual(observed,maps:get(status,Replay)),
    io:format("RESIDUAL reproduced=3/3 replay=~p/3 temporary_delta=~p~n",[Observed,maps:get(residual_delta,TP)]).
