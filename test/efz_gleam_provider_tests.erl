-module(efz_gleam_provider_tests).
-include_lib("eunit/include/eunit.hrl").

%% Ordinary recipes/off dispatch remain testable with no semantic artifact.
off_zero_test()->
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{17,23,41},stages=>[havoc]},[<<"a=1">>]),
    Es=[#{id=>1,input=><<"a=1">>}],
    {Rows,State}=take(efz_mutation_plan:new(C),Es,100,[]),
    {ZeroRows,ZeroState}=take(efz_mutation_plan:new(C#{gleam_layer=>
        #{structured_fraction=>0}}),Es,100,[]),
    ?assertEqual(Rows,ZeroRows),?assertEqual(maps:remove(config,State),maps:remove(config,ZeroState)),
    ?assertNot(maps:is_key(structured_counts,State)),
    lists:foreach(fun({B,P})->R=efz_recipe:make(P,B,C,#{}),
        ?assertEqual(1,maps:get(schema_version,R)),
        ?assertNot(maps:is_key(source_kind,R)),?assertEqual({ok,B},efz_recipe:regenerate(R)) end,Rows).

native_test_()->case code:which(efz_qs_model) of
    non_existing->[];
    _->{timeout,90,[fun catalogue/0,fun codec_laws/0,fun operations/0,
        fun mutation_limits/0,fun recipe_provenance/0,fun deterministic_grid/0,
        fun fallback_states/0,fun error_state/0,fun real_loop/0]}
end.
limits()->{limits,4096,32,128,1}.
catalogue()->
    ?assertEqual(2,efz_qs_model:generator_version()),
    Bs=[begin {ok,B}=efz_gleam_adapter:generate(I,limits()),B end||I<-lists:seq(0,11)],
    ?assertEqual(12,length(lists:usort(Bs))),
    ?assertEqual([0,2,8,18,5,7,386,383,95,92,4096,257],[byte_size(B)||B<-Bs]),
    lists:foreach(fun({I,B})->case I of
        5->?assertEqual(<<"a=1&x=%">>,B),?assertEqual(rejected,efz_qs_target:run(B));
        _->{ok,{query,Fs,canonical}}=efz_gleam_adapter:decode(B,limits()),
            ?assertEqual({accepted,[{K,V}||{field,K,V}<-Fs]},efz_qs_target:run(B))
        end,
        ?assertEqual({ok,B},efz_gleam_adapter:generate(I+12,limits()))
    end,lists:zip(lists:seq(0,11),Bs)),
    lists:foreach(fun({I,L})->?assertEqual({skip,limit},efz_gleam_adapter:generate(I,L)) end,
        [{6,{limits,4096,32,127,1}},{7,{limits,382,32,128,1}},
         {8,{limits,4096,31,128,1}},{9,{limits,4096,30,128,1}},
         {10,{limits,4095,32,128,1}},{11,{limits,4096,32,127,1}}]).
codec_laws()->
    %% An explicit grid, independently checked against the unchanged parser.
    Values=[<<>>,<<0>>,<<255>>,<<" +&=%">>,binary:copy(<<255>>,128)],
    lists:foreach(fun({Count,V})->
        Fs=lists:duplicate(Count,{field,<<"key">>,V}),M={query,Fs,canonical},
        {ok,N}=efz_gleam_adapter:normalize(M,limits()),
        ?assertEqual({ok,N},efz_gleam_adapter:normalize(N,limits())),
        case efz_gleam_adapter:encode(M,limits()) of
            {ok,B}->?assertEqual({ok,N},efz_gleam_adapter:decode(B,limits())),
                ?assertEqual({accepted,[{<<"key">>,V}||_<-Fs]},efz_qs_target:run(B));
            {skip,limit}->?assert(Count*byte_size(V)*3>4096)
        end
    end,[{Count,V}||Count<-[0,1,2,31,32],V<-Values]).
operations()->
    B= <<"a=1&b=2">>,
    Expected=[<<"x=%00%FF&a=1&b=2">>,<<"a=&b=2">>,<<"b=2">>,
        <<"b=2&a=1">>,<<"a=1%FF&b=2">>,<<"a=1&b=2&x=%">>],
    lists:foreach(fun({Op,Wire})->
        ?assertMatch({ok,Wire,#{operation:=Op}},efz_gleam_adapter:mutate(B,Op,limits())),
        case Op of 5->?assertEqual(rejected,efz_qs_target:run(Wire));
            _->?assertMatch({accepted,_},efz_qs_target:run(Wire)) end
    end,lists:zip(lists:seq(0,5),Expected)),
    {ok,M}=efz_gleam_adapter:decode(B,limits()),
    ?assertEqual({ok,lists:last(Expected)},efz_gleam_adapter:encode(setelement(3,M,bad_escape),limits())).
mutation_limits()->
    {ok,Full}=efz_gleam_adapter:generate(8,limits()),
    {ok,ValueMax}=efz_gleam_adapter:generate(6,limits()),
    ?assertEqual({skip,limit},efz_gleam_adapter:mutate(Full,0,limits())),
    ?assertEqual({skip,limit},efz_gleam_adapter:mutate(ValueMax,4,limits())),
    ?assertEqual({skip,limit},efz_gleam_adapter:mutate(<<"a=1">>,5,{limits,6,32,128,1})),
    ?assertEqual({error,boundary},efz_gleam_adapter:mutate(<<"a=1">>,0,{limits,4096,32,128,0})),
    ?assertEqual({error,boundary},efz_gleam_adapter:encode({query,[[{field,<<"a">>,<<>>}]],canonical},limits())),
    lists:foreach(fun(I)->{ok,Wire}=efz_gleam_adapter:generate(I,limits()),
        lists:foreach(fun(Op)->case efz_gleam_adapter:mutate(Wire,Op,limits()) of
            {ok,Out,_}->?assert(byte_size(Out)=<4096);
            {skip,Why}->?assert(lists:member(Why,[limit,unsupported])) end
        end,lists:seq(0,5)) end,lists:seq(0,11)).
config(Seed,Fraction,L)->
    {ok,C}=efz_mutation_plan:prepare(#{seed=>Seed,stages=>[havoc]},[<<"a=1">>]),
    P=(efz_gleam_adapter:defaults())#{structured_fraction=>Fraction,limits=>
        #{bytes=>element(2,L),fields=>element(3,L),component=>element(4,L),operations=>1}},
    With=C#{gleam_layer=>P},With#{config_id=>efz_mutation_plan:config_identity(With)}.
recipe_provenance()->
    C=config({17,23,41},100,limits()),Es=[#{id=>1,input=><<"a=1">>}],
    {Rows,_}=take(efz_mutation_plan:new(C),Es,20,[]),
    [{B,P}|_]=[{Wire,Plan}||{Wire,Plan}<-Rows,maps:is_key(structured,Plan)],
    R=efz_recipe:make(P,B,C,#{}),?assertEqual(3,maps:get(schema_version,R)),
    ?assertEqual(2,maps:get(operation_version,R)),
    {ok,Encoded}=efz_recipe:encode(R),?assertEqual({ok,R},efz_recipe:decode(Encoded)),
    Provenance=maps:get(structured,R),
    lists:foreach(fun(Change)->?assertMatch({error,_},efz_recipe:regenerate(R#{structured=>
        maps:merge(Provenance,Change)})) end,
        [#{schema_version=>2},#{versions=>{1,1,1,2,1,1}},#{operation=>99},
         #{fraction=>0},#{rng_before=>[0,0]},#{rng_after=>[1,2]},
         #{rng_before=>[1|2]},#{limits=>{limits,0,32,128,1}},#{extra=>true}]),
    ?assertMatch({error,_},efz_recipe:regenerate(R#{source_kind=>ordinary})),
    %% Old schema 2 structured artifacts and ordinary schema 1 remain readable.
    Old=(maps:without([structured,source_kind],R))#{schema_version=>2},
    ?assertEqual({ok,B},efz_recipe:regenerate(Old)),
    {ok,OldEncoded}=efz_recipe:encode(Old),?assertEqual({ok,Old},efz_recipe:decode(OldEncoded)),
    Dir=directory("recipes"),ok=efz_recipe:save(Dir++"/current.recipe",R),
    ok=efz_recipe:save(Dir++"/old.recipe",Old),ok=file:write_file(Dir++"/expected.input",B).
deterministic_grid()->
    Es=[#{id=>1,input=><<"a=1">>},#{id=>2,input=><<"name_only">>}],
    lists:foreach(fun({Seed,F})->C=config(Seed,F,limits()),
        {Rows,S}=take(efz_mutation_plan:new(C),Es,100,[]),
        {Again,SAgain}=take(efz_mutation_plan:new(C),Es,100,[]),
        ?assertEqual(Rows,Again),?assertEqual(maps:get(rng,S),maps:get(rng,SAgain)),
        Cs=maps:get(structured_counts,S,#{}),?assertEqual(maps:get(attempts,Cs,0),
            lists:sum(maps:values(maps:get(operations,Cs,#{})))),
        ?assertEqual(maps:get(generated_bytes,Cs,0),lists:sum([byte_size(B)||{B,P}<-Rows,maps:is_key(structured,P)])),
        lists:foreach(fun({B,P})->?assertEqual({ok,B},efz_recipe:regenerate(efz_recipe:make(P,B,C,#{}))) end,Rows)
    end,[{Seed,F}||Seed<-[{17,23,41},{43,44,45}],F<-[1,5,10,20,100]]).
fallback_states()->
    lists:foreach(fun({B,L,Reason})->
        C=config({17,23,41},100,L),Plain=efz_mutation_plan:new(maps:remove(gleam_layer,C)),
        Es=[#{id=>1,input=>B}],R0=maps:get(rng,Plain),
        {_,R1}=rand:uniform_s(100,R0),{_,R2}=rand:uniform_s(6,R1),
        {candidate,Expected,P,S}=efz_mutation_plan:next(Plain#{rng=>R2},Es),
        {candidate,Expected,P,SOn}=efz_mutation_plan:next(efz_mutation_plan:new(C),Es),
        ?assertEqual(maps:get(rng,S),maps:get(rng,SOn)),
        ?assertEqual(1,maps:get(Reason,maps:get(structured_counts,SOn))),
        ?assertNot(maps:is_key(structured,P))
    end,[{<<"name_only">>,limits(),unsupported},{<<"a=1">>,{limits,2,32,128,1},limit}]).

error_state()->
    {efz_qs_model,Original,File}=code:get_object_code(efz_qs_model),
    Var={var,1,'_'},Api=[{versions,0},{decode,2},{encode,2},{normalize,1},
        {generate,2},{mutate,3},{observe,4},{check,2}],
    Forms=[{attribute,1,module,efz_qs_model},{attribute,1,export,Api}]++
        [{function,1,F,A,[{clause,1,lists:duplicate(A,Var),[],[case F of
            versions->erl_parse:abstract({1,1,1,1,1,1});
            decode->erl_parse:abstract({ok,{query,[{field,<<"a">>,<<"1">>}],canonical}});
            _->{call,1,{remote,1,{atom,1,erlang},{atom,1,error}},[{atom,1,p3_fault_fixture}]}
        end]}]}||{F,A}<-Api],
    {ok,efz_qs_model,Beam}=compile:forms(Forms,[binary]),
    code:purge(efz_qs_model),code:delete(efz_qs_model),
    {module,efz_qs_model}=code:load_binary(efz_qs_model,"p3_contract_fault_stub",Beam),
    try
        C=config({17,23,41},100,limits()),S0=efz_mutation_plan:new(C),
        {_,R1}=rand:uniform_s(100,maps:get(rng,S0)),{_,R2}=rand:uniform_s(6,R1),
        {error,{semantic_layer_error,{semantic_layer_error,error,p3_fault_fixture}},S}=
            efz_mutation_plan:next(S0,[#{id=>1,input=><<"a=1">>}]),
        ?assertEqual(R2,maps:get(rng,S)),
        ?assertEqual(1,maps:get(errors,maps:get(structured_counts,S))),
        ?assertEqual(0,maps:get(operation_attempts,maps:get(counts,S)))
    after code:purge(efz_qs_model),code:delete(efz_qs_model),
        {module,efz_qs_model}=code:load_binary(efz_qs_model,File,Original) end.

real_loop()->
    catch efz:stop(),code:purge(cow_qs),code:delete(cow_qs),Dir=directory("loop"),
    {ok,Artifact}=efz_cov_native_public:compile("_build/default/lib/cowlib/src/cow_qs.erl",Dir++"/target",
        ["_build/default/lib/cowlib/include"]),
    {module,efz_qs_model}=code:ensure_loaded(efz_qs_model),
    {module,efz_qs_target}=code:ensure_loaded(efz_qs_target),
    Session=trace:session_create(p3_provider,self(),[]),
    trace:function(Session,{efz_qs_model,'_','_'},true,[local]),
    trace:function(Session,{efz_qs_target,run,1},true,[local]),
    trace:process(Session,all,true,[call,arity]),
    try
        C=#{target=>efz_qs_target,seeds=>[<<"a=1&b=2">>,<<"name_only">>,<<"a=%">>],
            artifacts=>[Artifact],coverage_backend=>otp_native_public,mutation_mode=>staged,
            selection_seed=>{17,23,41},max_iterations=>200,timeout=>1000,
            corpus_dir=>Dir++"/corpus",crash_dir=>Dir++"/crashes",
            mutation=>#{seed=>{17,23,41},stages=>[havoc],trace_limit=>200},
            gleam_layer=>#{structured_fraction=>20}},
        {ok,_}=efz:start(C),Worker=maps:get(worker,sys:get_state(whereis(efz_fuzzer))),Report=efz:await(30000),
        State=sys:get_state(whereis(efz_corpus)),ok=efz:stop(),
        Ref=trace:delivered(Session,all),Events=events(Ref,[]),
        trace:process(Session,all,false,[call,arity]),
        Calls=fun(F)->[{Pid,MFA}||{Pid,MFA={efz_qs_model,Name,_}}<-Events,Name=:=F] end,
        ?assertMatch([_|_],Calls(mutate)),
        ?assertEqual([],Calls(observe)),?assertEqual([],Calls(check)),
        ?assertNot(maps:is_key(semantic_seen,State)),
        ?assertEqual(0,maps:get(oracle_extra_executions,Report)),
        ?assertEqual(#{},maps:without([expected_rejections],maps:get(gleam_stats,Report))),
        ?assertEqual(completed,maps:get(status,Report)),
        Stats=maps:get(stats,Report),Count=maps:get(executions,Stats)+maps:get(calibrations,Stats),
        ?assertEqual(Count,length([MFA||{_,MFA={efz_qs_target,run,1}}<-Events])),
        ?assert(lists:all(fun({Pid,{efz_qs_model,F,_}}) when F=/=versions->Pid=:=Worker;(_)->true end,Events)),
        Recipes=maps:get(mutation_trace,Report),
        ?assertEqual(200,length(Recipes)),
        ?assert(lists:any(fun(R)->maps:is_key(structured,R) end,Recipes)),
        ?assert(lists:any(fun(R)->not maps:is_key(structured,R) end,Recipes)),
        ?assert(lists:any(fun(R)->maps:get(parent,R)=:=2 end,Recipes)),
        lists:foreach(fun(R)->?assertMatch({ok,_},efz_recipe:regenerate(R)) end,Recipes),
        Restored=run(C#{seeds=>[],max_iterations=>0,gleam_layer=>false}),
        ?assertEqual(lists:sort([maps:get(input,E)||E<-maps:get(corpus,Report)]),
            lists:sort([maps:get(input,E)||E<-maps:get(corpus,Restored)])),
        ok=file:write_file(Dir++"/proof.term",term_to_binary(#{report=>Report,restored=>Restored,
            call_mfas=>[MFA||{_,MFA}<-Events],target_execution_count=>Count,all_data_calls_on_efz_worker=>true}))
    after trace:session_destroy(Session),efz:stop() end.
run(C)->try {ok,_}=efz:start(C),efz:await(30000) after efz:stop() end.
events(Ref,Acc)->receive
    {trace,Pid,call,MFA}->events(Ref,[{Pid,MFA}|Acc]);
    {trace_delivered,_,Ref}->lists:reverse(Acc)
    after 5000->error(trace_barrier_timeout) end.
take(S,_,0,Acc)->{lists:reverse(Acc),S};
take(S,Es,N,Acc)->case efz_mutation_plan:next(S,Es) of
    {candidate,B,P,Next}->take(Next,Es,N-1,[{B,P}|Acc]);
    {skip,_,Next}->take(Next,Es,N,Acc)
end.
directory(Name)->Dir="_build/gleam-provider-tests/"++Name++"-"++integer_to_list(erlang:system_time(microsecond))
    ++"-"++integer_to_list(erlang:unique_integer([positive])),
    ok=filelib:ensure_dir(Dir++"/placeholder"),Dir.
