#!/usr/bin/env escript
-mode(compile).

%% Reproducible, local XML-RPC integration campaigns. Each matrix cell starts
%% in a fresh VM, so native coverage, adapter state and corpus cannot leak.
main(["--worker", Surface, Mode, Iterations, Seed, Profile, Source, Out]) ->
    guarded(fun() ->
        paths(Profile),
        run_one(surface(Surface), mode(Mode), integer(Iterations, 1, 1000000),
                integer(Seed, 0, 2147483647), Profile, filename:absname(Source),
                filename:absname(Out))
    end);
main(Args) ->
    guarded(fun() ->
        C = parse(Args, #{surface => all, mode => off, iterations => 1000,
                         seed => 424242, profile => "default",
                         source => filename:absname("_build/xmlrpc-dependency")}),
        paths(maps:get(profile, C)),
        run_matrix(C)
    end).

guarded(F) ->
    try F()
    catch Class:Reason:Stack ->
        io:format(standard_error, "XML-RPC suite failed: ~tp:~tp~n~tp~n", [Class, Reason, Stack]),
        halt(1)
    end.

parse([], C) -> C;
parse(["--surface", "all" | Rest], C) -> parse(Rest, C#{surface => all});
parse(["--surface", Value | Rest], C) -> parse(Rest, C#{surface => Value});
parse(["--mode", "all" | Rest], C) -> parse(Rest, C#{mode => all});
parse(["--mode", Value | Rest], C) -> parse(Rest, C#{mode => mode(Value)});
parse(["--iterations", Value | Rest], C) ->
    parse(Rest, C#{iterations => integer(Value, 1, 1000000)});
parse(["--seed", Value | Rest], C) ->
    parse(Rest, C#{seed => integer(Value, 0, 2147483647)});
parse(["--profile", Value | Rest], C) when Value =:= "default"; Value =:= "gleam" ->
    parse(Rest, C#{profile => Value});
parse(["--out", Value | Rest], C) -> parse(Rest, C#{out => filename:absname(Value)});
parse(["--source", Value | Rest], C) -> parse(Rest, C#{source => filename:absname(Value)});
parse(["--help"], _) ->
    io:format("Usage: escript scripts/xmlrpc_suite.escript [--surface all|NAME] "
              "[--mode all|off|observation_only|guided] [--iterations N] [--seed N] "
              "[--profile default|gleam] [--source PINNED_CHECKOUT] --out NEW_DIR~n"
              "Surfaces: call, response, fault, roundtrip, dispatch, encoder_validation.~n"
              "Run from the repository root after examples/xmlrpc/prepare_flows.escript; "
              "use the Gleam profile for observation_only/guided. "
              "All campaigns use locally constructed messages without listeners.~n"),
    halt(0);
parse(Other, _) -> error({invalid_arguments, Other}).

surface(Value) ->
    %% No atoms are created from command-line input.
    case [S || S <- efz_xmlrpc_suite:surfaces(), atom_to_list(S) =:= Value] of
        [S] -> S;
        [] -> error({unknown_surface, Value, efz_xmlrpc_suite:surfaces()})
    end.
mode("off") -> off;
mode("observation_only") -> observation_only;
mode("guided") -> guided;
mode(Value) -> error({unknown_mode, Value}).
integer(Value, Min, Max) ->
    case string:to_integer(Value) of
        {N, []} when N >= Min, N =< Max -> N;
        _ -> error({invalid_integer, Value, Min, Max})
    end.

paths(Profile) ->
    %% Dependencies may be shared with the default profile; the selected EFZ
    %% application is always placed last, at the front of the search path.
    Ebin = filename:join(["_build", Profile, "lib", "efz", "ebin"]),
    true = filelib:is_dir(Ebin),
    Deps = filelib:wildcard("_build/default/lib/*/ebin") ++
        filelib:wildcard(filename:join(["_build", Profile, "lib", "*", "ebin"])),
    Prepared = filename:join(["_build", "xmlrpc-example", "dependency-ebin"]),
    true = filelib:is_dir(Prepared),
    lists:foreach(fun(P) -> true = code:add_patha(filename:absname(P)) end,
        Deps ++ [Prepared, Ebin]),
    %% Loading the suite is safe; target libraries stay cold until preflight.
    {module, efz_xmlrpc_suite} = code:ensure_loaded(efz_xmlrpc_suite),
    ok.

run_matrix(C0) ->
    Out = maps:get(out, C0, filename:absname(filename:join("_build",
        "xmlrpc-suite-" ++ integer_to_list(erlang:system_time(millisecond))))),
    C = C0#{out => Out},
    Surfaces = case maps:get(surface, C) of
        all -> efz_xmlrpc_suite:surfaces(); Value -> [surface(Value)] end,
    Modes = case maps:get(mode, C) of all -> [off, observation_only, guided]; M -> [M] end,
    case lists:any(fun(M) -> M =/= off end, Modes) of
        true -> {module, efz_term_model} = code:ensure_loaded(efz_term_model);
        false -> ok
    end,
    Dependency = dependency_check(maps:get(source, C)),
    new_dir(Out),
    ok = write_term(filename:join(Out, "matrix.term"), C#{surfaces => Surfaces, modes => Modes,
        schema_version => 1, fresh_vm_per_campaign => true,
        dependency => Dependency}),
    Summaries = [begin
        Cell = filename:join([Out, atom_to_list(S), atom_to_list(M)]),
        new_dir(Cell),
        run_child(C, S, M, Cell),
        {ok, [Summary]} = file:consult(filename:join(Cell, "summary.term")),
        Summary
    end || S <- Surfaces, M <- Modes],
    ok = write_term(filename:join(Out, "summary.term"), Summaries),
    ok = write_summary_csv(filename:join(Out, "summary.csv"), Summaries),
    Comparisons = comparisons(Summaries),
    ok = write_term(filename:join(Out, "comparisons.term"), Comparisons),
    ok = write_comparison_csv(filename:join(Out, "comparisons.csv"), Comparisons),
    io:format("Results: ~s~n", [Out]),
    case [maps:with([surface,mode,status], S) || S <- Summaries,
            maps:get(status, S) =/= completed] of
        [] -> ok;
        Failed -> error({campaigns_did_not_complete, Failed})
    end.

run_child(C, S, M, Out) ->
    Escript = case os:find_executable("escript") of false -> error(escript_not_found); P -> P end,
    Args = [filename:absname(escript:script_name()), "--worker", atom_to_list(S),
        atom_to_list(M), integer_to_list(maps:get(iterations, C)),
        integer_to_list(maps:get(seed, C)), maps:get(profile, C), maps:get(source, C), Out],
    Port = open_port({spawn_executable, Escript},
        [binary, exit_status, stderr_to_stdout, {args, Args}]),
    child_output(Port, S, M).
child_output(Port, S, M) ->
    receive
        {Port, {data, Data}} -> io:put_chars(Data), child_output(Port, S, M);
        {Port, {exit_status, 0}} -> ok;
        {Port, {exit_status, Code}} -> error({campaign_vm_failed, S, M, Code})
    end.

run_one(Surface, Mode, Iterations, Seed, Profile, Source, Out) ->
    Started = erlang:monotonic_time(microsecond),
    Dependency = dependency_check(Source),
    Modules = lists:usort(efz_xmlrpc_suite:modules(Surface)),
    true = Modules =/= [],
    %% Calling modules/1 must not load a target library module. Native preflight
    %% deliberately refuses to replace an already loaded, different build.
    Artifacts = [compile_target(M, Source, Out) || M <- Modules],
    {ok, Manifests} = efz_cov_native_public:preflight(Artifacts),
    TotalLines = lists:sum([length(maps:get(lines, M)) || M <- Manifests]),
    ok = efz_xmlrpc_suite:setup(Surface),
    try
        C0 = efz_xmlrpc_suite:config(Surface, Mode, Iterations, Seed),
        Seeds = maps:get(seeds, C0),
        true = Seeds =/= [],
        CorpusHash = crypto:hash(sha256, term_to_binary(Seeds, [deterministic])),
        C = C0#{artifacts => Artifacts, coverage_backend => otp_native_public,
            monitoring => true, performance_profile => true,
            corpus_dir => filename:join(Out, "corpus"),
            crash_dir => filename:join(Out, "crashes")},
        save_seeds(filename:join(Out, "initial-corpus"), Seeds),
        ok = write_term(filename:join(Out, "config.term"), C),
        ok = write_term(filename:join(Out, "artifacts.term"), Artifacts),
        ok = write_term(filename:join(Out, "identity.term"),
            identity(Surface, Profile, Modules, Seeds, CorpusHash, Dependency)),
        PreparedUs = erlang:monotonic_time(microsecond) - Started,
        CampaignStart = erlang:monotonic_time(microsecond),
        {ok, _} = efz:start(C),
        try
            Report = efz:await(max(60000, Iterations * 2000)),
            WallUs = erlang:monotonic_time(microsecond) - CampaignStart,
            Snapshot = efz_fuzzer:monitor_snapshot(),
            Counts = efz_xmlrpc_suite:counters(Surface),
            Summary = summary(Surface, Mode, Iterations, Seed, CorpusHash,
                TotalLines, PreparedUs, WallUs, Report, Snapshot, Counts),
            %% The ETF copy retains process/reference identities for raw
            %% diagnostics; the text copy uses explicit consultable tags.
            ok = file:write_file(filename:join(Out, "report.etf"),
                term_to_binary(Report, [deterministic]), [exclusive]),
            ok = write_term(filename:join(Out, "report.term"), Report),
            ok = write_term(filename:join(Out, "snapshot.term"), Snapshot),
            ok = write_term(filename:join(Out, "summary.term"), Summary),
            io:format("~p/~p: ~p, ~B executions, ~B/~B library lines, ~B corpus, "
                "~B exceptions, ~B timeouts; ~.1f mutation exec/s~n", [Surface, Mode,
                maps:get(status, Summary), maps:get(executions, Summary),
                maps:get(coverage_lines, Summary), TotalLines, maps:get(corpus_size, Summary),
                maps:get(crash_occurrences, Summary), maps:get(timeouts, Summary),
                maps:get(mutation_exec_per_sec, Summary)]),
            validate_completed_campaign(Summary)
        after efz:stop() end
    after efz_xmlrpc_suite:teardown(Surface) end.

compile_target(M, Checkout, Out) ->
    %% xmerl is an ordinary OTP dependency; only these pinned library sources
    %% contribute native coverage. Erlang's compiler reads their Latin-1 marker.
    true = lists:member(M, [xmlrpc_encode, xmlrpc_decode, xmlrpc_util]),
    Src = filename:join(Checkout, "src"),
    Source = filename:join(Src, atom_to_list(M) ++ ".erl"),
    true = filelib:is_regular(Source),
    Includes = [Src],
    {ok, Artifact} = efz_cov_native_public:compile(Source,
        filename:join(Out, "target-beams"), Includes),
    Artifact.

dependency_check(Source) ->
    Pin = <<"fb46463b2acadf164ec534d9e2033e194341c507">>,
    case git(Source, ["rev-parse", "HEAD"]) of
        {0, Output} ->
            case list_to_binary(string:trim(binary_to_list(Output))) of
                Pin -> ok;
                Commit -> error({xmlrpc_commit_mismatch, Pin, Commit})
            end;
        Error -> error({xmlrpc_checkout_unavailable, Source, Error})
    end,
    Files = ["src/xmlrpc_encode.erl", "src/xmlrpc_decode.erl",
             "src/xmlrpc_util.erl", "src/log.hrl"],
    case git(Source, ["diff", "--exit-code", "HEAD", "--" | Files]) of
        {0, _} -> ok;
        Modified -> error({xmlrpc_dependency_modified, Modified})
    end,
    #{repository => <<"https://github.com/etnt/xmlrpc">>, commit => Pin,
      checkout => Source, clean_selected_sources => true,
      sources => [begin
          {ok, Bytes} = file:read_file(filename:join(Source, File)),
          #{path => File, sha256 => crypto:hash(sha256, Bytes)}
      end || File <- Files]}.

git(Source, Args) ->
    Git = case os:find_executable("git") of
        false -> error(git_executable_missing);
        Path -> Path
    end,
    Port = open_port({spawn_executable, Git}, [binary, exit_status, use_stdio,
        stderr_to_stdout, {args, ["-C", Source | Args]}]),
    collect_git(Port, <<>>, erlang:monotonic_time(millisecond) + 10000).
collect_git(Port, Output, Deadline) ->
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, Data}} when byte_size(Output) + byte_size(Data) =< 65536 ->
            collect_git(Port, <<Output/binary, Data/binary>>, Deadline);
        {Port, {data, _}} -> port_close(Port), error(git_output_limit);
        {Port, {exit_status, Status}} -> {Status, Output}
    after Remaining -> port_close(Port), error(git_timeout)
    end.

validate_completed_campaign(Summary) ->
    case maps:get(status, Summary) of
        completed ->
            case {maps:get(executions, Summary), maps:get(requested_iterations, Summary)} of
                {N, N} -> ok;
                Mismatch -> error({execution_budget_mismatch, Mismatch})
            end;
        _ -> ok
    end,
    case maps:get(invocation_accounting, Summary) of
        #{valid := true} -> ok;
        Accounting -> error({target_invocation_accounting_failed, Accounting})
    end.

summary(Surface, Mode, Budget, Seed, CorpusHash, TotalLines, PreparedUs, WallUs, R, Snapshot, Counts0) ->
    Stats = maps:get(stats, R),
    N = maps:get(executions, Stats),
    Timing = maps:get(timing, R),
    MutationUs = maps:get(mutation_us, Timing),
    Corpus = maps:get(corpus, R),
    Calibration = [D || D <- maps:get(decisions, R), maps:get(phase, D, undefined) =:= calibration],
    CalibrationLines = lists:usort(lists:append([maps:get(new_probes, D, []) || D <- Calibration])),
    Counts = maps:merge(#{invocations => 0, accepted => 0, rejected => 0, incomplete => 0}, Counts0),
    Invocations = maps:get(invocations, Counts),
    CompletedCalls = lists:sum([maps:get(K, Counts) || K <- [accepted, rejected, incomplete]]),
    ExpectedCalls = maps:get(calibrations, Stats) + N,
    Failed = maps:get(crash_occurrences, Stats) > 0 orelse maps:get(timeouts, Stats) > 0,
    #{schema_version => 1, surface => Surface, mode => Mode, status => maps:get(status, R),
      requested_iterations => Budget, seed => Seed, initial_corpus_sha256 => CorpusHash,
      preparation_us => PreparedUs, campaign_wall_us => WallUs,
      calibration_us => maps:get(calibration_us, Timing), mutation_us => MutationUs,
      executions => N, calibrations => maps:get(calibrations, Stats),
      mutation_exec_per_sec => N * 1000000 / max(1, MutationUs),
      campaign_exec_per_sec => N * 1000000 / max(1, WallUs),
      coverage_lines => length(maps:get(coverage, R)), coverage_total_lines => TotalLines,
      calibration_coverage_lines => length(CalibrationLines),
      mutation_new_coverage_lines => length(maps:get(coverage, R)) - length(CalibrationLines),
      corpus_size => length(Corpus), discoveries => maps:get(discoveries, Stats),
      corpus_equivalent_rejections => maps:get(rejections, Stats),
      crash_occurrences => maps:get(crash_occurrences, Stats),
      unique_crashes => maps:get(unique_crashes, Stats), timeouts => maps:get(timeouts, Stats),
      infrastructure_failures => maps:get(infrastructure_failures, Stats),
      target_counters => Counts,
      target_invocations => Invocations, target_accepted => maps:get(accepted, Counts),
      target_rejected => maps:get(rejected, Counts), target_incomplete => maps:get(incomplete, Counts),
      invocation_accounting => #{expected_calls => ExpectedCalls, invocations => Invocations,
          completed_calls => CompletedCalls, target_failure_observed => Failed,
          valid => Invocations =:= ExpectedCalls andalso CompletedCalls =:= Invocations},
      calibration_outcomes => count_outcomes(Calibration),
      monitored_outcomes => maps:get(outcomes, Snapshot, #{}),
      monitored_outcome_note => <<"returned includes accepted and incomplete; counts include calibration; encoder_validation rejections are expected">>,
      gleam_stats => maps:get(gleam_stats, R, #{}),
      structured_stats => maps:get(structured_stats, R, #{}),
      semantic_feature_count => length(maps:get(semantic_features, R, [])),
      semantic_retained => length([ok || #{metadata := Meta} <- Corpus,
          maps:get(retention_reason, Meta, undefined) =:= new_semantic]),
      coverage_diagnostics => maps:get(coverage_diagnostics, R),
      findings_note => <<"Exceptions and timeouts are untriaged observations, not confirmed defects">>}.

count_outcomes(Decisions) ->
    lists:foldl(fun(D, Acc) ->
        Class = outcome_class(maps:get(outcome, D)),
        Acc#{Class => maps:get(Class, Acc, 0) + 1}
    end, #{}, Decisions).
outcome_class({ok, {accepted, _}}) -> accepted;
outcome_class({ok, {rejected, _}}) -> rejected;
outcome_class({ok, {incomplete, _}}) -> incomplete;
outcome_class({ok, _}) -> returned_other;
outcome_class({crash, _, _, _}) -> exception;
outcome_class({exit, _}) -> exception;
outcome_class({timeout, _}) -> timeout;
outcome_class(_) -> other.

identity(Surface, Profile, Modules, Seeds, CorpusHash, Dependency) ->
    Helpers = [efz_xmlrpc_flow, efz_xmlrpc_suite, efz_xmlrpc_suite:target(Surface)],
    #{schema_version => 1, otp_release => erlang:system_info(otp_release),
      erts_version => erlang:system_info(version), schedulers => erlang:system_info(schedulers),
      profile => Profile, libraries => [app_identity(A) || A <- [xmerl, efz]],
      xmlrpc_dependency => Dependency,
      execution_helpers => [helper_identity(M) || M <- Helpers],
      instrumented_modules => Modules, initial_corpus_sha256 => CorpusHash,
      initial_seed_sha256 => [crypto:hash(sha256, B) || B <- Seeds],
      initial_seed_count => length(Seeds)}.
helper_identity(M) ->
    {ok, I} = efz_replay:harness_identity(M),
    {M, Beam, _} = code:get_object_code(M),
    I#{beam_sha256 => crypto:hash(sha256, Beam)}.
app_identity(App) ->
    case application:load(App) of ok -> ok; {error, {already_loaded, App}} -> ok end,
    {ok, Version} = application:get_key(App, vsn),
    #{application => App, version => Version}.

save_seeds(Dir, Seeds) ->
    new_dir(Dir),
    lists:foreach(fun({I, B}) ->
        Name = lists:flatten(io_lib:format("~4..0B-~s.bin", [I, binary:encode_hex(crypto:hash(sha256, B), lowercase)])),
        ok = file:write_file(filename:join(Dir, Name), B, [exclusive])
    end, lists:zip(lists:seq(1, length(Seeds)), Seeds)).

comparisons(Summaries) ->
    [begin
        Baseline = hd([B || B <- Summaries, maps:get(surface, B) =:= maps:get(surface, R),
                           maps:get(mode, B) =:= off]),
        true = maps:get(initial_corpus_sha256, Baseline) =:= maps:get(initial_corpus_sha256, R),
        true = maps:get(seed, Baseline) =:= maps:get(seed, R),
        true = maps:get(requested_iterations, Baseline) =:= maps:get(requested_iterations, R),
        BaseUs = maps:get(mutation_us, Baseline) / max(1, maps:get(executions, Baseline)),
        RunUs = maps:get(mutation_us, R) / max(1, maps:get(executions, R)),
        #{surface => maps:get(surface, R), mode => maps:get(mode, R),
          mutation_us_per_execution => RunUs,
          mutation_overhead_percent_vs_off => (RunUs / max(0.000001, BaseUs) - 1) * 100,
          coverage_lines_delta_vs_off => maps:get(coverage_lines, R) - maps:get(coverage_lines, Baseline),
          corpus_size_delta_vs_off => maps:get(corpus_size, R) - maps:get(corpus_size, Baseline),
          note => <<"Single paired campaign; guided inputs diverge, not an isolated observer cost benchmark">>}
    end || R <- Summaries, maps:get(mode, R) =/= off,
        lists:any(fun(B) -> maps:get(surface, B) =:= maps:get(surface, R) andalso
                           maps:get(mode, B) =:= off end, Summaries)].

write_summary_csv(Path, Rows) ->
    Keys = [surface, mode, status, executions, calibrations, preparation_us, campaign_wall_us,
        calibration_us, mutation_us, mutation_exec_per_sec, coverage_lines, coverage_total_lines,
        calibration_coverage_lines, mutation_new_coverage_lines,
        corpus_size, discoveries, corpus_equivalent_rejections, crash_occurrences,
        unique_crashes, timeouts, infrastructure_failures, target_invocations,
        target_accepted, target_rejected, target_incomplete, semantic_feature_count, semantic_retained],
    write_csv(Path, Keys, Rows).
write_comparison_csv(Path, Rows) ->
    write_csv(Path, [surface, mode, mutation_us_per_execution, mutation_overhead_percent_vs_off,
        coverage_lines_delta_vs_off, corpus_size_delta_vs_off], Rows).
write_csv(Path, Keys, Rows) ->
    Header = lists:join($,, [atom_to_list(K) || K <- Keys]),
    Body = [[lists:join($,, [csv_cell(maps:get(K, R)) || K <- Keys]), $\n] || R <- Rows],
    file:write_file(Path, [Header, $\n, Body], [exclusive]).
csv_cell(Value) ->
    Text = iolist_to_binary(io_lib:format("~p", [Value])),
    case binary:match(Text, [<<",">>, <<"\"">>, <<"\n">>, <<"\r">>]) of
        nomatch -> Text;
        _ -> [<<"\"">>, binary:replace(Text, <<"\"">>, <<"\"\"">>, [global]), <<"\"">>]
    end.
new_dir(Dir) ->
    ok = filelib:ensure_dir(filename:join(filename:dirname(Dir), "placeholder")),
    case file:make_dir(Dir) of
        ok -> ok;
        {error, eexist} -> error({output_already_exists, Dir});
        {error, Why} -> error({cannot_create_output, Dir, Why})
    end.
write_term(Path, Term) ->
    %% ~tp returns Unicode character data. Writing that list directly treats
    %% codepoints below 256 as Latin-1 bytes, which file:consult/1 cannot read.
    Text = unicode:characters_to_binary(io_lib:format("~tp.~n", [consultable(Term)])),
    file:write_file(Path, Text, [exclusive]).

consultable(Term) when is_reference(Term) -> runtime_identity(reference, Term);
consultable(Term) when is_pid(Term) -> runtime_identity(pid, Term);
consultable(Term) when is_port(Term) -> runtime_identity(port, Term);
consultable(Term) when is_function(Term) -> runtime_identity(function, Term);
consultable(Term) when is_map(Term) ->
    maps:from_list([{consultable(K), consultable(V)} || {K, V} <- maps:to_list(Term)]);
consultable(Term) when is_tuple(Term) -> list_to_tuple([consultable(X) || X <- tuple_to_list(Term)]);
consultable([H | T]) -> [consultable(H) | consultable(T)];
consultable(Term) -> Term.
runtime_identity(Kind, Term) ->
    {efz_runtime_identity, Kind, unicode:characters_to_binary(io_lib:format("~tp", [Term]))}.
