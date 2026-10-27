-module(efz_erlamsa_integration_tests).
-include_lib("eunit/include/eunit.hrl").

%% Optional core tests are explicit: ordinary EFZ builds have no vendor checkout.
%% Validation records must distinguish an unset path from a successful run.
erlamsa_integration_test_()->
    case os:getenv("EFZ_ERLAMSA_CORE_PATH") of
        false->[];
        Path->{timeout,90,[
            {"real core preserves deterministic arbitrary binary requests",{timeout,30,fun()->binary_requests(Path) end}},
            {"real core planner provenance regenerates exactly",{timeout,30,fun()->planner_recipe(Path) end}},
            {"real core mutates decoded wrappers",{timeout,30,fun()->wrapped_inputs(Path) end}},
            {"continuous provider stop persists provenance across restart",{timeout,30,fun()->continuous_restart(Path) end}},
            {"hybrid keeps the existing semantic adapter",{timeout,30,fun()->semantic_hybrid(Path) end}}
            ]++case code:which(efz_qs_model) of
                non_existing->[];
                _->[{"hybrid keeps compiled Gleam observation",{timeout,30,fun()->gleam_hybrid(Path) end}}]
            end}
    end.

provider_options(Path)->#{mode=>erlamsa,core_path=>Path,timeout=>5000,on_skip=>skip,
    options=>#{operators=>[{byte_flip,1},{byte_insert,1}],patterns=>[{once,1}]},
    limits=>#{operations=>1}}.
prepare(Path)->
    {ok,P}=efz_mutation_provider:prepare(provider_options(Path),1024),P.
request(Operator)->#{seed=>{17,23,41},operator=>Operator,pattern=>once,strategy=>auto,budget=>1}.

binary_requests(Path)->
    P=prepare(Path),
    Inputs=[<<>>,<<0>>,list_to_binary(lists:seq(0,255)),<<255,254,128,0,195,40>>],
    lists:foreach(fun(Input)->
        Op=case Input of <<>>->byte_insert;_->byte_flip end,
        Req=request(Op),
        First={ok,Out,_}=efz_mutation_provider:mutate(Input,Req,P),
        ?assertNotEqual(Input,Out),
        ?assertEqual(First,efz_mutation_provider:mutate(Input,Req,P)),
        %% Unrelated previous calls and target/process PRNG draws are irrelevant.
        _=rand:seed(exsplus,{100,200,300}),_=rand:uniform(),
        ?assertMatch({ok,_,_},efz_mutation_provider:mutate(<<1,2,3>>,request(byte_flip),P)),
        ?assertEqual(First,efz_mutation_provider:mutate(Input,Req,P))
    end,Inputs),
    ?assertMatch({ok,_,_},efz_mutation_provider:mutate(binary:copy(<<0>>,1024),request(byte_flip),P)),
    ?assertEqual({skip,input_limit},efz_mutation_provider:mutate(binary:copy(<<0>>,1025),request(byte_flip),P)),
    ?assertEqual({error,invalid_provider_request},
        efz_mutation_provider:mutate(<<0>>,(request(byte_flip))#{unexpected=>true},P)).

planner_recipe(Path)->
    P=prepare(Path),Input = <<"local bytes",0,255>>,
    {ok,C0}=efz_mutation_plan:prepare(#{seed=>{17,23,41},stages=>[havoc],max_input_bytes=>1024},[Input]),
    C1=C0#{provider=>P},C=C1#{config_id=>efz_mutation_plan:config_identity(C1)},
    {provider_request,Input,Req,_,Cont,Waiting}=efz_mutation_plan:next(
        efz_mutation_plan:new(C),[#{id=>1,input=>Input}]),
    Result={ok,Out,_}=efz_mutation_provider:mutate(Input,Req,P),
    {candidate,Out,Provenance,_}=efz_mutation_plan:complete_provider(Result,#{},Cont,Waiting),
    Recipe=efz_recipe:make(Provenance,Out,C,#{}),
    ?assert(efz_mutation_provider:valid_recipe_data(maps:get(provider,Recipe))),
    ?assertEqual({ok,Out},efz_recipe:regenerate(Recipe)),
    {ok,Encoded}=efz_recipe:encode(Recipe),
    ?assertEqual({ok,Recipe},efz_recipe:decode(Encoded)),
    ?assertEqual({ok,Out},efz_recipe:regenerate_provider(Recipe,P)),
    I=maps:get(core_identity,P),
    ?assertEqual({error,provider_recipe_identity_mismatch},
        efz_recipe:regenerate_provider(Recipe,P#{core_identity=>I#{app_sha256=><<0:256>>}})),
    ?assertEqual({error,provider_recipe_configuration_mismatch},
        efz_recipe:regenerate_provider(Recipe,P#{config_identity=><<0:256>>})).

wrapped_inputs(Path)->
    Payload = <<"content in a local wrapper",0,255>>,
    Cases=[{base64,base64:encode(Payload),fun base64:decode/1},
        {gzip,zlib:gzip(Payload),fun zlib:gunzip/1},
        {zlib,zlib:compress(Payload),fun zlib:uncompress/1}],
    lists:foreach(fun({Operator,Input,Decode})->
        Options=(provider_options(Path))#{options=>#{operators=>[{Operator,1}],
            patterns=>[{once,1}],inner_operator=>byte_flip},limits=>#{operations=>2}},
        {ok,P}=efz_mutation_provider:prepare(Options,1024),
        Req=(request(Operator))#{budget=>2},
        {ok,Changed,Meta}=efz_mutation_provider:mutate(Input,Req,P),
        Decoded=Decode(Changed),
        ?assertEqual(byte_size(Payload),byte_size(Decoded)),
        ?assertNotEqual(Payload,Decoded),
        ?assertEqual({ok,Changed,Meta},efz_mutation_provider:mutate(Input,Req,P))
    end,Cases).

campaign(Path)->#{target=>efz_erlamsa_fixture,coverage=>manual,seeds=>[<<0>>],
    mutation_mode=>staged,max_iterations=>infinity,max_input_bytes=>1024,
    mutation=>#{seed=>{17,23,41},stages=>[bitflip],trace_limit=>32},
    mutation_provider=>(provider_options(Path))#{options=>#{operators=>[{byte_flip,1}],patterns=>[{once,1}]}},
    selection_seed=>{17,23,41}}.

continuous_restart(Path)->
    Dir=filename:absname("_build/erlamsa-restart-"++integer_to_list(erlang:unique_integer([positive]))),
    C=(campaign(Path))#{corpus_dir=>Dir},
    try
        {ok,F}=efz:start(C),wait_executions(1,10000),
        %% Stop an in-flight mutation, not just between two successful targets.
        wait_pending(F,10000),Start=erlang:monotonic_time(millisecond),
        ok=efz:request_stop(),ok=efz:request_stop(),First=efz:await(8000),
        ?assert(erlang:monotonic_time(millisecond)-Start<8000),
        assert_campaign(First,stopped_by_user),
        Recipes=[maps:get(mutation,maps:get(metadata,E))||E<-maps:get(corpus,First),
            maps:is_key(mutation,maps:get(metadata,E))],
        ?assertMatch([_|_],Recipes),
        [Stored|_]=Recipes,
        ?assertEqual(erlamsa,maps:get(source,maps:get(provider,Stored))),
        ?assertMatch({ok,_},efz_recipe:regenerate(Stored)),
        ok=efz:stop(),
        {ok,_}=efz:start(C#{seeds=>[],max_iterations=>0}),Second=efz:await(10000),
        assert_campaign(Second,completed),
        ?assertEqual(length(maps:get(corpus,First)),maps:get(restored_inputs,maps:get(corpus_restore,Second))),
        Restored=[maps:get(persistence,maps:get(metadata,E))||E<-maps:get(corpus,Second)],
        RecipeBytes=[maps:get(recipe,R)||R<-Restored,maps:get(recipe,R)=/=none],
        ?assert(lists:any(fun(Bytes)->efz_recipe:decode(Bytes)=:={ok,Stored} end,RecipeBytes))
    after
        efz:stop(),_=file:del_dir_r(Dir)
    end.

semantic_hybrid(Path)->
    C=(campaign(Path))#{target=>efz_plugin_length_target,coverage=>automatic,coverage_backend=>none,
        seeds=>[<<1:16,0>>],max_iterations=>40,
        mutation_provider=>(provider_options(Path))#{mode=>hybrid,weights=>[{native,1},{erlamsa,1}]},
        gleam_layer=>#{adapter=>efz_plugin_length_adapter,structured_fraction=>30,feedback=>guided}},
    R=run(C),assert_campaign(R,completed),
    ?assert(maps:get(requests,maps:get(provider_stats,R))>0),
    ?assert(maps:get(successes,maps:get(structured_stats,R),0)>0),
    ?assert(maps:get(observer_calls,maps:get(gleam_stats,R),0)>0),
    ?assertEqual(0,maps:get(target_exceptions,maps:get(gleam_stats,R),0)).

gleam_hybrid(Path)->
    C=(campaign(Path))#{target=>efz_qs_target,coverage=>automatic,coverage_backend=>none,
        seeds=>[<<"a=1">>],max_iterations=>40,
        mutation_provider=>(provider_options(Path))#{mode=>hybrid,weights=>[{native,1},{erlamsa,1}]},
        gleam_layer=>#{adapter=>efz_qs_adapter,structured_fraction=>30,feedback=>guided,oracle=>disabled}},
    R=run(C),assert_campaign(R,completed),
    ?assert(maps:get(requests,maps:get(provider_stats,R))>0),
    ?assert(maps:get(successes,maps:get(structured_stats,R),0)>0),
    Stats=maps:get(stats,R),
    ?assertEqual(maps:get(executions,Stats)+maps:get(calibrations,Stats),
        maps:get(observer_calls,maps:get(gleam_stats,R))),
    ?assertEqual(0,maps:get(target_exceptions,maps:get(gleam_stats,R),0)).

run(C)->try {ok,_}=efz:start(C),efz:await(30000) after efz:stop() end.
assert_campaign(R,Status)->
    ?assertEqual(Status,maps:get(status,R)),Stats=maps:get(stats,R),
    ?assertEqual(0,maps:get(infrastructure_failures,Stats)),
    ?assertEqual(0,maps:get(crashes,Stats)),?assertEqual(0,maps:get(timeouts,Stats)).
wait_executions(N,Ms)->wait(fun()->maps:get(executions,efz:stats())>=N end,Ms).
wait_pending(F,Ms)->wait(fun()->
    W=maps:get(worker,sys:get_state(F)),maps:is_key(pending_mutation,sys:get_state(W)) end,Ms).
wait(F,Ms)->wait_until(F,erlang:monotonic_time(millisecond)+Ms).
wait_until(F,Deadline)->case F() of
    true->ok;
    false->case erlang:monotonic_time(millisecond)<Deadline of
        true->receive after 5->wait_until(F,Deadline) end;
        false->error(provider_campaign_stalled)
    end
end.
