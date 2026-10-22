-module(efz_spec_schema_tests).
-include_lib("eunit/include/eunit.hrl").

beam() -> code:which(efz_spec_fixture).
inferred(F, A) ->
    {ok, Entry} = efz_spec_schema:from_beam(beam(), F, A), Entry.
schemas(F) -> maps:get(arguments, maps:get(options, inferred(F, 1))).

aliases_and_real_api_test() ->
    #{options := Options, diagnostics := Notes, source := Source} = inferred(combine, 3),
    [Items, Mode, Values] = maps:get(arguments, Options),
    ?assertMatch(#{kind := list, item := #{kind := tuple, items := [
        #{kind := atom, values := [tag]}, #{kind := integer, min := 0, max := 3}]}}, Items),
    ?assertEqual(#{kind => atom, values => [read, write]}, Mode),
    ?assertMatch(#{kind := map, key := Mode, value := #{kind := binary}}, Values),
    ?assert(lists:any(fun(#{code := Code}) -> Code =:= binary_semantics_unknown end, Notes)),
    ?assertEqual(32, byte_size(maps:get(beam_sha256, Source))),
    ?assertEqual([invariants, expected_exceptions, stateful_lifecycle, oracle], maps:get(manual, Source)),
    Args = [[{tag, 3}], write, #{read => <<"raw">>}],
    {ok, Raw} = efz_term_codec:encode(Args, maps:get(arguments, Options), #{}),
    ?assertEqual(list_to_tuple(Args), efz_term_codec:execute(Raw, Options)),
    %% Generated and mutated inputs use the existing codec/adapter, including
    %% explicit binary bounds; no extra execution or model is introduced.
    Seeds = [Seed || I <- lists:seq(0, 31), {ok, Seed} <- [efz_term_api_adapter:seed(I, Options, #{})]],
    ?assert(Seeds =/= []),
    lists:foreach(fun(Seed) ->
        ?assertMatch({ok, _}, efz_term_codec:decode(Seed, maps:get(arguments, Options), #{}))
    end, Seeds).

variables_and_alias_scopes_test() ->
    ?assertEqual([#{kind => integer, min => 1, max => 4}], schemas(bounded)),
    ?assertMatch([#{kind := tuple, items := [#{values := [tag]}, #{kind := integer}]}], schemas(shadow)),
    ?assertMatch([#{kind := tuple, items := [_, #{kind := tuple, items := [_,
        #{kind := binary}]}]}], schemas(nested)),
    ?assertEqual([#{kind => atom, values => [other, read, write]}], schemas(union_alias)),
    ?assertMatch([#{kind := list, min_length := 1,
        item := #{kind := binary, min_length := 1}}], schemas(qualified)),
    ?assertEqual([#{kind => integer, min => -3, max => 3}], schemas(labeled)).

primitive_domains_and_return_not_an_oracle_test() ->
    [#{items := Items}] = schemas(primitives),
    ?assertMatch([#{kind := integer}, #{kind := float}, #{kind := boolean},
        #{min := 0, max := 255}, #{min := 0, max := 255}, #{min := 0, max := 16#10ffff},
        #{min := 1}, #{max := -1}, #{min := 0}, #{kind := binary, min_length := 1},
        #{kind := list, item := #{max := 16#10ffff}}, #{max_length := 0},
        #{kind := map, max_length := 0}, #{kind := binary, min_length := 2, max_length := 2}], Items),
    ?assertEqual([], maps:get(arguments, maps:get(options, inferred(zero, 0)))).

unsupported_contracts_test_() ->
    [{atom_to_list(F), fun() ->
        {error, #{code := Actual, message := Message, path := Path} = D} =
            efz_spec_schema:from_beam(beam(), F, 1),
        ?assertEqual(Code, Actual), ?assert(byte_size(Message) > 0),
        ?assert(is_list(Path)), ?assert(iolist_size(efz_spec_schema:format_diagnostic(D)) > 0)
    end} || {F, Code} <- [
        {overload, overloaded_spec}, {mixed, ambiguous_union},
        {required, map_constraints}, {fields, map_constraints}, {remote, remote_type},
        {recursive, recursive_type}, {opaque_arg, opaque_type},
        {unconstrained, unbound_variable}, {atom_arg, ambiguous_type},
        {runtime_arg, unsupported_type}, {no_spec, missing_spec},
        {stride, binary_size_constraint}, {wide, integer_range},
        {expression, unsupported_integer_expression}, {too_deep, schema_limit}]].

inspection_is_deterministic_and_lists_rejections_test() ->
    {ok, First} = efz_spec_schema:inspect(beam()),
    ?assertEqual({ok, First}, efz_spec_schema:inspect(beam())),
    Entries = maps:get(entries, First),
    ?assert(lists:any(fun(#{status := Status}) -> Status =:= unsupported end, Entries)),
    ?assertNot(lists:any(fun(#{entrypoint := {_, F, _}}) -> F =:= module_info end, Entries)),
    ?assertMatch({error, #{code := not_exported}}, efz_spec_schema:from_beam(beam(), missing, 7)).

missing_debug_and_no_target_loading_test() ->
    M = efz_spec_cold_fixture,
    Forms = [{attribute, 1, module, M}, {attribute, 2, export, [{call, 0}]},
        {attribute, 3, on_load, {init, 0}},
        {attribute, 4, spec, {{call, 0}, [{type, 4, 'fun',
            [{type, 4, product, []}, {atom, 4, ok}]}]}},
        {function, 5, init, 0, [{clause, 5, [], [], [
            {call, 5, {remote, 5, {atom, 5, erlang}, {atom, 5, register}},
                [{atom, 5, M}, {call, 5, {atom, 5, self}, []}]}, {atom, 5, ok}]}]},
        {function, 6, call, 0, [{clause, 6, [], [], [{atom, 6, ok}]}]}],
    D = directory(), Path = filename:join(D, atom_to_list(M) ++ ".beam"),
    try
        {ok, M, Debug, []} = compile:forms(Forms, [debug_info, return_errors, return_warnings]),
        ok = file:write_file(Path, Debug),
        ?assertMatch({ok, _}, efz_spec_schema:from_beam(Path, call, 0)),
        ?assertEqual(false, code:is_loaded(M)), ?assertEqual(undefined, whereis(M)),
        {ok, M, Stripped, []} = compile:forms(Forms, [no_debug_info, return_errors, return_warnings]),
        ok = file:write_file(Path, Stripped),
        ?assertMatch({error, #{code := missing_abstract_code}}, efz_spec_schema:inspect(Path)),
        ok = file:write_file(Path, <<"not BEAM">>),
        ?assertMatch({error, #{code := invalid_beam}}, efz_spec_schema:inspect(Path))
    after ok = file:del_dir_r(D) end.

scaffold_cli_test_() -> {timeout, 30, fun scaffold_cli/0}.
scaffold_cli() ->
    D = directory(), Out = filename:join(D, "connector"),
    Script = filename:absname("scripts/semantic_scaffold.escript"),
    try
        Args = [Script, "spec", Out, "efz_spec_generated_target", beam(), "combine", "3"],
        {0, _} = escript(Args),
        {ok, [Options]} = file:consult(filename:join(Out, "options.term")),
        {ok, [Report]} = file:consult(filename:join(Out, "spec-report.term")),
        ?assertEqual(Options, maps:get(options, maps:get(entry, Report))),
        {ok, [Campaign]} = file:consult(filename:join(Out, "campaign.term")),
        Layer = maps:get(gleam_layer, Campaign),
        ?assertEqual(Options, maps:get(adapter_options, Layer)),
        ?assertEqual(disabled, maps:get(oracle, Layer)),
        [Seed] = maps:get(seeds, Campaign),
        ?assertEqual({ok, Seed}, file:read_file(filename:join(Out, "seeds/00"))),
        Source = filename:join(Out, "efz_spec_generated_target.erl"),
        {ok, efz_spec_generated_target, Bin, []} = compile:file(Source,
            [binary, return_errors, return_warnings, warnings_as_errors]),
        {module, efz_spec_generated_target} = code:load_binary(efz_spec_generated_target, Source, Bin),
        ?assertEqual(efz_term_codec:execute(Seed, Options), efz_spec_generated_target:run(Seed)),
        ?assertEqual(Options, efz_spec_generated_target:options()),
        %% Refusal leaves prior generated source and seed intact.
        {ok, Before} = file:read_file(Source),
        {2, _} = escript(Args), ?assertEqual({ok, Before}, file:read_file(Source)),
        ?assertEqual({ok, Seed}, file:read_file(filename:join(Out, "seeds/00"))),
        Rejected = filename:join(D, "rejected"),
        {2, ErrorText} = escript([Script, "spec", Rejected, "efz_rejected", beam(), "required", "1"]),
        ?assertNotEqual(nomatch, binary:match(ErrorText, <<"map_constraints">>)),
        ?assertNot(filelib:is_dir(Rejected)),
        {0, Text} = escript([Script, "inspect", beam()]),
        {ok, Tokens, _} = erl_scan:string(binary_to_list(Text)),
        {ok, Inspected} = erl_parse:parse_term(Tokens),
        ?assertEqual(1, maps:get(schema_version, Inspected)),
        %% Existing modes remain usable through the same creation path.
        {0, _} = escript([Script, "generic", filename:join(D, "manual")]),
        {0, _} = escript([Script, "domain", filename:join(D, "domain")])
    after
        _ = code:purge(efz_spec_generated_target), _ = code:delete(efz_spec_generated_target),
        ok = file:del_dir_r(D)
    end.

directory() ->
    D = filename:join("_build/spec-schema-tests", integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(D, "placeholder")), D.

escript(Args) ->
    Ebin = filename:absname(filename:dirname(code:which(efz_spec_schema))),
    Port = open_port({spawn_executable, os:find_executable("escript")},
        [binary, exit_status, stderr_to_stdout, {args, Args},
            {env, [{"ERL_FLAGS", "+S 2:2 -pa " ++ Ebin}]}]),
    port_result(Port, []).
port_result(Port, Acc) ->
    receive
        {Port, {data, Bytes}} -> port_result(Port, [Bytes | Acc]);
        {Port, {exit_status, Code}} -> {Code, iolist_to_binary(lists:reverse(Acc))}
    after 20000 -> port_close(Port), error(scaffold_cli_timeout)
    end.
