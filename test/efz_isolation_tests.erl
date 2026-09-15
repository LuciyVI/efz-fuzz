-module(efz_isolation_tests).
-include_lib("eunit/include/eunit.hrl").
-export([fresh/2]).

isolation_test_() -> {setup,fun setup/0,fun cleanup/1,fun(S)->[
    {"normal root",fun()->check(S,<<"normal">>,{ok,ok},1) end},
    {"crashed root",fun()->R=check(S,<<"crash">>,crash,1),?assertMatch({crash,error,isolation_crash,_},maps:get(outcome,R)) end},
    {"root timeout",fun()->check(S,<<"timeout">>,{timeout,30},1) end},
    {"root traps exit but kill still terminates",fun()->check(S,<<"trap_exit">>,{timeout,30},1) end},
    {"linked child with trap_exit is reaped",fun()->check(S,<<"linked">>,{ok,ok},2) end},
    {"unlinked child is reaped",fun()->check(S,<<"unlinked">>,{ok,ok},2) end},
    {"nested descendants share exact coverage context",fun()->check(S,<<"nested">>,{ok,ok},4) end},
    {"caller killed: guardian survives and drains DOWN",fun()->owner_failure(S,caller) end},
    {"campaign and application cancellation reap descendants",fun()->cancel(S) end},
    {"coordinator killed: result waits for guardian cleanup",fun()->owner_failure(S,coordinator) end},
    {"descendants created during timeout are reaped",fun()->lists:foreach(fun(_)->check(S,<<"timeout_spawn">>,{timeout,30},at_least_two) end,lists:seq(1,10)) end},
    {"owned ETS, registered names, dictionary and mailbox do not leak",fun()->owned_resources(S) end},
    {"dirty VM policies and ordinary spawn rejection",{timeout,30,fun()->
        lists:foreach(fun(Mode)->fresh_vm(S,Mode) end,
            [persistent,env,shared_ets,escaped_ets,escaped_name,raw_spawn,raw_nested,guardian_killed,campaign_dirty,coordinator_dirty])
    end}}
] end}.
setup() ->
    Out=filename:absname("_build/isolation-test"),
    {ok,A}=efz_instrument:compile("fixtures/efz_isolation_target.erl",
        #{modules=>[efz_isolation_target],source_root=>".",outdir=>filename:join(Out,"target")}),
    {ok,Ms}=efz_instrument:preflight([A]),
    Path=filename:join(Out,"artifact.term"),ok=file:write_file(Path,term_to_binary(A)),
    #{out=>Out,descriptor=>Path,artifact=>A,options=>#{coverage=>automatic,manifests=>Ms,max_input_bytes=>128}}.
cleanup(_)->efz:stop(),code:purge(efz_isolation_target),code:delete(efz_isolation_target),ok.
observed(F) ->
    true=register(efz_isolation_observer,self()),
    try F() after unregister(efz_isolation_observer),drain([]) end.
drain(Acc) -> receive {owned,_,_,_,_}=M->drain([M|Acc]);{tree_ready,_}->drain(Acc) after 0->lists:reverse(Acc) end.
check(S,Input,Expected,Count) -> observed(fun()->
    Before=tables(),
    Timeout=case Expected of {timeout,T}->T;_->1000 end,
    R=efz_executor:run(efz_isolation_target,Input,Timeout,maps:get(options,S)),
    case Expected of crash->ok;_->?assertEqual(Expected,maps:get(outcome,R)) end,
    ?assertEqual(ok,maps:get(coverage_status,R)),?assert(maps:get(coverage,R)=/=[]),
    case Count of
        4 -> [Manifest]=maps:get(manifests,maps:get(options,S)),
             Ids=[Id||#{function:=child,kind:=fun_clause,probe_id:=Id}<-maps:get(probes,Manifest)],
             ?assert(lists:any(fun({_,_,Id})->lists:member(Id,Ids) end,maps:get(coverage,R)));
        _ -> ok
    end,
    ?assertEqual(true,maps:get(runner_reusable,R)),
    #{status:=confirmed,processes:=Ps,survivors:=[],violations:=[]}=maps:get(cleanup,R),
    case Count of at_least_two->?assert(length(Ps)>=2);_->?assertEqual(Count,length(Ps)) end,
    dead(Ps),
    Delivered=drain([]),Ref=maps:get(execution_ref,R),
    ?assert(lists:all(fun({owned,_,P,G,F})->lists:member(P,Ps) andalso F=:=Ref andalso not is_process_alive(G) end,Delivered)),
    %% A process admitted as the deadline wins may die at its start gate.
    case Count of at_least_two->?assert(length(Delivered)>=2);_->?assertEqual(length(Ps),length(Delivered)) end,
    ?assertEqual(Before,tables()),R
end).
tables() -> lists:sort([T||T<-ets:all(),ets:info(T,name)=:=efz_execution_coverage]).
dead(Ps) -> lists:foreach(fun(P)->
    ?assertNot(is_process_alive(P)),M=monitor(process,P),
    receive {'DOWN',M,process,P,noproc}->ok after 1000->error(missing_down) end
end,Ps).
async(S,Input) ->
    Parent=self(),Tag=make_ref(),{Caller,Mon}=spawn_monitor(fun()->
        Parent!{Tag,efz_executor:run(efz_isolation_target,Input,5000,maps:get(options,S))}
    end),{Caller,Mon,Tag}.
tree() ->
    receive {tree_ready,_}->ok after 3000->error(no_tree) end,
    Events=drain([]),[{owned,root,_,G,_}]=[E||E={owned,root,_,_,_}<-Events],
    {G,[P||{owned,_,P,_,_}<-Events]}.
owner_failure(S,Which) -> observed(fun()->
    Before=tables(),{Caller,Mon,Tag}=async(S,<<"hold">>),{G,Ps}=tree(),
    ?assertEqual(3,length(Ps)),GMon=monitor(process,G),
    case Which of
        caller -> exit(Caller,kill),receive {'DOWN',Mon,process,Caller,killed}->ok end;
        coordinator ->
            {monitors,Ms}=process_info(G,monitors),
            [C]=[P||{process,P}<-Ms,process_info(P,current_function)=:={current_function,{efz_executor,coordinate,1}}],
            exit(C,kill),
            R=receive {Tag,X}->X after 3000->error(no_result) end,
            ?assertEqual({infrastructure,{coordinator_down,killed}},maps:get(outcome,R)),
            ?assertEqual(confirmed,maps:get(status,maps:get(cleanup,R))),
            ?assertEqual(true,maps:get(runner_reusable,R)),
            receive {'DOWN',Mon,process,Caller,normal}->ok end
    end,
    receive {'DOWN',GMon,process,G,normal}->ok after 3000->error(guardian_leak) end,
    dead(Ps),?assertEqual(Before,tables())
end).
cancel(S) ->
    lists:foreach(fun(Stop)->observed(fun()->
        {ok,_}=efz:start(#{target=>efz_isolation_target,artifacts=>[maps:get(artifact,S)],
            seeds=>[<<"hold">>],timeout=>5000,max_iterations=>0}),
        try
            {G,Ps}=tree(),Mon=monitor(process,G),ok=Stop(),
            receive {'DOWN',Mon,process,G,normal}->ok after 3000->error(cancel_guardian_leak) end,
            dead(Ps),?assertEqual(3,length(Ps)),?assertEqual(ready,efz_executor:runner_status())
        after efz:stop() end
    end) end,[fun efz:stop/0,fun()->application:stop(efz) end]).
owned_resources(S) -> observed(fun()->
    T=ets:new(efz_isolation_shared,[named_table,public]),
    try
        O=maps:get(options,S),
        A=efz_executor:run(efz_isolation_target,<<"A">>,1000,O),
        R=efz_executor:run(efz_isolation_target,<<"resources">>,1000,O),
        ?assertEqual({ok,ok},maps:get(outcome,R)),dead(maps:get(processes,maps:get(cleanup,R))),
        ?assertEqual(undefined,whereis(efz_isolation_root)),?assertEqual(undefined,whereis(efz_isolation_child)),
        ?assertEqual(undefined,ets:info(efz_isolation_owned)),?assertEqual(undefined,ets:info(efz_isolation_child_table)),
        B=efz_executor:run(efz_isolation_target,<<"A">>,1000,O),
        ?assertEqual({ok,{false,false,[],undefined,clean_mailbox}},maps:get(outcome,B)),
        ?assertEqual(maps:get(outcome,A),maps:get(outcome,B)),
        ?assertEqual(maps:get(coverage,A),maps:get(coverage,B)),?assertEqual(ready,efz_executor:runner_status())
    after ets:delete(T) end
end).
fresh_vm(S,Mode) ->
    Erl=os:find_executable("erl"),
    Eval=lists:flatten(io_lib:format("efz_isolation_tests:fresh(~p,~tp),halt().",[Mode,maps:get(descriptor,S)])),
    Args=["+S","2:2","-noshell","-pa",filename:dirname(code:which(?MODULE)),
        "-pa",filename:dirname(code:which(efz)),"-eval",Eval],
    Port=open_port({spawn_executable,Erl},[binary,exit_status,use_stdio,stderr_to_stdout,{args,Args}]),
    {Status,Output}=port_result(Port,[]),
    ok=file:write_file(filename:join(maps:get(out,S),atom_to_list(Mode)++".log"),Output),
    ?assertEqual({Mode,0},{Mode,Status}).
port_result(P,Acc) -> receive
    {P,{data,B}}->port_result(P,[B|Acc]);
    {P,{exit_status,S}}->{S,iolist_to_binary(lists:reverse(Acc))}
    after 10000->port_close(P),error(fresh_vm_timeout)
end.
fresh(Mode,Descriptor) ->
    {ok,B}=file:read_file(Descriptor),Artifact=binary_to_term(B),{ok,Ms}=efz_instrument:preflight([Artifact]),
    _=application:load(efz),
    S=#{options=>#{coverage=>automatic,manifests=>Ms,max_input_bytes=>128}},
    observed(fun()->
        ets:new(efz_isolation_shared,[named_table,public]),
        case Mode of escaped_name ->
            External=spawn(fun()->receive done->ok end end),
            persistent_term:put({efz_isolation_target,external},External);
            _->ok
        end,
        O=maps:get(options,S),
        A=efz_executor:run(efz_isolation_target,<<"A">>,1000,O),
        ?assertEqual({ok,{false,false,[],undefined,clean_mailbox}},maps:get(outcome,A)),
        _=drain([]),
        R=case Mode of
            coordinator_dirty ->
                {Caller,Mon,Tag}=async(S,<<"dirty_hold">>),{G,Ps}=tree(),
                {monitors,Ms0}=process_info(G,monitors),
                [C]=[P||{process,P}<-Ms0,process_info(P,current_function)=:={current_function,{efz_executor,coordinate,1}}],
                exit(C,kill),X=receive {Tag,V}->V after 3000->error(no_coordinator_failure) end,
                receive {'DOWN',Mon,process,Caller,normal}->ok end,
                ?assertEqual({infrastructure,{coordinator_down,killed}},maps:get(outcome,X)),
                ?assertEqual({error,dirty_runner},maps:get(coverage_status,X)),
                ?assertEqual({error,{infrastructure,{coordinator_down,killed}}},
                    efz_feedback:evaluate(efz_feedback:new(#{}),X,mutation)),
                dead(Ps),X;
            campaign_dirty ->
                {ok,_}=efz:start(#{target=>efz_isolation_target,artifacts=>[Artifact],seeds=>[<<>>],
                    mutation_mode=>staged,max_iterations=>10,
                    mutation=>#{stages=>[dictionary_insert],dictionary=>[<<"dirty_persistent">>]}}),
                Report=efz:await(5000),ok=efz:stop(),
                ?assertMatch({infrastructure_failure,#{kind:=dirty_runner}},maps:get(status,Report)),
                ?assertEqual(1,maps:get(infrastructure_failures,maps:get(stats,Report))),
                ?assertEqual(1,maps:get(executions,maps:get(stats,Report))),
                Context=maps:get(failure_context,Report),?assertEqual(<<"dirty_persistent">>,maps:get(input,Context)),
                X=maps:get(result,Context),dead(maps:get(processes,maps:get(cleanup,X))),X;
            guardian_killed ->
                {Caller,Mon,Tag}=async(S,<<"hold">>),{G,Ps}=tree(),exit(G,kill),
                X=receive {Tag,V}->V after 3000->error(no_guardian_failure) end,
                receive {'DOWN',Mon,process,Caller,normal}->ok end,
                %% Guardian loss cannot certify cleanup. Retire VM; clean test
                %% resources explicitly only after asserting the dirty outcome.
                ?assertEqual(unconfirmed,maps:get(status,maps:get(cleanup,X))),
                lists:foreach(fun(P)->M=monitor(process,P),exit(P,kill),receive {'DOWN',M,process,P,_}->ok end end,Ps),
                dead(Ps),X;
            _ -> Input=case Mode of persistent-><<"dirty_persistent">>;env-><<"dirty_env">>;
                    shared_ets-><<"dirty_ets">>;escaped_ets-><<"escaped_ets">>;
                    escaped_name-><<"escaped_name">>;raw_spawn-><<"raw_spawn">>;raw_nested-><<"raw_nested">> end,
                 X=efz_executor:run(efz_isolation_target,Input,1000,O),
                 dead(maps:get(processes,maps:get(cleanup,X))),X
        end,
        %% Dirty cleanup never replaces an earlier infrastructure cause.
        case maps:get(target_outcome,R,undefined) of
            {infrastructure,_}=Primary->?assertEqual(Primary,maps:get(outcome,R));
            _->?assertMatch({infrastructure,#{kind:=dirty_runner}},maps:get(outcome,R))
        end,
        ?assertEqual(false,maps:get(runner_reusable,R)),?assertMatch({dirty,_},efz_executor:runner_status()),
        _=drain([]),
        Next=efz_executor:run(efz_isolation_target,<<"A">>,1000,O),
        ?assertMatch({infrastructure,#{kind:=dirty_runner}},maps:get(outcome,Next)),
        ?assertEqual(not_started,maps:get(status,maps:get(cleanup,Next))),?assertEqual([],drain([])),
        case Mode of
            campaign_dirty ->
                {ok,_}=efz:start(#{target=>efz_isolation_target,artifacts=>[Artifact],seeds=>[<<"A">>],max_iterations=>0}),
                Rejected=efz:await(5000),ok=efz:stop(),
                ?assertMatch({infrastructure_failure,#{kind:=dirty_runner}},maps:get(status,Rejected)),
                ?assertEqual([],drain([]));
            _->ok
        end,
        io:format("~p A -> dirty -> A blocked: ~tp~n",[Mode,maps:with([cleanup,runner_reusable],R)])
    end).
