#!/usr/bin/env escript
%%! +S 2:2
-mode(compile).

%% Finite integration measurements, separate VMs per invocation, no discovery
%% claims. Compiler/setup and post-run recipe reconstruction are outside timing.
main(["prepare", Out]) -> load_paths(), prepare(filename:absname(Out));
main(["campaign", KindText, ModeText, RepeatText, Out]) ->
    load_paths(),
    Kind = kind(KindText), Mode = mode(ModeText), Repeat = repeat(RepeatText),
    campaign(Kind, Mode, Repeat, 17, 100, filename:absname(Out));
main(["campaign", K, M, R, Seed, Count, Out]) ->
    load_paths(),campaign(kind(K),mode(M),repeat(R),list_to_integer(Seed),list_to_integer(Count),filename:absname(Out));
main(["stateful-counts", Run, _Out]) -> load_paths(),stateful_counts(filename:absname(Run));
main(["callbacks", KindText, Out]) ->
    load_paths(), callbacks(kind(KindText), filename:absname(Out));
main(_) -> io:format(standard_error,
    "Usage: semantic_bench.escript prepare OUT\n"
    "       semantic_bench.escript campaign generic|xmlrpc|stateful off|on REPEAT OUT\n"
    "       semantic_bench.escript callbacks generic|qs|xmlrpc OUT\n", []), halt(2).

root() -> filename:dirname(filename:dirname(filename:absname(escript:script_name()))).
load_paths() ->
    lists:foreach(fun(Path) -> true = code:add_pathz(filename:join(root(), Path)) end,
        ["_build/gleam/lib/efz/ebin", "_build/default/lib/cowlib/ebin",
         "_build/xmlrpc-example/dependency-ebin"]),
    {module, efz_config} = code:ensure_loaded(efz_config), ok.
kind("generic") -> generic;
kind("xmlrpc") -> xmlrpc;
kind("stateful") -> stateful;
kind("qs") -> qs.
mode("off") -> off;
mode("on") -> on.
repeat(Text) -> N = list_to_integer(Text), true = N >= 1 andalso N =< 3, N.

prepare(Out) ->
    Generic = compile_target("examples/term_api/efz_term_tuple_library.erl",
        efz_term_tuple_library, filename:join(Out, "targets/generic"), [], true),
    Stateful = compile_target("examples/stateful/efz_stateful_counter.erl",
        efz_stateful_counter, filename:join(Out, "targets/stateful"), [], true),
    Source = filename:join(root(), "_build/xmlrpc-dependency"),
    {ok, [Identity]} = file:consult(filename:join(root(), "_build/xmlrpc-example/dependency-identity.term")),
    <<"fb46463b2acadf164ec534d9e2033e194341c507">> = maps:get(commit, Identity),
    lists:foreach(fun({M, H}) ->
        File = filename:join([Source, "src", atom_to_list(M) ++ ".erl"]),
        {ok, B} = file:read_file(File), H = crypto:hash(sha256, B)
    end, maps:get(sources, Identity)),
    Xml = [compile_target(filename:join([Source, "src", atom_to_list(M) ++ ".erl"]),
        M, filename:join(Out, "targets/xmlrpc"), [{i, filename:join(Source, "src")}], false)
        || M <- [xmlrpc_decode, xmlrpc_util]],
    write_term(filename:join(Out, "target-artifacts.term"),
        #{generic => [Generic], xmlrpc => Xml, stateful => [Stateful]}),
    write_json(filename:join(Out, "target-preparation.json"),
        #{settings => settings(), xmlrpc_identity => Identity,
          coverage => target_only_ets,
          xmlrpc_limitations => [xmerl_otp_internals_not_instrumented,
              xmerl_hrl_record_defaults_preserved_strict_false],
          stateful_policy => admitted_child_counter_only_ets,
          stateful_limitations => [otp27_proc_lib_metadata_bootstrap,
              gen_server_and_otp_internals_not_instrumented]}),
    io:format("Prepared target-only artifacts in ~ts~n", [Out]).
compile_target(Source0, Module, Out, Extra, Strict) ->
    Source = case filename:pathtype(Source0) of absolute -> Source0;
        _ -> filename:join(root(), Source0) end,
    {ok, A} = efz_instrument:compile(Source,
        #{modules => [Module], source_root => root(), outdir => Out,
          erl_opts => [debug_info, warnings_as_errors | Extra], strict => Strict}), A.

configuration(generic) -> consult_config("tuple_api");
configuration(xmlrpc) -> consult_config("xmlrpc");
configuration(stateful) -> consult_config("stateful");
configuration(qs) -> consult_config("cow_qs").
consult_config(Name) ->
    {ok, [C]} = file:consult(filename:join([root(), "examples", "semantic_configs", Name ++ ".term"])), C.

campaign(Kind, Mode, Repeat, Seed, Count, Out) ->
    true=Count>=1 andalso Count=<1000, true=Seed>=1 andalso Seed=<1000000,
    RNG={Seed,Seed+6,Seed+24},
    false = Kind =:= qs,
    Run = filename:join(Out, atom_to_list(Kind) ++ "-" ++ atom_to_list(Mode) ++ "-" ++ integer_to_list(Repeat) ++ "-s" ++ integer_to_list(Seed)),
    false = filelib:is_dir(Run),
    ok = filelib:ensure_dir(filename:join(Run, "placeholder")),
    {ok, [Artifacts]} = file:consult(filename:join(Out, "target-artifacts.term")),
    C0 = configuration(Kind),
    %% The fixture admits the counter child through efz_target:spawn_link/1;
    %% its ETS probes were verified independently before this series.
    {Backend, Selected, Limitations} = case Kind of
        stateful -> {ets, maps:get(stateful, Artifacts),
            [otp27_proc_lib_metadata_bootstrap, gen_server_and_otp_internals_not_instrumented]};
        _ -> {ets, maps:get(Kind, Artifacts), []}
    end,
    Layer = case Mode of off -> false; on -> maps:get(gleam_layer, C0) end,
    C = C0#{coverage_backend => Backend, artifacts => Selected, gleam_layer => Layer,
        max_iterations => Count, timeout => 1000,
        corpus_dir => filename:join(Run,"durable-corpus"),
        random_seed => RNG, selection_seed => RNG,
        mutation => #{seed => RNG, stages => [havoc], trace_limit => Count},
        crash_dir => filename:join(Run, "target-outcomes")},
    Start = erlang:monotonic_time(microsecond),
    {Result, Wall} = try
        {ok, _} = efz:start(C),
        R = efz:await(30000), {R, erlang:monotonic_time(microsecond) - Start}
    catch Class:Why ->
        Partial = case catch efz:stats() of S when is_map(S) -> S; _ -> #{} end,
        {#{status => {benchmark_failed, Class, bounded(Why)}, stats => Partial,
            corpus => [], coverage => [], mutation_trace => []},
         erlang:monotonic_time(microsecond) - Start}
    after efz:stop() end,
    Stats = maps:get(stats, Result), Mutations = maps:get(executions, Stats, 0),
    Calibrations = maps:get(calibrations, Stats, 0), Primary = Mutations + Calibrations,
    Extra = maps:get(verification_executions, Stats, 0) + maps:get(oracle_extra_executions, Result, 0),
    Counts = maps:get(structured_stats, Result, #{}), Callback = maps:get(gleam_stats, Result, #{}),
    Corpus = maps:get(corpus, Result),
    Summary0 = #{kind => Kind, mode => Mode, repeat => Repeat, settings => settings(),
        rng_seed => RNG, requested_mutation_executions => Count, target_timeout_ms => 1000,
        campaign_deadline_ms => 30000, wall_us => Wall,
        completed => maps:get(status, Result) =:= completed andalso Mutations =:= Count,
        status => maps:get(status, Result), primary_executions => Primary,
        mutation_executions => Mutations, calibration_executions => Calibrations,
        total_target_executions => Primary + Extra, extra_target_executions => Extra,
        primary_executions_per_second => Primary * 1000000 / max(1, Wall),
        timing => maps:get(timing, Result, #{}), stats => Stats,
        coverage_backend => Backend, coverage_count => length(maps:get(coverage, Result)),
        coverage => maps:get(coverage, Result), coverage_limitations => Limitations,
        corpus_entries => length(Corpus),
        semantic_only_novelty => length([E || E <- Corpus,
            maps:get(retention_reason, maps:get(metadata, E), none) =:= new_semantic]),
        semantic_features => maps:get(semantic_features, Result, []),
        semantic_feature_count => length(maps:get(semantic_features, Result, [])),
        provider_attempts => maps:get(attempts, Counts, 0),
        provider_successes => maps:get(successes, Counts, 0),
        provider_fallbacks => maps:get(fallbacks, Counts, 0),
        provider_counters => Counts, callback_counters => Callback,
        callback_us => maps:get(callback_us, Counts, 0) + maps:get(observer_us, Callback, 0)
            + maps:get(oracle_us, Callback, 0),
        initial_seeds => [#{bytes => byte_size(B), sha256 => crypto:hash(sha256, B)} || B <- maps:get(seeds, C)],
        execution_identities => maps:get(execution_identities, Result, #{}),
        layer_configuration => Layer,
        model_loaded_after_run => [{M, code:is_loaded(M) =/= false}
            || M <- [efz_term_model, efz_xmlrpc_model, efz_qs_model]],
        mutation_trace_entries => length(maps:get(mutation_trace, Result))},
    Summary = case Kind of stateful -> Summary0#{scenario_counters => scenario_counts(C, Result)};
        _ -> Summary0 end,
    write_binary(filename:join(Run, "report.term"), term_to_binary(Result)),
    write_term(filename:join(Run, "configuration.term"), C),
    write_term(filename:join(Run, "summary.term"), Summary),
    write_json(filename:join(Run, "summary.json"), Summary),
    io:format("~p ~p repeat ~p: ~p mutations, ~.1f primary/s, status ~p~n",
        [Kind, Mode, Repeat, Mutations, maps:get(primary_executions_per_second, Summary), maps:get(status, Result)]),
    case maps:get(completed, Summary) andalso maps:get(infrastructure_failures, Stats, 0) =:= 0 of
        true -> ok; false -> halt(1)
    end.

scenario_counts(C, R) ->
    O = efz_stateful_target:options(), Specs = maps:get(arguments, O),
    Recipes = maps:get(mutation_trace, R),
    Inputs = maps:get(seeds, C) ++ [B || Recipe <- Recipes, {ok, B} <- [efz_recipe:regenerate(Recipe)]],
    Counts = [case efz_term_codec:decode(B, Specs, #{}) of
        {ok, [Commands]} -> {scenario, length(Commands)};
        {skip, _} -> rejected_packet
    end || B <- Inputs],
    #{primary_target_executions => maps:get(executions, maps:get(stats, R), 0)
            + maps:get(calibrations, maps:get(stats, R), 0),
      reconstructed_valid_scenarios => length([ok || {scenario, _} <- Counts]),
      reconstructed_rejected_packets => length([ok || rejected_packet <- Counts]),
      reconstructed_library_operations => lists:sum([N || {scenario, N} <- Counts]),
      reconstructed_inputs => length(Inputs),
      source => canonical_seed_and_recipe_packet_decoding_without_target_execution,
      limitation => planned_operations_actual_completion_requires_zero_timeouts_and_crashes}.

%% Cold diagnostic: execute the recorded packet workload in a separate VM.
%% Counts come from actual completed target outcomes, not codec reconstruction.
stateful_counts(Run) ->
    {ok,[C]}=file:consult(filename:join(Run,"configuration.term")),
    {ok,ReportBytes}=file:read_file(filename:join(Run,"report.term")),
    R=binary_to_term(ReportBytes),
    Inputs=maps:get(seeds,C)++[begin {ok,B}=efz_recipe:regenerate(Q),B end || Q<-maps:get(mutation_trace,R)],
    true=length(Inputs)=:=maps:get(executions,maps:get(stats,R))+maps:get(calibrations,maps:get(stats,R)),
    {ok,H}=efz_replay:harness_identity(efz_stateful_target),
    Rows=[begin
        {Us,{ok,Result}}=timer:tc(fun()->efz_recipe:execute(B,efz_stateful_target,[],[],
            #{coverage_backend=>none,timeout=>1000,expected_harness=>H}) end),
        #{status:=confirmed,survivors:=[],violations:=[]}=maps:get(cleanup,Result),
        case maps:get(outcome,Result) of
            {ok,#{scenario_executions:=1,library_operations:=N,trace:=Trace}} ->
                true=N=:=length(Trace),#{accepted=>true,operations=>N,wall_us=>Us};
            {ok,{efz_term_input_rejected,_}} -> #{accepted=>false,operations=>0,wall_us=>Us};
            Other->error({stateful_diagnostic_failure,Other})
        end
    end || B<-Inputs],
    Accepted=[X||X<-Rows,maps:get(accepted,X)],
    Summary=#{schema_version=>1,source=>actual_guarded_target_outcomes_in_separate_diagnostic_vm,
        primary_input_executions=>length(Rows),accepted_scenarios=>length(Accepted),
        rejected_packets=>length(Rows)-length(Accepted),
        completed_library_operations=>lists:sum([maps:get(operations,X)||X<-Rows]),
        accepted_scenario_wall_us=>lists:sum([maps:get(wall_us,X)||X<-Accepted]),
        rejected_packet_wall_us=>lists:sum([maps:get(wall_us,X)||X<-Rows,not maps:get(accepted,X)]),
        rows=>Rows,limitations=>[includes_executor_and_scenario_setup_cleanup,
            no_isolated_per_operation_latency_claim,no_original_campaign_timeouts_or_crashes_required]},
    0=maps:get(timeouts,maps:get(stats,R),0),0=maps:get(crashes,maps:get(stats,R),0),
    write_json(filename:join(Run,"stateful-actual.json"),Summary).

callbacks(Kind, Out) ->
    true = lists:member(Kind, [generic, qs, xmlrpc]),
    C = configuration(Kind),
    {ok, Prepared} = efz_config:prepare(C),
    P = maps:get(gleam_layer, Prepared), M = maps:get(adapter, P), Context = maps:get(adapter_context, P),
    [Raw | _] = maps:get(seeds, C), Target = maps:get(target, C),
    %% One explicit uninstrumented target execution creates the supplied outcome.
    Outcome = {ok, Target:run(Raw)}, Operation = hd(efz_gleam_adapter:operations(P)),
    Functions = [{generation, fun() -> M:generate(1, Context) end,
                              fun() -> efz_gleam_adapter:generate(1, P) end},
        {mutation, fun() -> M:mutate(Raw, Operation, #{choice => 1}, Context) end,
                   fun() -> efz_gleam_adapter:mutate(Raw, Operation, #{choice => 1}, P) end},
        {observation, fun() -> M:observe(Raw, Outcome, Context) end,
                      fun() -> efz_gleam_adapter:observe(Raw, Outcome, P) end},
        {oracle, fun() -> M:oracle(Raw, Outcome, Context) end,
                 fun() -> efz_gleam_adapter:oracle(Raw, Outcome, P) end}],
    Measurements = lists:flatmap(fun({Name, Direct, Facade}) ->
        [{Name, Path, begin
            Result = F(), ok = check_callback(Name, Result), loop(100, F),
            [begin {Us, ok} = timer:tc(fun() -> loop(1000, F) end),
                #{repeat => N, calls => 1000, elapsed_us => Us, us_per_call => Us / 1000,
                  target_executions => 0, result_class => result_class(Result)}
             end || N <- lists:seq(1, 3)]
        end} || {Path, F} <- [{direct_adapter, Direct}, {validated_facade, Facade}]]
    end, Functions),
    Summary = #{kind => Kind, settings => settings(), measurements => Measurements,
        setup_primary_executions => 1, warmup_calls_per_path => 100,
        measured_target_executions => 0, coverage_backend => none,
        scope => compiled_callback_and_boundary_only_without_execution_loop,
        raw_sha256 => crypto:hash(sha256, Raw), adapter_identity => efz_gleam_adapter:identity(P)},
    write_term(filename:join(Out, atom_to_list(Kind) ++ "-callbacks.term"), Summary),
    write_json(filename:join(Out, atom_to_list(Kind) ++ "-callbacks.json"), Summary),
    io:format("~p callback measurements saved~n", [Kind]).

result_class({ok, _, _}) -> ok;
result_class({ok, _}) -> ok;
result_class({pass, _}) -> pass;
result_class({fail, _}) -> fail;
result_class({inconclusive, _}) -> inconclusive;
result_class({skip, _}) -> skip;
result_class({error, _}) -> layer_error.
check_callback(generation, {ok, B}) when is_binary(B) -> ok;
check_callback(mutation, {ok, B, R}) when is_binary(B), is_map(R) -> ok;
check_callback(observation, {ok, Fs}) when is_list(Fs) -> ok;
check_callback(oracle, {pass, _}) -> ok;
check_callback(oracle, {inconclusive, no_property}) -> ok;
check_callback(Name, R) -> error({unexpected_benchmark_callback, Name, R}).
loop(0, _) -> ok;
loop(N, F) -> _ = F(), loop(N - 1, F).
settings() -> #{otp => erlang:system_info(otp_release), erts => erlang:system_info(version),
    schedulers_online => erlang:system_info(schedulers_online),
    architecture => erlang:system_info(system_architecture),
    rng_algorithm => exsplus,
    efz_beam => beam_identity(efz), model_compiler => gleam_1_10_0_optional_profile}.
beam_identity(M) -> {M, B, _} = code:get_object_code(M), crypto:hash(sha256, B).
bounded(R) -> case erlang:external_size(R) =< 2048 of true -> R; false -> truncated_error end.
write_term(Path, T) -> write_binary(Path, iolist_to_binary(io_lib:format("~tp.~n", [T]))).
write_json(Path, T) -> write_binary(Path, json:encode(portable(T))).
write_binary(Path, B) ->
    ok = filelib:ensure_dir(Path), {ok, F} = file:open(Path, [write, binary, exclusive]),
    ok = file:write(F, B), ok = file:close(F).
portable(B) when is_binary(B) -> binary:encode_hex(B, lowercase);
portable(T) when is_tuple(T) -> [portable(X) || X <- tuple_to_list(T)];
portable(M) when is_map(M) -> maps:from_list([{map_key(K), portable(V)} || {K,V} <- maps:to_list(M)]);
portable(L) when is_list(L) -> [portable(X) || X <- L];
portable(A) when A =:= true; A =:= false; A =:= null -> A;
portable(A) when is_atom(A) -> atom_to_binary(A, utf8);
portable(N) when is_integer(N); is_float(N) -> N;
portable(P) when is_pid(P) -> <<"runtime_pid">>;
portable(R) when is_reference(R) -> <<"runtime_reference">>;
portable(P) when is_port(P) -> <<"runtime_port">>;
portable(F) when is_function(F) -> <<"runtime_function">>.
map_key(A) when is_atom(A) -> atom_to_binary(A, utf8);
map_key(B) when is_binary(B) -> B;
map_key(K) -> iolist_to_binary(io_lib:format("~tp", [K])).
