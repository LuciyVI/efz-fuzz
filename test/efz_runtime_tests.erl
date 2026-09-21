-module(efz_runtime_tests).
-include_lib("eunit/include/eunit.hrl").
-export([dirty_vm/0, verification_dirty_vm/0, guardian_failure_vm/0, overload_vm/0, mutate/2]).
mutate(B,O)->V=efz_mutator_random:mutate(B,O),whereis(efz_runtime_mutation_observer)!{mutated,V},V.
policy()->{ok,P}=efz_runtime_config:prepare(#{enabled=>true,resources=>#{sample_interval_ms=>5,ets_interval_ms=>10,
    memory_bytes=>100000,mailbox_messages=>20,ets_memory_bytes=>10000},
    stability=>#{max_extra_executions=>10}}),P.
config_test()->
    ?assertMatch({ok,#{enabled:=false}},efz_runtime_config:prepare(#{})),
    [?assertEqual({error,invalid_runtime_oracles},efz_runtime_config:prepare(P))||P<-[#{unknown=>1},
      #{enabled=>yes},#{stability=>#{seed_runs=>0}},#{stability=>#{seed_runs=>17}},
      #{stability=>#{unknown=>1}},#{resources=>#{max_samples=>100000}},
      #{resources=>#{sample_interval_ms=>0}},#{resources=>#{max_samples=>256,max_sampled_processes=>256}},
      #{hangs=>#{max_sample_age_ms=>1}},#{storage=>#{max_metadata_bytes=>100}}]].
row(O,C)->efz_stability:snapshot(#{outcome=>O,coverage=>C,builds=>#{test=><<1>>},coverage_status=>ok},policy()).
stability_test()->
    A={test,<<1>>,1},B={test,<<1>>,2},
    S=efz_stability:summarize([row({ok,make_ref()},[A]),row({ok,make_ref()},[A]),row({exit,no},[A,B])],3),
    ?assertEqual(200/3,maps:get(outcome_repeatability,S)),
    ?assertEqual(200/3,maps:get(coverage_repeatability,S)),
    ?assertEqual([A],maps:get(stable_probes,S)),?assertEqual([B],maps:get(variable_probes,S)),
    ?assertEqual(50.0,maps:get(stable_probe_ratio,S)),
    ?assertEqual([unstable_outcome,unstable_coverage],maps:get(categories,S)),
    E=efz_stability:summarize([row({ok,ok},[]),row({ok,ok},[])],2),
    ?assertEqual(100.0,maps:get(coverage_repeatability,E)),?assertEqual(100.0,maps:get(stable_probe_ratio,E)),
    ?assert(maps:get(valid_empty_coverage,E)),
    ?assertEqual(insufficient_samples,maps:get(status,efz_stability:summarize([row({ok,ok},[])],3))),
    ?assertEqual(not_comparable,efz_stability:bounded_return(make_ref())),
    ?assertEqual(not_comparable,efz_stability:bounded_return(<<0:16000>>)),
    ?assertEqual(not_comparable,efz_stability:bounded_return(lists:seq(1,2000))),
    ?assertMatch({comparable,_},efz_stability:bounded_return(#{x=>[1,2,3]})),
    Broken=efz_stability:snapshot(#{outcome=>{infrastructure,broken},coverage_status=>{error,broken},coverage=>[]},policy()),
    Incomplete=efz_stability:summarize([row({ok,ok},[A]),Broken],3),
    ?assertEqual(1,maps:get(valid,Incomplete)),?assertEqual(1,maps:get(failed,Incomplete)),
    ?assertEqual(1,maps:get(skipped,Incomplete)),?assertEqual([],maps:get(categories,Incomplete)).
timeout_unit_test()->
    H=maps:get(hangs,policy()),P=self(),
    Sample=fun(T,R,S)->#{at_ms=>T,partial=>false,processes=>[#{pid=>P,reductions=>R,status=>S}]} end,
    ?assertMatch(#{categories:=[timeout_busy]},efz_runtime:timeout([Sample(20,3000,running),Sample(10,0,running)],21,H)),
    ?assertMatch(#{categories:=[timeout_waiting]},efz_runtime:timeout([Sample(20,0,waiting),Sample(10,0,waiting)],21,H)),
    ?assertMatch(#{categories:=[timeout_unknown]},efz_runtime:timeout([Sample(20,0,waiting),Sample(10,0,waiting)],999,H)),
    ?assertMatch(#{categories:=[timeout_unknown]},efz_runtime:timeout([],21,H)),
    Dead=spawn(fun()->ok end),M=monitor(process,Dead),receive {'DOWN',M,process,Dead,_}->ok end,
    ?assertEqual(unavailable,efz_runtime:process_sample(Dead,8)),
    T=ets:new(gone,[]),ets:delete(T),?assertEqual(unowned,efz_runtime:table_sample(T,#{self()=>true})).
integration_test_()->{setup,fun setup/0,fun(_)->efz:stop() end,fun(A)->[
    {"deterministic and valid empty real executor",fun()->deterministic(A) end},
    {"owned resource peaks survive cleanup",fun()->resources(A) end},
    {"child observation does not override root",fun()->children(A) end},
    {"busy and waiting timeouts have recent evidence",fun()->timeouts(A) end},
    { "sampling is partial under process and ETS caps",fun()->partial_sampling(A) end},
    {"sampler death degrades diagnostics",fun()->sampler_failure(A) end},
    {"explicit return comparison is bounded",fun()->return_comparison(A) end},
    {"verification-only crash, storage and explicit replay",{timeout,20,fun()->campaign(A) end}},
    {"verification preserves staged recipes and random mutation inputs",{timeout,30,fun()->independence(A) end}},
    { "verification budget includes seed repeats",fun()->budget(A) end},
    {"store bounds, corruption, interrupted publication",fun()->store(A) end},
    {"dirty runner stops repeats in disposable test VM",{timeout,15,fun dirty_external/0}}
] end}.
setup()->
    {ok,H,B}=compile:file("fixtures/runtime/efz_runtime_harness.erl",[binary,debug_info]),
    {module,H}=code:load_binary(H,"fixtures/runtime/efz_runtime_harness.erl",B),
    {ok,A}=efz_instrument:compile("fixtures/runtime/efz_runtime_sites.erl",#{modules=>[efz_runtime_sites],
        source_root=>".",outdir=>"_build/runtime-tests/targets"}),A.
options(A)->{ok,Ms}=efz_instrument:preflight([A]),#{coverage=>automatic,manifests=>Ms,runtime_oracles=>policy()}.
run(A,B,T)->efz_executor:run(efz_runtime_harness,B,T,options(A)).
deterministic(A)->
    Rs=[run(A,<<"reference">>,500)||_<-lists:seq(1,3)],
    S=efz_stability:summarize([efz_stability:snapshot(R,policy())||R<-Rs],3),
    ?assertEqual([],maps:get(categories,S)),?assertEqual(100.0,maps:get(outcome_repeatability,S)),
    [E1,E2]=[run(A,<<"empty">>,500)||_<-[1,2]],
    ?assertEqual([],maps:get(coverage,E1)),
    ?assert(maps:get(valid_empty_coverage,efz_stability:summarize([efz_stability:snapshot(R,policy())||R<-[E1,E2]],2))),
    ?assertEqual(not_sampled,maps:get(sampling_status,maps:get(runtime_observations,E1))),
    ?assertEqual(false,maps:is_key(runtime_observations,efz_executor:run(efz_runtime_harness,<<"empty">>,500,#{coverage=>manual}))).
resources(A)->
    R=run(A,<<"memory">>,1000),Rt=maps:get(runtime_observations,R),
    ?assertMatch({ok,_},maps:get(outcome,R)),?assert(lists:member(memory_pressure,maps:get(categories,Rt))),
    ?assertEqual(confirmed,maps:get(status,maps:get(after_cleanup,Rt))),
    ?assert(maps:get(memory_bytes,maps:get(peak,Rt))>=100000),
    E=run(A,<<"mailbox_ets">>,1000),ER=maps:get(runtime_observations,E),
    ?assert(lists:member(mailbox_pressure,maps:get(categories,ER))),
    ?assert(lists:member(ets_growth_suspected,maps:get(categories,ER))),
    ?assert(maps:get(ets_memory_bytes,maps:get(peak,ER))>=10000),
    ?assert(lists:all(fun(S)->maps:get(known_processes,S)=<1 end,maps:get(samples,ER))).
children(A)->
    R=run(A,<<"abnormal_child">>,500),?assertEqual({ok,ok},maps:get(outcome,R)),
    ?assert(lists:member(child_abnormal_exit,efz_runtime:categories(R))),
    C=run(A,<<"child">>,500),?assertEqual({ok,true},maps:get(outcome,C)),
    ?assertNot(lists:member(child_abnormal_exit,efz_runtime:categories(C))),
    ?assertEqual(1,maps:get(descendants_created,maps:get(runtime_observations,C))),
    ?assertEqual([],maps:get(survivors,maps:get(cleanup,C))).
timeouts(A)->
    [begin R=run(A,B,100),?assertEqual({timeout,100},maps:get(outcome,R)),
        ?assert(lists:member(C,efz_runtime:categories(R))),
        ?assert(maps:get(sample_age_ms,maps:get(timeout,maps:get(runtime_observations,R)))<100)
    end||{B,C}<-[{<<"busy">>,timeout_busy},{<<"waiting">>,timeout_waiting}]],
    O=options(A),P=policy(),PR=maps:get(resources,P),
    R=efz_executor:run(efz_runtime_harness,<<"waiting">>,100,O#{runtime_oracles=>P#{resources=>PR#{max_samples=>2}}}),
    ?assertEqual(2,length(maps:get(samples,maps:get(runtime_observations,R)))),
    ?assert(lists:member(timeout_waiting,efz_runtime:categories(R))).
partial_sampling(A)->
    P=policy(),Res=maps:get(resources,P),O=options(A),
    R=efz_executor:run(efz_runtime_harness,<<"live_children">>,500,
        O#{runtime_oracles=>P#{resources=>Res#{max_ets_tables=>1,max_sampled_processes=>2}}}),
    Rt=maps:get(runtime_observations,R),?assert(maps:get(partial,Rt)),
    ?assert(lists:any(fun(S)->maps:get(known_processes,S)=:=5 andalso maps:get(observed_processes,S)=:=2 end,maps:get(samples,Rt))),
    ?assert(lists:all(fun(S)->case maps:get(ets,S) of
        #{scanned_vm_tables:=N}->N=<1;_->true end end,maps:get(samples,Rt))).
return_comparison(A)->
    P=policy(),St=maps:get(stability,P),Compare=P#{stability=>St#{compare_return=>true}},
    Rows=[efz_stability:snapshot(run(A,<<"reference">>,500),Compare)||_<-[1,2]],
    S=efz_stability:summarize(Rows,2),?assertEqual(0,maps:get(return_comparable,S)),
    ?assertEqual([],maps:get(categories,S)),
    X=efz_stability:summarize([ (row({ok,ok},[]))#{return=>efz_stability:bounded_return(V)}||V<-[1,2]],2),
    ?assertEqual([unstable_return],maps:get(categories,X)).
sampler_failure(A)->
    Parent=self(),Pid=spawn(fun()->Parent!{sample_result,run(A,<<"waiting">>,100)} end),
    wait_sampler(100),
    receive {sample_result,R}->?assertEqual({timeout,100},maps:get(outcome,R)),
        ?assertMatch({failed,_},maps:get(sampler_status,maps:get(runtime_observations,R))) after 2000->exit(Pid,kill),error(no_result) end.
wait_sampler(0)->error(no_sampler);
wait_sampler(N)->case [T||T<-ets:all(),ets:info(T,name)=:=efz_runtime_buffer] of
    []->receive after 1->wait_sampler(N-1) end;
    [_]->G=whereis(efz_execution_guardian),{monitors,Ms}=process_info(G,monitors),
        %% Sampler is the only guardian child running efz_runtime:sampler/4.
        Ps=[P||{process,P}<-Ms,is_pid(P),case process_info(P,current_function) of
             {current_function,{efz_runtime,_,_}}->true;_->false end],
        case Ps of [P|_]->exit(P,test_sampler_failure);_->receive after 1->wait_sampler(N-1) end end
end.
source(N)->receive
    {next,P}->P!{turn,N},source(N+1);
    stop->ok
end.
with_source(F)->P=spawn(fun()->source(1) end),true=register(efz_runtime_test_source,P),
    try F() after P!stop,unregister_if() end.
unregister_if()->case whereis(efz_runtime_test_source) of undefined->ok;_->unregister(efz_runtime_test_source) end.
unique_dir()->filename:join("_build/runtime-tests",binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8),lowercase))).
config(A,D)->#{target=>efz_runtime_harness,artifacts=>[A],seeds=>[<<"vary">>],max_iterations=>0,
    timeout=>500,crash_dir=>filename:join(D,"crashes"),runtime_oracles=>policy()}.
campaign(A)->with_source(fun()->
    D=unique_dir(),{ok,_}=efz:start(config(A,D)),Report=efz:await(10000),efz:stop(),
    ?assertEqual(completed,maps:get(status,Report)),
    ?assertEqual(2,maps:get(verification_executions,maps:get(stats,Report))),
    ?assertEqual(1,maps:get(crashes,maps:get(stats,Report))),
    [Crash]=maps:get(crashes,Report),?assertEqual(verification,maps:get(origin,maps:get(metadata,Crash))),
    ?assertEqual(1,length(maps:get(corpus,Report))),
    RD=maps:get(runtime_diagnostics,Report),[Check]=maps:get(checks,RD),
    [Initial|_]=maps:get(samples,Check),?assertEqual(maps:get(coverage,Initial),maps:get(coverage,Report)),
    ?assert(lists:member(unstable_outcome,maps:get(categories,Check))),
    Groups=maps:get(groups,maps:get(findings,RD)),
    [G|_]=maps:values(Groups),[Rep|_]=maps:get(representatives,G),Path=maps:get(path,Rep),
    ?assertMatch({ok,_,<<"vary">>},efz_runtime_store:load(Path)),
    {ok,Replay}=efz_runtime_replay:run(Path,efz_runtime_harness,[A],#{runs=>1}),
    ?assertEqual(inconclusive,maps:get(status,Replay)),
    ?assertMatch({error,replay_harness_mismatch},efz_runtime_replay:run(Path,efz_runtime_sites,[A],#{runs=>2}))
end).
independence(A)->
    [begin Off=independent_campaign(A,Mode,false),On=independent_campaign(A,Mode,true),
        ?assertEqual(maps:get(coverage,Off),maps:get(coverage,On)),
        case Mode of staged->?assertEqual(maps:get(mutation_trace,Off),maps:get(mutation_trace,On)),
                             ?assertEqual(maps:get(mutation_stats,Off),maps:get(mutation_stats,On));
            random->?assertEqual(maps:get(observed_mutations,Off),maps:get(observed_mutations,On)) end,
        ?assertEqual(10,maps:get(executions,maps:get(stats,On)))
    end||Mode<-[random,staged]].
independent_campaign(A,Mode,Enabled)->
    C0=(config(A,unique_dir()))#{seeds=>[<<>>],mutation_mode=>Mode,max_iterations=>10,random_seed=>{1,2,3},selection_seed=>{4,5,6},
        runtime_oracles=>#{enabled=>Enabled,resources=>#{enabled=>false},hangs=>#{enabled=>false}}},
    C=case Mode of staged->C0#{mutation=>#{seed=>{1,2,3},trace_limit=>100}};_->C0#{mutator=>?MODULE} end,
    true=register(efz_runtime_mutation_observer,self()),
    try {ok,_}=efz:start(C),R=efz:await(10000),efz:stop(),?assertEqual(completed,maps:get(status,R)),
        R#{observed_mutations=>mutation_messages([])}
    after unregister(efz_runtime_mutation_observer) end.
mutation_messages(L)->receive {mutated,V}->mutation_messages([V|L]) after 0->lists:reverse(L) end.
budget(A)->
    P=policy(),St=maps:get(stability,P),
    C=(config(A,unique_dir()))#{seeds=>[<<"deterministic">>],
        runtime_oracles=>P#{stability=>St#{seed_runs=>16,max_extra_executions=>1}}},
    {ok,_}=efz:start(C),R=efz:await(5000),efz:stop(),
    ?assertEqual(1,maps:get(verification_executions,maps:get(stats,R))),
    [Check]=maps:get(checks,maps:get(runtime_diagnostics,R)),
    ?assertEqual(16,maps:get(requested,Check)),?assertEqual(2,maps:get(completed,Check)),
    ?assertEqual(14,maps:get(skipped,Check)),?assertEqual([],maps:get(categories,Check)).
store(A)->
    D=unique_dir(),R=run(A,<<"empty">>,500),{ok,H}=efz_replay:harness_identity(efz_runtime_harness),
    Rec=#{coverage_mode=>automatic,scope=>target_owned,origin=>calibration,original_outcome=><<"ok">>,
        evidence=>#{},mutation=>undefined,harness=>H,target_builds=>efz_recipe:build_ids(maps:get(builds,R)),category=>memory_pressure,
        policy=>policy(),max_input_bytes=>4096,timeout=>500},
    P=(maps:get(storage,policy()))#{max_groups=>1,max_representatives=>1},
    {ok,S}=efz_runtime_store:save(D,<<1>>,Rec,P,efz_runtime_store:new()),
    [G0]=maps:values(maps:get(groups,S)),[Rep0]=maps:get(representatives,G0),
    ?assertMatch({ok,_,<<1>>},efz_runtime_store:load(maps:get(path,Rep0))),
    Mismatch=Rec#{target_builds=>[{<<"efz_runtime_sites">>,<<0:256>>}]},
    {ok,MS}=efz_runtime_store:save(unique_dir(),<<1>>,Mismatch,P,efz_runtime_store:new()),
    [MG]=maps:values(maps:get(groups,MS)),[MR]=maps:get(representatives,MG),
    ?assertEqual({error,replay_build_mismatch},efz_replay:runtime(maps:get(path,MR),efz_runtime_harness,[A],#{runs=>2})),
    BadFile=unique_dir(),ok=file:write_file(BadFile,<<"file-not-directory">>),
    ?assertMatch({error,_},efz_runtime_store:save(BadFile,<<1>>,Rec,P,efz_runtime_store:new())),
    {ok,S2}=efz_runtime_store:save(D,<<1>>,Rec,P,S),?assertEqual(1,maps:get(suppressed,S2)),
    {ok,S3}=efz_runtime_store:save(D,<<2>>,Rec,P,S2),?assertEqual(1,maps:get(dropped,S3)),
    {ok,S4}=efz_runtime_store:save(D,<<3>>,Rec#{category=>mailbox_pressure},P,S3),
    ?assertEqual(2,maps:get(dropped,S4)),
    Small=P#{max_metadata_bytes=>4096,max_total_metadata_bytes=>4096},
    {ok,Large}=efz_runtime_store:save(unique_dir(),<<1>>,Rec#{evidence=><<0:40000>>},Small,efz_runtime_store:new()),
    ?assertEqual(1,maps:get(dropped,Large)),?assertEqual(0,map_size(maps:get(groups,Large))),
    ?assertMatch({ok,_},efz_runtime_store:save(D,<<1>>,Rec,P,efz_runtime_store:new())),
    ?assertEqual({error,stale_runtime_store},efz_runtime_store:save(D,<<1>>,Rec,P,S)),
    ok=file:write_file(filename:join(D,"index"),<<"corrupt">>),
    ?assertEqual({error,corrupt_or_interrupted_runtime_store},efz_runtime_store:save(D,<<1>>,Rec,P,efz_runtime_store:new())),
    D2=unique_dir(),ok=filelib:ensure_dir(filename:join(D2,".tmp-interrupted/x")),
    ?assertEqual({error,corrupt_or_interrupted_runtime_store},efz_runtime_store:save(D2,<<1>>,Rec,P,efz_runtime_store:new())).
dirty_external()->
    Cmd="timeout 10s erl +S 2:2 -noshell -pa _build/test/lib/efz/ebin _build/test/lib/efz/test -eval 'efz_runtime_tests:dirty_vm(), halt().'",
    Out=os:cmd(Cmd),?assertNotEqual(nomatch,string:find(Out,"DIRTY_OK")),
    Cmd2="timeout 10s erl +S 2:2 -noshell -pa _build/test/lib/efz/ebin _build/test/lib/efz/test -eval 'efz_runtime_tests:verification_dirty_vm(), halt().'",
    Out2=os:cmd(Cmd2),?assertNotEqual(nomatch,string:find(Out2,"VERIFICATION_DIRTY_OK")),
    Cmd3="timeout 10s erl +S 2:2 -noshell -pa _build/test/lib/efz/ebin _build/test/lib/efz/test -eval 'efz_runtime_tests:guardian_failure_vm(), halt().'",
    Out3=os:cmd(Cmd3),?assertNotEqual(nomatch,string:find(Out3,"GUARDIAN_FAILURE_OK")),
    Cmd4="timeout 10s erl +S 2:2 -noshell -pa _build/test/lib/efz/ebin _build/test/lib/efz/test -eval 'efz_runtime_tests:overload_vm(), halt().'",
    Out4=os:cmd(Cmd4),?assertNotEqual(nomatch,string:find(Out4,"OVERLOAD_OK")).
dirty_vm()->
    A=setup(),C=(config(A,unique_dir()))#{seeds=>[<<"dirty">>]},
    {ok,_}=efz:start(C),R=efz:await(5000),efz:stop(),
    {infrastructure_failure,_}=maps:get(status,R),
    0=maps:get(verification_executions,maps:get(stats,R),0),
    {dirty,_}=efz_executor:runner_status(),io:put_chars("DIRTY_OK").

verification_dirty_vm()->with_source(fun()->
    A=setup(),C=(config(A,unique_dir()))#{seeds=>[<<"vary_dirty">>]},
    {ok,_}=efz:start(C),R=efz:await(5000),efz:stop(),
    {infrastructure_failure,_}=maps:get(status,R),
    1=maps:get(verification_executions,maps:get(stats,R)),
    [Check]=maps:get(checks,maps:get(runtime_diagnostics,R)),
    1=maps:get(failed,Check),1=maps:get(skipped,Check),
    {dirty,_}=efz_executor:runner_status(),io:put_chars("VERIFICATION_DIRTY_OK")
end).

guardian_failure_vm()->
    A=setup(),Parent=self(),
    spawn(fun()->Parent!{guardian_result,run(A,<<"waiting">>,500)} end),
    G=await_guardian(100),receive after 20->ok end,
    {monitors,Ms}=process_info(G,monitors),Pids=[P||{process,P}<-Ms,is_pid(P)],
    exit(G,test_guardian_failure),
    receive {guardian_result,R}->
        {infrastructure,#{kind:=dirty_runner}}=maps:get(outcome,R),
        false=maps:get(runner_reusable,R),
        {dirty,_}=efz_executor:runner_status()
    after 2000->error(no_guardian_result) end,
    %% Explicit TEST cleanup of survivors; this is not executor cleanup evidence.
    [exit(P,kill)||P<-Pids,P=/=self()],io:put_chars("GUARDIAN_FAILURE_OK").
await_guardian(0)->error(no_guardian);
await_guardian(N)->case whereis(efz_execution_guardian) of
    undefined->receive after 1->await_guardian(N-1) end;P->P end.

%% Artificially stalled sampler is stronger and more deterministic than scheduler luck.
overload_vm()->
    A=setup(),Parent=self(),Start=erlang:monotonic_time(millisecond),
    spawn(fun()->Parent!{overload_result,run(A,<<"waiting">>,150)} end),
    G=await_guardian(100),Sampler=await_sampler(G,100),
    true=erlang:suspend_process(Sampler),
    receive {overload_result,R}->
        {timeout,150}=maps:get(outcome,R),
        confirmed=maps:get(status,maps:get(cleanup,R)),
        true=erlang:monotonic_time(millisecond)-Start<1000,
        false=is_process_alive(Sampler),io:put_chars("OVERLOAD_OK")
    after 2000->error(sampler_delayed_deadline) end.
await_sampler(_,0)->error(no_sampler);
await_sampler(G,N)->
    {monitors,Ms}=process_info(G,monitors),
    case [P||{process,P}<-Ms,is_pid(P),case process_info(P,current_function) of
        {current_function,{efz_runtime,_,_}}->true;_->false end] of
        [P|_]->P;
        _->receive after 1->await_sampler(G,N-1) end
    end.
