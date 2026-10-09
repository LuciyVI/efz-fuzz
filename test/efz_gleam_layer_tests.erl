-module(efz_gleam_layer_tests).
-include_lib("eunit/include/eunit.hrl").

off_config_test()->
    ?assertEqual({ok,#{}},efz_gleam_adapter:prepare(false,#{})),
    ?assertEqual(false,maps:get(gleam_layer,efz_config:defaults())).
namespace_test()->
    ?assert(efz_semantic:valid([{<<"cow_qs">>,1,0}])),
    ?assertNot(efz_semantic:valid([{<<"cow_qs">>,2,0}])),
    ?assertNot(efz_semantic:valid([{<<"cow_qs">>,1,12}])),
    ?assertNot(efz_semantic:valid([0|improper])).
boundary_test()->
    L={limits,4096,32,128,1},
    ?assertEqual({error,boundary},efz_gleam_adapter:decode(<<1:1>>,L)),
    ?assertEqual({error,boundary},efz_gleam_adapter:decode(<<"a=1">>,bad_limits)),
    ?assertEqual({error,boundary},efz_gleam_adapter:encode({query,[{field,<<"a">>,<<>>}|bad],canonical},L)),
    ?assertEqual({error,boundary},efz_gleam_adapter:encode({query,[{field,"a",<<>>}],canonical},L)),
    ?assertEqual({error,boundary},efz_gleam_adapter:mutate(<<>>,bad,L)).

parser_rejection_test()->
    lists:foreach(fun(B)->?assertEqual(rejected,efz_qs_target:run(B)) end,
        [<<"a=%GG">>,<<"a=%0G">>,<<"a=%">>,<<"=a=b">>]),
    ?assertEqual({accepted,[{<<"a">>,<<0>>}]},efz_qs_target:run(<<"a=",0>>)),
    ?assertEqual({accepted,[{<<"a">>,true}]},efz_qs_target:run(<<"a">>)).

native_test_()->case code:which(efz_qs_model) of
    non_existing->[];
    _ -> {timeout,90,[fun codec/0,fun limits_and_failures/0,fun determinism/0,
        fun guidance/0,fun observer_only/0,fun persistence_retry/0,fun restart/0,
        fun coverage_attribution/0,fun finding_replay/0,fun reduction/0,fun fallback_rng/0,
        fun fault_injection/0]}
end.
limits()->{limits,4096,32,128,1}.
codec()->
    ?assertEqual({1,1,1,1,1,1},efz_qs_model:versions()),
    Models=[{query,[],canonical},{query,[{field,<<"a">>,<<0,255,32,38,61,37>>}],canonical},
        {query,[{field,<<"a">>,<<>>},{field,<<"a">>,<<"1">>}],canonical}],
    lists:foreach(fun(M)->{ok,B}=efz_gleam_adapter:encode(M,limits()),
        ?assertEqual({ok,M},efz_gleam_adapter:decode(B,limits())),
        ?assertEqual({ok,M},efz_gleam_adapter:normalize(M,limits())),
        {query,Fs,canonical}=M,
        ?assertEqual({accepted,[{K,V}||{field,K,V}<-Fs]},efz_qs_target:run(B))
    end,Models),
    {ok,Plus}=efz_gleam_adapter:decode(<<"a+b=c+d">>,limits()),
    ?assertEqual({query,[{field,<<"a b">>,<<"c d">>}],canonical},Plus),
    {ok,Bad,_}=efz_gleam_adapter:mutate(<<"a=1">>,5,limits()),
    ?assertEqual(rejected,efz_qs_target:run(Bad)),
    ?assertEqual({skip,unsupported},efz_gleam_adapter:decode(Bad,limits())),
    ?assertEqual({skip,unsupported},efz_gleam_adapter:decode(<<"=a=b">>,limits())),
    %% Differential byte vocabulary check against the pinned real parser.
    lists:foreach(fun(Byte)->lists:foreach(fun(Raw)->
        case efz_gleam_adapter:decode(Raw,limits()) of
            {ok,_}->?assertEqual({pass,query_model_agreement},
                efz_gleam_adapter:oracle(Raw,{ok,efz_qs_target:run(Raw)},limits()));
            {skip,unsupported}->ok
        end
    end,[<<"a=",Byte>>,<<Byte,"=1">>]) end,lists:seq(0,255)).
limits_and_failures()->
    ?assertEqual({skip,limit},efz_gleam_adapter:decode(<<"a=1">>,{limits,2,32,128,1})),
    ?assertEqual({skip,limit},efz_gleam_adapter:decode(<<"a=11">>,{limits,4096,32,1,1})),
    ?assertEqual({skip,limit},efz_gleam_adapter:decode(<<"a=1&b=2">>,{limits,4096,1,128,1})),
    ?assertEqual({skip,unsupported},efz_gleam_adapter:decode(<<"a">>,limits())),
    ?assertEqual({error,boundary},efz_gleam_adapter:encode({query,[],wrong_tag},limits())),
    ?assertMatch({error,{gleam_configuration,_}},efz_gleam_adapter:prepare(#{oracle=>deferred},base())),
    ?assertMatch({error,{gleam_configuration,_}},efz_gleam_adapter:prepare(#{},
        (base())#{manifests=>[#{module=>efz_feedback}]})),
    ?assertEqual({inconclusive,unsupported},efz_gleam_adapter:oracle(<<"a">>,{ok,{accepted,[{<<"a">>,true}]}},limits())),
    ?assertEqual({pass,query_model_agreement},efz_gleam_adapter:oracle(<<"a=1">>,{ok,{accepted,[{<<"a">>,<<"1">>}]}},limits())),
    ?assertEqual({fail,query_model_agreement},efz_gleam_adapter:oracle(<<"a=1">>,{ok,rejected},limits())).
determinism()->
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{17,23,41},stages=>[havoc]},[<<"a=1">>]),
    E=[#{id=>1,input=><<"a=1">>}],
    P=efz_gleam_adapter:defaults(),
    Off=take(efz_mutation_plan:new(C),E,20,[]),
    Zero=take(efz_mutation_plan:new(C#{gleam_layer=>P#{structured_fraction=>0}}),E,20,[]),
    ?assertEqual(Off,Zero),
    On=C#{gleam_layer=>P#{structured_fraction=>100}},
    ?assertEqual(take(efz_mutation_plan:new(On),E,20,[]),take(efz_mutation_plan:new(On),E,20,[])),
    {Rows,_}=take(efz_mutation_plan:new(On),E,20,[]),
    lists:foreach(fun({B,R})->Recipe=efz_recipe:make(R,B,On,#{}),
        ?assertEqual({ok,B},efz_recipe:regenerate(Recipe)),
        {ok,Wire}=efz_recipe:encode(Recipe),?assertEqual({ok,Recipe},efz_recipe:decode(Wire)) end,Rows).
take(S,_,0,Acc)->{lists:reverse(Acc),maps:get(rng,S)};
take(S,E,N,Acc)->case efz_mutation_plan:next(S,E) of
    {candidate,B,R,Next}->take(Next,E,N-1,[{B,R}|Acc]);
    {skip,_,Next}->take(Next,E,N,Acc) end.
base()->#{target=>efz_qs_target,mutation_mode=>staged,max_input_bytes=>4096,manifests=>[],mutation=>#{}}.
setup(Name)->
    catch efz:stop(),code:purge(cow_qs),code:delete(cow_qs),
    Out=filename:join("_build/gleam-layer-tests",Name++"-"++integer_to_list(erlang:system_time(microsecond))),
    {ok,A}=efz_cov_native_public:compile("_build/default/lib/cowlib/src/cow_qs.erl",Out,["_build/default/lib/cowlib/include"]),
    {Out,A}.
config(Out,A,Feedback)->#{target=>efz_qs_target,seeds=>[<<"a=1">>],artifacts=>[A],coverage_backend=>otp_native_public,
    mutation_mode=>staged,max_iterations=>12,timeout=>1000,crash_dir=>Out++"/crashes",
    mutation=>#{seed=>{17,23,41},stages=>[dictionary_overwrite],dictionary=>[<<255>>],trace_limit=>32},
    gleam_layer=>#{structured_fraction=>0,feedback=>Feedback}}.
campaign(C)->try {ok,_}=efz:start(C),efz:await(30000) after efz:stop() end.
guidance()->
    {Out,A}=setup("guidance"),R=campaign(config(Out,A,guided)),
    Semantic=[E||E<-maps:get(corpus,R),maps:get(retention_reason,maps:get(metadata,E),none)=:=new_semantic],
    ?assertMatch([_|_],Semantic),
    [First|_]=Semantic,Id=maps:get(id,First),
    ?assert(lists:any(fun(Recipe)->maps:get(parent,Recipe)=:=Id end,maps:get(mutation_trace,R))),
    ?assertEqual([],maps:get(new_probes,maps:get(metadata,First))),
    ok=file:write_file(Out++"/proof.term",term_to_binary(R)).
observer_only()->
    {Out,A}=setup("observation"),R=campaign(config(Out,A,observation_only)),
    ?assertEqual([], [E||E<-maps:get(corpus,R),maps:get(retention_reason,maps:get(metadata,E),none)=:=new_semantic]),
    ?assertEqual([],maps:get(semantic_features,R)),
    {Out2,A2}=setup("off"),Off=campaign((config(Out2,A2,guided))#{gleam_layer=>false}),
    ?assertEqual([maps:get(input,E)||E<-maps:get(corpus,Off)],[maps:get(input,E)||E<-maps:get(corpus,R)]).
persistence_retry()->
    Dir="_build/gleam-layer-tests/retry-"++integer_to_list(erlang:system_time(microsecond)),
    {ok,C}=efz_config:prepare(#{target=>efz_qs_target,seeds=>[<<"a=1">>],coverage_backend=>none,max_iterations=>0}),
    Identity=efz_corpus_store:identity(C),Store=#{dir=>Dir,identity=>Identity},
    {ok,Pid}=efz_corpus:start_link([<<"a=1">>],{1,2,3},Store,4096,#{feedback=>guided}),
    try
        Fs=[{<<"cow_qs">>,1,10}],M=#{parent=>1,phase=>mutation,new_probes=>[],retention_reason=>equivalent_coverage},
        ok=file:rename(Dir,Dir++"-saved"),ok=file:write_file(Dir,<<"block write">>),
        ?assertMatch({error,_},efz_corpus:admit_semantic(<<"a=2">>,M,Fs,false)),
        ?assertEqual([],efz_corpus:semantic_state()),
        ok=file:delete(Dir),ok=file:rename(Dir++"-saved",Dir),
        ?assertMatch({ok,2,_},efz_corpus:admit_semantic(<<"a=2">>,M,Fs,false)),
        ?assertEqual(Fs,efz_corpus:semantic_state()),
        ?assertMatch({existing,2,_},efz_corpus:admit_semantic(<<"a=2">>,M,Fs,false)),
        ?assertEqual(2,efz_corpus:size()),
        [_,SavedEntry]=efz_corpus:all(),
        ?assertEqual(new_semantic,maps:get(retention_reason,maps:get(metadata,SavedEntry)))
    after gen_server:stop(Pid) end,
    ?assertMatch({ok,[_,_],[]},efz_corpus_store:restore(Dir,Identity,reject)).
restart()->
    {Out,A}=setup("restart"),Dir=Out++"/store-"++integer_to_list(erlang:unique_integer([positive])),
    C=(config(Out,A,guided))#{corpus_dir=>Dir},R=campaign(C),
    R2=campaign(C#{seeds=>[],max_iterations=>0}),
    ?assertEqual(maps:get(semantic_features,R),maps:get(semantic_features,R2)),
    ?assertEqual(length(maps:get(corpus,R)),length(maps:get(corpus,R2))),
    Count=fun(Report)->length([E||E<-maps:get(corpus,Report),
        maps:get(retention_reason,maps:get(metadata,E),none)=:=new_semantic]) end,
    ?assert(Count(R)>0),?assertEqual(Count(R),Count(R2)).
coverage_attribution()->
    {Out,A}=setup("attribution"),
    R1=campaign((config(Out,A,disabled))#{seeds=>[<<"a=1">>],max_iterations=>0,gleam_layer=>false}),
    R2=campaign((config(Out,A,guided))#{seeds=>[<<"a=",255>>],max_iterations=>0,
        gleam_layer=>#{structured_fraction=>0,feedback=>guided,oracle=>inline}}),
    ?assertEqual(maps:get(coverage,R1),maps:get(coverage,R2)),
    ?assert(lists:all(fun({M,_,_})->M=:=cow_qs end,maps:get(coverage,R2))),
    ?assertEqual(0,maps:get(oracle_extra_executions,R2)).
finding_replay()->
    {Out,A}=setup("finding"),
    C=(config(Out,A,disabled))#{target=>efz_qs_defect_target,seeds=>[<<"bug=11&x=2">>],max_iterations=>0,
        gleam_layer=>#{structured_fraction=>0,feedback=>disabled,oracle=>inline}},
    Input= <<"bug=11&x=2">>,
    R=campaign(C#{benchmark_replay_inputs=>[Input,Input,Input]}),
    ?assertEqual(3,maps:get(oracle_failures,maps:get(gleam_stats,R))),
    ?assertEqual(1,length(maps:get(corpus,R))),
    [Crash]=maps:get(crashes,R),Path=maps:get(path,Crash),
    {ok,E}=efz_semantic_replay:load(Path++".semantic"),
    {ok,B}=file:read_file(Path++".input"),
    O=#{timeout=>1000,coverage_backend=>otp_native_public,max_input_bytes=>4096},
    ?assertMatch({ok,#{status:=reproduced}},efz_semantic_replay:run(B,efz_qs_defect_target,[A],E,O)),
    {ok,Min}=efz_semantic_replay:minimize(B,efz_qs_defect_target,[A],E,O,64),
    ?assertEqual(<<"bug=">>,maps:get(input,Min)),
    ?assertMatch({error,_},efz_semantic_replay:run(B,efz_qs_defect_target,[A],E#{property=>{query_model_agreement,2}},O)),
    ok=file:write_file(Out++"/minimized.input",maps:get(input,Min)).
reduction()->
    S1=efz_semantic:metadata([{<<"cow_qs">>,1,5}]),S2=efz_semantic:metadata([{<<"cow_qs">>,1,10}]),
    Rows=[#{id=>1,metadata=>#{phase=>calibration,semantic=>S1}},
        #{id=>2,metadata=>#{phase=>mutation,semantic=>S2,new_probes=>[]}},
        #{id=>3,metadata=>#{phase=>mutation,semantic=>S2,new_probes=>[]}}],
    {Kept,_,Fs}=efz_semantic:cover(Rows),?assertEqual([1,2],[maps:get(id,E)||E<-Kept]),
    ?assertEqual([{<<"cow_qs">>,1,5},{<<"cow_qs">>,1,10}],Fs),
    {ok,Pid}=efz_corpus:start_link([<<"a=1">>],{1,2,3},undefined,4096,#{feedback=>guided}),
    try
        Probe={cow_qs,<<0:256>>,1},M=#{phase=>mutation,retention_reason=>new_coverage,new_probes=>[Probe]},
        Features=[{<<"cow_qs">>,1,10}],
        ?assertMatch({ok,2,_},efz_corpus:admit_semantic(<<"a=2">>,M,Features,true)),
        ?assertMatch({existing,2,_},efz_corpus:admit_semantic(<<"a=2">>,
            M#{retention_reason=>equivalent_coverage,new_probes=>[]},Features,false)),
        [_,Entry]=efz_corpus:all(),?assertEqual([Probe],maps:get(new_probes,maps:get(metadata,Entry))),
        ?assertEqual(new_coverage,maps:get(retention_reason,maps:get(metadata,Entry)))
    after gen_server:stop(Pid) end.
fallback_rng()->
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{17,23,41},stages=>[havoc]},[<<"name_only">>]),
    Es=[#{id=>1,input=><<"name_only">>}],Plain=efz_mutation_plan:new(C),R0=maps:get(rng,Plain),
    {_,R1}=rand:uniform_s(100,R0),{_,R2}=rand:uniform_s(6,R1),
    {candidate,B,P,S}=efz_mutation_plan:next(Plain#{rng=>R2},Es),
    On=efz_mutation_plan:new(C#{gleam_layer=>(efz_gleam_adapter:defaults())#{structured_fraction=>100}}),
    {candidate,B,P,SOn}=efz_mutation_plan:next(On,Es),
    ?assertEqual(maps:get(rng,S),maps:get(rng,SOn)),
    ?assertEqual(1,maps:get(unsupported,maps:get(structured_counts,SOn))).
fault_injection()->
    %% Explicit contract fault stub; real BEAM integration is tested above.
    {efz_qs_model,Original,File}=code:get_object_code(efz_qs_model),
    {Out,A}=setup("fault"),
    Var={var,1,'_'},
    Unused=[{normalize,1},{encode,2},{generate,2},{observe,4},{check,2}],
    Forms=[{attribute,1,module,efz_qs_model},{attribute,1,export,[{versions,0},{decode,2},{mutate,3}|Unused]},
        {function,1,versions,0,[{clause,1,[],[],[erl_parse:abstract({1,1,1,1,1,1})]}]},
        {function,1,decode,2,[{clause,1,[Var,Var],[],[erl_parse:abstract({ok,{query,[{field,<<"a">>,<<"1">>}],canonical}})]}]},
        {function,1,mutate,3,[{clause,1,[Var,Var,Var],[],[
            {call,1,{remote,1,{atom,1,erlang},{atom,1,error}},[{atom,1,injected_failure}]}]}]}]++
        [{function,1,F,Arity,[{clause,1,lists:duplicate(Arity,Var),[],[
            {call,1,{remote,1,{atom,1,erlang},{atom,1,error}},[{atom,1,unused_fault_callback}]}]}]}
          ||{F,Arity}<-Unused],
    {ok,efz_qs_model,B}=compile:forms(Forms,[binary]),
    code:purge(efz_qs_model),code:delete(efz_qs_model),
    {module,efz_qs_model}=code:load_binary(efz_qs_model,"contract_fault_stub",B),
    try
        C=(config(Out,A,disabled))#{gleam_layer=>#{structured_fraction=>100}},
        R=campaign(C),?assertMatch({infrastructure_failure,_},maps:get(status,R)),
        ?assertEqual(0,maps:get(executions,maps:get(stats,R))),
        ?assertEqual(1,maps:get(errors,maps:get(structured_stats,R)))
    after
        code:purge(efz_qs_model),code:delete(efz_qs_model),
        {module,efz_qs_model}=code:load_binary(efz_qs_model,File,Original)
    end.
