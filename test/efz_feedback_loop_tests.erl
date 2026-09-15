-module(efz_feedback_loop_tests).
-behaviour(efz_target).
-include_lib("eunit/include/eunit.hrl").
-export([run/1, replay_files/1]).

-define(OBSERVER, efz_feedback_loop_observer).

feedback_loop_test_() ->
    {"discovered inputs become mutation parents and replay in a fresh VM",
     {timeout, 30, fun feedback_loop/0}}.

%% A real binary harness. Observe delivery without changing the input, coverage,
%% corpus or scheduler. The context ref correlates bytes with retained decisions.
run(Input) when is_binary(Input) ->
    Value = efz_lineage_parser:parse(Input),
    case whereis(?OBSERVER) of
        undefined -> ok;
        Observer ->
            {efz_context, 1, Ref, _, _} = get('$efz_execution_context'),
            Observer ! {lineage_delivery, Ref, Input, Value}
    end,
    Value.

feedback_loop() ->
    Out = filename:absname("_build/feedback-loop-test"),
    unload_parser(),
    true = register(?OBSERVER, self()),
    try
        {ok, Artifact} = efz_instrument:compile("fixtures/efz_lineage_parser.erl",
            #{modules => [efz_lineage_parser], source_root => ".",
              outdir => filename:join(Out, "target")}),
        Config = #{target => ?MODULE, artifacts => [Artifact], seeds => [<<>>],
            coverage => automatic, mutation_mode => staged, timeout => 1000,
            max_iterations => 100, crash_dir => filename:join(Out, "crashes"),
            max_input_bytes => 16, mutation => #{seed => {17, 23, 41}, stages => [dictionary_insert],
                %% No AB/ABC token, havoc or splice can bypass parent reuse.
                dictionary => [<<"A">>, <<"B">>, <<"C">>],
                 trace_limit => 100}},
        {ok, _} = efz:start(Config),
        Report = efz:await(10000),
        ?assertEqual(maps:get(corpus, Report), efz_corpus:all()),
        ok = efz:stop(),
        check_campaign(Report, Artifact, Out)
    after
        efz:stop(),
        unregister(?OBSERVER),
        flush_deliveries(),
        unload_parser()
    end.

check_campaign(Report, Artifact, Out) ->
    #{stats := Stats, corpus := Entries, decisions := Decisions,
      mutation_trace := Trace} = Report,
    ?assertMatch({mutation_exhausted, _}, maps:get(status, Report)),
    ?assertEqual(1, maps:get(calibrations, Stats)),
    ?assertEqual(3, maps:get(discoveries, Stats)),
    lists:foreach(fun(K) -> ?assertEqual(0, maps:get(K, Stats)) end,
                  [crashes, timeouts, infrastructure_failures]),
    ?assertEqual([efz_mutation:hash(<<>>)], maps:get(mutation_initial_corpus, Report)),
    ?assertEqual([<<>>, <<"A">>, <<"AB">>, <<"ABC">>],
                 [maps:get(input, E) || E <- Entries]),
    [Initial, A, AB, ABC] = Entries,
    ?assertEqual(#{}, maps:get(metadata, Initial)),
    [Calibration] = [D || #{phase := calibration} = D <- Decisions],
    ?assertEqual(seed_calibration, maps:get(retention_reason, Calibration)),
    ?assertEqual(maps:get(id, Initial), maps:get(parent, Calibration)),
    ?assertEqual(efz_mutation:hash(<<>>), maps:get(input_id, Calibration)),

    ?assertEqual(maps:get(executions, Stats), length(Trace)),
    ?assertEqual(length(Trace), maps:get(generated_candidates, maps:get(mutation_stats, Report))),
    Deliveries = collect_deliveries(length(Trace) + 1, #{}),
    ?assertEqual({<<>>, unknown}, maps:get(maps:get(execution_ref, Calibration), Deliveries)),
    Generated = [begin {ok, B} = efz_recipe:regenerate(R), B end || R <- Trace],
    %% Different target processes need not deliver messages in the same order.
    %% Keep multiplicities, and additionally correlate each retained input by Ref.
    ?assertEqual(lists:sort([<<>> | Generated]),
                 lists:sort([B || {B, _} <- maps:values(Deliveries)])),
    ?assertEqual([], flush_deliveries()),

    Links = [{Initial, A, <<"A">>, path_a},
             {A, AB, <<"B">>, path_ab},
             {AB, ABC, <<"C">>, path_abc}],
    Recipes = [check_link(P, E, Token, Value, Trace, Deliveries) ||
                  {P, E, Token, Value} <- Links],
    ?assertEqual([maps:get(output_hash, R) || R <- Recipes],
                 [maps:get(input_id, D) || #{retention_reason := new_coverage} = D <- Decisions]),
    Positions = [recipe_position(R, Trace) || R <- Recipes],
    [First, Second, Third] = Positions,
    ?assert(First < Second andalso Second < Third),

    %% Validate that discoveries are distinct automatic parser probes and that
    %% the initial seed plus discovery deltas account for the actual global set.
    Deltas = [maps:get(new_probes, Calibration) |
              [maps:get(new_probes, maps:get(metadata, E)) || E <- [A, AB, ABC]]],
    {ok, Manifest} = efz_cov_manifest:from_beam(maps:get(beam, Artifact)),
    Allowed = efz_cov_manifest:identities(Manifest),
    Probes = lists:append(Deltas),
    ?assert(lists:all(fun(Hits) -> Hits =/= [] end, Deltas)),
    ?assertEqual(length(Probes), length(lists:usort(Probes))),
    ?assert(lists:all(fun(Id) -> lists:member(Id, Allowed) end, Probes)),
    ?assertEqual(lists:sort(Probes), maps:get(coverage, Report)),

    ok = file:write_file(filename:join(Out, "report.term"), term_to_binary(Report)),
    Witnesses = [save_witness(E, R, Out) || {E, R} <- lists:zip([A, AB, ABC], Recipes)],
    ok = file:write_file(filename:join(Out, "replay.term"),
                        term_to_binary(#{artifact => Artifact, witnesses => Witnesses})),
    Provenance = [maps:with([parent, primary, primary_id, operations, output_hash], R) || R <- Recipes],
    ok = file:write_file(filename:join(Out, "lineage.txt"),
        io_lib:format("entries=~tp~nprovenance=~tp~nexecutions=~B deliveries=~B~n",
            [[maps:with([id, input], E) || E <- Entries], Provenance, length(Trace), map_size(Deliveries)])),
    fresh_replay(Out).

check_link(Parent, Entry, Token, Value, Trace, Deliveries) ->
    #{input := Input, metadata := Meta} = Entry,
    ParentId = maps:get(id, Parent),
    Primary = maps:get(input, Parent),
    Recipe = maps:get(mutation, Meta),
    ?assertEqual(mutation, maps:get(phase, Meta)),
    ?assertEqual(new_coverage, maps:get(retention_reason, Meta)),
    ?assert(maps:get(new_probes, Meta) =/= []),
    ?assertEqual({ok, Value}, maps:get(outcome, Meta)),
    ?assertEqual(ParentId, maps:get(parent, Meta)),
    ?assertEqual(efz_mutation:hash(Input), maps:get(input_id, Meta)),
    ?assertEqual({Input, Value}, maps:get(maps:get(execution_ref, Meta), Deliveries)),
    ?assertEqual(ParentId, maps:get(parent, Recipe)),
    ?assertEqual(Primary, maps:get(primary, Recipe)),
    ?assertEqual(efz_mutation:hash(Primary), maps:get(primary_id, Recipe)),
    ?assertEqual(dictionary_insert, maps:get(stage, Recipe)),
    ?assertEqual([{dictionary_insert, byte_size(Primary), Token}], maps:get(operations, Recipe)),
    ?assertEqual(byte_size(Input), maps:get(output_size, Recipe)),
    ?assertEqual(efz_mutation:hash(Input), maps:get(output_hash, Recipe)),
    ?assertEqual({ok, Input}, efz_recipe:regenerate(Recipe)),
    ?assert(lists:member(Recipe, Trace)),
    Recipe.

recipe_position(Recipe, Trace) ->
    [Index] = [I || {R, I} <- lists:zip(Trace, lists:seq(1, length(Trace))), R =:= Recipe],
    Index.

collect_deliveries(0, Acc) -> Acc;
collect_deliveries(N, Acc) ->
    receive
        {lineage_delivery, Ref, Input, Value} ->
            ?assertNot(maps:is_key(Ref, Acc)),
            collect_deliveries(N - 1, Acc#{Ref => {Input, Value}})
    after 2000 -> error({missing_harness_deliveries, N})
    end.

flush_deliveries() ->
    receive {lineage_delivery, _, _, _} = Message -> [Message | flush_deliveries()]
    after 0 -> []
    end.

save_witness(Entry, Recipe, Out) ->
    Path = filename:join(Out, "entry-" ++ integer_to_list(maps:get(id, Entry)) ++ ".recipe"),
    ok = efz_recipe:save(Path, Recipe),
    Meta = maps:get(metadata, Entry),
    {ok,H}=efz_replay:harness_identity(?MODULE),
    #{recipe => Path, input => maps:get(input, Entry), harness=>H,
      outcome => maps:get(outcome, Meta), coverage => maps:get(new_probes, Meta)}.

fresh_replay(Out) ->
    Eval = lists:flatten(io_lib:format("ok = ~p:replay_files(~tp), halt(0).", [?MODULE, Out])),
    Port = open_port({spawn_executable, os:find_executable("erl")},
        [binary, exit_status, stderr_to_stdout,
         {args, ["+S", "2:2", "-noshell", "-pa", filename:dirname(code:which(efz_recipe)),
                 filename:dirname(code:which(?MODULE)), "-eval", Eval]}]),
    try
        {Status, Output} = port_result(Port, <<>>),
        ok = file:write_file(filename:join(Out, "fresh-replay.log"), Output),
        ?assertEqual({0, true}, {Status, binary:match(Output, <<"LINEAGE_REPLAY_OK 3">>) =/= nomatch})
    after
        catch port_close(Port)
    end.

%% Called only in the fresh VM. No campaign, corpus, mutation plan or RNG state
%% is restored: disk recipes must independently reconstruct and execute inputs.
replay_files(Out) ->
    ?assertEqual(undefined, whereis(efz_corpus)),
    ?assertEqual(false, code:is_loaded(efz_lineage_parser)),
    {ok, Bytes} = file:read_file(filename:join(Out, "replay.term")),
    #{artifact := Artifact, witnesses := Witnesses} = binary_to_term(Bytes),
    lists:foreach(fun(#{recipe := Path, input := Input, outcome := Outcome, coverage := Hits, harness:=H}) ->
        {ok, Recipe} = efz_recipe:load(Path),
        ?assertEqual({ok, Input}, efz_recipe:regenerate(Recipe)),
        {ok, Result} = efz_recipe:execute(Input, ?MODULE, [Artifact],
            maps:get(target_builds, Recipe), #{timeout => 1000,expected_harness=>H}),
        ?assertEqual(Outcome, maps:get(outcome, Result)),
        ?assertEqual(ok, maps:get(coverage_status, Result)),
        ?assertEqual(lists:sort(Hits), maps:get(coverage, Result))
    end, Witnesses),
    ?assertEqual(undefined, whereis(efz_corpus)),
    io:format("LINEAGE_REPLAY_OK ~B~n", [length(Witnesses)]),
    ok.

port_result(Port, Acc) ->
    receive
        {Port, {data, Bytes}} -> port_result(Port, <<Acc/binary, Bytes/binary>>);
        {Port, {exit_status, Status}} -> {Status, Acc}
    after 10000 -> error(lineage_replay_vm_timeout)
    end.

unload_parser() ->
    _ = code:purge(efz_lineage_parser),
    _ = code:delete(efz_lineage_parser),
    _ = code:purge(efz_lineage_parser),
    ok.
