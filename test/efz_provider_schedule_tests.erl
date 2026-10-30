-module(efz_provider_schedule_tests).
-include_lib("eunit/include/eunit.hrl").

entries()->[#{id=>1,input=><<0>>}].
native_config()->
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{17,23,41},stages=>[bitflip],
        max_input_bytes=>64,max_idle_visits=>1},[<<0>>]),C.
provider(Mode,OnSkip)->
    #{mode=>Mode,weights=>[{native,70},{erlamsa,30}],options=>#{},
      limits=>#{input_bytes=>64,output_bytes=>64,intermediate_bytes=>64,
        depth=>4,nodes=>128,entries=>16,entry_bytes=>64,unpacked_bytes=>64,
        expansion_ratio=>32,operations=>8,repeats=>4,block_bytes=>16},
      timeout=>1000,on_skip=>OnSkip,core_context=>#{fixture=>true},
      core_identity=>#{fixture_identity=><<1:256>>},core_path=>"/trusted/fixture/ebin",
      config_identity=><<2:256>>}.
configured(P)->C=(native_config())#{provider=>P},
    C#{config_id=>efz_mutation_plan:config_identity(C)}.
plan(Mode,OnSkip)->efz_mutation_plan:new(configured(provider(Mode,OnSkip))).
request(S)->efz_mutation_plan:next(S,entries()).

native_configuration_and_choices_unchanged_test()->
    Campaign=#{target=>efz_continuous_fixture,seeds=>[<<0>>],coverage_backend=>none,
        mutation_mode=>staged,max_iterations=>1,
        mutation=>#{seed=>{17,23,41},stages=>[bitflip]}},
    {ok,Default}=efz_config:prepare(Campaign),
    {ok,Explicit}=efz_config:prepare(Campaign#{mutation_provider=>native}),
    ?assertEqual(Default,Explicit),
    Mutation=maps:get(mutation,Default),
    ?assertNot(maps:is_key(provider,Mutation)),
    ?assertNot(maps:is_key(mutation_provider,Explicit)),
    S=efz_mutation_plan:new(Mutation),
    ?assertNot(maps:is_key(provider_counts,S)),
    {candidate,<<128>>,P,Next}=request(S),
    ?assertNot(maps:is_key(source_kind,P)),
    ?assertEqual(maps:get(rng,S),maps:get(rng,Next)),
    ?assertEqual({ok,<<128>>},efz_recipe:regenerate(efz_recipe:make(P,<<128>>,Mutation,#{}))).

native_random_choices_ignore_process_rng_test()->
    {ok,C}=efz_mutation_plan:prepare(#{seed=>{17,23,41},stages=>[havoc],
        max_input_bytes=>64,max_idle_visits=>64},[<<0>>]),
    Seed=efz_mutation_plan:new(C),
    First=native_choices(32,Seed,[]),
    _=rand:seed(exsplus,{100,200,300}),
    _=[rand:uniform(1000000)||_<-lists:seq(1,100)],
    ?assertEqual(First,native_choices(32,Seed,[])).

native_choices(0,S,Acc)->{lists:reverse(Acc),S};
native_choices(N,S,Acc)->case request(S) of
    {candidate,Out,P,Next}->native_choices(N-1,Next,[{Out,P}|Acc]);
    {skip,Why,Next}->native_choices(N-1,Next,[{skip,Why}|Acc]);
    {done,Why,Next}->{lists:reverse([{done,Why}|Acc]),Next}
end.

enabled_random_rejected_before_target_loading_test()->
    Target=efz_provider_target_must_not_load,
    ?assertEqual(false,code:is_loaded(Target)),
    Base=#{target=>Target,seeds=>[<<0>>],coverage_backend=>none},
    lists:foreach(fun(Option)->
        ?assertEqual({error,mutation_provider_requires_staged_mode},
            efz_config:prepare(Base#{mutation_provider=>Option})),
        ?assertEqual(false,code:is_loaded(Target))
    end,[erlamsa,hybrid,#{mode=>erlamsa,core_path=>"/missing/ebin"}]).

enabled_missing_core_rejected_before_target_loading_test()->
    Target=efz_provider_target_must_not_load,
    Base=#{target=>Target,seeds=>[<<0>>],coverage_backend=>none,
        mutation_mode=>staged,max_iterations=>1,
        mutation_provider=>#{mode=>erlamsa,core_path=>"/efz-core-does-not-exist"}},
    ?assertEqual(false,code:is_loaded(Target)),
    ?assertEqual({error,{mutation_provider_configuration,missing_core}},efz_config:prepare(Base)),
    ?assertEqual(false,code:is_loaded(Target)).

source_weights_and_timeout_validation_test()->
    Invalid=[#{weights=>[{native,1},{native,2}]},
        #{weights=>[{unknown,1}]},#{weights=>[{native,-1}]},
        #{weights=>[{native,1.0}]},#{weights=>[{native,0},{erlamsa,0}]},
        #{timeout=>0},#{timeout=>60001},#{on_skip=>hidden_fallback}],
    lists:foreach(fun(Option)->
        ?assertMatch({error,{mutation_provider_configuration,_}},
            efz_mutation_provider:prepare(Option#{mode=>erlamsa},64))
    end,Invalid),
    ?assertMatch({error,{mutation_provider_configuration,unknown_option}},
        efz_mutation_provider:prepare(#{mode=>native,timeout=>1000},64)).

provider_paths_are_not_configuration_identity_test()->
    P=provider(erlamsa,skip),A=configured(P),
    B=configured(P#{core_path=>"/another/local/ebin",core_context=>#{different=>true}}),
    ?assertEqual(maps:get(config_id,A),maps:get(config_id,B)),
    ?assertNotEqual(maps:get(config_id,native_config()),maps:get(config_id,A)).

child_seed_is_explicit_and_repeatable_test()->
    S=plan(erlamsa,skip),
    First={provider_request,<<0>>,Request,P,_Cont,Next}=request(S),
    ?assertEqual(First,request(S)),
    {A,R1}=rand:uniform_s(1 bsl 64,maps:get(rng,S)),
    {B,R2}=rand:uniform_s(1 bsl 64,R1),{D,R3}=rand:uniform_s(1 bsl 64,R2),
    ?assertEqual({A-1,B-1,D-1},maps:get(seed,Request)),
    ?assertEqual(R3,maps:get(rng,Next)),
    ?assertEqual(#{seed=>{A-1,B-1,D-1},operator=>auto,pattern=>auto,strategy=>auto,budget=>8},Request),
    ?assertEqual(1,maps:get(request_number,maps:get(provider,P))),
    ?assertEqual(1,maps:get(provider_sequence,Next)),
    ?assertEqual(1,maps:get(requests,maps:get(provider_counts,Next))).

completion_provenance_and_numbering_test()->
    {provider_request,_,Request,_,Cont,Waiting}=request(plan(erlamsa,skip)),
    CoreRecipe=#{operations_used=>1,fixture=>true},
    {candidate,<<1>>,P,Next}=efz_mutation_plan:complete_provider(
        {ok,<<1>>,CoreRecipe},#{elapsed_us=>10},Cont,Waiting),
    Data=maps:get(provider,P),
    ?assertEqual(provider,maps:get(source_kind,P)),
    ?assertEqual([{provider_replace,1,efz_mutation:hash(<<1>>),<<1>>}],maps:get(operations,P)),
    ?assertEqual(Request,maps:get(request,Data)),
    ?assertEqual(term_to_binary(CoreRecipe,[deterministic]),maps:get(recipe,Data)),
    ?assertEqual(erlamsa,maps:get(source,Data)),?assertEqual(none,maps:get(fallback,Data)),
    ?assertNot(maps:is_key(core_path,Data)),?assertNot(maps:is_key(core_context,Data)),
    ?assertEqual(1,maps:get(changed,maps:get(provider_counts,Next))),
    {provider_request,_,_,P2,_,_}=request(Next),
    ?assertEqual(2,maps:get(request_number,maps:get(provider,P2))).

skip_does_not_stall_on_native_deterministic_pending_test()->
    {provider_request,_,_,_,Cont,Waiting}=request(plan(erlamsa,skip)),
    {skip,{provider,<<"no_change">>},Next}=efz_mutation_plan:complete_provider(
        {skip,no_change},#{},Cont,Waiting),
    ?assertMatch({done,idle_budget_exhausted,_},request(Next)),
    Counts=maps:get(provider_counts,Next),
    ?assertEqual(1,maps:get(skips,Counts)),
    ?assertEqual(#{<<"no_change">>=>1},maps:get(skip_reasons,Counts)),
    [Cursor]=maps:values(maps:get(cursors,Next)),
    ?assertEqual(0,maps:get(bitflip,Cursor,0)).

continuous_skip_keeps_provider_schedule_test()->
    {provider_request,_,_,_,Cont,Waiting}=request(plan(erlamsa,skip)),
    {skip,_,Idle}=efz_mutation_plan:complete_provider({skip,no_change},#{},Cont,Waiting),
    {provider_request,<<0>>,_,P,_,Next}=efz_mutation_plan:next_continuous(Idle,entries()),
    ?assertEqual(erlamsa,maps:get(source,maps:get(provider,P))),
    ?assertEqual(2,maps:get(provider_sequence,Next)),
    ?assertEqual(0,maps:get(continuous_fallbacks,maps:get(counts,Next),0)).

skip_fallback_runs_native_once_and_records_reason_test()->
    {provider_request,_,Request,_,Cont,Waiting}=request(plan(erlamsa,native)),
    {candidate,<<128>>,P,Next}=efz_mutation_plan:complete_provider(
        {skip,no_match},#{},Cont,Waiting),
    Data=maps:get(provider,P),
    ?assertEqual(native,maps:get(source,Data)),?assertEqual(<<"no_match">>,maps:get(fallback,Data)),
    ?assertEqual(Request,maps:get(request,Data)),?assertEqual(#{},maps:get(recipe,Data)),
    ?assertEqual([{flip_bits,0,1}],maps:get(operations,P)),
    Counts=maps:get(provider_counts,Next),
    ?assertEqual(1,maps:get(requests,Counts)),?assertEqual(1,maps:get(fallbacks,Counts)),
    ?assertEqual(#{native=>1,erlamsa=>0},maps:get(generated,Counts)).

errors_and_timeouts_never_fall_back_test()->
    {provider_request,_,_,_,Cont,Waiting}=request(plan(erlamsa,native)),
    {error,{mutation_provider,broken},Failed}=efz_mutation_plan:complete_provider(
        {error,broken},#{},Cont,Waiting),
    ?assertEqual(0,maps:get(fallbacks,maps:get(provider_counts,Failed))),
    ?assertEqual(1,maps:get(errors,maps:get(provider_counts,Failed))),
    {error,{mutation_provider,{timeout,deadline}},Timed}=efz_mutation_plan:complete_provider(
        {timeout,deadline},#{},Cont,Waiting),
    ?assertEqual(1,maps:get(timeouts,maps:get(provider_counts,Timed))),
    ?assertEqual(0,maps:get(fallbacks,maps:get(provider_counts,Timed))),
    ?assertMatch({error,{mutation_provider,oversized_output},_},
        efz_mutation_plan:complete_provider({ok,<<0:520>>,#{}},#{},Cont,Waiting)),
    ?assertMatch({error,{mutation_provider,invalid_recipe_data},_},
        efz_mutation_plan:complete_provider({ok,<<1>>,#{pid=>self()}},#{},Cont,Waiting)),
    ?assertMatch({error,{mutation_provider,invalid_reply},_},
        efz_mutation_plan:complete_provider({skip,{unexpected,reason}},#{},Cont,Waiting)).

native_hybrid_provenance_test()->
    P=(provider(hybrid,skip))#{weights=>[{native,100},{erlamsa,0}]},
    {candidate,<<128>>,Prov,Next}=request(efz_mutation_plan:new(configured(P))),
    Data=maps:get(provider,Prov),
    ?assertEqual(native,maps:get(source,Data)),?assertEqual(none,maps:get(request,Data)),
    ?assertEqual(none,maps:get(request_number,Data)),?assertEqual(none,maps:get(fallback,Data)),
    Counts=maps:get(provider_counts,Next),
    ?assertEqual(#{native=>1,erlamsa=>0},maps:get(selected,Counts)),
    ?assertEqual(0,maps:get(requests,Counts)).

semantic_adapter_precedes_ordinary_provider_test()->
    %% This existing semantic adapter is ordinary Erlang and needs no optional
    %% Gleam runtime. All its operations change a nonempty valid payload.
    {ok,Campaign}=efz_config:prepare(#{target=>efz_plugin_length_target,
        seeds=>[<<1:16,0>>],coverage_backend=>none,max_input_bytes=>64,
        mutation_mode=>staged,max_iterations=>1,mutation=>#{seed=>{17,23,41},stages=>[bitflip]},
        gleam_layer=>#{adapter=>efz_plugin_length_adapter,structured_fraction=>100}}),
    C0=(maps:get(mutation,Campaign))#{provider=>provider(erlamsa,skip)},
    C=C0#{config_id=>efz_mutation_plan:config_identity(C0)},
    {candidate,_,P,Next}=efz_mutation_plan:next(efz_mutation_plan:new(C),
        [#{id=>1,input=><<1:16,0>>}]),
    ?assertEqual(structured,maps:get(source_kind,P)),
    ?assertNot(maps:is_key(provider,P)),
    ?assertEqual(0,maps:get(requests,maps:get(provider_counts,Next))),
    ?assertEqual(#{native=>0,erlamsa=>0},maps:get(selected,maps:get(provider_counts,Next))).

hybrid_choices_repeat_with_frozen_corpus_test()->
    C=configured(provider(hybrid,skip)),
    {Choices,Final}=choices(40,efz_mutation_plan:new(C),[]),
    ?assertEqual({Choices,Final},choices(40,efz_mutation_plan:new(C),[])),
    Selected=maps:get(selected,maps:get(provider_counts,Final)),
    ?assert(maps:get(native,Selected)>0),?assert(maps:get(erlamsa,Selected)>0).
choices(0,S,Acc)->{lists:reverse(Acc),S};
choices(N,S,Acc)->case request(S) of
    {candidate,Out,P,Next}->choices(N-1,Next,[{maps:get(source,maps:get(provider,P)),Out}|Acc]);
    {provider_request,_,Req,_,Cont,Waiting}->
        {candidate,_,_,Next}=efz_mutation_plan:complete_provider({ok,<<255>>,#{}},#{},Cont,Waiting),
        choices(N-1,Next,[{erlamsa,maps:get(seed,Req)}|Acc]);
    {skip,Why,Next}->choices(N-1,Next,[{skip,Why}|Acc]);
    {done,_,Next}->choices(N-1,Next,[done|Acc])
end.
