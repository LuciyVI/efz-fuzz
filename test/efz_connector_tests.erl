-module(efz_connector_tests).
-include_lib("eunit/include/eunit.hrl").

%% The CLI is tested in a fresh BEAM so metadata extraction, serialization and
%% generated harness compilation are checked together, without loading the API.
connector_test_() -> {timeout, 30, fun integration/0}.
integration() ->
    D = "_build/connector-tests-" ++ integer_to_list(erlang:system_time(microsecond)),
    ok = filelib:ensure_dir(D ++ "/placeholder"),
    {ok, efz_connector_fixture} = compile:file("test/efz_connector_fixture.erl", [debug_info, {outdir, D}]),
    Beam = filename:absname(D ++ "/efz_connector_fixture.beam"),
    {0, _} = scaffold([D ++ "/good", "efz_connector_target", Beam, "combine", "2"]),
    {ok, [C]} = file:consult(D ++ "/good/campaign.term"),
    O = maps:get(adapter_options, maps:get(gleam_layer, C)),
    [Pair, Bytes] = maps:get(arguments, O),
    ?assertMatch(#{kind := tuple, items := [#{kind := tuple,
        items := [#{kind := atom, values := [blue, green, red]}, #{min := 1, max := 9}]},
        #{min := 1, max := 9}]}, Pair),
    ?assertMatch(#{kind := list, item := #{kind := integer, min := 0, max := 255}}, Bytes),
    [Seed] = maps:get(seeds, C),
    ?assertMatch({ok, [{{_, _}, _}, _]}, efz_term_codec:decode(Seed, maps:get(arguments, O), #{})),
    {ok, efz_connector_target} = compile:file(D ++ "/good/efz_connector_target.erl", [warnings_as_errors, {outdir, D}]),
    {module, efz_connector_target} = code:load_abs(filename:absname(D ++ "/efz_connector_target")),
    try generated_campaigns(C)
    after code:purge(efz_connector_target), code:delete(efz_connector_target) end,
    {ok, [Evidence]} = file:consult(D ++ "/good/inference.term"),
    {ok, RawBeam} = file:read_file(Beam),
    ?assertEqual(crypto:hash(sha256, RawBeam), maps:get(beam_sha256, Evidence)),
    {ok, [Options]} = file:consult(D ++ "/good/options.term"),
    {ok, [Report]} = file:consult(D ++ "/good/spec-report.term"),
    ?assertEqual(O, Options),
    ?assertEqual(O, maps:get(options, maps:get(entry, Report))),
    ?assertEqual(maps:get(arguments, O), maps:get(inferred_arguments, Evidence)),
    ?assertEqual(maps:get(beam, Report), maps:get(source, Evidence)),
    %% Both public commands share schemas, seeds and diagnostics. The old
    %% command additionally keeps its inference.term provenance artifact.
    {0, _} = run_scaffold("spec", [D ++ "/canonical", "efz_canonical_target", Beam, "combine", "2"]),
    {ok, [Canonical]} = file:consult(D ++ "/canonical/campaign.term"),
    ?assertEqual(O, maps:get(adapter_options, maps:get(gleam_layer, Canonical))),
    ?assertEqual(maps:get(seeds, C), maps:get(seeds, Canonical)),
    ?assertEqual({ok, [Report]}, file:consult(D ++ "/canonical/spec-report.term")),
    {2, Conflict} = scaffold([D ++ "/conflict", "efz_connector_fixture", Beam, "combine", "2"]),
    ?assert(string:find(Conflict, "harness_module_conflicts_with_entrypoint") =/= nomatch),
    ?assertNot(filelib:is_dir(D ++ "/conflict")),
    {2, Existing} = scaffold([D ++ "/good", "efz_connector_target", Beam, "combine", "2"]),
    ?assert(string:find(Existing, "already_exists") =/= nomatch),
    {0, _} = scaffold([D ++ "/strings", "efz_string_target", Beam, "strings", "2"]),
    {ok, [Strings]} = file:consult(D ++ "/strings/campaign.term"),
    ?assertMatch([#{kind := binary}, #{kind := list, min_length := 1,
        item := #{kind := integer, min := 0, max := 16#10ffff}}],
        maps:get(arguments, maps:get(adapter_options, maps:get(gleam_layer, Strings)))),
    lists:foreach(fun({F, Why}) ->
        Out = D ++ "/reject-" ++ F,
        {2, Error} = scaffold([Out, "efz_rejected_target", Beam, F, "1"]),
        ?assert(string:find(Error, Why) =/= nomatch),
        ?assertNot(filelib:is_dir(Out))
    end, [{"union", "ambiguous_union"}, {"broad", "ambiguous_type"},
        {"recursive", "recursive_type"}, {"overloaded", "overloaded_spec"}]),
    OnLoadSource = D ++ "/efz_connector_onload.erl",
    Marker = filename:absname(D ++ "/onload-executed"),
    ok = file:write_file(OnLoadSource, io_lib:format(
        "-module(efz_connector_onload).\n-export([api/1]).\n-on_load(init/0).\n"
        "init()->file:write_file(~tp,<<\"loaded\">>).\n-spec api(integer())->integer().\napi(X)->X.\n", [Marker])),
    {ok, efz_connector_onload} = compile:file(OnLoadSource, [debug_info, {outdir, D}]),
    {0, _} = scaffold([D ++ "/onload", "efz_onload_target",
        filename:absname(D ++ "/efz_connector_onload.beam"), "api", "1"]),
    ?assertNot(filelib:is_file(Marker)),
    {ok, efz_connector_fixture} = compile:file("test/efz_connector_fixture.erl", [{outdir, D}]),
    {2, NoDebug} = scaffold([D ++ "/no-debug", "efz_rejected_target", Beam, "combine", "2"]),
    ?assert(string:find(NoDebug, "missing_abstract_code") =/= nomatch).

scaffold(Args) -> run_scaffold("from-beam", Args).
run_scaffold(Mode, Args) ->
    Es = os:find_executable("escript"),
    Port = open_port({spawn_executable, Es}, [binary, exit_status, stderr_to_stdout,
        {args, ["scripts/semantic_scaffold.escript", Mode | Args]}]),
    collect(Port, <<>>).
collect(Port, Bytes) ->
    receive
        {Port, {data, B}} -> collect(Port, <<Bytes/binary, B/binary>>);
        {Port, {exit_status, Status}} -> {Status, binary_to_list(Bytes)}
    after 20000 -> port_close(Port), error(scaffold_timeout)
    end.

%% The generated source is exercised unchanged in each available runtime mode.
%% Ordinary builds require no optional model; Gleam builds also verify callbacks.
generated_campaigns(C) ->
    Layer = (maps:get(gleam_layer, C))#{structured_fraction => 100},
    Layers = case code:which(efz_term_model) of
        non_existing -> [false];
        _ -> [false, Layer#{feedback => observation_only}, Layer#{feedback => guided}]
    end,
    lists:foreach(fun(L) ->
        try
            {ok, _} = efz:start(C#{gleam_layer => L, max_iterations => 20}),
            R = efz:await(10000),
            ?assertEqual(completed, maps:get(status, R)),
            ?assertEqual(20, maps:get(executions, maps:get(stats, R))),
            ?assertEqual(1, maps:get(calibrations, maps:get(stats, R))),
            ?assertEqual(0, maps:get(crashes, maps:get(stats, R))),
            ?assertEqual(0, maps:get(infrastructure_failures, maps:get(stats, R))),
            case L of
                false -> ok;
                _ -> ?assert(maps:get(observer_calls, maps:get(gleam_stats, R), 0) > 0),
                    ?assert(maps:get(successes, maps:get(structured_stats, R), 0) > 0)
            end
        after efz:stop() end
    end, Layers).
