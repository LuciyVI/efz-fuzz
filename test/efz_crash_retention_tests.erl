-module(efz_crash_retention_tests).
-include_lib("eunit/include/eunit.hrl").
-export([fresh/2, late_guardian_exit/0]).

retention_test_()->{setup,fun setup/0,fun(_)->efz:stop() end,fun(S)->[
    {"disk cap, duplicates, exact representative Reason and counter",fun()->bounded(S) end},
    {"disk policy survives a fresh VM and campaign restart",fun()->fresh_vm(S,retention) end},
    {"corrupt summary or representative cannot reset the cap",fun()->corruption(S) end},
    {"summary commit failure preserves the committed raw artifact",fun()->commit_failure(S) end},
    {"interrupted and concurrent writers fail closed",fun()->interrupted(S) end},
    {"late guardian death preserves primary result, report, stats and retirement",fun()->fresh_vm(S,late_guardian) end}
] end}.
setup()->
    Base=filename:absname("_build/retention-test-"++hex(crypto:strong_rand_bytes(6))),
    {ok,A}=efz_instrument:compile("fixtures/efz_crash_target.erl",
        #{modules=>[efz_crash_target],source_root=>".",outdir=>Base++"/target"}),
    ok=filelib:ensure_dir(Base++"/harness/placeholder"),
    {ok,efz_crash_harness}=compile:noenv_file("fixtures/efz_crash_harness.erl",[debug_info,{outdir,Base++"/harness"}]),
    ok=file:write_file(Base++"/artifact.term",term_to_binary(A)),Base.
hex(B)->binary_to_list(binary:encode_hex(B,lowercase)).
result(B)->#{outcome=>{crash,error,{same_bug,B},[{parser,run,1,[{file,"/raw/path.erl"},{line,19}]}]}}.
opts(S,Name)->#{crash_dir=>S++"/"++Name,crash_policy=>#{max_representatives=>2}}.
save(S,Name,B)->efz_crash:save(B,result(B),#{},opts(S,Name)).
bounded(S)->
    {ok,A}=save(S,"bounded",<<"A">>),{ok,Dup}=save(S,"bounded",<<"A">>),
    {ok,B}=save(S,"bounded",<<"B">>),{ok,C}=save(S,"bounded",<<"C">>),
    ?assertEqual([saved,duplicate,saved,limit_reached],[maps:get(storage,X)||X<-[A,Dup,B,C]]),
    ?assertEqual(maps:get(path,A),maps:get(path,Dup)),
    ?assertEqual(maps:get(occurrence_id,A),maps:get(representative_occurrence_id,Dup)),
    ?assertNotEqual(maps:get(occurrence_id,A),maps:get(occurrence_id,Dup)),
    ?assertNot(maps:is_key(path,C)),
    Group=maps:get(group_path,A),{ok,Index}=efz_crash_store:read(Group),
    ?assertEqual(4,maps:get(occurrences,Index)),?assertEqual(2,length(maps:get(representatives,Index))),
    ?assertEqual(2,length(filelib:wildcard(Group++"/*/artifact.input"))),
    {ok,Raw}=file:read_file(maps:get(path,A)++".term"),
    ?assertEqual(result(<<"A">>),maps:get(result,binary_to_term(Raw))),
    %% A lower limit must not silently delete or ignore existing representatives.
    ?assertMatch({error,#{reason:={representative_limit_below_existing,2,1}}},
        efz_crash:save(<<"D">>,result(<<"D">>),#{},(opts(S,"bounded"))#{crash_policy=>#{max_representatives=>1}})).
corruption(S)->
    {ok,A}=save(S,"corrupt-summary",<<"A">>),Path=maps:get(group_path,A)++"/summary",
    ok=file:write_file(Path,<<"truncated">>),
    ?assertMatch({error,#{reason:=invalid_crash_summary}},save(S,"corrupt-summary",<<"B">>)),
    {ok,B}=save(S,"missing-summary",<<"A">>),ok=file:delete(maps:get(group_path,B)++"/summary"),
    ?assertMatch({error,#{reason:={unindexed_crash_group,_}}},save(S,"missing-summary",<<"B">>)),
    {ok,C}=save(S,"corrupt-input",<<"A">>),ok=file:write_file(maps:get(path,C)++".input",<<"changed">>),
    ?assertMatch({error,#{kind:=filesystem}},save(S,"corrupt-input",<<"B">>)).
commit_failure(S)->
    O=opts(S,"commit-failure"),I=efz_crash:identify(<<"A">>,result(<<"A">>),efz_crash:defaults()),
    %% Use real filesystem operations to fail summary rename after a complete
    %% representative commit. The old summary must remain authoritative.
    Write=fun(Group,Name)->
        {ok,P}=efz_fs:atomic_group(Group,Name,[{"artifact.input",<<"A">>},{"artifact.term",<<"raw">>}]),
        ok=file:make_dir(Group++"/summary"),{ok,P++"/artifact"}
    end,
    {error,E}=efz_crash_store:save(maps:get(crash_dir,O),I,2,Write),
    ?assertMatch(#{kind:=filesystem,operation:=rename,saved_artifact:=_},E),
    ?assertEqual({ok,<<"A">>},file:read_file(maps:get(saved_artifact,E)++".input")),
    ?assertNot(filelib:is_dir(filename:dirname(filename:dirname(maps:get(saved_artifact,E)))++"/.lock")).
interrupted(S)->
    Dir=maps:get(crash_dir,opts(S,"interrupted")),
    I=efz_crash:identify(<<"A">>,result(<<"A">>),efz_crash:defaults()),Parent=self(),
    {Writer,Mon}=spawn_monitor(fun()->efz_crash_store:save(Dir,I,2,fun(Group,_)->
        Parent!{locked,Group},receive never->error(unreachable) end end) end),
    Group=receive {locked,G}->G after 1000->error(no_lock) end,
    ?assertMatch({error,#{reason:=writer_active_or_interrupted}},save(S,"interrupted",<<"B">>)),
    exit(Writer,kill),receive {'DOWN',Mon,process,Writer,killed}->ok end,
    ?assertMatch({error,#{reason:=writer_active_or_interrupted}},save(S,"interrupted",<<"B">>)),
    ?assertEqual([],filelib:wildcard(Group++"/*/artifact.input")),
    %% A committed representative without summary must not be mistaken for a
    %% new empty group after someone removes a stale lock.
    Orphan=S++"/orphan",Id=hex(maps:get(signature_id,I)),
    {ok,_}=efz_fs:atomic_group(Orphan++"/"++Id,hex(maps:get(occurrence_id,I)),
        [{"artifact.input",<<"A">>},{"artifact.term",<<"raw">>}]),
    ?assertMatch({error,#{reason:={unindexed_crash_group,_}}},save(S,"orphan",<<"B">>)).

fresh_vm(S,Mode)->
    case Mode of
        retention->[G]=maps:get(crashes,campaign(S,[<<"a">>,<<"b">>])),
            ?assertEqual(2,maps:get(durable_occurrences,G));
        _->ok
    end,
    Eval=lists:flatten(io_lib:format("efz_crash_retention_tests:fresh(~p,~tp),halt().",[Mode,S])),
    Port=open_port({spawn_executable,os:find_executable("erl")},[binary,exit_status,stderr_to_stdout,
        {args,["+S","2:2","-noshell","-pa",filename:dirname(code:which(?MODULE)),
            filename:dirname(code:which(efz)),"-eval",Eval]}]),
    {Status,Output}=collect(Port,<<>>),
    ok=file:write_file(S++"/"++atom_to_list(Mode)++".log",Output),?assertEqual({Mode,0},{Mode,Status}).
collect(P,B)->receive {P,{data,D}}->collect(P,<<B/binary,D/binary>>);{P,{exit_status,S}}->{S,B}
    after 10000->port_close(P),error({fresh_vm_timeout,B}) end.
fresh(retention,S)->
    %% bounded/1 ran in the previous VM. The cap must apply to the same disk
    %% group, not restart at zero with the new caller's in-memory crash groups.
    {ok,C}=save(S,"bounded",<<"C">>),?assertEqual(limit_reached,maps:get(storage,C)),
    {ok,A}=save(S,"bounded",<<"A">>),?assertEqual(duplicate,maps:get(storage,A)),
    ?assertEqual(6,maps:get(durable_occurrences,A)),?assertEqual(2,maps:get(disk_representatives,A)),
    ?assertEqual({ok,<<"A">>},file:read_file(maps:get(path,A)++".input")),
    R=campaign(S,[<<"c">>,<<"a">>]),[G]=maps:get(crashes,R),
    ?assertEqual(completed,maps:get(status,R)),?assertEqual(2,maps:get(occurrences,G)),
    ?assertEqual(4,maps:get(durable_occurrences,G)),?assertEqual(2,maps:get(disk_representatives,G)),
    ?assertEqual(2,length(filelib:wildcard(maps:get(group_path,G)++"/*/artifact.input"))),
    [Rep]=[X||X<-maps:get(representatives,G),maps:get(storage,X)=:=duplicate],
    {ok,E}=efz_replay:load(maps:get(path,Rep)++".replay"),
    {ok,AB}=file:read_file(S++"/artifact.term"),Artifact=binary_to_term(AB),
    ?assertMatch({ok,#{status:=reproduced}},efz_replay:run(raw,maps:get(path,Rep)++".input",
        efz_crash_harness,[Artifact],E,#{})),
    io:format("fresh VM: direct saves 6 occurrences / 2 representatives; campaigns 4 / 2~n");
fresh(late_guardian,S)->late_guardian(S).
campaign(S,Seeds)->
    true=code:add_patha(S++"/harness"),{ok,B}=file:read_file(S++"/artifact.term"),A=binary_to_term(B),
    try {ok,_}=efz:start(#{target=>efz_crash_harness,artifacts=>[A],seeds=>Seeds,max_iterations=>0,
        crash_policy=>#{max_representatives=>2},crash_dir=>S++"/campaign"}),efz:await(5000)
    after efz:stop(),code:del_path(S++"/harness") end.

late_guardian(S)->
    true=code:add_patha(S++"/harness"),{ok,B}=file:read_file(S++"/artifact.term"),A=binary_to_term(B),
    %% Fault injection in a private VM only: insert a gate immediately AFTER
    %% the real guardian reply. All lifecycle, executor and campaign code runs.
    %% No production option/hook, fabricated result or replacement executor.
    {ok,Forms}=epp:parse_file("src/efz_guardian.erl",[],[]),
    Patched=[case F of
        {function,L,reply,3,Cs}->{function,L,reply,3,[begin
            {clause,CL,Args,Guards,[Send|Rest]}=C,
            Gate={call,CL,{remote,CL,{atom,CL,?MODULE},{atom,CL,late_guardian_exit}},[]},
            {clause,CL,Args,Guards,[Send,Gate|Rest]}
        end||C<-Cs]};_->F end||F<-Forms],
    {ok,efz_guardian,Beam}=compile:forms(Patched,[binary,debug_info]),
    {module,efz_guardian}=code:load_binary(efz_guardian,"late-guardian-injection",Beam),
    true=register(efz_crash_observer,self()),
    {ok,_}=efz:start(#{target=>efz_crash_harness,artifacts=>[A],seeds=>[<<"WAIT">>],
        max_iterations=>0,timeout=>3000,crash_dir=>S++"/late"}),
    try
        Root=receive {ready,P}->P after 1000->error(no_target) end,
        G=whereis(efz_execution_guardian),{monitors,Ms}=process_info(G,monitors),
        [Coordinator]=[P||{process,P}<-Ms,process_info(P,current_function)=:={current_function,{efz_executor,coordinate,1}}],
        exit(Coordinator,kill),
        receive {guardian_replied,G}->ok after 2000->error(no_guardian_reply) end,
        ?assertNot(is_process_alive(Root)),
        [{efz_worker,Worker,worker,_}]=supervisor:which_children(efz_worker_sup),
        ?assertEqual({current_function,{efz_executor,run_pinned,4}},process_info(Worker,current_function)),
        G!die,
        Report=efz:await(5000),Primary={infrastructure,{coordinator_down,killed}},
        ?assertEqual({infrastructure_failure,Primary},maps:get(status,Report)),
        Stats=maps:get(stats,Report),?assertEqual(1,maps:get(infrastructure_failures,Stats)),
        ?assertEqual(Primary,maps:get(primary_infrastructure_failure,Stats)),
        #{input:=<<"WAIT">>,result:=R}=maps:get(failure_context,Report),
        ?assertEqual({infrastructure,{coordinator_down,killed}},maps:get(outcome,R)),
        ?assertMatch(#{reason:={guardian_down,injected_after_reply}},maps:get(guardian_failure,R)),
        ?assertEqual(false,maps:get(runner_reusable,R)),
        ?assertEqual(unconfirmed,maps:get(status,maps:get(cleanup,R))),
        ?assertEqual(confirmed,maps:get(status,maps:get(cleanup,maps:get(execution_evidence,R)))),
        ?assertMatch({dirty,_},efz_executor:runner_status()),
        %% Disable the test gate for subsequent rejection, then prove no reuse.
        unregister(efz_crash_observer),
        Next=efz_executor:run(efz_crash_harness,<<"OK">>,100,#{coverage=>manual}),
        ?assertMatch({infrastructure,#{kind:=dirty_runner}},maps:get(outcome,Next)),
        ?assertEqual(not_started,maps:get(status,maps:get(cleanup,Next))),
        io:format("late guardian: primary=~tp, secondary=~tp, no reuse~n",[Primary,maps:get(guardian_failure,R)])
    after efz:stop(),_=catch unregister(efz_crash_observer) end.
late_guardian_exit()->case whereis(efz_crash_observer) of
    undefined->ok;
    P->P!{guardian_replied,self()},receive die->exit(injected_after_reply) end
end.
