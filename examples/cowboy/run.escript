#!/usr/bin/env escript
-mode(compile).

main(Args) ->
    case Args of
        [Root] -> run(filename:absname(Root), 500);
        [Root, "check"] -> run(filename:absname(Root), check);
        [Root, Count] ->
            case string:to_integer(Count) of
                {N, []} when N > 0, N =< 100000 -> run(filename:absname(Root), N);
                _ -> usage()
            end;
        _ -> usage()
    end.

usage() ->
    io:format(standard_error,
        "From the EFZ root: escript examples/cowboy/run.escript COWBOY_DIR [check|1..100000]~n"
        "First build that Cowboy checkout with make (including deps/cowlib).~n", []),
    halt(1).

run(Root, Action) ->
    true = code:add_patha("_build/default/lib/efz/ebin"),
    Cowlib = filename:join([Root, "deps", "cowlib"]),
    lists:foreach(fun(Path) ->
        case filelib:is_regular(Path) of
            true -> ok;
            false -> io:format(standard_error, "Missing build artifact: ~ts~nRun make in COWBOY_DIR first.~n", [Path]), halt(1)
        end
    end, [filename:join([Root, "ebin", "cowboy_req.beam"]),
          filename:join([Cowlib, "ebin", "cow_qs.beam"])]),
    load_local(efz_cowboy_target),
    {ok, Cowboy} = efz_instrument:compile(filename:join([Root, "src", "cowboy_req.erl"]),
        #{modules => [cowboy_req], source_root => Root, strict => false,
          erl_opts => [debug_info, warnings_as_errors], outdir => "_build/cowboy-targets"}),
    {ok, Qs} = efz_instrument:compile(filename:join([Cowlib, "src", "cow_qs.erl"]),
        #{modules => [cow_qs], source_root => Cowlib,
          erl_opts => [debug_info, warnings_as_errors, {i, filename:join(Cowlib, "include")}],
          outdir => "_build/cowboy-targets"}),
    Artifacts = [Cowboy, Qs],
    {ok, Manifests} = efz_instrument:preflight(Artifacts),
    lists:foreach(fun(M) ->
        io:format("~p: ~p probes, build ~ts, ~p instrumentation limitations~n",
            [maps:get(module, M), length(maps:get(probes, M)),
             binary:encode_hex(maps:get(build_id, M)), length(maps:get(limitations, M))])
    end, Manifests),
    case Action of
        check ->
            load_local(efz_cowboy_checks),
            ok = eunit:test(efz_cowboy_checks:tests(Artifacts, Manifests), [verbose]);
        N -> campaign(Artifacts, N)
    end.

load_local(Module) ->
    File = filename:join("examples/cowboy", atom_to_list(Module) ++ ".erl"),
    {ok, Module, Beam} = compile:noenv_file(File, [binary, debug_info, warnings_as_errors]),
    {module, Module} = code:load_binary(Module, File, Beam).

campaign(Artifacts, N) ->
    {ok, _} = efz:start(#{target => efz_cowboy_target, artifacts => Artifacts,
        seeds => [<<>>], max_iterations => N, mutation_mode => staged,
        crash_dir => "_build/cowboy-crashes", timeout => 100,
        max_input_bytes => 1024, mutation => #{seed => {17, 23, 41},
            stages => [dictionary_insert, bitflip, havoc],
            dictionary => [<<"a=1">>, <<"&">>, <<"=">>, <<"+">>, <<"%00">>, <<"%2F">>, <<"%ff">>, <<"%">>]}}),
    try
        Report = efz:await(infinity),
        ok = file:write_file("_build/cowboy-report.term", term_to_binary(Report)),
        io:format("~tp~nReport: _build/cowboy-report.term~n",
            [maps:with([status, stats, mutation_stats], Report)]),
        completed = maps:get(status, Report)
    after efz:stop() end.
