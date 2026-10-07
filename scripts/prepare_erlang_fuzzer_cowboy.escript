#!/usr/bin/env escript
-mode(compile).

main([Out]) ->
    lists:foreach(fun(P) -> true = code:add_patha(filename:absname(P)) end,
        ["_build/default/lib/efz/ebin" |
         filelib:wildcard("_build/default/lib/*/ebin")]),
    Root = filename:absname("_build/default/lib/cowboy"),
    Target = filename:join(Out, "target-beams"),
    Harness = filename:join(Out, "harness-beams"),
    ok = filelib:ensure_dir(filename:join(Target, "placeholder")),
    ok = filelib:ensure_dir(filename:join(Harness, "placeholder")),
    Mods = [cowboy_http, cowboy_req, cowboy_router, cowboy_stream],
    lists:foreach(fun(M) ->
        Src = filename:join([Root, "src", atom_to_list(M) ++ ".erl"]),
        {ok, _} = efz_cov_native_public:compile(Src, Target)
    end, Mods),
    lists:foreach(fun(M) ->
        Src = filename:join("test/targets/cowboy", atom_to_list(M) ++ ".erl"),
        {ok, M} = compile:file(Src, [debug_info, {outdir, Harness}, warnings_as_errors])
    end, [efz_cowboy_transport, efz_cowboy_stream, efz_cowboy_long_target]),
    {ok, efz_erlang_fuzzer_cowboy} = compile:file(
        "bench/efz_erlang_fuzzer_cowboy.erl",
        [debug_info, {outdir, Harness}, warnings_as_errors]),
    io:format("~s~n", [filename:absname(filename:join(Harness,
        "efz_erlang_fuzzer_cowboy.beam"))]);
main(_) ->
    io:format(standard_error, "usage: prepare_erlang_fuzzer_cowboy.escript OUT~n", []),
    halt(2).
