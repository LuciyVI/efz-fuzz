-module(efz_phase2_tests).
-include_lib("eunit/include/eunit.hrl").
-export([run/1]).

phase2_test_() ->
    {setup, fun setup/0, fun cleanup/1, fun(S) ->
        [{"plain and instrumented semantics", fun() -> semantics(S) end},
         {"all required probe kinds and same-line clauses", fun() -> manifest(S) end},
         {"repeatability, empty contexts, inactive runtime", fun() -> repeatability(S) end},
         {"separate processes and contexts", fun() -> separate_contexts(S) end},
         {"exceptions retain coverage", fun() -> exceptions(S) end},
         {"external kill retains coverage", fun() -> external_kill(S) end},
         {"timeout retains coverage", {timeout, 10, fun() -> timeout(S) end}},
         {"completion deadline boundary and resource lifetime", fun() -> boundary(S) end},
         {"owner death cleans target and table", fun() -> owner_death(S) end},
         {"caught backend failure is infrastructure failure", fun() -> broken_backend(S) end},
         {"build reproducibility and changed code", fun() -> determinism(S) end},
         {"build mismatch and uninstrumented preflight", fun() -> mismatch(S) end},
         {"sidecar map ordering and preflight in a fresh VM", fun sidecar_encoding/0},
         {"tail position preserved", fun() -> tail(S) end},
         {"skipped syntax, strict mode, unknown AST, double transform", fun skipped/0},
         { "build facade safety and option handling", fun build_options/0},
         {"automatic campaign decisions and crash continuation", fun campaign/0},
         {"cancellation and restart", fun() -> cancel(S) end}]
    end}.

opts() -> [debug_info, warnings_as_errors, {i, "fixtures/include"}, {d, 'MAGIC', 42}].
config(M, Dir) -> #{modules => [M], outdir => Dir, source_root => ".", erl_opts => opts()}.
compile_fixture(M, Dir) ->
    {ok, A} = efz_instrument:compile("fixtures/" ++ atom_to_list(M) ++ ".erl", config(M, Dir)), A.
unload(M) -> _ = code:purge(M), _ = code:delete(M), _ = code:purge(M), ok.
plain_load(M) ->
    unload(M),
    {ok, M, Beam} = compile:noenv_file("fixtures/" ++ atom_to_list(M) ++ ".erl", [binary | opts()]),
    {module, M} = code:load_binary(M, "ordinary-fixture", Beam).
inputs() ->
    [{clauses, 0}, {clauses, 2}, {clauses, -1}, {clauses, atom},
     {nested, 0}, {nested, 1}, {nested, 2}, {binary, <<0, 5>>}, {binary, <<9>>},
     {funs, 0}, {funs, 3}, {funs, -2}, {try_it, ok}, {try_it, 17},
     {try_it, error}, {try_it, throw}, {try_it, exit},
     {exception, error}, {exception, throw}, {exception, exit},
     {receive_it, [{keep, 1}, {take, 7}]}, {receive_it, []}, receive_timeout,
     {short, true}, {short, false}, {included, 42}, {included, 5},
     {record_it, 0}, {record_it, 7}, {cross, 0}, {cross, 1}, {legacy_catch, throw}].
setup() ->
    plain_load(efz_fixture_helper), plain_load(efz_fixture),
    Plain = [{I, normalize(efz_executor:run(efz_fixture, I, 1000))} || I <- inputs()],
    unload(efz_fixture), unload(efz_fixture_helper),
    A1 = compile_fixture(efz_fixture_helper, "_build/phase2-targets"),
    A2 = compile_fixture(efz_fixture, "_build/phase2-targets"),
    {ok, Ms} = efz_instrument:preflight([A1, A2]),
    #{plain => Plain, artifacts => [A1, A2], manifests => Ms, coverage => automatic}.
cleanup(_) ->
    case whereis(efz_fuzzer) of undefined -> ok; _ -> efz:stop() end,
    lists:foreach(fun unload/1, [efz_fixture, efz_fixture_helper, efz_skipped, efz_example_parser]).
normalize({crash, C, R, St}) ->
    {crash, C, R, [{M, F, case A of Args when is_list(Args) -> length(Args); _ -> A end} ||
                     {M, F, A, _} <- St, M =:= efz_fixture]};
normalize(X) -> X.
execute(I, S) -> efz_executor:run(efz_fixture, I, 1000, S).
hits(I, S) -> maps:get(coverage, execute(I, S)).
fixture_manifest(S) -> hd([M || #{module := efz_fixture} = M <- maps:get(manifests, S)]).

semantics(S) ->
    lists:foreach(fun({Input, Expected}) ->
        R = execute(Input, S),
        ?assertEqual(ok, maps:get(coverage_status, R)),
        ?assertEqual(Expected, normalize(maps:get(outcome, R)))
    end, maps:get(plain, S)).
manifest(S) ->
    M = fixture_manifest(S), Ps = maps:get(probes, M),
    ?assertEqual(ok, efz_cov_manifest:validate(M)),
    Kinds = lists:usort([maps:get(kind, P) || P <- Ps]),
    lists:foreach(fun(K) -> ?assert(lists:member(K, Kinds)) end,
       [function_clause, case_clause, if_clause, receive_clause, receive_after,
        try_body, try_of_clause, catch_clause, try_after, fun_clause, named_fun_clause]),
    SameLine = [{maps:get(line, P), maps:get(probe_id, P)} || P <- Ps,
                 maps:get(kind, P) =:= case_clause],
    ?assert(length(lists:usort([L || {L, _} <- SameLine])) < length(SameLine)),
    ?assert(lists:all(fun(P) -> is_integer(maps:get(column, P)) end, Ps)),
    ?assertEqual({error, invalid_or_duplicate_probe}, efz_cov_manifest:validate(M#{probes => Ps ++ [hd(Ps)]})),
    %% Runtime observations are actual manifest identities, including cross-module calls.
    Cross = hits({cross, 0}, S),
    ?assert(lists:any(fun({Mod, _, _}) -> Mod =:= efz_fixture_helper end, Cross)),
    ?assert(lists:any(fun({Mod, _, _}) -> Mod =:= efz_fixture end, Cross)),
    ObservedKinds = fun(Input) ->
        Hs = hits(Input, S),
        [maps:get(kind, P) || P <- Ps,
          lists:member({efz_fixture, maps:get(build_id, M), maps:get(probe_id, P)}, Hs)]
    end,
    ErrorKinds = ObservedKinds({try_it, error}),
    ?assert(lists:member(try_body, ErrorKinds)),
    ?assert(lists:member(catch_clause, ErrorKinds)),
    ?assert(lists:member(try_after, ErrorKinds)),
    ?assertNot(lists:member(try_of_clause, ErrorKinds)),
    TimeoutKinds = ObservedKinds(receive_timeout),
    ?assert(lists:member(receive_after, TimeoutKinds)),
    ?assertNot(lists:member(receive_clause, TimeoutKinds)),
    ?assertEqual(2, length([K || K <- ObservedKinds({nested, 0}), K =:= case_clause])).
repeatability(S) ->
    A = execute({clauses, 0}, S), B = execute({clauses, 0}, S), C = execute({clauses, 2}, S),
    ?assertEqual(maps:get(coverage, A), maps:get(coverage, B)),
    ?assertNotEqual(maps:get(execution_ref, A), maps:get(execution_ref, B)),
    ?assertNotEqual(maps:get(coverage, A), maps:get(coverage, C)),
    ?assertEqual([], ordsets:intersection(maps:get(coverage, A), maps:get(coverage, C))),
    Context = efz_cov:open(),
    ?assertEqual({ok, []}, efz_cov:snapshot(Context)), efz_cov:close(Context),
    ?assertEqual(zero, efz_fixture:run({clauses, 0})),
    #{coverage := [{manual, example}], coverage_status := ok} =
        efz_executor:run(?MODULE, manual_probe, 1000, #{coverage => manual}),
    #{outcome := {infrastructure, _}} = efz_executor:run(?MODULE, manual_probe, 1000, S).
separate_contexts(S) ->
    A = efz_cov:open(), B = efz_cov:open(), Parent = self(),
    Spawn = fun(C, I) -> spawn_monitor(fun() ->
        efz_cov:attach(C), efz_fixture:run(I), Parent ! {recorded, self()},
        receive finish -> ok end
    end) end,
    {P1, R1} = Spawn(A, {clauses, 0}), {P2, R2} = Spawn(B, {clauses, 2}),
    receive {recorded, P1} -> ok end, receive {recorded, P2} -> ok end,
    {ok, H1} = efz_cov:snapshot(A), {ok, H2} = efz_cov:snapshot(B),
    ?assertEqual(hits({clauses, 0}, S), H1), ?assertEqual(hits({clauses, 2}, S), H2),
    P1 ! finish, P2 ! finish,
    receive {'DOWN', R1, process, P1, normal} -> ok end,
    receive {'DOWN', R2, process, P2, normal} -> ok end,
    efz_cov:close(A), efz_cov:close(B).
exceptions(S) ->
    lists:foreach(fun(C) ->
        R = execute({exception, C}, S),
        ?assert(maps:get(coverage, R) =/= []),
        ?assertEqual(ok, maps:get(coverage_status, R)),
        ?assert(maps:get(outcome, R) =/= {ok, ok}),
        ok = file:write_file("_build/phase2-" ++ atom_to_list(C) ++ ".term", term_to_binary(R))
    end, [error, throw, exit]).
async(Input, T, S) ->
    Parent = self(),
    spawn_monitor(fun() -> Parent ! {execution_finished, self(), efz_executor:run(efz_fixture, Input, T, S)} end).
ready() -> receive {probe_recorded, Pid} -> Pid after 3000 -> error(target_never_recorded_probe) end.
finished(P, Ref) ->
    R = receive {execution_finished, P, Result} -> Result after 4000 -> error(execution_never_finished) end,
    receive {'DOWN', Ref, process, P, normal} -> ok end, R.
assert_sync_hit(R, S) ->
    M = fixture_manifest(S), Ids = maps:get(coverage, R),
    ?assertEqual(ok, maps:get(coverage_status, R)),
    ?assert(lists:any(fun(P) ->
        maps:get(function, P) =:= run andalso maps:get(kind, P) =:= function_clause andalso
        lists:member({efz_fixture, maps:get(build_id, M), maps:get(probe_id, P)}, Ids)
    end, maps:get(probes, M))).
external_kill(S) ->
    {P, Ref} = async({wait, self()}, 3000, S), Target = ready(),
    exit(Target, kill), R = finished(P, Ref),
    ?assertEqual({exit, killed}, maps:get(outcome, R)), assert_sync_hit(R, S),
    ok = file:write_file("_build/phase2-kill.term", term_to_binary(R)).
timeout(S) ->
    {P, Ref} = async({wait, self()}, 1000, S), Target = ready(),
    R = finished(P, Ref),
    ?assertEqual({timeout, 1000}, maps:get(outcome, R)),
    ?assertNot(is_process_alive(Target)), assert_sync_hit(R, S),
    ok = file:write_file("_build/phase2-timeout.term", term_to_binary(R)).
coverage_tables() -> lists:sort([T || T <- ets:all(), ets:info(T, name) =:= efz_execution_coverage]).
boundary(S) ->
    Before = coverage_tables(), Expected = hits({clauses, 0}, S),
    lists:foreach(fun(N) ->
        R = efz_executor:run(efz_fixture, {clauses, 0}, N rem 2, S),
        ?assert(lists:member(maps:get(outcome, R), [{ok, zero}, {timeout, N rem 2}])),
        ?assertEqual(Expected, hits({clauses, 0}, S))
    end, lists:seq(1, 50)),
    ?assertEqual(Before, coverage_tables()),
    receive {target_result, _, _, _} -> error(late_target_result) after 0 -> ok end.
owner_death(S) ->
    Before = coverage_tables(),
    {P, Ref} = async({wait, self()}, 3000, S), Target = ready(),
    [Table] = coverage_tables() -- Before,
    Owner = ets:info(Table, owner), OwnerRef = monitor(process, Owner), TargetRef = monitor(process, Target),
    exit(P, kill),
    receive {'DOWN', Ref, process, P, killed} -> ok end,
    receive {'DOWN', TargetRef, process, Target, killed} -> ok after 3000 -> error(target_leaked) end,
    receive {'DOWN', OwnerRef, process, Owner, normal} -> ok after 3000 -> error(owner_leaked) end,
    ?assertEqual(Before, coverage_tables()).
run(broken) ->
    {efz_context, 1, Ref, _Table, Owner} = get('$efz_execution_context'),
    put('$efz_execution_context', {efz_context, 1, Ref, make_ref(), Owner}),
    %% A target catch must not convert broken instrumentation into success.
    try efz_cov_rt:hit({manual, bogus}) catch error:_ -> caught end;
run(manual_probe) -> efz_cov:hit(example), ok;
run(<<"cancel">>) ->
    {efz_context, 1, _, _, Owner} = get('$efz_execution_context'),
    whereis(efz_phase2_observer) ! {cancel_target, self(), Owner},
    receive never -> ok end;
run(uninstrumented) -> ok.
broken_backend(S) ->
    R = efz_executor:run(?MODULE, broken, 1000, S),
    ?assertMatch({infrastructure, _}, maps:get(outcome, R)),
    ?assertMatch({ok, caught}, maps:get(target_outcome, R)),
    ?assertMatch({error, _}, maps:get(coverage_status, R)).
determinism(S) ->
    A = compile_fixture(efz_fixture, "_build/phase2-repeat"),
    {ok, M} = efz_cov_manifest:from_beam(maps:get(beam, A)),
    ?assertEqual(fixture_manifest(S), M),
    Root = filename:absname("_build/relocated"),
    ok = filelib:ensure_dir(filename:join(Root, "fixtures/include/x")),
    {ok, _} = file:copy("fixtures/efz_fixture.erl", filename:join(Root, "fixtures/efz_fixture.erl")),
    {ok, _} = file:copy("fixtures/include/efz_fixture.hrl", filename:join(Root, "fixtures/include/efz_fixture.hrl")),
    C = (config(efz_fixture, "_build/phase2-relocated"))#{source_root => Root,
        erl_opts => [debug_info, warnings_as_errors, {i, filename:join(Root, "fixtures/include")}, {d, 'MAGIC', 42}]},
    {ok, A2} = efz_instrument:compile(filename:join(Root, "fixtures/efz_fixture.erl"), C),
    ?assertEqual(maps:get(build_id, A), maps:get(build_id, A2)),
    {ok, A3} = efz_instrument:compile("fixtures/efz_fixture.erl", (config(efz_fixture, "_build/phase2-changed"))#{
        erl_opts => [debug_info, warnings_as_errors, {i, "fixtures/include"}, {d, 'MAGIC', 43}]}),
    ?assertNotEqual(maps:get(build_id, A), maps:get(build_id, A3)).
mismatch(S) ->
    R = execute({clauses, 0}, S), F = efz_feedback:new(maps:get(builds, R)),
    ?assertEqual({error, instrumentation_build_mismatch}, efz_feedback:evaluate(F, R#{builds => #{}}, mutation)),
    [M | Rest] = maps:get(manifests, S),
    Bad = S#{manifests => [M#{build_id => <<0:256>>} | Rest]},
    R2 = execute({cross, 0}, Bad),
    ?assertMatch({infrastructure, _}, maps:get(outcome, R2)),
    ?assertEqual({error, automatic_coverage_requires_artifacts}, efz_instrument:preflight([])),
    ?assertEqual({error, missing_instrumentation}, efz_cov_manifest:from_beam(code:which(?MODULE))),
    Sidecar = "_build/phase2-plain-sidecar.efz-manifest",
    ok = file:write_file(Sidecar, term_to_binary(fixture_manifest(S))),
    ?assertMatch({error, {artifact_identity, _, {error, missing_instrumentation}}},
        efz_instrument:preflight([#{module => ?MODULE, beam => code:which(?MODULE), manifest => Sidecar,
                                   build_id => maps:get(build_id, fixture_manifest(S))}])),
    ?assertEqual({error, incompatible_manifest}, efz_cov_manifest:validate((fixture_manifest(S))#{schema_version => 99})),
    ?assertMatch({error, _}, efz:start(#{target => ?MODULE, seeds => [<<>>]})),
    A = compile_fixture(efz_fixture, "_build/phase2-preflight"),
    ?assertMatch({error, _}, efz_instrument:load(A#{build_id => <<0:256>>})),
    ?assertMatch({error, _}, efz:start(#{target => ?MODULE, seeds => [<<>>], workers => 2, coverage => manual})).
sidecar_encoding() ->
    A=compile_fixture(efz_fixture_helper,"_build/phase2-sidecar"),
    {ok,M}=efz_cov_manifest:from_beam(maps:get(beam,A)),
    Path=maps:get(manifest,A),{ok,Original}=file:read_file(Path),
    %% MAP_EXT permits any key order; this must not depend on VM atom order.
    Pairs=lists:reverse(lists:sort(maps:to_list(M))),
    Payload=iolist_to_binary([[etf_part(K),etf_part(V)]||{K,V}<-Pairs]),
    Reordered = <<131,116,(map_size(M)):32,Payload/binary>>,
    ?assertEqual(M,binary_to_term(Reordered)),?assertNotEqual(Original,Reordered),
    try
        ok=file:write_file(Path,Reordered),
        ?assertEqual({ok,M},efz_instrument:load(A)),
        Descriptor="_build/phase2-sidecar/artifact.term",
        ok=file:write_file(Descriptor,term_to_binary(A)),
        Eval=lists:flatten(io_lib:format(
            "{ok,B}=file:read_file(~tp),{ok,[_]}=efz_instrument:preflight([binary_to_term(B)]),halt(0).",
            [filename:absname(Descriptor)])),
        Port=open_port({spawn_executable,os:find_executable("erl")},[binary,exit_status,stderr_to_stdout,
            {args,["+S","2:2","-noshell","-pa",filename:dirname(code:which(efz_instrument)),"-eval",Eval]}]),
        ?assertEqual({0,<<>>},port_result(Port,<<>>)),
        lists:foreach(fun(Bytes)->
            ok=file:write_file(Path,Bytes),
            ?assertMatch({error,{manifest_artifact_mismatch,efz_fixture_helper}},efz_instrument:load(A))
        end,[<<"invalid ETF">>,term_to_binary(M#{build_id=><<0:256>>})])
    after ok=file:write_file(Path,Original) end.
etf_part(T)-><<131,Rest/binary>>=term_to_binary(T),Rest.
port_result(Port,Output)->
    receive
        {Port,{data,B}}->port_result(Port,<<Output/binary,B/binary>>);
        {Port,{exit_status,Status}}->{Status,Output}
    after 3000->port_close(Port),error(preflight_vm_timeout)
    end.
tail(S) ->
    [A] = [X || #{module := efz_fixture} = X <- maps:get(artifacts, S)],
    {ok, {efz_fixture, [{abstract_code, {raw_abstract_v1, Forms}}]}} = beam_lib:chunks(maps:get(beam, A), [abstract_code]),
    [{function, _, tail, 2, [_, {clause, _, _, _, Body}]}] = [F || {function, _, tail, 2, _} = F <- Forms],
    ?assertMatch({call, _, {atom, _, tail}, _}, lists:last(Body)),
    R = execute({tail, 20000}, S),
    ?assertMatch({ok, {20000, _}}, maps:get(outcome, R)).
skipped() ->
    C = #{modules => [efz_skipped], outdir => "_build/phase2-skipped", source_root => "."},
    ?assertMatch({error, {compilation, _, _}}, efz_instrument:compile("fixtures/efz_skipped.erl", C)),
    {ok, A} = efz_instrument:compile("fixtures/efz_skipped.erl", C#{strict => false}),
    unload(efz_skipped), {ok, M} = efz_instrument:load(A),
    ?assertEqual([bc, lc, 'maybe', mc], lists:sort([maps:get(construct, D) || D <- maps:get(limitations, M)])),
    Cases = [{list, [0, 1]}, {binary, [0, 1]}, {map, [1, 2]}, {maybe_it, {ok, 5}}, {maybe_it, error}],
    Instrumented = [efz_skipped:run(I) || I <- Cases],
    unload(efz_skipped), plain_load(efz_skipped),
    ?assertEqual(Instrumented, [efz_skipped:run(I) || I <- Cases]), unload(efz_skipped),
    {ok, Forms} = epp:parse_file("fixtures/efz_fixture_helper.erl", [], []),
    Opts = [{efz_modules, [efz_fixture_helper]}, {efz_source_root, "."}],
    New = efz_instrument_pt:parse_transform(Forms, Opts),
    ?assertError(efz_already_instrumented, efz_instrument_pt:parse_transform(New, Opts)),
    Unknown = [{attribute, 1, module, efz_fixture_helper},
               {function, 2, run, 0, [{clause, 2, [], [], [{future_syntax, 2, foo}]}]}],
    ?assertException(error, {efz_incomplete_instrumentation, _}, efz_instrument_pt:parse_transform(Unknown, Opts)),
    %% Nonliteral record defaults execute at record construction, not definition.
    RC = #{modules => [efz_record_default], outdir => "_build/phase2-record-default", source_root => "."},
    ?assertMatch({error, _}, efz_instrument:compile("fixtures/efz_record_default.erl", RC)),
    {ok, RA} = efz_instrument:compile("fixtures/efz_record_default.erl", RC#{strict => false}),
    {ok, RM} = efz_instrument:load(RA),
    [#{construct := record_default}] = maps:get(limitations, RM),
    RV = efz_record_default:run(7), unload(efz_record_default), plain_load(efz_record_default),
    ?assertEqual(RV, efz_record_default:run(7)), unload(efz_record_default), erase(value).

build_options() ->
    OldPath = code:get_path(),
    C = (config(efz_fixture_helper, "_build/phase2-options"))#{code_paths => ["_build/phase2-targets"]},
    {ok, _} = efz_instrument:compile("fixtures/efz_fixture_helper.erl", C),
    ?assertEqual(OldPath, code:get_path()),
    ?assertMatch({error, _}, efz_instrument:compile("fixtures/efz_fixture_helper.erl", C#{modules => [not_selected]})),
    ?assertMatch({error, _}, efz_instrument:compile("fixtures/efz_fixture_helper.erl", C#{erl_opts => [{parse_transform, fake}]})),
    File = "_build/phase2-options/efz_source_transform.erl",
    ok = file:write_file(File, "-module(efz_source_transform).\n-compile({parse_transform, fake}).\n-export([run/0]).\nrun()->ok.\n"),
    ?assertMatch({error, {unsupported_source_compiler_options, _}}, efz_instrument:compile(File,
        #{modules => [efz_source_transform], outdir => "_build/phase2-other"})),
    ?assertMatch({error, _}, efz_instrument:compile("fixtures/efz_fixture_helper.erl",
        C#{outdir => filename:dirname(code:which(efz))})).
campaign() ->
    unload(efz_example_parser),
    {ok, ParserSource} = file:read_file("examples/simple_parser/efz_example_parser.erl"),
    ?assertEqual(nomatch, binary:match(ParserSource, <<"efz_cov">>)),
    {ok, A} = efz_instrument:compile("examples/simple_parser/efz_example_parser.erl",
        #{modules => [efz_example_parser], source_root => ".", outdir => "_build/phase2-example"}),
    {ok, _} = efz:start(#{target => efz_example_target, artifacts => [A], seeds => [<<0>>],
        mutator => efz_scripted_mutator, max_iterations => 5,
        crash_dir => "_build/phase2-crashes-"++binary_to_list(binary:encode_hex(crypto:strong_rand_bytes(6),lowercase))}),
    try
        R = efz:await(5000), Stats = maps:get(stats, R),
        ?assertEqual(completed, maps:get(status, R)),
        ?assertEqual(1, maps:get(calibrations, Stats)),
        ?assertEqual(5, maps:get(executions, Stats)),
        ?assertEqual(2, maps:get(discoveries, Stats)),
        ?assertEqual(2, maps:get(rejections, Stats)),
        ?assertEqual(1, maps:get(crashes, Stats)),
        ?assertEqual(3, length(maps:get(corpus, R))),
        [Crash] = maps:get(crashes, R),
        ?assertEqual(<<255>>, maps:get(input, Crash)),
        ?assert(filelib:is_regular(maps:get(path, Crash) ++ ".input")),
        ?assert(maps:get(coverage, maps:get(result, Crash)) =/= []),
        [Empty] = [E || #{input := <<>>} = E <- maps:get(corpus, R)],
        Meta = maps:get(metadata, Empty),
        ?assertEqual(new_coverage, maps:get(retention_reason, Meta)),
        ?assert(maps:get(new_probes, Meta) =/= []),
        %% Crash-only coverage must not suppress future successful novelty.
        CrashR = maps:get(result, Crash), Builds = maps:get(builds, CrashR),
        F = efz_feedback:new(Builds),
        {ok, F, _} = efz_feedback:evaluate(F, CrashR, mutation),
        {ok, _, #{retention_reason := new_coverage}} = efz_feedback:evaluate(F, CrashR#{outcome => {ok, fine}}, mutation),
        ok = file:write_file("_build/phase2-acceptance.term", term_to_binary(R))
    after efz:stop(), unload(efz_example_parser) end.
cancel(S) ->
    Before = coverage_tables(),
    %% Start/stop repeatedly without sleep or a scheduling assumption.
    lists:foreach(fun(_) ->
        {ok, _} = efz:start(#{target => efz_example_target, coverage => manual, seeds => [<<0>>], max_iterations => 0}),
        #{status := completed} = efz:await(5000), ok = efz:stop(),
        ?assertEqual(undefined, whereis(efz_corpus)),
        ?assertEqual(undefined, whereis(efz_stats)),
        ?assertEqual(undefined, whereis(efz_worker_sup))
    end, lists:seq(1, 3)),
    true = register(efz_phase2_observer, self()),
    try
        lists:foreach(fun(Stop) ->
            {ok, _} = efz:start(#{target => ?MODULE, coverage => manual,
                                 seeds => [<<"cancel">>], timeout => 10000}),
            {Target, Owner} = receive {cancel_target, T, O} -> {T, O} after 3000 -> error(no_active_execution) end,
            TR = monitor(process, Target), OR = monitor(process, Owner),
            ok = Stop(),
            receive {'DOWN', TR, process, Target, killed} -> ok after 3000 -> error(cancel_target_leaked) end,
            receive {'DOWN', OR, process, Owner, normal} -> ok after 3000 -> error(cancel_owner_leaked) end,
            ?assertEqual(undefined, whereis(efz_fuzzer))
        end, [fun efz:stop/0, fun() -> application:stop(efz) end])
    after unregister(efz_phase2_observer) end,
    ?assertEqual(Before, coverage_tables()),
    ?assert(hits({clauses, 0}, S) =/= []).
