%% P1 acceptance fixtures. Fault stubs test contracts, not Gleam integration.
-module(efz_gleam_contract_tests).
-include_lib("eunit/include/eunit.hrl").

off_preserves_configuration_test() ->
    Before = code:is_loaded(efz_qs_model),
    C = #{target => unrelated_term_target, opaque => {keep, unchanged}},
    ?assertEqual({ok, C}, efz_gleam_adapter:prepare(false, C)),
    ?assertEqual(Before, code:is_loaded(efz_qs_model)).

malformed_model_and_limits_test() ->
    L = {limits, 4096, 32, 128, 1},
    Models = [{query, [[{field, <<"a">>, <<>>}]], canonical},
              {query, [{field, <<"a">>, <<1:1>>}], canonical},
              {query, lists:duplicate(33, {field, <<"a">>, <<>>}), canonical},
              {query, [{field, <<"a">>, binary:copy(<<0>>, 129)}], canonical},
              {query, [{field, <<"a">>, <<>>} | improper], canonical}],
    lists:foreach(fun(M) ->
        ?assertEqual({error, boundary}, efz_gleam_adapter:encode(M, L))
    end, Models),
    lists:foreach(fun(Bad) ->
        ?assertEqual({error, boundary}, efz_gleam_adapter:decode(<<>>, Bad))
    end, [{limits, 4096.0, 32, 128, 1}, {limits, -1, 32, 128, 1},
          {limits, 4096, 32, 128, 2}, {limits, 4096, 32, 128}]).

invalid_capabilities_test() ->
    ?assertEqual({error, {gleam_configuration, unsupported_gleam_oracle_policy}},
                 efz_gleam_adapter:prepare(#{oracle => deferred}, base())),
    ?assertEqual({error, {gleam_configuration, structured_requires_staged_mode}},
                 efz_gleam_adapter:prepare(#{}, (base())#{mutation_mode => random})),
    ?assertEqual({error, {gleam_configuration, unsupported_gleam_target}},
                 efz_gleam_adapter:prepare(#{}, (base())#{target => efz_example_target})),
    lists:foreach(fun({P, C}) ->
        ?assertMatch({error, {gleam_configuration, _}}, efz_gleam_adapter:prepare(P, C))
    end, [{#{oracle => deferred}, base()}, {#{adapter => arbitrary}, base()},
          {#{structured_fraction => 101}, base()}, {#{feedback => unknown}, base()},
          {#{oracle_budget => -1}, base()}, {#{limits => #{nesting => 3}}, base()},
          {#{}, (base())#{target => efz_example_target}},
          {#{structured_fraction => 1}, (base())#{mutation_mode => random}}]).

semantic_schema_restore_test() ->
    Dir = "_build/gleam-contract-tests/schema-" ++ integer_to_list(erlang:system_time(microsecond)),
    {ok, C} = efz_config:prepare(#{target => efz_qs_target, seeds => [<<"a=1">>],
                                 coverage_backend => none, max_iterations => 0}),
    Identity = efz_corpus_store:identity(C), Store = #{dir => Dir, identity => Identity},
    {ok, Initial} = efz_corpus_store:save(Store, <<"a=1">>, 1, #{}),
    ?assertEqual(1, maps:get(schema_version, Initial)),
    Input = <<"a=2">>,
    M = #{parent => 1, parent_content => crypto:hash(sha256, <<"a=1">>),
          phase => mutation, retention_reason => new_semantic, new_probes => [],
          semantic => efz_semantic:metadata([{<<"cow_qs">>, 1, 10}])},
    {ok, Record} = efz_corpus_store:save(Store, Input, 2, M),
    ?assertEqual(3, maps:get(schema_version, Record)),
    ?assertMatch({ok, [_, _], []}, efz_corpus_store:restore(Dir, Identity, reject)),
    D = maps:get(discovery, Record), Semantic = maps:get(semantic, D),
    Invalid = Record#{discovery => D#{semantic => Semantic#{feature_version => 2}}},
    Payload = term_to_binary(Invalid),
    Encoded = <<"EFZC", 1, (byte_size(Payload)):32,
                (crypto:hash(sha256, Payload))/binary, Payload/binary>>,
    Path = filename:join([Dir, binary_to_list(binary:encode_hex(crypto:hash(sha256, Input), lowercase)), "metadata"]),
    %% Deliberately alter only this private fixture; preserve real corpus/artifacts.
    ok = file:write_file(Path, Encoded),
    ?assertMatch({error, {invalid_corpus_metadata, _, incompatible_semantic_schema}},
                 efz_corpus_store:restore(Dir, Identity, reject)).

native_contract_test_() ->
    case code:which(efz_qs_model) of
        non_existing -> [];
        _ -> {timeout, 30, [fun runtime_shipment/0, fun outcome_verdicts/0, fun zero_budget_random_mode/0,
                           fun runtime_off_callbacks/0, fun package_capabilities/0]}
    end.

base() -> #{target => efz_qs_target, mutation_mode => staged, max_input_bytes => 4096,
            manifests => [], mutation => #{}}.

runtime_shipment() ->
    Dir = filename:dirname(code:which(efz_qs_model)),
    ?assertNot(filelib:is_file(filename:join(Dir, "efz_semantic@@main.beam"))),
    {ok, [{application, efz_semantic, Props}]} = file:consult(filename:join(Dir, "efz_semantic.app")),
    ?assertEqual([efz_qs_model], proplists:get_value(modules, Props)),
    ?assertEqual([], proplists:get_value(applications, Props)),
    ?assertNot(lists:keymember(efz_semantic, 1, application:which_applications())).

outcome_verdicts() ->
    L = {limits, 4096, 32, 128, 1},
    FullFields = iolist_to_binary(lists:join(<<"&">>, lists:duplicate(32, <<"a=1">>))),
    ?assertEqual({skip, limit}, efz_gleam_adapter:mutate(FullFields, 0, L)),
    ?assertEqual({skip, limit}, efz_gleam_adapter:mutate(<<"a=1">>, 0, {limits,4096,32,1,1})),
    ?assertEqual({skip, limit}, efz_gleam_adapter:mutate(<<"a=", (binary:copy(<<"1">>,128))/binary>>, 4, L)),
    ?assertEqual({inconclusive, target_timeout}, efz_gleam_adapter:oracle(<<"a=1">>, {timeout, 100}, L)),
    ?assertEqual({inconclusive, target_exception}, efz_gleam_adapter:oracle(<<"a=1">>, {crash, error, badarg, []}, L)),
    ?assertEqual({inconclusive, limit}, efz_gleam_adapter:oracle(<<"a=1">>, {ok, rejected}, {limits, 2, 32, 128, 1})),
    ?assertEqual({pass, query_model_agreement}, efz_gleam_adapter:oracle(<<"a=1">>, {ok, efz_qs_target:run(<<"a=1">>)}, L)),
    ?assertEqual({fail, query_model_agreement}, efz_gleam_adapter:oracle(<<"a=1">>, {ok, {accepted, [{<<"a">>, <<"2">>}]}}, L)),
    {ok, A} = efz_gleam_adapter:observe(<<"a=1">>, {ok, {accepted, [{<<"a">>, <<"1">>}]}}, L),
    {ok, B} = efz_gleam_adapter:observe(<<"a=",255>>, {ok, {accepted, [{<<"a">>, <<255>>}]}}, L),
    ?assertNotEqual(A, B), ?assertEqual([{<<"cow_qs">>, 1, 10}], B -- A).

campaign(Layer, N) ->
    catch efz:stop(),
    try
        {ok, _} = efz:start(#{target => efz_qs_target, seeds => [<<"a=1">>],
            coverage_backend => none, max_iterations => N, random_seed => {17,23,41},
            selection_seed => {17,23,41}, gleam_layer => Layer}),
        R = efz:await(10000), {R, efz_corpus:semantic_state()}
    after efz:stop() end.

zero_budget_random_mode() ->
    {R, State} = campaign(#{structured_fraction => 0, feedback => observation_only,
                           oracle => inline, oracle_budget => 0}, 0),
    ?assertEqual(completed, maps:get(status, R)), ?assertEqual(disabled, State),
    Counts = maps:get(gleam_stats, R),
    ?assertEqual(0, maps:get(oracle_checks, Counts, 0)),
    ?assertEqual(1, maps:get(oracle_skipped, Counts)),
    ?assertEqual(0, maps:get(oracle_extra_executions, R)),
    ?assertEqual(#{}, maps:get(structured_stats, R)).

runtime_off_callbacks() ->
    {module, efz_gleam_adapter} = code:ensure_loaded(efz_gleam_adapter),
    Session = trace:session_create(efz_contract_off, self(), []),
    try
        [trace:function(Session, {efz_gleam_adapter, F, A}, true, [local]) ||
            {F,A} <- [{decode,2},{encode,2},{normalize,2},{generate,2},{mutate,3},{observe,3},{oracle,3}]],
        _ = trace:process(Session, all, true, [call, arity]),
        {R, State} = campaign(false, 8),
        Ref = trace:delivered(Session, all),
        Calls = trace_calls(Ref, []),
        ?assertEqual([], Calls), ?assertEqual(disabled, State),
        ?assertEqual(completed, maps:get(status, R)),
        ?assertNot(maps:is_key(gleam_stats, R)), ?assertNot(maps:is_key(semantic_features, R))
    after trace:session_destroy(Session) end.

trace_calls(Ref, Acc) ->
    receive
        {trace, _, call, MFA} -> trace_calls(Ref, [MFA | Acc]);
        {trace_delivered, _, Ref} -> lists:reverse(Acc)
    after 5000 -> error(trace_barrier_timeout)
    end.

package_capabilities() ->
    {efz_qs_model, Original, File} = code:get_object_code(efz_qs_model),
    Dirs = [D || D <- code:get_path(), filelib:is_file(filename:join(D, "efz_qs_model.beam"))],
    try
        code:purge(efz_qs_model), code:delete(efz_qs_model),
        [code:del_path(D) || D <- Dirs],
        ?assertEqual(non_existing, code:which(efz_qs_model)),
        ?assertMatch({error, {gleam_configuration, {gleam_package_unavailable, _}}},
                     efz_gleam_adapter:prepare(#{}, base())),
        ?assertEqual({ok, #{}}, efz_gleam_adapter:prepare(false, #{})),
        ?assertEqual(false, code:is_loaded(efz_qs_model)),
        Forms = [{attribute,1,module,efz_qs_model}, {attribute,1,export,[{versions,0}]},
            {function,1,versions,0,[{clause,1,[],[],[erl_parse:abstract({2,1,1,1,1,1})]}]}],
        {ok, efz_qs_model, Stub} = compile:forms(Forms, [binary]),
        {module, efz_qs_model} = code:load_binary(efz_qs_model, "contract_version_stub", Stub),
        ?assertEqual({error, {gleam_configuration, incompatible_gleam_versions}},
                     efz_gleam_adapter:prepare(#{}, base()))
    after
        [code:add_patha(D) || D <- lists:reverse(Dirs)],
        code:purge(efz_qs_model), code:delete(efz_qs_model),
        {module, efz_qs_model} = code:load_binary(efz_qs_model, File, Original)
    end.
