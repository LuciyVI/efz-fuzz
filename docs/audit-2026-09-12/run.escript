#!/usr/bin/env escript
-mode(compile).
main([Dir]) ->
    true = code:add_patha("_build/default/lib/efz/ebin"),
    true = register(audit_observer, self()),
    lists:foreach(fun(M) ->
        F = filename:join(Dir, atom_to_list(M) ++ ".erl"),
        {ok, M, Beam} = compile:noenv_file(F, [binary, debug_info, warnings_as_errors]),
        {module, M} = code:load_binary(M, F, Beam)
    end, [audit_harness, audit_faults]),
    {ok, A} = efz_instrument:compile(filename:join(Dir, "audit_target.erl"),
        #{modules => [audit_target], source_root => Dir, outdir => filename:join(Dir, "instrumented")}),
    ok = file:write_file(filename:join(Dir, "artifact.term"), term_to_binary(A)),
    e2e(Dir, A),
    faults(Dir, A),
    io:format("AUDIT_DIAGNOSTICS_COMPLETED~n").
campaign(C) ->
    {ok, _} = efz:start(C),
    try efz:await(10000) after efz:stop() end.
e2e(Dir, A) ->
    SeedFile = filename:join(Dir, "seed.input"),
    ok = file:write_file(SeedFile, <<>>), {ok, Seed} = file:read_file(SeedFile),
    C = #{target => audit_harness, artifacts => [A], seeds => [Seed],
        mutation_mode => staged, max_iterations => 200, timeout => 1000,
        crash_dir => filename:join(Dir, "crashes"),
        mutation => #{seed => {17,23,41}, stages => [dictionary_insert],
            dictionary => [<<"A">>, <<"B">>, <<"C">>, <<"CRASH">>],
            max_input_bytes => 32, trace_limit => 200}},
    R = campaign(C),
    Es = maps:get(corpus, R), Tr = maps:get(mutation_trace, R),
    Delivered = deliveries([]),
    Generated = [begin {ok, B} = efz_recipe:regenerate(P), B end || P <- Tr],
    [Seed | Generated] = Delivered,
    [EA] = [E || #{input := <<"A">>} = E <- Es],
    [EAB] = [E || #{input := <<"AB">>} = E <- Es],
    [EABC] = [E || #{input := <<"ABC">>} = E <- Es],
    AId = maps:get(id, EA), ABId = maps:get(id, EAB),
    #{parent := AId, retention_reason := new_coverage} = maps:get(metadata, EAB),
    #{parent := ABId, retention_reason := new_coverage} = maps:get(metadata, EABC),
    true = lists:any(fun(P) -> maps:get(parent, P) =:= AId andalso
        maps:get(output_hash, P) =:= efz_mutation:hash(<<"AB">>) end, Tr),
    [Crash | _] = maps:get(crashes, R), Base = maps:get(path, Crash),
    {ok, <<"CRASH">>} = file:read_file(Base ++ ".input"),
    {ok, Recipe} = efz_recipe:load(Base ++ ".recipe"),
    {ok, <<"CRASH">>} = efz_recipe:regenerate(Recipe),
    {ok, Replay} = efz_recipe:execute_file(Base ++ ".input", audit_harness, [A],
        maps:get(target_builds, Recipe), #{timeout => 1000}),
    {crash, error, test_crash, _} = maps:get(outcome, Replay),
    _ = deliveries([]),
    R2 = campaign(C#{max_iterations => 0}),
    1 = length(maps:get(corpus, R2)), _ = deliveries([]),
    emit(Dir, e2e, #{status => maps:get(status, R), stats => maps:get(stats, R),
        corpus => [maps:with([id,input], E) || E <- Es],
        ancestry => [{<<"AB">>, AId}, {<<"ABC">>, ABId}],
        exact_deliveries => length(Delivered), recipes_regenerated => length(Generated),
        restart_corpus_size => length(maps:get(corpus, R2)),
        crash_base => Base, replay => maps:get(outcome, Replay)}),
    ok = file:write_file(filename:join(Dir, "e2e-report.term"), term_to_binary(R)).
deliveries(Acc) -> receive {delivered, _, B} -> deliveries([B | Acc]) after 0 -> lists:reverse(Acc) end.
faults(Dir, A) ->
    {ok, Ms} = efz_instrument:preflight([A]),
    {ok, P} = efz_cov_manifest:prepare(automatic, Ms),
    O = #{coverage => automatic, coverage_plan => P},
    Run = fun(I) -> efz_executor:run(audit_faults, I, 1000, O) end,
    Before = Run(<<"state">>), _ = Run(<<"dirty">>), After = Run(<<"state">>),
    true = maps:get(coverage, Before) =/= maps:get(coverage, After),
    persistent_term:erase({audit_faults, dirty}),
    emit(Dir, cross_case_state, #{before_result => Before, after_result => After}),
    lists:foreach(fun(I) ->
        R = efz_executor:run(audit_faults, I, 100, O),
        {Root, Child, undefined, path_abc} = receive {child, R0, C0, Ctx, V} -> {R0, C0, Ctx, V} end,
        false = is_process_alive(Root), true = is_process_alive(Child),
        [] = maps:get(coverage, R),
        emit(Dir, binary_to_atom(I), #{result => R, root_dead => true, child_alive => true,
            child_has_context => false, child_reached => path_abc}),
        kill(Child)
    end, [<<"child">>, <<"linked_child">>, <<"child_timeout">>]),
    Parent = self(),
    {Caller, Mon} = spawn_monitor(fun() -> Parent ! {owner_result, Run(<<"hold">>)} end),
    {Target, Owner} = receive {holding, T, W} -> {T,W} end,
    kill(Owner),
    OwnerResult = receive {owner_result, X} -> X end,
    receive {'DOWN', Mon, process, Caller, normal} -> ok end,
    true = is_process_alive(Target), kill(Target),
    emit(Dir, coordinator_kill, #{result => OwnerResult, target_alive_after_return => true}),
    Empty = campaign(#{target => audit_faults, artifacts => [A], seeds => [<<"noop">>], max_iterations => 3}),
    [] = maps:get(coverage, Empty), completed = maps:get(status, Empty),
    emit(Dir, disconnected_artifacts, maps:with([status,coverage,stats], Empty)),
    Malformed = Run(<<"malformed">>),
    #{outcome := {ok,caught}, coverage_status := ok, coverage := []} = Malformed,
    emit(Dir, caught_malformed_context, Malformed),
    Classes = [{C, Reason, maps:get(outcome, Run({raise,C,Reason}))} || {C,Reason} <-
        [{error, R} || R <- [function_clause, case_clause, badmatch, badarg, system_limit, badarith, undef]]
        ++ [{throw, thrown}, {exit, normal}, {exit, kill}]],
    emit(Dir, exception_classes, #{classes => Classes, linked_exit => maps:get(outcome,Run(<<"linked_exit">>))}),
    Duplicate = campaign(#{target => audit_faults, coverage => manual,
        seeds => [<<"noop">>,<<"noop">>], max_iterations => 0}),
    2 = length(maps:get(corpus, Duplicate)),
    emit(Dir, duplicate_initial_seeds, maps:with([status,corpus,stats], Duplicate)),
    %% Replace selected code after preflight: a pinned plan does not check loaded code per input.
    F = filename:join(Dir, "audit_target.erl"),
    {ok,audit_target,Beam} = compile:noenv_file(F,[binary,debug_info]),
    {module,audit_target} = code:load_binary(audit_target,F,Beam),
    Hot = Run(<<"state">>), #{outcome := {ok,path_a}, coverage_status := ok, coverage := []} = Hot,
    emit(Dir, hot_reload, Hot),
    efz_cov_manifest:release(P).
kill(P) -> M = monitor(process,P), exit(P,kill), receive {'DOWN',M,process,P,_} -> ok end.
emit(Dir, Name, Value) ->
    Text = io_lib:format("~tp.~n",[Value]),
    ok = file:write_file(filename:join(Dir,atom_to_list(Name)++".txt"),Text),
    io:format("~p: ~tp~n",[Name,Value]).
