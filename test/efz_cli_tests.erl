-module(efz_cli_tests).
-include_lib("eunit/include/eunit.hrl").

cli_test_() -> {setup, fun setup/0, fun cleanup/1, fun(S) -> [
    {"help in a fresh VM", fun() -> help(S) end},
    {"external harness, raw seeds, real automatic campaign", fun() -> campaign(S) end},
    {"durable inputs reused by a second launcher VM", fun() -> durable_campaign(S) end},
    {"legacy random campaign through the same launcher", fun() -> random_campaign(S) end},
    {"disconnected campaign diagnostic and strict exit in fresh VMs",fun()->coverage_policy(S) end},
    {"missing target module", fun() -> invalid(S, missing_module,
        #{"--target" => "efz_nonexistent_cli_harness"}, <<"could not be loaded">>) end},
    {"canonical run/1 is required", fun() -> invalid(S, missing_run,
        #{"--target" => "efz_cli_parser"}, <<"must export run/1">>) end},
    {"missing seed directory", fun() -> invalid(S, missing_seeds,
        #{"--seeds" => path(S, "missing")}, <<"Cannot read seed directory">>) end},
    {"empty corpus directory", fun() -> invalid(S, empty_corpus,
        #{"--seeds" => path(S, "empty")}, <<"Empty corpus">>) end},
    {"unreadable seed file", fun() -> unreadable_seed(S) end},
    {"invalid instrumented BEAM", fun() -> invalid(S, invalid_beam,
        #{"--artifacts" => path(S, "bad-beam")}, <<"Invalid artifacts">>) end},
    {"invalid paired manifest", fun() -> invalid(S, invalid_manifest,
        #{"--artifacts" => path(S, "bad-manifest")}, <<"manifest_artifact_mismatch">>) end},
    {"missing paired manifest", fun() -> invalid(S, missing_manifest,
        #{"--artifacts" => path(S, "missing-manifest")}, <<"missing_or_nonregular_artifact_files">>) end},
    {"missing artifact directory", fun() -> invalid(S, missing_artifacts,
        #{"--artifacts" => path(S, "missing")}, <<"artifact_directory">>) end},
    {"unknown and malformed options", {timeout, 10, fun() -> bad_options(S) end}},
    {"output path must be writable", fun() -> invalid(S, invalid_out,
        #{"--out" => path(S, "out-file")}, <<"Output directory">>) end},
    {"zero-byte CLI limit accepts empty files in both modes", fun() -> zero_bound(S) end},
    {"staged input bound is enforced", fun() -> invalid(S, size_bound,
        #{"--max-input-bytes" => "0"}, <<"input_too_large">>) end},
    {"random mode cannot silently ignore input bound", fun() -> invalid(S, random_bound,
        #{"--mutation" => "random", "--max-input-bytes" => "0"}, <<"input_too_large">>) end},
    {"target crash is saved and does not fail the launcher", fun() -> crash(S) end},
    {"timeout is passed to the real executor", fun() -> timeout(S) end},
    {"real infrastructure failure gives nonzero exit", fun() -> infrastructure(S) end},
    {"report write failure gives nonzero exit", fun() -> report_failure(S) end}
] end}.

setup() ->
    Base = filename:absname("_build/cli-test-" ++ binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(8))) ++ " space"),
    Script = filename:join([Base, "tool", "scripts", "fuzz.escript"]),
    Ebin = filename:join([Base, "tool", "_build", "default", "lib", "efz", "ebin"]),
    ok = filelib:ensure_dir(Script),
    {ok, _} = file:copy("scripts/fuzz.escript", Script),
    ok = filelib:ensure_dir(filename:join(Ebin, "placeholder")),
    %% Package the actual current build, not a potentially stale default-profile
    %% BEAM. The unmodified production escript must resolve it from a foreign cwd.
    Built = filename:dirname(code:which(efz_cli)),
    lists:foreach(fun(P) -> {ok, _} = file:copy(P, filename:join(Ebin, filename:basename(P))) end,
        filelib:wildcard(filename:join(Built, "*.beam")) ++ [filename:join(Built, "efz.app")]),
    S = #{base => Base, script => Script},
    lists:foreach(fun(D) -> ok = filelib:ensure_dir(path(S, D ++ "/placeholder")) end,
        ["external", "empty", "seeds/nested", "bad-beam", "bad-manifest", "missing-manifest", "cwd"]),
    lists:foreach(fun(M) ->
        {ok, M} = compile:noenv_file("fixtures/" ++ atom_to_list(M) ++ ".erl",
            [debug_info, warnings_as_errors, {outdir, path(S, "external")}])
    end, [efz_cli_harness]),
    {ok, A} = efz_instrument:compile("fixtures/efz_cli_parser.erl",
        #{modules => [efz_cli_parser], source_root => ".", outdir => path(S, "instrumented")}),
    {ok, _} = file:copy(maps:get(beam, A), path(S, "bad-manifest/efz_cli_parser.beam")),
    {ok, _} = file:copy(maps:get(beam, A), path(S, "missing-manifest/efz_cli_parser.beam")),
    ok = file:write_file(path(S, "bad-manifest/efz_cli_parser.efz-manifest"), <<"invalid sidecar">>),
    ok = file:write_file(path(S, "bad-beam/invalid.beam"), <<"invalid beam">>),
    ok = file:write_file(path(S, "bad-beam/invalid.efz-manifest"), <<"invalid sidecar">>),
    ok = file:write_file(path(S, "out-file"), <<"preserve">>),
    lists:foreach(fun({Name,B}) -> ok = file:write_file(path(S, "seeds/" ++ Name), B) end,
        [{"10-first", <<0>>}, {"20-raw", raw()}, {"30-empty", <<>>}]),
    %% Fault fixtures exercise existing classification; no custom fuzz engine,
    %% mutator, corpus or coverage collector is supplied to the launcher.
    fixture(S, efz_cli_crash, "run(B) -> error({cli_crash, B})."),
    fixture(S, efz_cli_timeout, "run(_) -> receive after 60000 -> ok end."),
    fixture(S, efz_cli_infra, "run(_) -> efz_cov:hit(unselected_manual_probe)."),
    fixture(S, efz_cli_disconnected, "run(B) when is_binary(B) -> ok."),
    S.
cleanup(S) -> ok = file:del_dir_r(maps:get(base, S)).
path(S, Suffix) -> filename:join(maps:get(base, S), Suffix).
raw() -> <<32,10,13,0,255,195,40>>.
fixture(S, M, Body) ->
    File = path(S, atom_to_list(M) ++ ".erl"),
    ok = file:write_file(File, io_lib:format("-module(~p).~n-export([run/1]).~n~s~n", [M, Body])),
    {ok, M} = compile:noenv_file(File, [debug_info, warnings_as_errors, {outdir, path(S, "external")}]).

args(S, Name, Changes) ->
    O = maps:merge(#{"--target" => "efz_cli_harness", "--seeds" => path(S, "seeds"),
        "--out" => path(S, atom_to_list(Name)), "--artifacts" => path(S, "instrumented"),
        "--code-path" => path(S, "external"), "--mutation" => "staged", "--timeout" => "1000",
        "--max-input-bytes" => "4096", "--max-iterations" => "4"}, Changes),
    lists:append([[K,V] || {K,V} <- lists:sort(maps:to_list(O)), V =/= undefined]).
invoke(S, Args) ->
    Port = open_port({spawn_executable, os:find_executable("escript")},
        [binary, exit_status, stderr_to_stdout, {cd, path(S, "cwd")},
         {env, [{"ERL_FLAGS", "+S 2:2"}]}, {args, [maps:get(script, S) | Args]}]),
    receive_output(Port, <<>>).
receive_output(P, Acc) -> receive
    {P, {data, B}} -> receive_output(P, <<Acc/binary, B/binary>>);
    {P, {exit_status, Status}} -> {Status, Acc}
after 4000 -> port_close(P), error({cli_vm_timeout, Acc}) end.
contains(Output, Text) -> ?assertNotEqual({Text, nomatch}, {Text, binary:match(Output, Text)}).
report(S, Name) ->
    {ok, B} = file:read_file(path(S, atom_to_list(Name) ++ "/report.term")), binary_to_term(B).
help(S) ->
    {0, Output} = invoke(S, ["--help"]), contains(Output, <<"MODULE:run(binary())">>),
    contains(Output, <<"--max-input-bytes">>).
invalid(S, Name, Changes, Message) ->
    {Status, Output} = invoke(S, args(S, Name, Changes)),
    contains(Output, Message), ?assertEqual(2, Status),
    ?assertNot(filelib:is_file(path(S, atom_to_list(Name) ++ "/report.term"))).
campaign(S) ->
    {Status, Output} = invoke(S, args(S, success, #{}) ++ ["--code-path", path(S, "cwd")]),
    ?assertEqual({0, true}, {Status, binary:match(Output, <<"Status: completed">>) =/= nomatch}),
    R = report(S, success), St = maps:get(stats, R),
    ?assertEqual(3, maps:get(calibrations, St)), ?assertEqual(4, maps:get(executions, St)),
    ?assertEqual(0, maps:get(infrastructure_failures, St)),
    ?assertEqual(4096, maps:get(max_input_bytes, maps:get(mutation, R))),
    ?assertEqual([<<0>>, raw(), <<>>], [maps:get(input, E) || E <- lists:sublist(maps:get(corpus, R), 3)]),
    Cal = [D || #{phase := calibration} = D <- maps:get(decisions, R)],
    ?assertEqual([{ok, {low, B}} || B <- [<<0>>, raw(), <<>>]], [maps:get(outcome, D) || D <- Cal]),
    [Found] = [E || E <- maps:get(corpus, R), maps:get(input, E) =:= <<128>>],
    Meta = maps:get(metadata, Found),
    ?assertEqual(new_coverage, maps:get(retention_reason, Meta)),
    ?assertEqual(1, maps:get(parent, Meta)),
    ?assert(maps:get(new_probes, Meta) =/= []),
    ?assertEqual({ok, <<128>>}, efz_recipe:regenerate(maps:get(mutation, Meta))).
random_campaign(S) ->
    {0, _} = invoke(S, args(S, random, #{"--mutation" => "random", "--max-input-bytes" => "7"})),
    R = report(S, random), ?assertEqual(completed, maps:get(status, R)),
    ?assertEqual(4, maps:get(executions, maps:get(stats, R))),
    ?assertEqual(7,maps:get(max_input_bytes,R)),
    ?assert(lists:all(fun(#{input:=B})->byte_size(B)=<7 end,maps:get(corpus,R))).
coverage_policy(S) ->
    Changes=#{"--target"=>"efz_cli_disconnected","--max-iterations"=>"0"},
    {0,Output}=invoke(S,args(S,disconnected,Changes)),contains(Output,<<"no_probes_observed">>),
    ?assertMatch(#{status:=no_probes_observed},maps:get(coverage_diagnostics,report(S,disconnected))),
    {1,StrictOutput}=invoke(S,args(S,strict_disconnected,Changes#{"--coverage-policy"=>"strict"})),
    contains(StrictOutput,<<"coverage_not_observed">>),
    ?assertMatch({infrastructure_failure,#{kind:=coverage_not_observed}},maps:get(status,report(S,strict_disconnected))),
    {2,Bad}=invoke(S,args(S,unknown_policy,Changes#{"--coverage-policy"=>"unknown"})),
    contains(Bad,<<"--coverage-policy must be diagnostic or strict">>).
zero_bound(S) ->
    Dir=path(S,"zero-seed"),ok=file:make_dir(Dir),ok=file:write_file(filename:join(Dir,"empty"),<<>>),
    lists:foreach(fun({Mode,Name})->
        {0,_}=invoke(S,args(S,Name,#{"--seeds"=>Dir,"--mutation"=>Mode,"--max-input-bytes"=>"0"})),
        R=report(S,Name),?assertEqual(0,maps:get(max_input_bytes,R)),
        ?assertEqual([<<>>],[maps:get(input,E)||E<-maps:get(corpus,R)]),
        ?assertEqual(1,maps:get(calibrations,maps:get(stats,R)))
    end,[{"random",random_zero},{"staged",staged_zero}]).
durable_campaign(S) ->
    Store=path(S,"persistent-corpus"),
    {0,_}=invoke(S,args(S,durable_first,#{"--corpus-dir"=>Store})),
    First=report(S,durable_first),N=length(maps:get(corpus,First)),
    {0,_}=invoke(S,args(S,durable_second,#{"--corpus-dir"=>Store,"--seeds"=>undefined,"--max-iterations"=>"1"})),
    Second=report(S,durable_second),
    ?assertEqual(N,maps:get(calibrations,maps:get(stats,Second))),
    ?assertEqual(N,maps:get(restored_inputs,maps:get(corpus_restore,Second))),
    ?assertEqual(1,maps:get(executions,maps:get(stats,Second))),
    ?assertEqual(lists:sort([maps:get(input,E)||E<-maps:get(corpus,First)]),
                 lists:sort([maps:get(input,E)||E<-maps:get(corpus,Second)])).
unreadable_seed(S) ->
    File = path(S, "unreadable/input"), ok = filelib:ensure_dir(File),
    ok = file:write_file(File, <<0>>), ok = file:change_mode(File, 0),
    try
        Message = case file:read_file(File) of
            {error, eacces} -> <<"Cannot read seed file">>;
            {ok, _} ->
                %% Privileged test runners can bypass mode bits. A dangling
                %% seed symlink still verifies failure instead of silent skip.
                ok = file:delete(File), ok = file:make_symlink("missing-input", File),
                <<"not a readable regular file">>
        end,
        invalid(S, unreadable, #{"--seeds" => path(S, "unreadable")}, Message)
    after ok = file:delete(File) end.
bad_options(S) ->
    lists:foreach(fun(Options) ->
        {2, Output} = invoke(S, Options), contains(Output, <<"Unknown option">>)
    end, [["--unknown"], ["--function", "parse"], ["--arity", "1"]]),
    {2, Missing} = invoke(S, ["--target"]), contains(Missing, <<"Missing value">>),
    {2, Required} = invoke(S, []), contains(Required, <<"Missing required option">>),
    {2, BadNumber} = invoke(S, ["--timeout", "no"]), contains(BadNumber, <<"nonnegative integer">>),
    {2, EmptyPath} = invoke(S, ["--code-path", ""]), contains(EmptyPath, <<"must not be empty">>),
    {2, Policy} = invoke(S, ["--corpus-build-policy", "resume"]), contains(Policy, <<"reject or recalibrate">>),
    {2, Duplicate} = invoke(S, ["--target", "one", "--target", "two"]), contains(Duplicate, <<"Duplicate option">>).
crash(S) ->
    {0, _} = invoke(S, args(S, crash, #{"--target" => "efz_cli_crash", "--max-iterations" => "0"})),
    R = report(S, crash), ?assertEqual(3, maps:get(crashes, maps:get(stats, R))),
    Inputs = [begin {ok, B} = file:read_file(P), B end || P <- filelib:wildcard(path(S, "crash/crashes/*/*/artifact.input"))],
    ?assertEqual(lists:sort([<<0>>, raw(), <<>>]), lists:sort(Inputs)).
timeout(S) ->
    {0, _} = invoke(S, args(S, timeout, #{"--target" => "efz_cli_timeout", "--timeout" => "5", "--max-iterations" => "0"})),
    R = report(S, timeout), ?assertEqual(3, maps:get(timeouts, maps:get(stats, R))),
    ?assertEqual([{timeout, 5}], lists:usort([maps:get(outcome, maps:get(result, C)) || C <- maps:get(crashes, R)])).
infrastructure(S) ->
    {1, Output} = invoke(S, args(S, infra, #{"--target" => "efz_cli_infra"})),
    contains(Output, <<"infrastructure failure">>),
    R = report(S, infra), ?assertMatch({infrastructure_failure, _}, maps:get(status, R)),
    ?assertEqual(1, maps:get(infrastructure_failures, maps:get(stats, R))).
report_failure(S) ->
    ok = filelib:ensure_dir(path(S, "report-failure/report.term/placeholder")),
    {1, Output} = invoke(S, args(S, 'report-failure', #{})),
    contains(Output, <<"report_storage">>).
