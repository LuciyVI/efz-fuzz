-module(efz_phase3_tests).
-include_lib("eunit/include/eunit.hrl").
-export([run/1,mutate/2]).

phase3_test_()->{setup,fun setup/0,fun cleanup/1,fun(A)->[
    {"real deterministic operator discoveries and crash continuation",fun()->campaign(A) end},
    {"bounded trace does not change mutation choices",fun()->trace_independence(A) end},
    {"fresh VM regeneration and actual crash replay",fun()->fresh_replay(A) end},
    {"replay rejects incompatible builds and disposed plan options",fun()->replay_boundaries(A) end},
    {"no candidate is not a target execution",fun exhaustion/0},
    {"256 seeds reach productive bitflip after an unavailable dictionary lane",fun()->scheduler_progress(A) end},
    %% 5376 guarded executions (calibration + mutations), not a speed benchmark.
    {"finite deterministic exhaustion differs from the idle guard",{timeout,30,fun()->scheduler_exhaustion(A) end}},
    {"mutator exceptions are infrastructure failures",fun()->mutator_failure(A) end}
] end}.
setup()->
    _=code:purge(efz_staged_parser),_=code:delete(efz_staged_parser),
    {ok,Source}=file:read_file("examples/staged/efz_staged_parser.erl"),
    ?assertEqual(nomatch,binary:match(Source,<<"efz_cov">>)),
    {ok,A}=efz_instrument:compile("examples/staged/efz_staged_parser.erl",
        #{modules=>[efz_staged_parser],source_root=>".",outdir=>"_build/phase3-test-targets"}),A.
cleanup(_)->efz:stop(),_=code:purge(efz_staged_parser),_=code:delete(efz_staged_parser),ok.
configuration(A,Trace)->#{target=>efz_staged_parser,artifacts=>[A],seeds=>[<<0>>],
    mutation_mode=>staged,max_iterations=>200,
    crash_dir=>"_build/phase3-test-crashes-"++binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(6),lowercase)),
    max_input_bytes => 32, mutation => #{seed=>{17,23,41},max_block_bytes=>8,max_token_bytes=>8,
        dictionary=>[<<"TOKEN">>,<<"BOOM!">>],stages=>[dictionary_insert,boundary,arithmetic],trace_limit=>Trace}}.
run_campaign(C)->run_campaign(C,10000).
run_campaign(C,Wait)->{ok,_}=efz:start(C),try efz:await(Wait) after efz:stop() end.
campaign(A)->
    R=run_campaign(configuration(A,200)),#{status:=completed,stats:=St,mutation_stats:=Ms}=R,
    ?assertEqual(1,maps:get(calibrations,St)),?assertEqual(200,maps:get(executions,St)),
    ?assertEqual(200,maps:get(generated_candidates,Ms)),?assertEqual(0,maps:get(infrastructure_failures,St)),
    ?assert(maps:get(discoveries,St)>=3),?assert(maps:get(crashes,St)>0),?assert(maps:get(rejections,St)>0),
    lists:foreach(fun({Value,Stage,Tag})->
        [E]=[E||E<-maps:get(corpus,R),maps:get(outcome,maps:get(metadata,E),undefined)=:={ok,Value}],
        Meta=maps:get(metadata,E),Recipe=maps:get(mutation,Meta),
        ?assertEqual(new_coverage,maps:get(retention_reason,Meta)),
        ?assertEqual(Stage,maps:get(stage,Recipe)),
        ?assert(lists:any(fun(Op)->element(1,Op)=:=Tag end,maps:get(operations,Recipe))),
        ?assertEqual({ok,maps:get(input,E)},efz_recipe:regenerate(Recipe)),
        ?assert(maps:get(new_probes,Meta)=/= [])
    end,[{dictionary_token,dictionary_insert,dictionary_insert},{signed_boundary,boundary,set_integer}]),
    [_|_]=AfterCrash=lists:dropwhile(fun(D)->maps:get(retention_reason,D)=/=target_failure end,maps:get(decisions,R)),
    ?assert(lists:any(fun(D)->maps:get(retention_reason,D)=:=new_coverage end,AfterCrash)),
    [Crash|_]=maps:get(crashes,R),Recipe=maps:get(mutation,maps:get(metadata,Crash)),
    ?assertEqual({ok,maps:get(input,Crash)},efz_recipe:regenerate(Recipe)),
    ?assertEqual([],maps:get(new_probes,maps:get(metadata,Crash))),
    ?assertEqual(ok,maps:get(coverage_status,maps:get(result,Crash))),
    ?assertEqual([],ordsets:intersection(maps:get(coverage,R),maps:get(coverage,maps:get(result,Crash)))),
    ok=file:write_file("_build/phase3-acceptance.term",term_to_binary(R)).
trace_independence(A)->
    C=(configuration(A,0))#{max_iterations=>60,mutation=>(maps:get(mutation,configuration(A,0)))#{stages=>[havoc,splice,dictionary_insert]}},
    R1=run_campaign(C),_=rand:seed(exsplus,{5,6,7}),_=rand:uniform(),
    R2=run_campaign(C#{mutation=>(maps:get(mutation,C))#{trace_limit=>60}}),
    ?assertEqual([],maps:get(mutation_trace,R1)),?assertEqual(60,length(maps:get(mutation_trace,R2))),
    ?assertEqual(logical(R1),logical(R2)),
    %% An unrelated target process consuming rand cannot change the explicit stream.
    Manual=C#{target=>?MODULE,coverage=>manual},
    R3=run_campaign(Manual#{mutation=>(maps:get(mutation,Manual))#{trace_limit=>60}}),
    R4=run_campaign(Manual#{mutation=>(maps:get(mutation,Manual))#{trace_limit=>60}}),
    ?assertEqual(maps:get(mutation_trace,R3),maps:get(mutation_trace,R4)).
logical(R)->#{stats=>maps:remove(started_at,maps:get(stats,R)),mutation_stats=>maps:get(mutation_stats,R),
    inputs=>[maps:get(input,E)||E<-maps:get(corpus,R)],coverage=>maps:get(coverage,R),
    decisions=>[{maps:get(input_id,D),maps:get(retention_reason,D),maps:get(new_probes,D)}||D<-maps:get(decisions,R)]}.
saved_crash()->{ok,B}=file:read_file("_build/phase3-acceptance.term"),[C|_]=maps:get(crashes,binary_to_term(B)),C.
fresh_replay(A)->
    Crash=saved_crash(),Base=maps:get(path,Crash),Input=maps:get(input,Crash),
    Descriptor="_build/phase3-replay-artifact.term",ok=file:write_file(Descriptor,term_to_binary(A)),
    Eval=lists:flatten(io_lib:format(
      "{ok,AB}=file:read_file(~tp),A=binary_to_term(AB),{ok,R}=efz_recipe:load(~tp),{ok,B}=efz_recipe:regenerate(R),{ok,B}=file:read_file(~tp),{ok,E}=efz_replay:load(~tp),{ok,Result}=efz_recipe:execute(B,efz_staged_parser,[A],maps:get(target_builds,R),#{expected_harness=>maps:get(harness,E)}),{crash,error,artificial_staged_exception,_}=maps:get(outcome,Result),ok=maps:get(coverage_status,Result),io:format(\"replayed ~~B bytes~~n\",[byte_size(B)]),halt(0).",
      [Descriptor,Base++".recipe",Base++".input",Base++".replay"])),
    Port=open_port({spawn_executable,os:find_executable("erl")},[binary,exit_status,stderr_to_stdout,
        {args,["+S","2:2","-noshell","-pa",filename:dirname(code:which(efz_recipe)),"-eval",Eval]}]),
    {Status,Output}=port_result(Port,<<>>),?assertEqual(0,Status),
    ?assertNotEqual(nomatch,binary:match(Output,list_to_binary("replayed "++integer_to_list(byte_size(Input))++" bytes"))),
    ok=file:write_file("_build/phase3-fresh-replay.txt",Output).
replay_boundaries(A)->
    Crash=saved_crash(),Recipe=maps:get(mutation,maps:get(metadata,Crash)),Input=maps:get(input,Crash),
    Bs=maps:get(target_builds,Recipe),{ok,E}=efz_replay:load(maps:get(path,Crash)++".replay"),H=maps:get(harness,E),{ok,Manifests}=efz_instrument:preflight([A]),
    {ok,Plan}=efz_cov_manifest:prepare(automatic,Manifests),ok=efz_cov_manifest:release(Plan),
    ?assertEqual({ok,Input},efz_recipe:regenerate(Recipe)),
    ?assertEqual({error,unsupported_replay_options},efz_recipe:execute(Input,efz_staged_parser,[A],Bs,#{coverage_plan=>Plan})),
    [{M,_}]=Bs,?assertEqual({error,replay_build_mismatch},efz_recipe:execute(Input,efz_staged_parser,[A],[{M,<<0:256>>}],#{})),
    ?assertMatch({error,_},efz_recipe:execute(Input,efz_staged_parser,[],Bs,#{})),
    {ok,Result}=efz_recipe:execute(Input,efz_staged_parser,[A],Bs,#{coverage_backend=>ets_member,expected_harness=>H}),
    ?assertMatch({crash,error,artificial_staged_exception,_},maps:get(outcome,Result)),
    Raw="_build/phase3-authoritative.input",Bad="_build/phase3-corrupt.recipe",
    ok=file:write_file(Raw,Input),ok=file:write_file(Bad,<<"corrupt">>),
    ?assertMatch({error,_},efz_recipe:load(Bad)),
    ?assertMatch({ok,#{outcome:={crash,error,artificial_staged_exception,_}}},efz_recipe:execute_file(Raw,efz_staged_parser,[A],Bs,#{expected_harness=>H})).
exhaustion()->
    R=run_campaign(#{target=>?MODULE,coverage=>manual,seeds=>[<<>>],max_iterations=>100,mutation_mode=>staged,
        mutation=>#{seed=>{1,2,3},stages=>[splice],max_idle_visits=>3}}),
    ?assertEqual({mutation_stopped,idle_budget_exhausted},maps:get(status,R)),
    ?assertEqual(0,maps:get(executions,maps:get(stats,R))),?assertEqual(1,maps:get(calibrations,maps:get(stats,R))),
    ?assertEqual(3,maps:get(visits,maps:get(mutation_stats,R))).
scheduler_progress(A)->
    R=run_campaign(#{target=>efz_staged_parser,artifacts=>[A],
        seeds=>[<<I>>||I<-lists:seq(0,255)],mutation_mode=>staged,max_iterations=>256,
        timeout=>1000,mutation=>#{seed=>{17,23,41},stages=>[dictionary_overwrite,bitflip],
            dictionary=>[<<"AB">>],trace_limit=>256}}),
    ?assertEqual(completed,maps:get(status,R)),
    St=maps:get(stats,R),Ms=maps:get(mutation_stats,R),Trace=maps:get(mutation_trace,R),
    ?assertEqual(256,maps:get(max_idle_visits,maps:get(mutation,R))),
    ?assertEqual(256,maps:get(calibrations,St)),
    ?assertEqual(256,maps:get(executions,St)),
    ?assertEqual(256,maps:get(generated_candidates,Ms)),
    ?assert(maps:get(skipped_candidates,Ms)>=256),
    ?assertEqual(0,maps:get(infrastructure_failures,St)),
    ?assertEqual([bitflip],lists:usort([maps:get(stage,P)||P<-Trace])),
    ?assertEqual(lists:seq(1,256),[maps:get(parent,P)||P<-Trace]),
    ok=file:write_file("_build/scheduler-progress.term",term_to_binary(R)).
scheduler_exhaustion(A)->
    R=run_campaign(#{target=>efz_staged_parser,artifacts=>[A],
        seeds=>[<<I>>||I<-lists:seq(0,255)],mutation_mode=>staged,max_iterations=>10000,
        timeout=>1000,mutation=>#{seed=>{17,23,41},stages=>[bitflip],max_idle_visits=>1}},25000),
    ?assertEqual({mutation_exhausted,mutation_exhausted},maps:get(status,R)),
    ?assertEqual(5120,maps:get(executions,maps:get(stats,R))),
    ?assertEqual(5120,maps:get(generated_candidates,maps:get(mutation_stats,R))),
    ?assertEqual(0,maps:get(infrastructure_failures,maps:get(stats,R))).
mutator_failure(A)->
    R=run_campaign(#{target=>efz_staged_parser,artifacts=>[A],seeds=>[<<0>>],mutator=>?MODULE,max_iterations=>1}),
    ?assertMatch({infrastructure_failure,_},maps:get(status,R)),
    ?assertEqual(1,maps:get(infrastructure_failures,maps:get(stats,R))),
    ?assertEqual(0,maps:get(crashes,maps:get(stats,R))),?assertEqual(0,maps:get(executions,maps:get(stats,R))).
run(B)->_=rand:uniform(),B.
mutate(_,_) -> error(artificial_mutator_failure).
port_result(P,Acc)->receive {P,{data,B}}->port_result(P,<<Acc/binary,B/binary>>);{P,{exit_status,N}}->{N,Acc}
    after 4000->port_close(P),error(replay_vm_timeout) end.
