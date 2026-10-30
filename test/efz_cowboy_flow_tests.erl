-module(efz_cowboy_flow_tests).
-include_lib("eunit/include/eunit.hrl").

payload_boundaries_test_() ->
    [{atom_to_list(Surface), fun() ->
        ok = efz_cowboy_suite:setup(Surface),
        try
            Target = efz_cowboy_suite:target(Surface),
            Inputs = [<<>>, <<0>>, <<255>>, list_to_binary(lists:seq(0, 255)),
                binary:copy(<<255>>, 1024)] ++
                [Target:sample(I) || I <- lists:seq(0, 63)],
            lists:foreach(fun(Input) ->
                ?assertMatch({accepted, _}, Target:run(Input)),
                ?assertEqual(undefined, get(efz_cowboy_bench_result))
            end, Inputs),
            ?assertEqual(#{accepted => length(Inputs), invocations => length(Inputs)},
                efz_cowboy_suite:counters(Surface)),
            ?assertEqual(0, mailbox_len())
        after efz_cowboy_suite:teardown(Surface) end
    end} || Surface <- efz_cowboy_suite:surfaces()].

identical_campaign_inputs_test() ->
    lists:foreach(fun(Surface) ->
        Off = efz_cowboy_suite:config(Surface, off, 30, 123),
        Obs = efz_cowboy_suite:config(Surface, observation_only, 30, 123),
        Guided = efz_cowboy_suite:config(Surface, guided, 30, 123),
        ?assertEqual(maps:remove(gleam_layer, Off), maps:remove(gleam_layer, Obs)),
        ?assertEqual(maps:remove(gleam_layer, Off), maps:remove(gleam_layer, Guided)),
        ?assertEqual(false, maps:get(gleam_layer, Off)),
        ?assertEqual(0, maps:get(structured_fraction, maps:get(gleam_layer, Obs))),
        ?assertEqual(30, maps:get(structured_fraction, maps:get(gleam_layer, Guided))),
        ?assert(lists:all(fun(B) -> byte_size(B) =< 1024 end, maps:get(seeds, Off)))
    end, efz_cowboy_suite:surfaces()).

adapter_replay_and_shrink_test() ->
    lists:foreach(fun(Surface) ->
        Target = efz_cowboy_suite:target(Surface),
        {ok, Context} = efz_cowboy_flow_adapter:prepare(Target,
            #{surface => Surface}, #{bytes => 1024}),
        {ok, Seed} = efz_cowboy_flow_adapter:generate(35, Context),
        ?assertEqual(Seed, Target:sample(35)),
        lists:foreach(fun(Operation) ->
            First = efz_cowboy_flow_adapter:mutate(Seed, Operation, #{choice => 53}, Context),
            ?assertEqual(First, efz_cowboy_flow_adapter:mutate(Seed, Operation,
                #{choice => 53}, Context)),
            ?assertMatch({ok, _, #{choice := 53, operation := Operation}}, First)
        end, [0, 1, 2]),
        {ok, Candidates} = efz_cowboy_flow_adapter:shrink(Seed, Context),
        ?assert(Candidates =/= []),
        ?assert(lists:all(fun(B) -> byte_size(B) < byte_size(Seed) end, Candidates))
    end, efz_cowboy_suite:surfaces()),
    ?assertEqual({error, invalid_cowboy_flow_adapter},
        efz_cowboy_flow_adapter:prepare(efz_cowboy_qs_target,
            #{surface => http1}, #{bytes => 1024})).

optional_model_test_() ->
    case code:ensure_loaded(efz_term_model) of
        {module, efz_term_model} -> [{"Gleam features reflect results", fun() ->
            {ok, A} = efz_cowboy_flow_adapter:observe(<<>>, {ok, {accepted,
                #{body_bytes => 0, framing => 0}}}, #{}),
            {ok, B} = efz_cowboy_flow_adapter:observe(<<>>, {ok, {accepted,
                #{body_bytes => 256, framing => 1}}}, #{}),
            ?assertNotEqual(A, B),
            ?assert(lists:all(fun(I) -> is_integer(I) andalso I >= 0 andalso I =< 255 end, A ++ B))
        end}];
        _ -> []
    end.

mailbox_len() -> {message_queue_len, N} = process_info(self(), message_queue_len), N.
