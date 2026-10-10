%% End-to-end public contract checks. Properties here are explicitly configured
%% acceptance rules on ordinary correct APIs, not claims of library defects.
-module(efz_semantic_api_tests).
-include_lib("eunit/include/eunit.hrl").
-export([output_empty/2,output_empty_slow/2]).

output_empty([_],{ok,Value}) when is_list(Value) -> Value=:=[];
output_empty(_,_) -> inconclusive.
output_empty_slow(Args,Outcome)->timer:sleep(5),output_empty(Args,Outcome).

directory(Name)->D="_build/semantic-api-tests/"++Name++"-"++integer_to_list(erlang:system_time(microsecond)),
    ok=filelib:ensure_dir(D++"/placeholder"),D.
campaign(C)->catch efz:stop(),try {ok,_}=efz:start(C),R=efz:await(30000),
    completed=maps:get(status,R),R after efz:stop() end.
base(T,Seeds,D)->#{target=>T,seeds=>Seeds,coverage_backend=>none,mutation_mode=>staged,
    max_iterations=>40,timeout=>1000,crash_dir=>D++"/crashes",selection_seed=>{17,23,41},
    mutation=>#{seed=>{17,23,41},stages=>[havoc],trace_limit=>100}}.

plugin_endtoend_test_()->{timeout,60,fun plugin_endtoend/0}.
plugin_endtoend()->
    D=directory("plugin"),Seed= <<4:16,"abcd">>,
    C=(base(efz_plugin_length_target,[Seed],D))#{corpus_dir=>D++"/store",
        gleam_layer=>#{adapter=>efz_plugin_length_adapter,structured_fraction=>100,feedback=>guided}},
    R=campaign(C),?assertEqual([],maps:get(coverage,R)),
    Semantic=[maps:get(id,E)||E<-maps:get(corpus,R),
        maps:get(retention_reason,maps:get(metadata,E),none)=:=new_semantic],
    ?assert(Semantic=/=[]),
    ?assert(lists:any(fun(Q)->lists:member(maps:get(parent,Q),Semantic) end,maps:get(mutation_trace,R))),
    Recipes=maps:get(mutation_trace,R),
    ?assert(lists:any(fun(Q)->maps:get(schema_version,Q)=:=4 end,Recipes)),
    lists:foreach(fun(Q)->{ok,B}=efz_recipe:regenerate(Q),
        {ok,Encoded}=efz_recipe:encode(Q),{ok,Loaded}=efz_recipe:decode(Encoded),
        ?assertEqual({ok,B},efz_recipe:regenerate(Loaded)) end,Recipes),
    R2=campaign(C#{seeds=>[],max_iterations=>0}),
    ?assertEqual(maps:get(semantic_features,R),maps:get(semantic_features,R2)),
    ?assertEqual(length(maps:get(corpus,R)),length(maps:get(corpus,R2))),
    Different=C#{gleam_layer=>#{adapter=>efz_plugin_observer_adapter,structured_fraction=>0,feedback=>guided}},
    ?assertMatch({error,{corpus_restore,{corpus_build_mismatch,_,_,_}}},efz_config:prepare(Different)),
    R3=campaign(Different#{seeds=>[],max_iterations=>0,corpus_build_policy=>recalibrate}),
    ?assertEqual([{<<"fixture.observer_a">>,1,1}],maps:get(semantic_features,R3)).

native_test_()->case code:which(efz_term_model) of non_existing->[];
    _->{timeout,90,[fun generic_campaign/0,fun property_replay_minimize/0,fun stateful_campaign/0]}
end.
generic_campaign()->
    D=directory("generic"),O=efz_term_reverse_target:options(),
    {ok,B}=efz_term_codec:encode([[1,2,3]],maps:get(arguments,O),#{}),
    C=(base(efz_term_reverse_target,[B],D))#{corpus_dir=>D++"/store",
        gleam_layer=>#{adapter=>efz_term_api_adapter,adapter_options=>O,
            structured_fraction=>100,feedback=>guided}},
    R=campaign(C),?assert(maps:get(successes,maps:get(structured_stats,R),0)>0),
    ?assertEqual(0,maps:get(oracle_extra_executions,R)),
    R2=campaign(C#{seeds=>[],max_iterations=>0}),
    ?assertEqual(maps:get(semantic_features,R),maps:get(semantic_features,R2)),
    {ok,P}=efz_config:prepare(C#{corpus_dir=>D++"/fresh-store",max_iterations=>0}),
    L=maps:get(gleam_layer,P),
    [Recipe|_]=[Q||Q<-maps:get(mutation_trace,R),maps:get(schema_version,Q)=:=4],
    ?assertEqual({ok,maps:get(output_hash,Recipe)},
        case efz_recipe:regenerate(Recipe) of {ok,Raw}->{ok,crypto:hash(sha256,Raw)} end),
    ?assert(efz_gleam_adapter:identity_valid(efz_gleam_adapter:identity(L))),
    ?assertEqual(efz_recipe:regenerate(Recipe),efz_recipe:regenerate_semantic(Recipe,L)),
    ?assertEqual({error,semantic_recipe_identity_mismatch},
        efz_recipe:regenerate_semantic(Recipe,L#{adapter_identity=>#{}})),
    ReduceConfig=(maps:remove(corpus_dir,C))#{seeds=>[B,<<"malformed">>]},
    {ok,Reduced}=efz_semantic_corpus:reduce(ReduceConfig,D++"/reduced",#{}),
    ?assertEqual(0,maps:get(online_executions,Reduced)),
    ?assertEqual(maps:get(semantic_features,maps:get(before,Reduced)),
        maps:get(semantic_features,maps:get(restarted,Reduced))),
    ?assertEqual(efz_gleam_adapter:identity(L),
        efz_gleam_adapter:identity(maps:get(gleam_layer,maps:get(restarted,Reduced)))).
property_replay_minimize()->
    D=directory("property"),O=(efz_term_reverse_target:options())#{property=>#{callback=>{?MODULE,output_empty}}},
    {ok,B}=efz_term_codec:encode([[1,2,3,4]],maps:get(arguments,O),#{}),
    Layer=#{adapter=>efz_term_api_adapter,adapter_options=>O,structured_fraction=>0,oracle=>inline},
    C=(base(efz_term_reverse_target,[B],D))#{max_iterations=>0,gleam_layer=>Layer},
    R=campaign(C),[Finding]=maps:get(crashes,R),Path=maps:get(path,Finding),
    {ok,E}=efz_semantic_replay:load(Path++".semantic"),
    ?assertEqual(2,maps:get(schema_version,E)),
    ?assertEqual({<<"generic_custom_property">>,1},maps:get(property,E)),
    Replay=#{coverage_backend=>none,timeout=>1000,max_input_bytes=>4096,gleam_layer=>Layer},
    ?assertMatch({ok,#{status:=reproduced,target_executions:=1}},
        efz_semantic_replay:run(B,efz_term_reverse_target,[],E,Replay)),
    ?assertEqual({error,semantic_replay_requires_adapter_configuration},
        efz_semantic_replay:run(B,efz_term_reverse_target,[],E,maps:remove(gleam_layer,Replay))),
    I=maps:get(adapter_identity,E),Bad=E#{adapter_identity=>I#{options=><<"different">>}},
    ?assertEqual({error,semantic_replay_identity_mismatch},
        efz_semantic_replay:run(B,efz_term_reverse_target,[],Bad,Replay)),
    {ok,Min}=efz_semantic_replay:minimize(B,efz_term_reverse_target,[],E,Replay,64),
    ?assert(maps:get(target_executions,Min)=<64),?assert(byte_size(maps:get(input,Min))<byte_size(B)),
    ?assertEqual(maps:get(property,E),maps:get(property,Min)),
    ?assertMatch({ok,#{status:=reproduced}},maps:get(verification,Min)),
    ?assertEqual({ok,B},file:read_file(Path++".input")),
    ?assertEqual({ok,E},efz_semantic_replay:load(Path++".semantic")),
    {ok,One}=efz_semantic_replay:minimize(B,efz_term_reverse_target,[],E,Replay,1),
    ?assertEqual(1,maps:get(target_executions,One)),
    ?assertEqual({skipped,budget},maps:get(verification,One)),
    ?assertEqual(B,maps:get(input,One)),
    SlowOptions=O#{property=>#{callback=>{?MODULE,output_empty_slow}}},
    SlowLayer=Layer#{adapter_options=>SlowOptions},
    {ok,PreparedSlow}=efz_config:prepare(C#{gleam_layer=>SlowLayer}),
    SlowIdentity=efz_gleam_adapter:identity(maps:get(gleam_layer,PreparedSlow)),
    {ok,Deadline}=efz_semantic_replay:minimize(B,efz_term_reverse_target,[],
        E#{adapter_identity=>SlowIdentity},Replay#{gleam_layer=>SlowLayer,minimization_timeout_ms=>1},64),
    ?assertEqual(deadline_exhausted,maps:get(status,Deadline)),
    ?assertEqual(1,maps:get(target_executions,Deadline)),
    ?assertEqual({skipped,deadline},maps:get(verification,Deadline)),
    %% Ordinary raw execution has no semantic adapter dependency.
    RawO=maps:remove(gleam_layer,Replay),
    ?assertMatch({ok,#{outcome:={ok,[4,3,2,1]}}},efz_recipe:execute(B,efz_term_reverse_target,[],[],
        RawO#{expected_harness=>maps:get(harness,E)})).
stateful_campaign()->
    D=directory("stateful"),O=(efz_stateful_target:options())#{property=>#{callback=>{efz_stateful_target,property}}},
    {ok,B}=efz_term_codec:encode([[{{'$efz_resource',counter},add,7},{{'$efz_resource',counter},get,0}]],
        maps:get(arguments,O),#{}),
    C=(base(efz_stateful_target,[B],D))#{gleam_layer=>#{adapter=>efz_term_api_adapter,
        adapter_options=>O,structured_fraction=>100,feedback=>guided,oracle=>inline}},
    R=campaign(C),?assertEqual(0,maps:get(oracle_failures,maps:get(gleam_stats,R),0)),
    ?assert(maps:get(oracle_passes,maps:get(gleam_stats,R),0)>0),
    ?assertEqual(efz_stateful_target:run(B),efz_stateful_target:run(B)).
