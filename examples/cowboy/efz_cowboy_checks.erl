-module(efz_cowboy_checks).
-export([tests/2]).
-include_lib("eunit/include/eunit.hrl").

tests(Artifacts, Manifests) ->
    Vectors = [
        {<<>>, {ok, []}},
        {<<"edit">>, {ok, [{<<"edit">>, true}]}},
        {<<"a=">>, {ok, [{<<"a">>, <<>>}]}},
        {<<"a=1&a=2">>, {ok, [{<<"a">>, <<"1">>}, {<<"a">>, <<"2">>}]}},
        {<<"q=a+b%2Fc">>, {ok, [{<<"q">>, <<"a b/c">>}]}},
        {<<"x=%00%ff">>, {ok, [{<<"x">>, <<0, 255>>}]}},
        {<<"x=%">>, {invalid, qs}},
        {<<"x=%0">>, {invalid, qs}},
        {<<"x=%GG">>, {invalid, qs}},
        {keys(99), {ok, lists:duplicate(99, {<<"a">>, true})}},
        {keys(100), {ok, lists:duplicate(100, {<<"a">>, true})}},
        {keys(101), {invalid, limit_reached}}
    ],
    [?_assertEqual(Expected, efz_cowboy_target:run(Input)) || {Input, Expected} <- Vectors] ++
    [{"exact scoped coverage through both backends", fun() ->
        {ok, Plan} = efz_cov_manifest:prepare(automatic, Manifests),
        try
            Options = #{coverage => automatic, coverage_plan => Plan},
            lists:foreach(fun({Input, Expected}) ->
                A = execute(Input, Options#{coverage_backend => ets}),
                B = execute(Input, Options#{coverage_backend => ets_member}),
                C = execute(Input, Options#{coverage_backend => ets}),
                ?assertEqual({ok, Expected}, maps:get(outcome, A)),
                ?assertEqual(maps:get(outcome, A), maps:get(outcome, B)),
                ?assertEqual(maps:get(coverage, A), maps:get(coverage, B)),
                ?assertEqual(maps:get(coverage, A), maps:get(coverage, C)),
                ?assertNotEqual(maps:get(execution_ref, A), maps:get(execution_ref, C)),
                ?assertEqual([cow_qs, cowboy_req],
                    lists:usort([M || {M, _, _} <- maps:get(coverage, A)]))
            end, Vectors),
            Empty = execute(<<>>, Options),
            Parsed = execute(<<"a=1">>, Options),
            ?assertNotEqual(maps:get(coverage, Empty), maps:get(coverage, Parsed))
        after efz_cov_manifest:release(Plan) end
    end}, {"real staged operator retains a query-string input", fun() ->
        {ok, _} = efz:start(#{target => efz_cowboy_target, artifacts => Artifacts,
            seeds => [<<>>], mutation_mode => staged, max_iterations => 20,
            crash_dir => "_build/cowboy-check-crashes",
            max_input_bytes => 64, mutation => #{seed => {17, 23, 41},
                stages => [dictionary_insert], dictionary => [<<"a=1">>, <<"%">>]}}),
        try
            Report = efz:await(5000),
            ?assertEqual(completed, maps:get(status, Report)),
            Stats = maps:get(stats, Report),
            ?assertEqual(1, maps:get(calibrations, Stats)),
            ?assertEqual(20, maps:get(executions, Stats)),
            ?assertEqual(0, maps:get(infrastructure_failures, Stats)),
            ?assertEqual(0, maps:get(crashes, Stats)),
            [Entry] = [E || #{input := <<"a=1">>} = E <- maps:get(corpus, Report)],
            Meta = maps:get(metadata, Entry),
            ?assertEqual(new_coverage, maps:get(retention_reason, Meta)),
            ?assertEqual(dictionary_insert, maps:get(stage, maps:get(mutation, Meta))),
            ?assert(maps:get(new_probes, Meta) =/= [])
        after efz:stop() end
    end}].

keys(N) -> iolist_to_binary(lists:join(<<"&">>, lists:duplicate(N, <<"a">>))).

execute(Input, Options) ->
    R = efz_executor:run(efz_cowboy_target, Input, 1000, Options),
    ?assertEqual(ok, maps:get(coverage_status, R)),
    R.
