#!/usr/bin/env escript
%%! +S 4:4
-mode(compile).

%% Build/setup only. Campaigns run through scripts/fuzz.escript and efz:start/1.
main(Args) ->
    Root = filename:dirname(filename:dirname(filename:absname(escript:script_name()))),
    try
        case options(Args, filename:join([Root, "_build", "quickstart"])) of
            help -> help();
            Dir -> prepare(Root, Dir)
        end
    catch
        throw:{setup_error, Message} ->
            io:format(standard_error, "EFZ setup: ~ts~n", [Message]), halt(1);
        Class:Reason ->
            io:format(standard_error, "EFZ setup failed: ~tp:~tp~n", [Class, Reason]), halt(1)
    end.

options([], Default) -> Default;
options(["--help"], _) -> help;
options(["--dir", Dir], _) when Dir =/= [] -> filename:absname(Dir);
options(_, _) -> fail("Use --help or --dir DIRECTORY; unknown/missing arguments", []).

help() ->
    io:put_chars("Usage: escript scripts/prepare.escript [--dir DIRECTORY]\n"
                 "Requires Erlang/OTP >= 27 (erl, erlc, escript) and rebar3 on PATH.\n"
                 "Builds EFZ, instruments the bundled staged parser, and copies raw seeds.\n"
                 "Default directory: REPOSITORY/_build/quickstart. --dir is relative to your cwd.\n"
                 "Does not install packages or run a campaign. Existing identical seeds are kept;\n"
                 "conflicting seed files fail. Corpus and findings are never removed.\n").

prepare(Root, Dir) ->
    OTP = erlang:system_info(otp_release),
    case list_to_integer(OTP) >= 27 of
        true -> ok;
        false -> fail("OTP >= 27 required; found ~ts", [OTP])
    end,
    lists:foreach(fun executable/1, ["erl", "erlc", "escript"]),
    Rebar = executable("rebar3"),
    io:format("OTP ~ts / ERTS ~ts~nRepository: ~ts~nSetup directory: ~ts~n",
              [OTP, erlang:system_info(version), Root, Dir]),
    %% Bound the default scheduler count also in the build VM, while honouring
    %% an explicitly supplied ERL_FLAGS. Do not run a shell or interpolate paths.
    Flags = case os:getenv("ERL_FLAGS") of false -> "+S 4:4"; Value -> Value end,
    Port = open_port({spawn_executable, Rebar}, [binary, exit_status, use_stdio,
        stderr_to_stdout, {args, ["compile"]}, {cd, Root},
        {env, [{"ERL_FLAGS", Flags}, {"REBAR_BASE_DIR", filename:join(Root,"_build")},
               {"REBAR_PROFILE", "default"}]}]),
    build_result(Port),
    Ebin = filename:join([Root, "_build", "default", "lib", "efz", "ebin"]),
    case code:add_patha(Ebin) of
        true -> ok;
        _ -> fail("EFZ build not found: ~ts", [Ebin])
    end,
    _ = require(application:ensure_all_started(crypto), "start crypto"),
    Seeds = filename:join(Dir, "seeds"),
    Artifacts = filename:join(Dir, "instrumented"),
    Out = filename:join(Dir, "findings"),
    Corpus = filename:join(Dir, "corpus"),
    lists:foreach(fun(D) -> ok = checked(efz_fs:directory(D), D) end,
                  [Seeds, Artifacts, Out, Corpus]),
    Source = filename:join([Root, "examples", "staged", "corpus"]),
    Names = lists:sort(filelib:wildcard(filename:join(Source, "*.seed"))),
    case Names of [] -> fail("No bundled seed files in ~ts", [Source]); _ -> ok end,
    lists:foreach(fun(P) -> copy_seed(P, filename:join(Seeds,filename:basename(P))) end, Names),
    A = require(efz_instrument:compile(filename:join([Root,"examples","staged","efz_staged_parser.erl"]),
        #{modules => [efz_staged_parser], source_root => Root, outdir => Artifacts}),
        "instrument staged parser"),
    _ = require(efz_instrument:preflight([A]), "validate instrumented build"),
    true = erlang:function_exported(efz_staged_parser, run, 1),
    io:format("Ready: ~B bundled seeds; instrumented efz_staged_parser:run/1.~n"
              "This target has a deliberate demonstration crash on BOOM!.~n~n", [length(Names)]),
    Command = ["escript", filename:join([Root,"scripts","fuzz.escript"]),
        "--target", "efz_staged_parser", "--seeds", Seeds, "--out", Out,
        "--artifacts", Artifacts, "--corpus-dir", Corpus, "--mutation", "staged",
        "--coverage-policy", "strict", "--timeout", "1000", "--max-input-bytes", "4096",
        "--max-iterations", "1000"],
    io:format("Run in a fresh VM (copy this command):~nERL_FLAGS='+S 4:4' ~ts~n",
              [lists:join(" ", [quote(X) || X <- Command])]).

executable(Name) ->
    case os:find_executable(Name) of
        false -> fail("Missing executable ~ts; install Erlang/OTP >= 27 and rebar3, then retry", [Name]);
        Path -> Path
    end.
build_result(Port) ->
    receive
        {Port, {data, Bytes}} -> ok = file:write(standard_io, Bytes), build_result(Port);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, N}} -> fail("rebar3 compile exited with status ~B", [N])
    end.
copy_seed(Source, Dest) ->
    Bytes = require(efz_input:read_file(Source,4096,seed_ingestion), Source),
    case file:read_file(Dest) of
        {ok, Bytes} -> ok;
        {ok, _} -> fail("Existing seed differs: ~ts (preserved; choose a new --dir)", [Dest]);
        {error, enoent} -> checked(efz_fs:atomic_file(Dest, Bytes), Dest);
        {error, Why} -> fail("Cannot read seed ~ts: ~tp", [Dest, Why])
    end,
    io:format("Seed: ~ts (~B bytes)~n", [filename:basename(Source), byte_size(Bytes)]).
require({ok, Value}, _) -> Value;
require({error, Why}, Context) -> fail("~ts: ~tp", [Context, Why]).
checked(ok, _) -> ok;
checked({error, Why}, Context) -> fail("~ts: ~tp", [Context, Why]).
quote(Text) -> "'" ++ lists:flatten(string:replace(Text, "'", "'\"'\"'", all)) ++ "'".
fail(Format, Args) -> throw({setup_error, io_lib:format(Format, Args)}).
