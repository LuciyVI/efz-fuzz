-module(efz_semantic_cli_tests).
-include_lib("eunit/include/eunit.hrl").

directory()->D="_build/semantic-cli/"++integer_to_list(erlang:system_time(microsecond)),
    ok=filelib:ensure_dir(D++"/placeholder"),D.
config(D,C)->P=D++"/campaign.term",ok=file:write_file(P,io_lib:format("~tp.~n",[C])),P.
base()->#{target=>efz_plugin_length_target,seeds=>[<<0:16>>],coverage_backend=>none,
    mutation_mode=>staged,max_iterations=>0,timeout=>1000}.
report(D)->{ok,B}=file:read_file(D++"/out/report.term"),binary_to_term(B,[safe]).

explicit_observer_config_test()->
    D=directory(),Path=config(D,(base())#{gleam_layer=>#{adapter=>efz_plugin_observer_adapter,
        structured_fraction=>0,feedback=>guided}}),
    ?assertEqual(0,efz_cli:main(["--config",Path,"--out",D++"/out"])),
    R=report(D),?assertEqual(completed,maps:get(status,R)),
    ?assertEqual([{<<"fixture.observer_a">>,1,1}],maps:get(semantic_features,R)).

config_runtime_flag_override_test()->
    D=directory(),Path=config(D,(base())#{runtime_oracles=>#{enabled=>false}}),
    ?assertEqual(0,efz_cli:main(["--config",Path,"--out",D++"/out",
        "--runtime-diagnostics","--runtime-runs","1","--verification-budget","0"])),
    R=report(D),Policy=maps:get(policy,maps:get(runtime_diagnostics,R)),
    ?assertEqual(true,maps:get(enabled,Policy)),
    ?assertEqual(1,maps:get(seed_runs,maps:get(stability,Policy))),
    ?assertEqual(0,maps:get(verification_executions,maps:get(stats,R))).

invalid_adapter_before_campaign_test()->
    D=directory(),Path=config(D,(base())#{gleam_layer=>#{adapter=>efz_plugin_missing_adapter,
        structured_fraction=>0}}),
    ?assertEqual(2,efz_cli:main(["--config",Path,"--out",D++"/out"])),
    ?assertNot(filelib:is_regular(D++"/out/report.term")),
    ?assertEqual(undefined,whereis(efz_fuzzer)).
