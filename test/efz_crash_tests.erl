-module(efz_crash_tests).
-include_lib("eunit/include/eunit.hrl").

crash_test_()->{setup,fun setup/0,fun cleanup/1,fun(S)->[
    {"different inputs are separate occurrences of one signature",fun()->occurrences(S) end},
    {"reason policy is configurable and runtime identities are normalized",fun()->reason_policy(S) end},
    {"same bug after real source relocation has the same signature",fun()->relocation(S) end},
    {"1000 real staged crashes keep reports and disk bounded",{timeout,60,fun()->bounded(S) end}},
    {"fresh VM raw and recipe execution verify identities and reproduce",fun()->fresh(S) end},
    {"raw input survives a missing or corrupt recipe and raw diagnostics",fun()->raw_authoritative(S) end},
    {"invalid recipe still persists exact raw input and reports infrastructure",fun()->bad_recipe(S) end},
    {"target build mismatch and harness mismatch reject before execution",fun()->mismatch(S) end},
    {"not reproduced and infrastructure failures use different CLI exits",fun()->classifications(S) end},
    {"missing expectation and corrupted raw bytes reject",fun()->corruption(S) end},
    {"real coordinator death remains primary despite a disposed plan",fun()->coordinator_down(S) end},
    {"worker death reports infrastructure count and triggering bytes",fun()->worker_down(S) end},
    {"secondary failures cannot replace primary stats reason",fun stats_primary/0}
] end}.
setup()->
    Base=filename:absname("_build/crash-test-"++hex(crypto:strong_rand_bytes(6))),
    lists:foreach(fun unload/1,[efz_crash_target,efz_crash_harness]),
    Artifacts=[begin
        Dir=Base++"/"++Name,ok=filelib:ensure_dir(Dir++"/placeholder"),
        {ok,A}=efz_instrument:compile("fixtures/efz_crash_target.erl",
            #{modules=>[efz_crash_target],source_root=>".",outdir=>Dir,erl_opts=>Opts}),A
    end||{Name,Opts}<-[{"instrumented",[]},{"different",[{d,'ALTERNATE'}]}]],
    [A,B]=Artifacts,
    lists:foreach(fun({Name,Opts})->
        Dir=Base++"/"++Name,ok=filelib:ensure_dir(Dir++"/placeholder"),
        {ok,efz_crash_harness}=compile:noenv_file("fixtures/efz_crash_harness.erl",[debug_info,{outdir,Dir}|Opts])
    end,[{"harness",[]},{"different-harness",[{d,'ALTERNATE'}]}]),
    true=code:add_patha(Base++"/harness"),{module,efz_crash_harness}=code:ensure_loaded(efz_crash_harness),
    {ok,Ms}=efz_instrument:preflight([A]),
    %% Fresh CLI VMs resolve this exact test-profile build from a private package.
    Script=Base++"/tool/scripts/replay.escript",ok=filelib:ensure_dir(Script),
    {ok,_}=file:copy("scripts/replay.escript",Script),
    Ebin=Base++"/tool/_build/default/lib/efz/ebin",ok=filelib:ensure_dir(Ebin++"/placeholder"),
    lists:foreach(fun(P)->{ok,_}=file:copy(P,Ebin++"/"++filename:basename(P)) end,
        filelib:wildcard(filename:dirname(code:which(efz_replay))++"/*.beam")),
    #{base=>Base,artifact=>A,alternate=>B,manifests=>Ms,script=>Script}.
cleanup(S)->efz:stop(),lists:foreach(fun unload/1,[efz_crash_target,efz_crash_harness]),
    true=code:del_path(maps:get(base,S)++"/harness"),ok.
unload(M)->_=code:purge(M),_=code:delete(M),_=code:purge(M),ok.
hex(B)->binary_to_list(binary:encode_hex(B,lowercase)).
config(S,Name,Extra)->maps:merge(#{target=>efz_crash_harness,artifacts=>[maps:get(artifact,S)],
    seeds=>[<<"a">>],max_iterations=>0,timeout=>1000,crash_dir=>maps:get(base,S)++"/"++Name},Extra).
campaign(S,Name,C)->{ok,_}=efz:start(config(S,Name,C)),try efz:await(50000) after efz:stop() end.
occurrences(S)->
    R=campaign(S,"occurrences",#{seeds=>[<<"a">>,<<"b">>]}),[G]=maps:get(crashes,R),
    ?assertEqual(2,maps:get(occurrences,G)),?assertEqual(2,maps:get(crash_occurrences,maps:get(stats,R))),
    ?assertEqual(1,maps:get(unique_crashes,maps:get(stats,R))),
    [A,B]=maps:get(representatives,G),?assertNotEqual(maps:get(occurrence_id,A),maps:get(occurrence_id,B)),
    ?assertNotEqual(maps:get(input_hash,A),maps:get(input_hash,B)),
    ?assertEqual(maps:get(signature_id,A),maps:get(signature_id,B)),
    [begin P=maps:get(path,C),ok=efz_fs:validate_group(filename:dirname(P)),
        ?assertEqual({ok,maps:get(input,C)},file:read_file(P++".input")),
        {ok,Raw}=file:read_file(P++".term"),D=binary_to_term(Raw),
        ?assertEqual(maps:get(result,C),maps:get(result,D)),
        ?assertMatch({crash,error,{parser_failure,_},[_|_]},maps:get(outcome,maps:get(result,D)))
    end||C<-[A,B]],ok.
reason_policy(S)->
    Stack=[{parser,parse,[<<"raw arg">>],[{file,"/one/tree/parser.erl"},{line,8}]},
           {harness,run,1,[]},{efz_executor,invoke,4,[]}],
    Other=[{parser,parse,1,[{file,"/other/tree/parser.erl"},{line,999}]},{harness,run,1,[]}],
    ?assertEqual(efz_crash:fingerprint(error,{badmatch,<<"A">>},Stack),
        efz_crash:fingerprint(error,{badmatch,<<"B">>},Other)),
    Exact=(efz_crash:defaults())#{reason=>exact},
    ?assertNotEqual(sig({badmatch,<<"A">>},Stack,Exact),sig({badmatch,<<"B">>},Other,Exact)),
    ?assertEqual(sig({error,self(),make_ref()},Stack,Exact),sig({error,self(),make_ref()},Other,Exact)),
    Ignore=Exact#{reason=>ignore,max_frames=>1},
    ?assertEqual(sig({different_tag,1},Stack,Ignore),sig(unknown,Other,Ignore)),
    ?assertMatch({error,_},efz_config:prepare(config(S,"invalid",#{crash_policy=>#{unknown=>true}}))),
    R=campaign(S,"exact",#{seeds=>[<<"a">>,<<"b">>],crash_policy=>#{reason=>exact}}),
    ?assertEqual(2,maps:get(unique_crashes,maps:get(stats,R))).
sig(Reason,Stack,P)->element(1,efz_crash:signature({crash,error,Reason,Stack},P)).
relocation(S)->
    Root=maps:get(base,S)++"/relocated",ok=filelib:ensure_dir(Root++"/placeholder"),
    {ok,_}=file:copy("fixtures/efz_crash_target.erl",Root++"/efz_crash_target.erl"),
    [G1]=maps:get(crashes,campaign(S,"before-relocation",#{})),
    {ok,A}=efz_instrument:compile(Root++"/efz_crash_target.erl",
        #{modules=>[efz_crash_target],source_root=>Root,outdir=>Root++"/instrumented"}),
    unload(efz_crash_target),
    try [G2]=maps:get(crashes,campaign(S,"after-relocation",#{artifacts=>[A]})),
        ?assertEqual(maps:get(signature_id,G1),maps:get(signature_id,G2)),
        ?assertNotEqual(maps:get(outcome,maps:get(result,G1)),maps:get(outcome,maps:get(result,G2)))
    after unload(efz_crash_target),{ok,_}=efz_instrument:preflight([maps:get(artifact,S)]) end.
bounded(S)->
    R=campaign(S,"bounded",#{seeds=>[binary:copy(<<0>>,128)],mutation_mode=>staged,max_iterations=>999,
        mutation=>#{stages=>[bitflip],trace_limit=>0},crash_policy=>#{max_representatives=>3}}),
    ?assertEqual(completed,maps:get(status,R)),[G]=maps:get(crashes,R),
    ?assertEqual(1000,maps:get(occurrences,G)),?assertEqual(1000,maps:get(crash_occurrences,maps:get(stats,R))),
    ?assertEqual(1,maps:get(unique_crashes,maps:get(stats,R))),
    ?assertEqual(3,length(maps:get(representatives,G))),?assertEqual(3,length(maps:get(decisions,R))),
    ?assert(erlang:external_size(R)<100000),
    Files=filelib:wildcard(maps:get(base,S)++"/bounded/*/*/artifact.input"),?assertEqual(3,length(Files)),
    {ok,Index}=efz_crash_store:read(maps:get(group_path,G)),
    ?assertEqual(1000,maps:get(occurrences,Index)),?assertEqual(1000,maps:get(durable_occurrences,G)),
    ?assertEqual(3,maps:get(disk_representatives,G)),
    ok=file:write_file(maps:get(base,S)++"/bounded-report.term",term_to_binary(R)).
saved(S)->
    R=campaign(S,"fresh-"++hex(crypto:strong_rand_bytes(6)),#{seeds=>[<<"OK">>],mutation_mode=>staged,max_iterations=>1,
        mutation=>#{stages=>[bitflip],trace_limit=>0}}),[G]=maps:get(crashes,R),G.
cli(S,C,Kind,Changes,Env)->
    Suffix=case Kind of raw->".input";recipe->".recipe" end,
    Flag=case Kind of raw->"--input";recipe->"--recipe" end,
    Args=maps:merge(#{Flag=>maps:get(path,C)++Suffix,"--target"=>"efz_crash_harness",
        "--code-path"=>maps:get(base,S)++"/harness","--artifacts"=>maps:get(base,S)++"/instrumented"},Changes),
    P=open_port({spawn_executable,os:find_executable("escript")},[binary,exit_status,stderr_to_stdout,
        {env,[{"ERL_FLAGS","+S 2:2"},{"EFZ_REPLAY_TEST_RESULT",Env}]},
        {args,[maps:get(script,S)|lists:append([[K,V]||{K,V}<-lists:sort(maps:to_list(Args)),V=/=undefined])]}]),
    collect(P,<<>>).
collect(P,B)->receive {P,{data,D}}->collect(P,<<B/binary,D/binary>>);{P,{exit_status,N}}->{N,B}
    after 5000->port_close(P),error({replay_vm_timeout,B}) end.
fresh(S)->C=saved(S),
    lists:foreach(fun(K)->{Status,O}=cli(S,C,K,#{},false),?assertEqual(0,Status),
        ?assertMatch({0,_},binary:match(O,<<"reproduced; build/harness compatibility verified">>)),
        ?assertNotEqual(nomatch,binary:match(O,binary:encode_hex(maps:get(input_hash,C),lowercase))),
        ok=file:write_file(maps:get(base,S)++"/"++atom_to_list(K)++"-replay.log",O)
    end,[raw,recipe]).
raw_authoritative(S)->C=saved(S),P=maps:get(path,C),
    ok=file:write_file(P++".recipe",<<"corrupt">>),ok=file:write_file(P++".term",<<"truncated">>),
    {0,_}=cli(S,C,raw,#{},false),
    {2,_}=cli(S,C,recipe,#{},false),ok=file:delete(P++".recipe"),{0,_}=cli(S,C,raw,#{},false).
bad_recipe(S)->
    {ok,Prepared}=efz_config:prepare(config(S,"bad-recipe",#{})),
    R=efz_executor:run(efz_crash_harness,<<"raw">>,1000,Prepared),
    {error,E}=efz_crash:save(<<"raw">>,R,#{mutation=>bad_recipe},config(S,"bad-recipe",#{})),
    ?assertMatch(#{operation:=encode_recipe,saved_artifact:=_},E),
    P=maps:get(saved_artifact,E),?assertEqual({ok,<<"raw">>},file:read_file(P++".input")),
    {0,_}=cli(S,#{path=>P},raw,#{},false).
mismatch(S)->C=saved(S),
    {2,Build}=cli(S,C,raw,#{"--artifacts"=>maps:get(base,S)++"/different"},false),
    ?assertNotEqual(nomatch,binary:match(Build,<<"replay_build_mismatch">>)),
    {2,Harness}=cli(S,C,raw,#{"--code-path"=>maps:get(base,S)++"/different-harness"},false),
    ?assertNotEqual(nomatch,binary:match(Harness,<<"replay_harness_mismatch">>)),
    ?assertEqual({error,missing_expected_harness_identity},efz_recipe:execute(<<"x">>,efz_crash_harness,
        [maps:get(artifact,S)],efz_recipe:build_ids(maps:get(builds,maps:get(result,C))),#{})).
classifications(S)->C=saved(S),
    [{3,O1},{3,O2},{1,O3}]=[cli(S,C,raw,#{},V)||V<-["ok","different","infrastructure"]],
    [?assertNotEqual(nomatch,binary:match(O,<<"not-reproduced">>))||O<-[O1,O2]],
    ?assertNotEqual(nomatch,binary:match(O3,<<"replay_test_infrastructure">>)).
corruption(S)->C=saved(S),P=maps:get(path,C),
    {1,MissingDir}=cli(S,C,raw,#{"--artifacts"=>maps:get(base,S)++"/absent"},false),
    ?assertNotEqual(nomatch,binary:match(MissingDir,<<"artifact_directory">>)),
    ok=file:change_mode(P++".input",0),
    try {1,Denied}=cli(S,C,raw,#{},false),?assertNotEqual(nomatch,binary:match(Denied,<<"eacces">>))
    after ok=file:change_mode(P++".input",8#600) end,
    ok=file:write_file(P++".input",<<"different">>),{2,O}=cli(S,C,raw,#{},false),
    ?assertNotEqual(nomatch,binary:match(O,<<"replay_input_hash_mismatch">>)),
    ok=file:write_file(P++".replay",<<"truncated">>),{2,_}=cli(S,C,raw,#{},false),
    ok=file:delete(P++".replay"),{1,_}=cli(S,C,raw,#{},false).
coordinator_down(S)->
    Parent=self(),true=register(efz_crash_observer,self()),
    {Owner,OMon}=spawn_monitor(fun()->{ok,P}=efz_cov_manifest:prepare(automatic,maps:get(manifests,S)),Parent!{plan,P},receive stop->ok end end),
    Plan=receive {plan,P}->P end,
    {Caller,CMon}=spawn_monitor(fun()->Parent!{result,efz_executor:run(efz_crash_harness,<<"WAIT">>,3000,#{coverage=>automatic,coverage_plan=>Plan})} end),
    try
        Root=receive {ready,R}->R after 2000->error(no_ready) end,
        G=whereis(efz_execution_guardian),{monitors,Ms}=process_info(G,monitors),
        [C]=[Pid||{process,Pid}<-Ms,process_info(Pid,current_function)=:={current_function,{efz_executor,coordinate,1}}],
        Owner!stop,receive {'DOWN',OMon,process,Owner,normal}->ok end,exit(C,kill),
        Result=receive {result,X}->X after 3000->error(no_result) end,
        receive {'DOWN',CMon,process,Caller,normal}->ok end,
        ?assertEqual({infrastructure,{coordinator_down,killed}},maps:get(outcome,Result)),
        ?assertEqual({error,invalid_coverage_plan},maps:get(coverage_status,Result)),
        ?assertNot(is_process_alive(Root)),
        F=efz_feedback:new(maps:get(builds,Result)),
        ?assertEqual({error,{infrastructure,{coordinator_down,killed}}},efz_feedback:evaluate(F,Result#{builds=>#{}},mutation))
    after unregister(efz_crash_observer),exit(Owner,kill),demonitor(OMon,[flush]) end.
worker_down(S)->
    true=register(efz_crash_observer,self()),
    try {ok,_}=efz:start(config(S,"worker-down",#{seeds=>[<<"WAIT">>],timeout=>3000})),
        Root=receive {ready,P}->P after 2000->error(no_ready) end,
        G=whereis(efz_execution_guardian),GM=monitor(process,G),RM=monitor(process,Root),
        [{efz_worker,W,worker,_}]=supervisor:which_children(efz_worker_sup),exit(W,kill),
        Report=efz:await(5000),?assertEqual({infrastructure_failure,{worker_down,killed}},maps:get(status,Report)),
        ?assertEqual(1,maps:get(infrastructure_failures,maps:get(stats,Report))),
        ?assertMatch(#{input:=<<"WAIT">>},maps:get(failure_context,Report)),
        receive {'DOWN',RM,process,Root,_}->ok after 2000->error(root_alive) end,
        receive {'DOWN',GM,process,G,_}->ok after 2000->error(guardian_alive) end
    after efz:stop(),unregister(efz_crash_observer) end.
stats_primary()->
    {ok,P}=efz_stats:start_link(),try
        First=#{kind=>filesystem,operation=>write,reason=>enospc},
        ?assertEqual(First,efz_stats:failure(First)),?assertEqual(First,efz_stats:failure({worker_down,killed})),
        ?assertEqual(2,maps:get(infrastructure_failures,efz_stats:get()))
    after gen_server:stop(P) end.
