-module(efz_plugin_contract_tests).
-include_lib("eunit/include/eunit.hrl").

base() ->
    {module,efz_plugin_length_target}=code:ensure_loaded(efz_plugin_length_target),
    #{target=>efz_plugin_length_target,mutation_mode=>staged,max_input_bytes=>4096,
        manifests=>[],mutation=>#{}}.
prepared(Module,Options,Extra) ->
    Layer=maps:merge(#{adapter=>Module,adapter_options=>Options,structured_fraction=>0,
        feedback=>disabled,oracle=>disabled},Extra),
    {ok,C}=efz_gleam_adapter:prepare(Layer,base()),maps:get(gleam_layer,C).

independent_wire_plugin_test() ->
    P=prepared(efz_plugin_length_adapter,#{},#{structured_fraction=>100,feedback=>guided}),
    ?assertEqual([100,101,102],efz_gleam_adapter:operations(P)),
    {ok,Raw}=efz_gleam_adapter:generate(2,P),
    ?assertEqual({payload,4},efz_plugin_length_target:run(Raw)),
    {ok,Changed,Recipe}=efz_gleam_adapter:mutate(Raw,100,#{choice=>42},P),
    ?assertEqual({payload,5},efz_plugin_length_target:run(Changed)),
    ?assertEqual({ok,Changed,Recipe},efz_gleam_adapter:mutate(Raw,100,#{choice=>42},P)),
    ?assertMatch({skip,_},efz_gleam_adapter:mutate(<<"bad wire">>,100,#{choice=>0},P)),
    {ok,Features}=efz_gleam_adapter:observe(Changed,{ok,efz_plugin_length_target:run(Changed)},P),
    ?assert(lists:member({<<"fixture.length_prefix">>,1,1},Features)),
    ?assertEqual({inconclusive,capability_disabled},efz_gleam_adapter:oracle(Changed,{ok,anything},P)).

partial_capabilities_test() ->
    Observer=prepared(efz_plugin_observer_adapter,#{},#{feedback=>observation_only}),
    Generator=prepared(efz_plugin_generator_adapter,#{},#{}),
    ?assertEqual({ok,[{<<"fixture.observer_a">>,1,1}]},efz_gleam_adapter:observe(<<0>>,anything,Observer)),
    ?assertEqual({skip,capability_disabled},efz_gleam_adapter:generate(0,Observer)),
    ?assertEqual({ok,<<0:16>>},efz_gleam_adapter:generate(0,Generator)),
    ?assertEqual({skip,capability_disabled},efz_gleam_adapter:observe(<<>>,anything,Generator)),
    ?assertNot(erlang:function_exported(efz_plugin_observer_adapter,generate,2)),
    ?assertNot(erlang:function_exported(efz_plugin_observer_adapter,mutate,4)),
    ?assertNot(erlang:function_exported(efz_plugin_observer_adapter,oracle,3)),
    ?assertNot(erlang:function_exported(efz_plugin_generator_adapter,observe,3)),
    ?assertNot(erlang:function_exported(efz_plugin_generator_adapter,mutate,4)),
    ?assertNot(erlang:function_exported(efz_plugin_generator_adapter,oracle,3)).

feature_namespaces_test() ->
    A=prepared(efz_plugin_observer_adapter,#{},#{feedback=>guided}),
    B=prepared(efz_plugin_other_observer_adapter,#{},#{feedback=>guided}),
    {ok,Fa}=efz_gleam_adapter:observe(<<>>,anything,A),
    {ok,Fb}=efz_gleam_adapter:observe(<<>>,anything,B),
    ?assertEqual([{<<"fixture.observer_a">>,1,1}],Fa),
    ?assertEqual([{<<"fixture.observer_b">>,1,1}],Fb),
    ?assertEqual([],ordsets:intersection(Fa,Fb)),
    Id=efz_gleam_adapter:identity(B),
    ?assert(lists:any(fun(#{module:=M})->M=:=<<"efz_plugin_observer_adapter">> end,maps:get(code,Id))).

callback_boundary_errors_test() ->
    Bad=prepared(efz_plugin_observer_adapter,#{mode=>invalid},#{}),
    ?assertEqual({error,{semantic_layer_error,error,invalid_observer_result}},
        efz_gleam_adapter:observe(<<>>,anything,Bad)),
    Throw=prepared(efz_plugin_observer_adapter,#{mode=>exception},#{}),
    ?assertEqual({error,{semantic_layer_error,error,fixture_callback_error}},
        efz_gleam_adapter:observe(<<>>,anything,Throw)),
    Large=prepared(efz_plugin_observer_adapter,#{mode=>large_error},#{}),
    ?assertEqual({error,invalid_boundary},efz_gleam_adapter:observe(<<>>,anything,Large)).

startup_failures_test() ->
    ?assertEqual({error,{gleam_configuration,{adapter_callback_unavailable,
        efz_plugin_missing_adapter,observe,3}}},
        efz_gleam_adapter:prepare(#{adapter=>efz_plugin_missing_adapter,structured_fraction=>0},base())),
    ?assertMatch({error,{gleam_configuration,{adapter_module_unavailable,_,_}}},
        efz_gleam_adapter:prepare(#{adapter=>efz_plugin_unknown_fixture,structured_fraction=>0},base())),
    ?assertEqual({error,{gleam_configuration,missing_mutation_capability}},
        efz_gleam_adapter:prepare(#{adapter=>efz_plugin_observer_adapter,structured_fraction=>1},base())),
    ?assertEqual({error,{gleam_configuration,missing_observation_capability}},
        efz_gleam_adapter:prepare(#{adapter=>efz_plugin_generator_adapter,
            structured_fraction=>0,feedback=>guided},base())),
    ?assertEqual({error,{gleam_configuration,incompatible_length_prefix_contract}},
        efz_gleam_adapter:prepare(#{adapter=>efz_plugin_length_adapter,structured_fraction=>0},
            (base())#{target=>efz_qs_target})),
    ?assertEqual({error,{gleam_configuration,invalid_observer_fixture_options}},
        efz_gleam_adapter:prepare(#{adapter=>efz_plugin_observer_adapter,
            structured_fraction=>0,adapter_options=>#{mode=>unknown}},base())),
    ?assertEqual({error,{gleam_configuration,invalid_gleam_coverage_selection}},
        efz_gleam_adapter:prepare(#{adapter=>efz_plugin_other_observer_adapter,structured_fraction=>0},
            (base())#{manifests=>[#{module=>efz_plugin_observer_adapter}]})).

output_limit_test() ->
    P=prepared(efz_plugin_length_adapter,#{},#{limits=>#{bytes=>2}}),
    ?assertEqual({ok,<<0:16>>},efz_gleam_adapter:generate(0,P)),
    ?assertEqual({skip,limit},efz_gleam_adapter:generate(1,P)),
    ?assertEqual({skip,limit},efz_gleam_adapter:mutate(<<0:16>>,100,#{choice=>0},P)),
    ?assertEqual({error,boundary},efz_gleam_adapter:mutate(<<0:16>>,0,#{choice=>0},P)),
    ?assertEqual({error,boundary},efz_gleam_adapter:mutate(<<0:16>>,100,#{choice=>65536},P)).

prepared_context_identity_test() ->
    try
        put({efz_plugin_context_adapter,context},1),
        A=prepared(efz_plugin_context_adapter,#{},#{}),
        ?assertEqual(efz_gleam_adapter:identity(A),
            efz_gleam_adapter:identity(prepared(efz_plugin_context_adapter,#{},#{}))),
        put({efz_plugin_context_adapter,context},2),
        B=prepared(efz_plugin_context_adapter,#{},#{}),
        ?assertNotEqual(efz_gleam_adapter:identity(A),efz_gleam_adapter:identity(B)),
        ?assert(efz_gleam_adapter:identity_valid(efz_gleam_adapter:identity(B)))
    after erase({efz_plugin_context_adapter,context}) end.
