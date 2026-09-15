-module(efz_config_tests).
-include_lib("eunit/include/eunit.hrl").
-export([run/1]).

run(B) when is_binary(B) -> B.
base() -> #{target => ?MODULE, seeds => [<<>>], coverage => manual}.

unknown_keys_test() ->
    lists:foreach(fun({K,V}) ->
        ?assertEqual({error, {unknown_campaign_keys, [K]}}, efz_config:prepare((base())#{K => V}))
    end, [{function, parse}, {arity, 2},  {corpus_store, #{}},
          {unexpected, true}, {manifests, []}, {coverage_plan, undefined}, {coordinator, self()}]),
    ?assertEqual({error, {unknown_campaign_keys, [arity, function]}},
        efz_config:prepare((base())#{function => run, arity => 1})).

schema_test() ->
    ?assertEqual({error, campaign_configuration_must_be_map}, efz_config:prepare([])),
    ?assertEqual({error, {missing_campaign_keys, [target,seeds]}}, efz_config:prepare(#{})),
    lists:foreach(fun({K,V}) ->
        ?assertEqual({error, {invalid_campaign_option, K}}, efz_config:prepare((base())#{K => V}))
    end, [{target, "module"}, {seeds, []}, {seeds, ["text"]}, {timeout, -1}, {workers, 2},
          {max_iterations, -1}, {mutation_mode, unsupported}, {mutation, []},
          {artifacts, [bad]}, {coverage, bad}, {coverage_backend, bad},
          {coverage_validation, bad}, {crash_dir, <<>>}, {random_seed, bad}, {selection_seed, 1},
          {corpus_dir, <<>>}, {corpus_build_policy, resume}]),
    {ok, C} = efz_config:prepare((base())#{mutation_mode => staged,
        max_input_bytes => 32, selection_seed => {1,2,3}, random_seed => {4,5,6}}),
    ?assertEqual(32, maps:get(max_input_bytes, maps:get(mutation, C))),
    ?assertEqual(1000, maps:get(max_iterations, C)),
    ?assertEqual({error, corpus_build_policy_requires_corpus_dir},
        efz_config:prepare((base())#{corpus_build_policy=>recalibrate})),
    ?assertEqual({error, mutation_options_require_staged_mode},
        efz_config:prepare((base())#{mutation => #{max_input_bytes => 32}})).

target_contract_test() ->
    ?assertMatch({error, {module_unavailable, target, efz_missing_config_target, _}},
        efz_config:prepare((base())#{target => efz_missing_config_target})),
    ?assertEqual({error, {missing_callback, target, lists, run, 1}},
        efz_config:prepare((base())#{target => lists})),
    ?assertMatch({ok, _}, efz_config:prepare(base())).

empty_persistent_test() ->
    Suffix=binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))),
    Dir=filename:absname("_build/nonexistent-corpus-"++Suffix),
    ?assertEqual({error,{empty_persistent_corpus,Dir}},efz_config:prepare((base())#{seeds=>[],corpus_dir=>Dir})),
    ?assertNot(filelib:is_dir(Dir)).
