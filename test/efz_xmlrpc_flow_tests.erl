-module(efz_xmlrpc_flow_tests).
-include_lib("eunit/include/eunit.hrl").

suite_contract_test() ->
    Surfaces = efz_xmlrpc_suite:surfaces(),
    ?assertEqual([call, response, fault, roundtrip, dispatch, encoder_validation], Surfaces),
    Targets = [efz_xmlrpc_suite:target(Surface) || Surface <- Surfaces],
    ?assertEqual(length(Targets), length(lists:usort(Targets))),
    lists:foreach(fun(Surface) ->
        Target = efz_xmlrpc_suite:target(Surface),
        Seeds = efz_xmlrpc_suite:seeds(Surface),
        ?assert(Seeds =/= []),
        ?assertEqual(Seeds, efz_xmlrpc_suite:seeds(Surface)),
        ?assertEqual(Seeds, efz_xmlrpc_flow:seeds(Surface)),
        ?assertEqual(Seeds, Target:seeds()),
        ?assertEqual(Surface, Target:surface()),
        ?assert(lists:all(fun bounded_input/1, Seeds)),
        Modules = efz_xmlrpc_suite:modules(Surface),
        ?assertEqual(Modules, Target:modules()),
        ?assert(Modules =/= []),
        ?assert(lists:all(fun erlang:is_atom/1, Modules)),
        lists:foreach(fun(I) ->
            Sample = efz_xmlrpc_flow:sample(Surface, I),
            ?assert(bounded_input(Sample)),
            ?assertEqual(Sample, efz_xmlrpc_flow:sample(Surface, I)),
            ?assertEqual(Sample, Target:sample(I))
        end, sample_indices())
    end, Surfaces).

identical_campaign_inputs_test() ->
    lists:foreach(fun(Surface) ->
        Off = efz_xmlrpc_suite:config(Surface, off, 30, 123),
        Obs = efz_xmlrpc_suite:config(Surface, observation_only, 30, 123),
        Guided = efz_xmlrpc_suite:config(Surface, guided, 30, 123),
        ?assertEqual(maps:remove(gleam_layer, Off), maps:remove(gleam_layer, Obs)),
        ?assertEqual(maps:remove(gleam_layer, Off), maps:remove(gleam_layer, Guided)),
        ?assertEqual(false, maps:get(gleam_layer, Off)),
        ?assertEqual(30, maps:get(max_iterations, Off)),
        ?assertEqual(512, maps:get(max_input_bytes, Off)),
        ?assertEqual(efz_xmlrpc_suite:target(Surface), maps:get(target, Off)),
        ?assertEqual(efz_xmlrpc_suite:seeds(Surface), maps:get(seeds, Off)),
        ?assert(lists:all(fun bounded_input/1, maps:get(seeds, Off))),
        ?assertEqual(maps:get(random_seed, Off), maps:get(selection_seed, Off)),
        ?assertEqual(maps:get(random_seed, Off), maps:get(seed, maps:get(mutation, Off))),
        check_layer(Surface, observation_only, 0, maps:get(gleam_layer, Obs)),
        check_layer(Surface, guided, 30, maps:get(gleam_layer, Guided)),
        ?assertEqual(infinity, maps:get(max_iterations,
            efz_xmlrpc_suite:config(Surface, off, infinity, 123))),
        OtherSeed = efz_xmlrpc_suite:config(Surface, off, 30, 124),
        ?assertNotEqual(maps:get(random_seed, Off), maps:get(random_seed, OtherSeed)),
        ?assertEqual(maps:get(seeds, Off), maps:get(seeds, OtherSeed))
    end, efz_xmlrpc_suite:surfaces()).

adapter_contract_test() ->
    Descriptor = efz_xmlrpc_flow_adapter:descriptor(),
    ?assertEqual(1, maps:get(api_version, Descriptor)),
    ?assertEqual([0, 1, 2], maps:get(operations, Descriptor)),
    ?assertEqual([efz_term_model], maps:get(model_modules, Descriptor)),
    ?assertEqual([], maps:get(properties, Descriptor)),
    ?assertEqual(lists:sort([generation, mutation, observation, shrink]),
        lists:sort(maps:get(capabilities, Descriptor))),
    lists:foreach(fun(Surface) ->
        Target = efz_xmlrpc_suite:target(Surface),
        lists:foreach(fun(Max) ->
            {ok, Context} = efz_xmlrpc_flow_adapter:prepare(Target,
                #{surface => Surface}, #{bytes => Max}),
            lists:foreach(fun(I) ->
                {ok, Input} = efz_xmlrpc_flow_adapter:generate(I, Context),
                ?assert(is_binary(Input)),
                ?assert(byte_size(Input) =< Max),
                ?assertEqual({ok, Input}, efz_xmlrpc_flow_adapter:generate(I, Context)),
                case Max of
                    512 -> ?assertEqual(Target:sample(I), Input);
                    _ -> ok
                end
            end, sample_indices()),
            Inputs = [<<>>, <<0>>, binary:copy(<<255>>, Max)],
            lists:foreach(fun(Input) ->
                check_mutations(Input, Context, Max),
                check_shrinks(Input, Context)
            end, Inputs)
        end, [1, 7, 512])
    end, efz_xmlrpc_suite:surfaces()).

invalid_adapter_options_test() ->
    Target = efz_xmlrpc_suite:target(call),
    lists:foreach(fun({WrongTarget, Options, Limits}) ->
        ?assertEqual({error, invalid_xmlrpc_flow_adapter},
            efz_xmlrpc_flow_adapter:prepare(WrongTarget, Options, Limits))
    end, [
        {efz_xmlrpc_suite:target(response), #{surface => call}, #{bytes => 512}},
        {Target, #{surface => unknown}, #{bytes => 512}},
        {Target, #{surface => call, typo => true}, #{bytes => 512}},
        {Target, #{}, #{bytes => 512}},
        {Target, #{surface => call}, #{bytes => 0}},
        {Target, #{surface => call}, #{bytes => 513}},
        {Target, #{surface => call}, #{bytes => 1.5}}
    ]).

payload_limit_test() ->
    lists:foreach(fun(Surface) ->
        Target = efz_xmlrpc_suite:target(Surface),
        ?assertError(function_clause, Target:run(binary:copy(<<0>>, 513))),
        ?assertError(function_clause, Target:run([]))
    end, efz_xmlrpc_suite:surfaces()).

%% Only absence of the optional dependency skips these checks. A bad BEAM,
%% on-load failure, or failure in an actual flow must fail the test suite.
xmlrpc_flows_test_() ->
    case optional_modules([xmlrpc_encode, xmlrpc_decode, xmlrpc_util]) of
        available ->
            [{atom_to_list(Surface), fun() -> exercise_surface(Surface) end}
                || Surface <- efz_xmlrpc_suite:surfaces()] ++
                [{"literal XML-RPC semantics", fun literal_semantics/0}];
        {missing, Modules} ->
            io:format("XML-RPC functional flows skipped; optional modules absent: ~p~n",
                [Modules]),
            []
    end.

optional_model_test_() ->
    case optional_modules([efz_term_model]) of
        available -> [{"finite semantic observations", fun observation_features/0}];
        {missing, Modules} ->
            io:format("XML-RPC flow observation checks skipped; optional modules absent: ~p~n",
                [Modules]),
            []
    end.

check_layer(Surface, Mode, Fraction, Layer) ->
    ?assertEqual(efz_xmlrpc_flow_adapter, maps:get(adapter, Layer)),
    ?assertEqual(#{surface => Surface}, maps:get(adapter_options, Layer)),
    ?assertEqual(Mode, maps:get(feedback, Layer)),
    ?assertEqual(Fraction, maps:get(structured_fraction, Layer)),
    ?assertEqual(disabled, maps:get(oracle, Layer)),
    ?assertEqual(512, maps:get(bytes, maps:get(limits, Layer))).

check_mutations(Input, Context, Max) ->
    lists:foreach(fun(Operation) ->
        lists:foreach(fun(Choice) ->
            Plan = #{choice => Choice},
            First = efz_xmlrpc_flow_adapter:mutate(Input, Operation, Plan, Context),
            ?assertEqual(First,
                efz_xmlrpc_flow_adapter:mutate(Input, Operation, Plan, Context)),
            ?assertMatch({ok, _, #{choice := Choice, operation := Operation}}, First),
            {ok, Output, _} = First,
            ?assert(is_binary(Output)),
            ?assert(byte_size(Output) =< Max)
        end, [0, 53, 65535])
    end, [0, 1, 2]).

check_shrinks(Input, Context) ->
    {ok, Candidates} = efz_xmlrpc_flow_adapter:shrink(Input, Context),
    ?assertEqual({ok, Candidates}, efz_xmlrpc_flow_adapter:shrink(Input, Context)),
    ?assertEqual(length(Candidates), length(lists:usort(Candidates))),
    case Input of
        <<>> -> ?assertEqual([], Candidates);
        _ -> ?assert(Candidates =/= [])
    end,
    ?assert(lists:all(fun(Candidate) ->
        is_binary(Candidate) andalso byte_size(Candidate) < byte_size(Input)
    end, Candidates)).

exercise_surface(Surface) ->
    Target = efz_xmlrpc_suite:target(Surface),
    Dictionary = lists:sort(get()),
    Mailbox = mailbox_len(),
    ok = efz_xmlrpc_suite:setup(Surface),
    try
        ?assertEqual(#{invocations => 0, accepted => 0, rejected => 0},
            efz_xmlrpc_suite:counters(Surface)),
        Inputs = boundary_inputs() ++ [Target:sample(I) || I <- sample_indices()] ++
            efz_xmlrpc_suite:seeds(Surface),
        Results = [begin
            First = Target:run(Input),
            check_result(Surface, Input, First),
            ?assertEqual(First, Target:run(Input)),
            ?assertEqual(Dictionary, lists:sort(get())),
            First
        end || Input <- Inputs],
        check_surface_coverage(Surface, Results),
        Invocations = 2 * length(Inputs),
        Expected = case Surface of
            encoder_validation -> #{invocations => Invocations, accepted => 0,
                rejected => Invocations};
            _ -> #{invocations => Invocations, accepted => Invocations, rejected => 0}
        end,
        ?assertEqual(Expected, efz_xmlrpc_suite:counters(Surface)),
        ?assertEqual(Mailbox, mailbox_len()),
        %% Setup must reset existing counters, including expected rejections.
        ok = efz_xmlrpc_suite:setup(Surface),
        ?assertEqual(#{invocations => 0, accepted => 0, rejected => 0},
            efz_xmlrpc_suite:counters(Surface))
    after
        ok = efz_xmlrpc_suite:teardown(Surface)
    end,
    ?assertEqual(#{}, efz_xmlrpc_suite:counters(Surface)),
    ?assertEqual(Dictionary, lists:sort(get())),
    ?assertEqual(Mailbox, mailbox_len()).

check_result(encoder_validation, Input, Result) ->
    ?assertMatch({rejected, #{surface := encoder_validation,
        expected_error_match := true}}, Result),
    {rejected, Value} = Result,
    ?assertEqual(byte_size(Input), maps:get(input_bytes, Value)),
    ?assert(maps:is_key(reason, Value)),
    ?assertEqual(maps:get(expected, Value), maps:get(reason, Value));
check_result(Surface, Input, Result) ->
    ?assertMatch({accepted, #{surface := Surface}}, Result),
    {accepted, Value} = Result,
    ?assertEqual(byte_size(Input), maps:get(input_bytes, Value)),
    ?assert(is_atom(maps:get(type, Value))),
    ?assert(is_integer(maps:get(count, Value))),
    ?assert(maps:get(count, Value) >= 0),
    ?assert(maps:is_key(value, Value)),
    ?assert(maps:is_key(payload, Value)),
    case Surface of
        call -> ?assertMatch({call, _, _}, maps:get(payload, Value));
        response -> ?assertMatch({response, _}, maps:get(payload, Value));
        fault ->
            ?assertEqual(fault, maps:get(type, Value)),
            ?assertMatch({response, {fault, _, _}}, maps:get(payload, Value));
        roundtrip ->
            ?assertMatch({call, _, _}, maps:get(payload, Value)),
            check_encoded_bytes(Value);
        dispatch ->
            ?assertMatch({call, _, _}, maps:get(request, Value)),
            ?assertMatch({response, _}, maps:get(payload, Value)),
            check_encoded_bytes(Value)
    end.

check_encoded_bytes(Value) ->
    ?assert(is_integer(maps:get(encoded_bytes, Value))),
    ?assert(maps:get(encoded_bytes, Value) > 0).

check_surface_coverage(Surface, Results)
    when Surface =:= call; Surface =:= response; Surface =:= roundtrip ->
    ?assertEqual(lists:sort([integer, boolean, string, double, date, base64, array, struct]),
        lists:usort([maps:get(type, Value) || {accepted, Value} <- Results]));
check_surface_coverage(dispatch, Results) ->
    ?assertEqual([echo, sum],
        lists:usort([maps:get(method, Value) || {accepted, Value} <- Results]));
check_surface_coverage(_, _) -> ok.

literal_semantics() ->
    Cases = [
        {call, <<0>>, {call, echo, [-1000000]}},
        {response, <<1>>, {response, [true]}},
        {roundtrip, <<2, "<&>\"'", 0, 255>>, {call, echo, ["<&>\"' a"]}},
        {roundtrip, <<5, 0, 255>>, {call, echo, [{base64, "AP8="}]}},
        {fault, <<7, 0, 255>>, {response, {fault, -32007, " a"}}},
        {dispatch, <<2, "echo">>, {response, ["echo"]}},
        {dispatch, <<0, 0, 128, 255>>, {response, [-1]}}
    ],
    lists:foreach(fun({Surface, Input, Expected}) ->
        ok = efz_xmlrpc_suite:setup(Surface),
        try
            {accepted, Value} = efz_xmlrpc_flow:run(Surface, Input),
            ?assertEqual(Expected, maps:get(payload, Value))
        after
            ok = efz_xmlrpc_suite:teardown(Surface)
        end
    end, Cases).

observation_features() ->
    Descriptor = efz_xmlrpc_flow_adapter:descriptor(),
    ?assertEqual([efz_term_model], maps:get(model_modules, Descriptor)),
    Outcomes = [
        {ok, {accepted, #{surface => call, type => integer, count => 1, value => 0}}},
        {ok, {accepted, #{surface => response, type => array, count => 8,
            value => {array, [1, 2, 3, 4, 5, 6, 7, 8]}}}},
        {ok, {rejected, #{surface => encoder_validation, expected_error_match => true}}},
        {crash, error, unexpected_flow_result, []},
        {timeout, 500}
    ],
    Features = [begin
        {ok, Values} = efz_xmlrpc_flow_adapter:observe(<<>>, Outcome, #{}),
        ?assertEqual({ok, Values}, efz_xmlrpc_flow_adapter:observe(<<>>, Outcome, #{})),
        ?assert(Values =/= []),
        ?assert(length(Values) =< 256),
        ?assert(lists:all(fun(Value) ->
            is_integer(Value) andalso Value >= 0 andalso Value =< 255
        end, Values)),
        Values
    end || Outcome <- Outcomes],
    ?assert(length(lists:usort(Features)) >= 3).

optional_modules(Modules) ->
    Loaded = [{Module, code:ensure_loaded(Module)} || Module <- Modules],
    Unexpected = [{Module, Result} || {Module, Result} <- Loaded,
        Result =/= {module, Module}, Result =/= {error, nofile}],
    case Unexpected of
        [] ->
            case [Module || {Module, {error, nofile}} <- Loaded] of
                [] -> available;
                Missing -> {missing, Missing}
            end;
        _ -> erlang:error({optional_dependency_load_failed, Unexpected})
    end.

sample_indices() -> lists:seq(0, 7) ++ [8, 17, 35, 53, 63, 255, 256, 65535].
boundary_inputs() -> [<<>>, <<0>>, <<255>>, list_to_binary(lists:seq(0, 255)),
    binary:copy(<<255>>, 512)].
bounded_input(Input) -> is_binary(Input) andalso byte_size(Input) =< 512.
mailbox_len() -> {message_queue_len, N} = process_info(self(), message_queue_len), N.
