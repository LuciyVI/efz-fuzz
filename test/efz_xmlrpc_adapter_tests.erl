-module(efz_xmlrpc_adapter_tests).
-include_lib("eunit/include/eunit.hrl").

descriptor_test() ->
    D = efz_xmlrpc_adapter:descriptor(),
    ?assertEqual(1, maps:get(api_version, D)),
    ?assertEqual([efz_xmlrpc_model], maps:get(model_modules, D)),
    ?assertEqual([{xmlrpc_model_agreement, 1}], maps:get(properties, D)).

invalid_options_test() ->
    ?assertMatch({error, {invalid_xmlrpc_options, _, _}},
        efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{string_bytes => 0}, limits())),
    ?assertMatch({error, {invalid_xmlrpc_options, _, _}},
        efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{methods => [<<195, 169>>]}, limits())),
    ?assertMatch({error, {invalid_xmlrpc_options, _, _}},
        efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{typo => 1}, limits())).

missing_harness_metadata_test() ->
    ?assertEqual({error, {xmlrpc_harness_contract_missing, lists}},
        efz_xmlrpc_adapter:prepare(lists, #{}, limits())).

%% Ordinary builds require neither Gleam nor the optional XML-RPC dependency.
%% Run these integration checks with the documented pinned dependency code path
%% and optional Gleam build; an unavailable dependency is visibly reported.
xmlrpc_integration_test_() ->
    case {code:ensure_loaded(efz_xmlrpc_model), code:ensure_loaded(xmlrpc_decode),
          code:ensure_loaded(efz_xmlrpc_target)} of
        {{module, efz_xmlrpc_model}, {module, xmlrpc_decode}, {module, efz_xmlrpc_target}} ->
            [fun generated_calls/0, fun mutations_and_determinism/0,
             fun finite_limits/0, fun expected_rejection_is_inconclusive/0,
             fun independent_oracle/0, fun name_normalization/0,
             fun xml_subset/0, fun shrinking/0, fun missing_actual_semantics/0,
             fun model_abi_preflight/0, fun semantic_replay/0];
        Missing ->
            io:format("XML-RPC optional integration unavailable: ~p~n", [Missing]),
            []
    end.

limits() -> #{bytes => 4096, depth => 8, nodes => 128, collection => 16, operations => 1}.
context() -> {ok, C} = efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{}, limits()), C.
primary(B) -> {ok, efz_xmlrpc_target:run(B)}.

generated_calls() ->
    C = context(),
    lists:foreach(fun(I) ->
        {ok, B} = efz_xmlrpc_adapter:generate(I, C),
        ?assert(byte_size(B) =< 4096),
        O = primary(B),
        ?assertMatch({ok, {accepted, {call, _, _}}}, O),
        ?assertEqual({pass, {xmlrpc_model_agreement, 1}}, efz_xmlrpc_adapter:oracle(B, O, C)),
        {ok, Fs} = efz_xmlrpc_adapter:observe(B, O, C),
        ?assert(length(Fs) =< 64),
        ?assert(lists:all(fun(F) -> F >= 0 andalso F =< 255 end, Fs))
    end, lists:seq(0, 17)).

mutations_and_determinism() ->
    C = context(),
    lists:foreach(fun(I) ->
        {ok, B} = efz_xmlrpc_adapter:generate(I, C),
        lists:foreach(fun(Op) ->
            lists:foreach(fun(Choice) ->
                P = #{choice => Choice},
                R = efz_xmlrpc_adapter:mutate(B, Op, P, C),
                ?assertEqual(R, efz_xmlrpc_adapter:mutate(B, Op, P, C)),
                case R of
                    {ok, Next, #{schema := 1, choice := Choice}} ->
                        ?assertMatch({ok, {accepted, _}}, primary(Next)),
                        ?assertEqual({pass, {xmlrpc_model_agreement, 1}},
                            efz_xmlrpc_adapter:oracle(Next, primary(Next), C));
                    {skip, limit} -> ok
                end
            end, [0, 1, 256, 65535])
        end, lists:seq(0, 5))
    end, lists:seq(0, 8)).

finite_limits() ->
    {ok, C} = efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{}, (limits())#{bytes => 64}),
    ?assertEqual({skip, limit}, efz_xmlrpc_adapter:generate(0, C)),
    {ok, D} = efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{}, (limits())#{depth => 1}),
    ?assertEqual({skip, limit}, efz_xmlrpc_adapter:generate(8, D)),
    {ok, N} = efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{}, (limits())#{nodes => 1}),
    ?assertEqual({skip, limit}, efz_xmlrpc_adapter:generate(1, N)),
    {ok, S} = efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{string_bytes => 3,
        methods => [<<"x">>]}, limits()),
    ?assertEqual({skip, limit}, efz_xmlrpc_adapter:generate(4, S)).

expected_rejection_is_inconclusive() ->
    C = context(),
    B = <<"<methodCall><methodName>echo</methodName><params><param><value><boolean>2</boolean></value></param></params></methodCall>">>,
    O = primary(B),
    ?assertMatch({ok, {rejected, _}}, O),
    ?assertEqual({inconclusive, unsupported}, efz_xmlrpc_adapter:oracle(B, O, C)),
    ?assertEqual({ok, [1]}, efz_xmlrpc_adapter:observe(B, O, C)),
    ?assertEqual({skip, unsupported}, efz_xmlrpc_adapter:mutate(B, 0, #{choice => 1}, C)).

independent_oracle() ->
    C = context(),
    {ok, B} = efz_xmlrpc_adapter:generate(1, C),
    ?assertEqual({fail, {xmlrpc_model_agreement, 1}},
        efz_xmlrpc_adapter:oracle(B, {ok, {accepted, {call, echo, [99]}}}, C)),
    ?assertEqual({pass, {xmlrpc_model_agreement, 1}},
        efz_xmlrpc_adapter:oracle(B, {ok, {accepted, {call, "echo", [0]}}}, C)).

name_normalization() ->
    %% Both existing atom and uninterned charlist names have the same model type.
    _ = echo,
    Unknown = <<"efz_xmlrpc_uninterned_test_name_v1">>,
    ?assertError(badarg, binary_to_existing_atom(Unknown, utf8)),
    {ok, C} = efz_xmlrpc_adapter:prepare(efz_xmlrpc_target, #{methods => [Unknown]}, limits()),
    {ok, B} = efz_xmlrpc_adapter:generate(7, C),
    ?assertMatch({ok, {accepted, {call, "efz_xmlrpc_uninterned_test_name_v1", _}}}, primary(B)),
    ?assertEqual({pass, {xmlrpc_model_agreement, 1}}, efz_xmlrpc_adapter:oracle(B, primary(B), C)),
    ?assertError(badarg, binary_to_existing_atom(Unknown, utf8)).

xml_subset() ->
    C = context(),
    {ok, B} = efz_xmlrpc_adapter:generate(4, C),
    Header = <<"<?xml version=\"1.0\"?>", B/binary>>,
    ?assertEqual({pass, {xmlrpc_model_agreement, 1}}, efz_xmlrpc_adapter:oracle(Header, primary(Header), C)),
    Unsupported = <<"<methodResponse><params><param><value><string>ok</string></value></param></params></methodResponse>">>,
    ?assertMatch({ok, {accepted, {response, _}}}, primary(Unsupported)),
    ?assertEqual({inconclusive, unsupported}, efz_xmlrpc_adapter:oracle(Unsupported, primary(Unsupported), C)),
    ?assertEqual({skip, unsupported}, efz_xmlrpc_adapter:mutate(<<195, 169>>, 0, #{choice => 0}, C)).

shrinking() ->
    C = context(),
    {ok, B} = efz_xmlrpc_adapter:generate(8, C),
    {ok, Candidates} = efz_xmlrpc_adapter:shrink(B, C),
    ?assert(Candidates =/= []),
    lists:foreach(fun(S) ->
        ?assert(byte_size(S) < byte_size(B)),
        ?assertEqual({pass, {xmlrpc_model_agreement, 1}}, efz_xmlrpc_adapter:oracle(S, primary(S), C))
    end, Candidates).

missing_actual_semantics() ->
    C=context(),{ok,B}=efz_xmlrpc_adapter:generate(1,C),
    lists:foreach(fun(Outcome)->
        ?assertEqual({inconclusive,primary_outcome_unavailable},
            efz_xmlrpc_adapter:oracle(B,Outcome,C))
    end,[{timeout,1000},{crash,error,example,[]},{exit,normal}]),
    %% Supported model input being rejected is a violation of the explicitly
    %% declared acceptance/agreement predicate, unlike malformed raw XML.
    ?assertEqual({fail,{xmlrpc_model_agreement,1}},
        efz_xmlrpc_adapter:oracle(B,{ok,{rejected,unsupported}},C)).

model_abi_preflight() ->
    {efz_xmlrpc_model,Original,OriginalFile}=code:get_object_code(efz_xmlrpc_model),
    Forms=[{attribute,1,module,efz_xmlrpc_model},{attribute,2,export,[{version,0}]},
        {function,3,version,0,[{clause,3,[],[],[{integer,3,1}]}]}],
    {ok,efz_xmlrpc_model,Wrong}=compile:forms(Forms,[binary,warnings_as_errors]),
    try
        _=code:purge(efz_xmlrpc_model),_=code:delete(efz_xmlrpc_model),
        {module,efz_xmlrpc_model}=code:load_binary(efz_xmlrpc_model,"wrong_abi_fixture",Wrong),
        ?assertEqual({error,xmlrpc_model_abi_mismatch},
            efz_xmlrpc_adapter:prepare(efz_xmlrpc_target,#{},limits()))
    after
        _=code:purge(efz_xmlrpc_model),_=code:delete(efz_xmlrpc_model),
        {module,efz_xmlrpc_model}=code:load_binary(efz_xmlrpc_model,OriginalFile,Original)
    end.

semantic_replay() ->
    C=context(),{ok,Raw}=efz_xmlrpc_adapter:generate(8,C),
    Layer=#{adapter=>efz_xmlrpc_adapter,structured_fraction=>0,
        limits=>limits(),oracle=>inline},
    {ok,P}=efz_config:prepare(#{target=>efz_xmlrpc_target,seeds=>[Raw],
        coverage_backend=>none,gleam_layer=>Layer}),
    Context=#{execution_identities=>maps:get(execution_identities,P),builds=>#{}},
    Meta=#{gleam_layer=>maps:get(gleam_layer,P),property=>{xmlrpc_model_agreement,1}},
    E=efz_semantic_replay:expectation(Context,Meta,crypto:hash(sha256,Raw)),
    Dir="_build/xmlrpc-replay/"++integer_to_list(erlang:unique_integer([positive])),
    ok=filelib:ensure_dir(Dir++"/expectation"),
    ok=file:write_file(Dir++"/expectation",efz_semantic_replay:encode(E)),
    ?assertEqual({ok,E},efz_semantic_replay:load(Dir++"/expectation")),
    Options=#{timeout=>1000,coverage_backend=>none,gleam_layer=>Layer},
    %% No failure is invented: the correct decoder satisfies the pinned property.
    ?assertMatch({ok,#{status:=not_reproduced,target_executions:=1}},
        efz_semantic_replay:run(Raw,efz_xmlrpc_target,[],E,Options)),
    ?assertMatch({ok,#{status:=not_reproduced,target_executions:=1}},
        efz_semantic_replay:minimize(Raw,efz_xmlrpc_target,[],E,Options,8)),
    ?assertMatch({ok,#{outcome:={ok,{accepted,{call,_,_}}}}},
        efz_recipe:execute(Raw,efz_xmlrpc_target,[],[],
            (maps:remove(gleam_layer,Options))#{expected_harness=>maps:get(harness,E)})).
