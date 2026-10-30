-module(efz_backend_tests).
-include_lib("eunit/include/eunit.hrl").
-export([run/1]).

backend_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(S) ->
        [{"canonical outcomes, exact probes and novelty", fun()->differential(S) end},
         {"published coverage survives external kill", fun()->termination(S,kill) end},
         {"published coverage survives timeout", {timeout,10,fun()->termination(S,timeout) end}},
         {"kill while repeatedly publishing probes", fun()->publishing_kill(S) end},
         {"broken backend cannot hide behind repeated observations", fun()->broken(S) end},
         {"invalid or mismatched validation plans", fun()->invalid_plan(S) end},
         {"prepared capability lifetime and empty-snapshot validation", fun()->plan_lifetime(S) end},
         {"two explicitly separate contexts", fun()->contexts(S) end},
         {"caller death releases execution storage", fun()->caller_death(S) end},
         %% Four independent variants previously shared one 5s throughput gate.
         [{"deadline boundary and repeated resource cleanup",fun()->boundary(S,V) end}||V<-variants()],
         {"campaign and application cancellation", fun()->cancel(S) end},
         %% Eight complete campaigns; compare decisions, not host throughput.
         {"seeded real and prerecorded corpus decisions", {timeout,30,fun()->campaigns(S) end}},
         {"invalid config and missing instrumentation", fun()->preflight(S) end}]
    end}.
variants() -> [{ets,per_execution},{ets_member,per_execution},{ets,prepared},{ets_member,prepared}].
setup() ->
    Artifacts=[begin
        _=code:purge(M),_=code:delete(M),_=code:purge(M),
        {ok,A}=efz_instrument:compile(File,#{modules=>[M],outdir=>"_build/backend-test-targets",source_root=>".",
            erl_opts=>[debug_info,warnings_as_errors,{i,"fixtures/include"},{d,'MAGIC',42}]}),A
    end || {M,File}<-[{efz_fixture,"fixtures/efz_fixture.erl"},
        {efz_fixture_helper,"fixtures/efz_fixture_helper.erl"},
        {efz_example_parser,"examples/simple_parser/efz_example_parser.erl"}]],
    {ok,Ms}=efz_instrument:preflight(Artifacts),#{artifacts=>Artifacts,manifests=>Ms}.
cleanup(_) ->
    efz:stop(),lists:foreach(fun(M)->code:purge(M),code:delete(M),code:purge(M) end,
        [efz_fixture,efz_fixture_helper,efz_example_parser]),ok.
options(S,{B,per_execution}) -> #{coverage=>automatic,coverage_backend=>B,manifests=>maps:get(manifests,S)};
options(S,{B,prepared}) ->
    {ok,P}=efz_cov_manifest:prepare(automatic,maps:get(manifests,S)),
    #{coverage=>automatic,coverage_backend=>B,coverage_plan=>P}.
release(#{coverage_plan:=P}) -> efz_cov_manifest:release(P);
release(_) -> ok.
with_options(S,Fun) ->
    [begin O=options(S,V),try Fun(O) after release(O) end end||V<-variants()].
canonical(#{outcome:=O,coverage_status:=Status,coverage:=Hs}) ->
    {outcome(O),Status,lists:sort(Hs)}.
outcome({crash,C,R,St}) -> {crash,C,R,[{M,F,arity(A)}||{M,F,A,_}<-St,M=/=efz_executor]};
outcome(O) -> O.
arity(A) when is_list(A)->length(A);
arity(A)->A.
execute(I,O)->efz_executor:run(efz_fixture,I,1000,O).
inputs() -> [{clauses,0},{clauses,2},{clauses,0},{nested,0},{nested,1},{binary,<<0,4>>},
    {funs,3},{try_it,error},{try_it,throw},{try_it,exit},{exception,error},{exception,throw},
    {exception,exit},{receive_it,[{keep,1},{take,7}]},receive_timeout,{short,false},{short,true},
    {cross,0},{cross,1},{tail,1000}].
differential(S) ->
    Runs=with_options(S,fun(O)->[execute(I,O)||I<-inputs()] end),
    [Reference|Others]=[[canonical(R)||R<-Rs]||Rs<-Runs],
    lists:foreach(fun(R)->?assertEqual(Reference,R) end,Others),
    Feedbacks=[begin
        F=efz_feedback:new(maps:get(builds,hd(Rs))),
        {Decisions,_}=lists:mapfoldl(fun(R,State)->
            {ok,Next,D}=efz_feedback:evaluate(State,R,mutation),{D,Next}
        end,F,Rs),Decisions
    end || Rs<-Runs],
    ?assertEqual(1,length(lists:usort(Feedbacks))).
async(M,I,T,O) ->
    Parent=self(),Tag=make_ref(),
    {P,Mon}=spawn_monitor(fun()->Parent!{Tag,efz_executor:run(M,I,T,O)} end),{P,Mon,Tag}.
ready()->receive {probe_recorded,P}->P after 3000->error(no_published_probe) end.
finished({P,Mon,Tag})->
    R=receive {Tag,X}->X after 4000->error(no_result) end,
    receive {'DOWN',Mon,process,P,normal}->ok end,R.
termination(S,Kind) ->
    Results=with_options(S,fun(O)->
        T=case Kind of timeout->1000;kill->3000 end,
        Handle=async(efz_fixture,{wait,self()},T,O),Target=ready(),
        case Kind of kill->exit(Target,kill);timeout->ok end,
        R=finished(Handle),?assertNot(is_process_alive(Target)),
        ?assertMatch({_,ok,[_|_]},canonical(R)),canonical(R)
    end),
    ?assertEqual(1,length(lists:usort(Results))).
probe_ids(S)->lists:sublist(lists:append([efz_cov_manifest:identities(M)||M<-maps:get(manifests,S)]),3).
run({write_loop,Parent,Ids}) ->
    lists:foreach(fun efz_cov_rt:hit/1,Ids), Parent!{probe_recorded,self()},write_loop(Ids);
run({break_backend,Id,Action}) ->
    efz_cov_rt:hit(Id),Context=get('$efz_execution_context'),T=table(Context),
    case Action of
        delete_table->ets:delete(T);
        invalid_handle->put('$efz_execution_context',setelement(4,Context,make_ref()));
        erase_observation->ets:delete(T,{probe,Id})
    end,
    try efz_cov_rt:hit(Id) catch error:_ -> caught end;
run(<<"waiting">>) -> efz_fixture:run({wait,whereis(efz_backend_observer)});
run(uninstrumented) -> ok.
write_loop(Ids)->lists:foreach(fun efz_cov_rt:hit/1,Ids),write_loop(Ids).
table({efz_context,1,_,{ets_member,T},_})->T;
table({efz_context,1,_,T,_})->T.
publishing_kill(S)->
    Ids=probe_ids(S),
    with_options(S,fun(O)->lists:foreach(fun(_)->
        H=async(?MODULE,{write_loop,self(),Ids},3000,O),Target=ready(),exit(Target,kill),
        ?assertEqual({{exit,killed},ok,lists:sort(Ids)},canonical(finished(H)))
    end,lists:seq(1,10)) end).
broken(S)->
    [Id|_]=probe_ids(S),
    with_options(S,fun(O)->
        lists:foreach(fun(Action)->
            R=efz_executor:run(?MODULE,{break_backend,Id,Action},1000,O),
            ?assertMatch({infrastructure,_},maps:get(outcome,R)),
            ?assertMatch({error,_},maps:get(coverage_status,R)),
            ?assertEqual({ok,caught},maps:get(target_outcome,R))
        end,[delete_table,invalid_handle]),
        %% Re-observation checks externally stored presence; no stale seen cache.
        ?assertEqual({{ok,ok},ok,[Id]},canonical(efz_executor:run(?MODULE,
            {break_backend,Id,erase_observation},1000,O)))
    end).
invalid_plan(S)->
    ?assertMatch({error,_},efz_cov_manifest:prepare(automatic,[])),
    [M|Rest]=maps:get(manifests,S),
    ?assertMatch({error,_},efz_cov_manifest:prepare(automatic,[M#{schema_version=>99}|Rest])),
    with_options(S#{manifests=>[M#{build_id=><<0:256>>}|Rest]},fun(O)->
        ?assertMatch({infrastructure,_},maps:get(outcome,execute({clauses,0},O)))
    end),
    lists:foreach(fun(B)->
        O=#{coverage_plan:=P}=options(S,{B,prepared}),
        efz_cov_manifest:release(P),
        R=execute({clauses,0},O),?assertMatch({infrastructure,invalid_coverage_plan},maps:get(outcome,R)),
        ?assert(maps:get(coverage,R)=/=[]) % Invalid plan does not discard valid observations.
    end,[ets,ets_member]).
plan_lifetime(S)->
    Before=tables(),Parent=self(),
    lists:foreach(fun(B)->
        {Owner,Mon}=spawn_monitor(fun()->
            {ok,P}=efz_cov_manifest:prepare(automatic,maps:get(manifests,S)),
            Parent!{plan,self(),P},receive stop->ok end
        end),
        P=receive {plan,Owner,Plan}->Plan end,
        {efz_cov_plan,1,T,Bs}=P,
        O=#{coverage=>automatic,coverage_backend=>B,coverage_plan=>P},
        try
            %% An immutable plan can be read by another execution caller.
            ?assertError(badarg,ets:insert(T,{foreign_write})),
            ?assertEqual(canonical(execute({clauses,0},O)),canonical(execute({clauses,0},O))),
            ?assertEqual({{ok,ok},ok,[]},canonical(efz_executor:run(?MODULE,uninstrumented,1000,O))),
            %% Marker validation is mandatory even when there are no hits.
            [M|_]=maps:keys(Bs),
            BadPlans=[setelement(2,P,99),setelement(4,P,Bs#{M=><<0:256>>})],
            lists:foreach(fun(Bad)->
                ?assertEqual({error,invalid_coverage_plan},efz_cov_manifest:validate_prepared(automatic,[],Bad)),
                ?assertMatch({infrastructure,_},maps:get(outcome,
                    efz_executor:run(?MODULE,uninstrumented,1000,O#{coverage_plan=>Bad})))
            end,BadPlans),
            ?assertMatch({infrastructure,invalid_coverage_plan},maps:get(outcome,
                efz_executor:run(?MODULE,uninstrumented,1000,O#{coverage=>manual}))),
            H=async(efz_fixture,{wait,self()},3000,O),Target=ready(),
            Owner!stop,receive {'DOWN',Mon,process,Owner,normal}->ok end,
            ?assertEqual(undefined,ets:info(T)),
            exit(Target,kill),R=finished(H),
            ?assertMatch({infrastructure,invalid_coverage_plan},maps:get(outcome,R)),
            ?assertEqual({exit,killed},maps:get(target_outcome,R)),
            ?assert(maps:get(coverage,R)=/=[]),
            ?assertMatch({infrastructure,invalid_coverage_plan},maps:get(outcome,
                efz_executor:run(?MODULE,uninstrumented,1000,O)))
        after
            exit(Owner,kill),demonitor(Mon,[flush])
        end
    end,[ets,ets_member]),
    ?assertEqual(Before,tables()).
contexts(S)->
    Expected=[maps:get(coverage,execute(I,options(S,{ets,per_execution})))||I<-[{clauses,0},{clauses,2}]],
    lists:foreach(fun(B)->
        C1=efz_cov:open(B),C2=efz_cov:open(B),Parent=self(),
        Handles=[spawn_monitor(fun()->efz_cov:attach(C),efz_fixture:run(I),Parent!{probe_recorded,self()},
            receive finish->ok end end)||{C,I}<-lists:zip([C1,C2],[{clauses,0},{clauses,2}])],
        _=ready(),_=ready(),
        lists:foreach(fun({P,Mon})->P!finish,receive {'DOWN',Mon,process,P,normal}->ok end end,Handles),
        Actual=[begin {ok,H}=efz_cov:snapshot(C),efz_cov:close(C),H end||C<-[C1,C2]],
        ?assertEqual(Expected,Actual)
    end,[ets,ets_member]).
tables()->lists:sort([T||T<-ets:all(),lists:member(ets:info(T,name),[efz_execution_coverage,efz_coverage_plan])]).
caller_death(S)->
    with_options(S,fun(O)->
        Before=tables(),{Caller,CMon,_}=async(efz_fixture,{wait,self()},3000,O),Target=ready(),
        [T]=tables()--Before,Owner=ets:info(T,owner),OMon=monitor(process,Owner),TMon=monitor(process,Target),
        exit(Caller,kill),receive {'DOWN',CMon,process,Caller,killed}->ok end,
        receive {'DOWN',TMon,process,Target,killed}->ok after 3000->error(target_leak) end,
        receive {'DOWN',OMon,process,Owner,normal}->ok after 3000->error(owner_leak) end,
        ?assertEqual(Before,tables())
    end).
boundary(S,V)->
    Before=tables(),
    O=options(S,V),try
        Expected=canonical(execute({clauses,0},O)),
        lists:foreach(fun(N)->
            R=efz_executor:run(efz_fixture,{clauses,0},N rem 2,O),
            ?assert(lists:member(maps:get(outcome,R),[{ok,zero},{timeout,N rem 2}])),
            ?assertEqual(ok,maps:get(coverage_status,R)),
            ?assertEqual(Expected,canonical(execute({clauses,0},O)))
        end,lists:seq(1,50))
    after release(O) end,?assertEqual(Before,tables()).
cancel(S)->
    Before=tables(),true=register(efz_backend_observer,self()),
    try lists:foreach(fun({B,V})->lists:foreach(fun(Stop)->
        {ok,_}=efz:start(#{target=>?MODULE,artifacts=>maps:get(artifacts,S),seeds=>[<<"waiting">>],
            coverage_backend=>B,coverage_validation=>V,timeout=>3000}),
        Target=ready(),[T]=[X||X<-tables()--Before,ets:info(X,name)=:=efz_execution_coverage],
        Owner=ets:info(T,owner),OMon=monitor(process,Owner),TMon=monitor(process,Target),
        ok=Stop(),
        receive {'DOWN',TMon,process,Target,killed}->ok after 3000->error(target_leak) end,
        receive {'DOWN',OMon,process,Owner,normal}->ok after 3000->error(owner_leak) end,
        ?assertEqual(Before,tables())
    end,[fun efz:stop/0,fun()->application:stop(efz) end]) end,variants())
    after unregister(efz_backend_observer) end.
campaigns(S)->
    [A]=[A||#{module:=efz_example_parser}=A<-maps:get(artifacts,S)],
    lists:foreach(fun({Mu,N})->
        Reports=[begin
            {ok,_}=efz:start(#{target=>efz_example_target,artifacts=>[A],seeds=>[<<0>>],
                max_iterations=>N,mutator=>Mu,coverage_backend=>B,coverage_validation=>V,
                random_seed=>{17,23,41},selection_seed=>{101,109,113},
                crash_dir=>"_build/backend-test-crashes-"++binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(6),lowercase))}),
            R=efz:await(5000),efz:stop(),normalize_report(R)
        end||{B,V}<-variants()],
        ?assertEqual(1,length(lists:usort(Reports)))
    end,[{efz_scripted_mutator,5},{efz_mutator_random,200}]).
normalize_report(R)->
    #{status=>maps:get(status,R),stats=>maps:without([started_at],maps:get(stats,R)),
      corpus=>lists:sort([maps:get(input,E)||E<-maps:get(corpus,R)]),coverage=>maps:get(coverage,R),
      decisions=>[{maps:get(input_id,D),maps:get(retention_reason,D),maps:get(new_probes,D)}||D<-maps:get(decisions,R)],
      crashes=>[{maps:get(input,C),canonical(maps:get(result,C))}||C<-maps:get(crashes,R)]}.
preflight(S)->
    lists:foreach(fun({B,V})->
        ?assertMatch({error,_},efz:start(#{target=>?MODULE,seeds=>[<<>>],coverage_backend=>B,coverage_validation=>V})),
        [A|_]=maps:get(artifacts,S),
        ?assertMatch({error,_},efz:start(#{target=>?MODULE,seeds=>[<<>>],coverage_backend=>B,coverage_validation=>V,
            artifacts=>[A#{build_id=><<0:256>>}]}))
    end,variants()),
    ?assertMatch({error,_},efz_config:prepare(#{target=>?MODULE,seeds=>[<<>>],coverage_backend=>unknown})).
