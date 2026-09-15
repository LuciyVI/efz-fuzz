%% Filesystem/argument adapter only. The existing campaign owns all fuzzing work.
-module(efz_cli).
-export([main/1]).

main(Args) ->
    try
        case parse(Args, #{}) of
            help -> io:put_chars(help()), 0;
            Options -> launch(Options)
        end
    catch
        throw:{cli_error, Message} -> io:format(standard_error, "EFZ: ~ts~n", [Message]), 2;
        Class:Reason -> io:format(standard_error, "EFZ infrastructure error: ~tp:~tp~n", [Class, Reason]), 1
    end.

help() ->
    "Usage: escript scripts/fuzz.escript --target MODULE --out DIR --artifacts DIR [--seeds DIR | --corpus-dir DIR] [options]\n"
    "\nTarget contract: MODULE:run(binary()) -> term(). Coverage is automatic.\n"
    "  --target MODULE          Harness or instrumented target exporting run/1 (required)\n"
    "  --seeds DIR              Read raw seed files (required unless --corpus-dir is supplied)\n"
    "  --corpus-dir DIR         Load/store reusable successful corpus, not a campaign checkpoint\n"
    "  --corpus-build-policy reject|recalibrate  Build mismatch policy (default: reject)\n"
    "  --out DIR                Create/use DIR; write report.term and crashes/ (required)\n"
    "  --artifacts DIR          Instrumented .beam files with paired .efz-manifest files (required)\n"
    "  --coverage-policy diagnostic|strict  No-probe campaign policy (default: diagnostic)\n"
    "  --code-path DIR          Ordinary harness/dependency BEAM directory (repeatable)\n"
    "  --mutation staged|random Default: staged\n"
    "  --timeout MS             Per-input timeout, nonnegative integer (default: 100)\n"
    "  --max-iterations N       Mutation execution limit (default: 1000)\n"
    "  --max-input-bytes N      Campaign/replay input bound, 0..1048576 (default: 4096)\n"
    "  --help                   Show this help\n"
    "\nSeed directories are not recursive; subdirectories are ignored. Empty files are valid seeds;\n"
    "a directory without seed files is an error.\n"
    "Exit: 0 completed/exhausted/idle stop (including target crashes); 2 invalid invocation/config;\n"
    "1 runtime infrastructure or report-storage failure. Existing report.term is replaced.\n".

parse([], Options) -> Options;
parse(["--help"], _) -> help;
parse([Option | Rest], Options) ->
    Key = option(Option),
    case Rest of
        [] -> fail("Missing value for ~ts", [Option]);
        ["--" ++ _ | _] -> fail("Missing value for ~ts", [Option]);
        [Value | Tail] ->
            case Key of
                code_paths -> parse(Tail, Options#{Key => maps:get(Key, Options, []) ++ [value(Key, Value)]});
                _ -> case maps:is_key(Key, Options) of
                    true -> fail("Duplicate option: ~ts", [Option]);
                    false -> parse(Tail, Options#{Key => value(Key, Value)})
                end
            end
    end.
option("--target") -> target;
option("--seeds") -> seeds;
option("--corpus-dir") -> corpus_dir;
option("--corpus-build-policy") -> corpus_build_policy;
option("--out") -> out;
option("--artifacts") -> artifacts;
option("--coverage-policy") -> coverage_policy;
option("--code-path") -> code_paths;
option("--mutation") -> mutation_mode;
option("--timeout") -> timeout;
option("--max-iterations") -> max_iterations;
option("--max-input-bytes") -> max_input_bytes;
option(Unknown) -> fail("Unknown option: ~ts (use --help)", [Unknown]).
value(target, Name) when Name =/= [], length(Name) =< 255 -> list_to_atom(Name);
value(target, _) -> fail("--target must be a module name of 1..255 characters", []);
value(mutation_mode, "staged") -> staged;
value(mutation_mode, "random") -> random;
value(mutation_mode, _) -> fail("--mutation must be staged or random", []);
value(corpus_build_policy, "reject") -> reject;
value(corpus_build_policy, "recalibrate") -> recalibrate;
value(corpus_build_policy, _) -> fail("--corpus-build-policy must be reject or recalibrate", []);
value(coverage_policy, "diagnostic") -> diagnostic;
value(coverage_policy, "strict") -> strict;
value(coverage_policy, _) -> fail("--coverage-policy must be diagnostic or strict", []);
value(K, Text) when K =:= timeout; K =:= max_iterations; K =:= max_input_bytes ->
    case Text =/= [] andalso lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Text) of
        true -> list_to_integer(Text);
        false -> fail("~ts must be a nonnegative integer", [flag(K)])
    end;
value(_, []) -> fail("Directory arguments must not be empty", []);
value(_, Text) -> Text.
flag(timeout) -> "--timeout";
flag(max_iterations) -> "--max-iterations";
flag(max_input_bytes) -> "--max-input-bytes".

launch(O) ->
    lists:foreach(fun(K) ->
        case maps:is_key(K, O) of
            true -> ok;
            false -> fail("Missing required option: --~s", [K])
        end
    end, [target, out, artifacts]),
    lists:foreach(fun add_code_path/1, maps:get(code_paths, O, [])),
    Max = maps:get(max_input_bytes,O,efz_input:default_limit()),
    case efz_input:valid_limit(Max) of true->ok;false->fail("--max-input-bytes must be 0..1048576",[]) end,
    Seeds = case maps:find(seeds, O) of
        {ok, SeedDir} -> read_seeds(SeedDir,Max);
        error -> case maps:is_key(corpus_dir, O) of
            true -> [];
            false -> fail("Missing required option: --seeds (or --corpus-dir)", [])
        end
    end,
    Artifacts = require(efz_instrument:discover(maps:get(artifacts, O)), "Invalid artifacts"),
    Mode = maps:get(mutation_mode, O, staged),
    C0 = #{target => maps:get(target, O), seeds => Seeds, artifacts => Artifacts,
           mutation_mode => Mode, timeout => maps:get(timeout, O, 100),
           max_iterations => maps:get(max_iterations, O, 1000)},
    C = C0#{max_input_bytes => Max},
    Out = filename:absname(maps:get(out, O)),
    Crashes = filename:join(Out, "crashes"),
    writable_directory(Out), writable_directory(Crashes),
    try
        case efz:start(maps:merge(C#{crash_dir => Crashes}, maps:with([corpus_dir,corpus_build_policy,coverage_policy],O))) of
            {ok, _} -> finish(efz:await(infinity), Out);
            {error, Why} -> fail("Cannot start campaign: ~ts", [start_error(Why)])
        end
    after _ = efz:stop() end.

add_code_path(Dir) ->
    case code:add_pathz(filename:absname(Dir)) of
        true -> ok;
        {error, Why} -> fail("Cannot add code path ~ts: ~tp", [Dir, Why])
    end.
read_seeds(Dir,Max) ->
    Names = require(file:list_dir(Dir), io_lib:format("Cannot read seed directory ~ts", [Dir])),
    Inputs = lists:filtermap(fun(Name) ->
        Path = filename:join(Dir, Name),
        case filelib:is_dir(Path) of
            true -> false;
            false ->
                case filelib:is_regular(Path) of
                    true -> {true, require(efz_input:read_file(Path,Max,seed_ingestion), io_lib:format("Cannot read seed file ~ts", [Path]))};
                    false -> fail("Seed entry is not a readable regular file: ~ts", [Path])
                end
        end
    end, lists:sort(Names)),
    case Inputs of [] -> fail("Empty corpus: no seed files in ~ts", [Dir]); _ -> Inputs end.

writable_directory(Dir) ->
    Probe = filename:join(Dir, ".efz-write-check-" ++ integer_to_list(erlang:unique_integer([positive]))),
    case filelib:ensure_dir(Probe) of
        ok -> ok;
        {error, Why} -> fail("Output directory unavailable ~ts: ~tp", [Dir, Why])
    end,
    case file:open(Probe, [write, binary, exclusive]) of
        {ok, F} ->
            Write = file:write(F, <<"EFZ">>), Close = file:close(F), Delete = file:delete(Probe),
            case {Write, Close, Delete} of
                {ok, ok, ok} -> ok;
                Other -> fail("Output directory is not writable ~ts: ~tp", [Dir, Other])
            end;
        {error, Why2} -> fail("Output directory is not writable ~ts: ~tp", [Dir, Why2])
    end.
finish(Report, Out) ->
    Path = filename:join(Out, "report.term"),
    case efz_fs:atomic_file(Path, term_to_binary(Report)) of
        ok -> ok;
        {error, Why} ->
            %% Keep a preceding crash/corpus failure primary even if writing the
            %% final report also fails. The exception carries the in-memory
            %% report (including exact triggering bytes) to the CLI diagnostic.
            Primary=efz_stats:failure(Why),
            Failed=Report#{status=>{infrastructure_failure,Primary},stats=>efz_stats:get(),report_storage_error=>Why},
            error({report_storage,Path,Why,Failed})
    end,
    Status = maps:get(status, Report),
    io:format("Status: ~tp~nStats: ~tp~nReport: ~ts~n", [Status, maps:get(stats, Report), Path]),
    case maps:get(coverage_diagnostics,Report,#{unused_artifacts=>[]}) of
        #{unused_artifacts:=[]} -> ok;
        Diagnostic -> io:format(standard_error,"EFZ coverage diagnostic: ~tp~n",[Diagnostic])
    end,
    case Status of
        completed -> 0;
        {mutation_exhausted, _} -> 0;
        {mutation_stopped, idle_budget_exhausted} -> 0;
        _ -> io:format(standard_error, "EFZ infrastructure failure: ~tp~n", [Status]), 1
    end.

%% supervisor:start_child wraps a start_link validation error in its child spec.
start_error({Why, {child, _, _, _, _, _, _, _, _}}) -> start_error(Why);
start_error({module_unavailable, Kind, M, Why}) ->
    io_lib:format("~p module ~p could not be loaded (~tp); use --code-path for ordinary BEAM files", [Kind, M, Why]);
start_error({missing_callback, Kind, M, F, A}) ->
    io_lib:format("~p module ~p must export ~p/~B", [Kind, M, F, A]);
start_error(Why) -> io_lib:format("~tp", [Why]).
require({ok, Value}, _) -> Value;
require({error, Why}, Context) -> fail("~ts: ~tp", [Context, Why]).
-spec fail(string(), [term()]) -> no_return().
fail(Format, Args) -> throw({cli_error, io_lib:format(Format, Args)}).
