-module(efz_provider_recipe_tests).
-include_lib("eunit/include/eunit.hrl").

%% These fixtures describe saved data only. Legacy structured recipes do not
%% need a semantic adapter, just as provider recipes do not need their library.
legacy_schemas_test() ->
    lists:foreach(fun({Version, R, Expected}) ->
        ?assertEqual(Version, maps:get(schema_version, R)),
        assert_roundtrip(R, Expected),
        ?assertMatch({error, _}, efz_recipe:regenerate(R#{operations =>
            [{provider_replace, 1, efz_mutation:hash(Expected), Expected}]}))
    end, legacy_recipes()).

provider_roundtrip_test() ->
    {R, Expected} = provider_recipe(),
    ?assertEqual(5, maps:get(schema_version, R)),
    ?assertEqual(4, maps:get(operation_version, R)),
    ?assertEqual(provider, maps:get(source_kind, R)),
    assert_roundtrip(R, Expected).

provider_limits_test() ->
    {R, Expected} = provider_recipe(),
    ?assertEqual({ok, Expected},
        efz_recipe:regenerate(R, #{max_input_bytes => byte_size(Expected)})),
    ?assertMatch({error, _},
        efz_recipe:regenerate(R, #{max_input_bytes => byte_size(Expected) - 1})),
    ?assertMatch({error, _}, efz_recipe:regenerate(R, #{max_input_bytes => 2})),
    Limits = maps:get(limits, R),
    ?assertMatch({error, _}, efz_recipe:regenerate(
        R#{limits => Limits#{max_input_bytes => byte_size(Expected) - 1}})),
    Data = maps:get(provider, R),
    CoreLimits = maps:get(limits, Data),
    ?assertMatch({error, _}, efz_recipe:regenerate(R#{provider =>
        Data#{limits => CoreLimits#{output_bytes => byte_size(Expected) - 1}}})),
    ?assertMatch({error, _}, efz_recipe:regenerate(R#{provider =>
        Data#{limits => CoreLimits#{intermediate_bytes => 1}}})).

provider_integrity_test() ->
    {R, Expected} = provider_recipe(),
    ?assertEqual({error, output_hash_mismatch},
        efz_recipe:regenerate(R#{output_hash => <<0:256>>})),
    ?assertEqual({error, output_size_mismatch},
        efz_recipe:regenerate(R#{output_size => byte_size(Expected) + 1})),
    ?assertMatch({error, _}, efz_recipe:regenerate(R#{operations =>
        [{provider_replace, 1, <<0:256>>, Expected}]})),
    Tampered = <<"LONGER">>,
    ?assertMatch({error, _}, efz_recipe:regenerate(R#{operations =>
        [{provider_replace, 1, efz_mutation:hash(Expected), Tampered}]})),
    ?assertEqual({error, output_hash_mismatch}, efz_recipe:regenerate(R#{operations =>
        [{provider_replace, 1, efz_mutation:hash(Tampered), Tampered}]})).

provider_schema_validation_test() ->
    {R, Expected} = provider_recipe(),
    Data = maps:get(provider, R),
    Invalid = [R#{extra => true}, R#{schema_version => 6},
        R#{operation_version => 5}, R#{source_kind => structured},
        R#{provider => Data#{extra => true}},
        R#{provider => Data#{schema_version => 2}},
        R#{provider => Data#{wrapper_version => 2}},
        R#{provider => Data#{source => arbitrary}},
        R#{provider => Data#{request_number => 0}},
        R#{provider => Data#{identity => (maps:get(identity, Data))#{extra => true}}},
        R#{provider => Data#{recipe => #{padding => binary:copy(<<0>>, 4097)}}},
        R#{provider => Data#{recipe => self()}},
        R#{operations => [{provider_replace, 2, efz_mutation:hash(Expected), Expected}]},
        R#{operations => [{provider_replace, 1, efz_mutation:hash(Expected), Expected},
                         {overwrite, 0, <<"x">>}]},
        R#{operations => [{structured_replace, 1, {1, 1, 1, 1, 1, 1}, 0, Expected}]}],
    lists:foreach(fun(Bad) ->
        ?assertMatch({error, _}, efz_recipe:regenerate(Bad)),
        ?assertMatch({error, _}, efz_recipe:encode(Bad))
    end, Invalid).

provider_trusted_mismatch_test() ->
    {R, _} = provider_recipe(),
    Data = maps:get(provider, R),
    Identity = maps:get(identity, Data),
    Trusted = #{core_identity => Identity,
                config_identity => maps:get(config_identity, Data)},
    Before = code:is_loaded(erlamsa_core),
    ?assertMatch({error, _}, efz_recipe:regenerate_provider(R,
        Trusted#{core_identity => Identity#{app_sha256 => <<1:256>>}})),
    ?assertMatch({error, _}, efz_recipe:regenerate_provider(R,
        Trusted#{config_identity => <<1:256>>})),
    ?assertEqual(Before, code:is_loaded(erlamsa_core)).

native_provider_operation_isolation_test() ->
    C = campaign(),
    Expected = <<"b=2">>,
    Data = (provider_data())#{source => native, mode => hybrid,
        request => none, request_number => none, recipe => #{}},
    Plan = (base_plan(C, [{overwrite, 0, Expected}]))#{
        source_kind => provider, provider => Data},
    R = efz_recipe:make(Plan, Expected, C, #{}),
    assert_roundtrip(R, Expected),
    Before = code:is_loaded(erlamsa_core),
    Trusted = #{core_identity => maps:get(identity, Data),
                config_identity => maps:get(config_identity, Data)},
    ?assertEqual({ok, Expected}, efz_recipe:regenerate_provider(R, Trusted)),
    ?assertEqual(Before, code:is_loaded(erlamsa_core)),
    lists:foreach(fun(Ops) ->
        ?assertMatch({error, _}, efz_recipe:regenerate(R#{operations => Ops}))
    end, [[{provider_replace, 1, efz_mutation:hash(Expected), Expected}],
          [{structured_replace, 1, {1, 1, 1, 1, 1, 1}, 0, Expected}]]).

provider_fresh_vm_test_() ->
    {timeout, 15, fun provider_fresh_vm/0}.

provider_fallback_fresh_vm_test_() ->
    {timeout, 15, fun() ->
        C=campaign(), Expected = <<"b=2">>,
        Data=(provider_data())#{source=>native,recipe=>#{},
            fallback=><<"erlamsa_optional_skip_reason_only">>},
        Plan=(base_plan(C,[{overwrite,0,Expected}]))#{source_kind=>provider,provider=>Data},
        R=efz_recipe:make(Plan,Expected,C,#{}),
        assert_roundtrip(R,Expected),
        provider_fresh_vm(R,Expected)
    end}.

provider_fresh_vm() ->
    {R, Expected} = provider_recipe(),
    provider_fresh_vm(R,Expected).

provider_fresh_vm(R,Expected) ->
    Base = filename:join("_build/provider-recipe-tests",
        integer_to_list(erlang:unique_integer([positive]))),
    RecipePath = filename:absname(Base ++ ".recipe"),
    OutputPath = filename:absname(Base ++ ".input"),
    ok = filelib:ensure_dir(RecipePath),
    BeamDir = filename:dirname(code:which(efz_recipe)),
    Eval = "[Recipe,Output]=init:get_plain_arguments(),"
        "non_existing=code:which(erlamsa_core),"
        "false=code:is_loaded(erlamsa_core),"
        "{ok,R}=efz_recipe:load(Recipe),"
        "{ok,B}=efz_recipe:regenerate(R),"
        "false=code:is_loaded(erlamsa_core),"
        "ok=file:write_file(Output,B),halt(0).",
    try
        ok = efz_recipe:save(RecipePath, R),
        Port = open_port({spawn_executable, os:find_executable("erl")},
            [binary, exit_status, stderr_to_stdout,
             {args, ["+S", "2:2", "-noshell", "-pa", BeamDir,
                     "-eval", Eval, "-extra", RecipePath, OutputPath]}]),
        {Status, Text} = port_result(Port, <<>>),
        ?assertEqual({0, <<>>}, {Status, Text}),
        ?assertEqual({ok, Expected}, file:read_file(OutputPath))
    after
        _ = file:delete(RecipePath),
        _ = file:delete(OutputPath)
    end.

port_result(Port, Acc) ->
    receive
        {Port, {data, Bytes}} -> port_result(Port, <<Acc/binary, Bytes/binary>>);
        {Port, {exit_status, Status}} -> {Status, Acc}
    after 5000 ->
        port_close(Port),
        error(provider_replay_vm_timeout)
    end.

provider_recipe() ->
    C = campaign(),
    Expected = <<"longer">>,
    Plan = (base_plan(C, [{provider_replace, 1,
                          efz_mutation:hash(Expected), Expected}]))#{
        source_kind => provider, provider => provider_data()},
    {efz_recipe:make(Plan, Expected, C, #{}), Expected}.

provider_data() ->
    #{schema_version => 1, wrapper_version => 1, source => erlamsa,
      mode => erlamsa, identity => core_identity(), config_identity => <<0:256>>,
      request => #{seed => {1, 2, 3}, operator => byte_flip,
                   pattern => once, strategy => perturb, budget => 1},
      request_number => 1, recipe => term_to_binary(
          #{operator => byte_flip, erlamsa_optional_metadata_only => true}, [deterministic]),
      limits => core_limits(), fallback => none}.

core_limits() ->
    #{input_bytes => 64, output_bytes => 64, intermediate_bytes => 65536,
      depth => 4, nodes => 1024, entries => 16, entry_bytes => 16384,
      unpacked_bytes => 65536, expansion_ratio => 32, operations => 8,
      repeats => 4, block_bytes => 128}.

core_identity() ->
    Names = [<<"erlamsa_core">>, <<"erlamsa_core_bytes">>, <<"erlamsa_core_fields">>,
        <<"erlamsa_core_json">>, <<"erlamsa_core_ops">>, <<"erlamsa_core_pack">>,
        <<"erlamsa_core_rng">>, <<"erlamsa_core_sgml">>, <<"erlamsa_core_tree">>],
    #{schema => 1, source_revision => <<"0000000000000000000000000000000000000000">>,
      source_clean => true,
      modules => [#{module => Name, beam_sha256 => <<0:256>>, beam_md5 => <<0:128>>}
                  || Name <- Names],
      app_sha256 => <<0:256>>, otp_release => <<"27">>, erts_version => <<"15.0">>,
      versions => #{api => 1, library => <<"0.1.0">>, rng => <<"splitmix64-v1">>,
                    catalogue => 1, patterns => 1, limits => 1}}.

assert_roundtrip(R, Expected) ->
    ?assertEqual({ok, Expected}, efz_recipe:regenerate(R)),
    {ok, Encoded} = efz_recipe:encode(R),
    ?assertEqual({ok, R}, efz_recipe:decode(Encoded)).

campaign() ->
    {ok, C} = efz_mutation_plan:prepare(
        #{seed => {1, 2, 3}, max_input_bytes => 64, stages => [havoc]},
        [<<"a=1">>]),
    C.

base_plan(C, Ops) ->
    Primary = <<"a=1">>,
    #{primary => Primary, primary_id => efz_mutation:hash(Primary),
      parent => 1, stage => havoc, operations => Ops,
      config_id => maps:get(config_id, C),
      dictionary_id => maps:get(dictionary_id, C)}.

legacy_recipes() ->
    C = campaign(),
    Expected = <<"b=2">>,
    Versions = {1, 1, 1, 1, 1, 1},
    R1 = efz_recipe:make(base_plan(C, [{overwrite, 0, Expected}]), Expected, C, #{}),
    Op1 = [{structured_replace, 1, Versions, 0, Expected}],
    R2 = efz_recipe:make(base_plan(C, Op1), Expected, C, #{}),
    Rng0 = rand:seed_s(exsplus, maps:get(seed, C)),
    {_, Rng1} = rand:uniform_s(100, Rng0),
    {Choice1, Rng2} = rand:uniform_s(6, Rng1),
    Op2 = [{structured_replace, 1, Versions, Choice1 - 1, Expected}],
    Legacy = #{schema_version => 1, versions => Versions, operation => Choice1 - 1,
        limits => {limits, 64, 32, 128, 1}, fraction => 100,
        rng_before => words(Rng0), rng_after => words(Rng2)},
    R3 = efz_recipe:make((base_plan(C, Op2))#{source_kind => structured,
        structured => Legacy}, Expected, C, #{}),
    Identity = semantic_identity(),
    {_, Rng3} = rand:uniform_s(1, Rng1),
    {Choice2, Rng4} = rand:uniform_s(65536, Rng3),
    Generic = #{schema_version => 2, identity => Identity, operation => 0,
        params => #{choice => Choice2 - 1}, recipe => <<>>,
        limits => maps:get(limits, Identity), fraction => 100,
        rng_before => words(Rng0), rng_after => words(Rng4)},
    R4 = efz_recipe:make((base_plan(C,
        [{structured_replace, 2, Identity, 0, Expected}]))#{
            source_kind => structured, structured => Generic}, Expected, C, #{}),
    [{1, R1, Expected}, {2, R2, Expected}, {3, R3, Expected}, {4, R4, Expected}].

words(Rng) ->
    {exsplus, [A | B]} = rand:export_seed_s(Rng),
    [A, B].

semantic_identity() ->
    #{descriptor => #{id => <<"cold-fixture">>, api_version => 1,
        model_version => 1, observer_version => 1, recipe_version => 1,
        operations_version => 1, capabilities => [mutation], operations => [0],
        model_modules => [], properties => []},
      code => [], options => <<>>, prepared_context_sha256 => <<0:256>>,
      limits => #{bytes => 64, depth => 8, nodes => 128,
                  collection => 32, operations => 1}}.
