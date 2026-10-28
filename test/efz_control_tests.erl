-module(efz_control_tests).
-include_lib("eunit/include/eunit.hrl").

json_bounds_test() ->
    ?assertEqual({error,invalid_json},efz_control_json:decode(<<"{\"a\":1,\"a\":2}">>)),
    Deep=iolist_to_binary([lists:duplicate(25,$[),"0",lists:duplicate(25,$])]),
    ?assertEqual({error,invalid_json},efz_control_json:decode(Deep)),
    ?assertEqual({ok,#{<<"literal">>=><<"[[]]">>}},efz_control_json:decode(<<"{\"literal\":\"[[]]\"}">>)).

binary_envelope_test() ->
    Raw=list_to_binary(lists:seq(0,255)),
    ?assertEqual(Raw,efz_control_json:bytes(#{<<"base64">>=>base64:encode(Raw)},256)),
    ?assertError({badmatch,false},efz_control_json:bytes(#{<<"base64">>=><<"AB==">>},1)),
    ?assertError({badmatch,false},efz_control_json:bytes(#{<<"base64">>=>base64:encode(Raw)},255)).

static_config_test() ->
    C=efz_control_json:campaign(#{<<"target">>=><<"local_fixture">>,
        <<"seeds">>=>[#{<<"base64">>=><<"AA==">>}],<<"mutation_mode">>=><<"staged">>,
        <<"mutation_provider">>=>#{<<"mode">>=><<"erlamsa">>,<<"options">>=>#{<<"profile">>=><<"fields">>,
            <<"field">>=>#{<<"offset">>=>0,<<"width">>=>16,<<"endian">>=><<"big">>,
                <<"payload_offset">>=>2,<<"payload_length">>=>4}}},
        <<"gleam_layer">>=>#{<<"adapter">>=><<"efz_qs_adapter">>,<<"feedback">>=><<"guided">>}}),
    ?assertEqual("local_fixture",maps:get(target,C)),
    ?assertEqual([<<0>>],maps:get(seeds,C)),
    ?assertEqual(erlamsa,maps:get(mode,maps:get(mutation_provider,C))),
    ?assertEqual(efz_qs_adapter,maps:get(adapter,maps:get(gleam_layer,C))),
    ?assertException(error,_,efz_control_json:campaign(#{<<"mutator">>=><<"arbitrary_module">>})),
    ?assertException(error,_,efz_control_json:campaign(#{<<"gleam_layer">>=>#{<<"adapter">>=><<"arbitrary_module">>}})).

request_schema_test() ->
    ?assertEqual({12,stats,#{}},efz_control_json:request(#{<<"version">>=>1,<<"id">>=>12,<<"op">>=><<"stats">>})),
    ?assertEqual({12,cancel,#{<<"target_id">>=>11}},efz_control_json:request(
        #{<<"version">>=>1,<<"id">>=>12,<<"op">>=><<"cancel">>,
          <<"args">>=>#{<<"target_id">>=>11}})),
    ?assertException(error,_,efz_control_json:request(#{<<"version">>=>1,<<"id">>=>12,<<"op">>=><<"eval">>})),
    ?assertEqual(#{seed=>{1,2,3},pattern=>[once,burst]},efz_control_json:mutation_request(
        #{<<"seed">>=>[1,2,3],<<"pattern">>=>[<<"once">>,<<"burst">>]})).

summary_excludes_diagnostics_test() ->
    R=#{status=>completed,stats=>#{executions=>12,primary_infrastructure_failure=>{self(),make_ref()}},
        corpus=>[#{input=><<0,255>>}],coverage=>[some_probe],arbitrary=>fun()->ok end},
    S=efz_control:report_summary(R,"/tmp/efz-control-summary"),
    ?assertEqual(12,maps:get(executions,maps:get(stats,S))),
    ?assertNot(maps:is_key(primary_infrastructure_failure,maps:get(stats,S))),
    ?assertNot(maps:is_key(corpus,S)),
    ?assertMatch({ok,_},efz_control_json:decode(efz_control_json:encode(S))).

summary_keeps_provider_measurements_test() ->
    R=#{status=>completed,provider=>#{mode=>hybrid,config_identity=><<0,255>>},
        provider_stats=>#{requests=>3,changed=>2,skip_reasons=>#{<<"format">>=>1}}},
    S=efz_control:report_summary(R,"/tmp/efz-control-summary"),
    {ok,Json}=efz_control_json:decode(efz_control_json:encode(S)),
    ?assertEqual(3,maps:get(<<"requests">>,maps:get(<<"provider_stats">>,Json))),
    ?assertEqual(#{<<"base64">>=><<"AP8=">>},
        maps:get(<<"config_identity">>,maps:get(<<"provider">>,Json))).

provider_cli_overrides_test() ->
    Base=#{mode=>erlamsa,weights=>[{native,2},{erlamsa,8}],
        timeout=>4000,limits=>#{depth=>2},options=>#{operators=>[{byte_flip,1}],profile=>bytes}},
    New=efz_cli:provider_options(Base,#{provider_mode=>hybrid,provider_timeout=>2000,
        provider_strategy=>preserve}),
    ?assertEqual(hybrid,maps:get(mode,New)),
    ?assertEqual(2000,maps:get(timeout,New)),
    ?assertEqual(maps:get(weights,Base),maps:get(weights,New)),
    ?assertEqual(maps:get(limits,Base),maps:get(limits,New)),
    ?assertEqual(#{operators=>[{byte_flip,1}],profile=>bytes,strategy=>preserve},maps:get(options,New)),
    ?assertEqual(native,efz_cli:provider_options(Base,#{provider_mode=>native})).
