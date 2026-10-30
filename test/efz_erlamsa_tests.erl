-module(efz_erlamsa_tests).
-include_lib("eunit/include/eunit.hrl").

identity_validation_stays_cold_test() ->
    Before = [{M, code:is_loaded(M)} || M <- [erlamsa_core, erlamsa_core_pack]],
    I = identity(),
    ?assert(efz_erlamsa:identity_valid(I)),
    ?assertEqual(Before, [{M, code:is_loaded(M)} || {M, _} <- Before]),
    ?assertNot(efz_erlamsa:identity_valid(I#{unexpected => true})),
    ?assertNot(efz_erlamsa:identity_valid(I#{source_clean => false})),
    ?assertNot(efz_erlamsa:identity_valid(I#{source_revision => <<"not-a-revision">>})),
    ?assertNot(efz_erlamsa:identity_valid(I#{modules => tl(maps:get(modules, I))})),
    ?assertNot(efz_erlamsa:identity_valid(I#{modules => lists:reverse(maps:get(modules, I))})),
    ?assertNot(efz_erlamsa:identity_valid(I#{versions => #{api => 2}})),
    [First | Rest] = maps:get(modules, I),
    ?assertNot(efz_erlamsa:identity_valid(I#{modules => [First#{module => <<"os">>} | Rest]})),
    ?assertNot(efz_erlamsa:identity_valid(I#{modules => [First#{beam_md5 => <<0>>} | Rest]})).

missing_and_unbuilt_core_test() ->
    ?assertEqual({error, missing_core}, efz_erlamsa:prepare(#{}, #{}, <<>>)),
    ?assertEqual({error, missing_core}, efz_erlamsa:prepare(#{}, #{}, [0])),
    ?assertEqual({error, unavailable_build}, efz_erlamsa:prepare(#{}, #{}, "/tmp")),
    ?assertNot(efz_erlamsa:live(#{unexpected => true})),
    ?assertEqual({error, invalid_core_context}, efz_erlamsa:mutate(<<>>, #{}, #{})).

identity() ->
    Names = [<<"erlamsa_core">>, <<"erlamsa_core_bytes">>, <<"erlamsa_core_fields">>,
        <<"erlamsa_core_json">>, <<"erlamsa_core_ops">>, <<"erlamsa_core_pack">>,
        <<"erlamsa_core_rng">>, <<"erlamsa_core_sgml">>, <<"erlamsa_core_tree">>],
    #{schema => 1, source_revision => binary:copy(<<"a">>, 40), source_clean => true,
        modules => [#{module => M, beam_sha256 => <<0:256>>, beam_md5 => <<0:128>>}
                    || M <- Names], app_sha256 => <<0:256>>,
        versions => #{api => 1, library => <<"0.1.0">>, rng => <<"splitmix64-v1">>,
            catalogue => 1, patterns => 1, limits => 1},
        otp_release => <<"27">>, erts_version => <<"15.0">>}.
