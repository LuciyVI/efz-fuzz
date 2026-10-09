#!/usr/bin/env escript
-mode(compile).

-define(MODULES, [cowboy_http, cowboy_req, cowboy_router, cowboy_stream]).
-define(HEADER, "elapsed_s,executions_total,exec_per_sec_window,exec_per_sec_total,corpus_size,global_coverage_count,new_coverage_events,crashes,timeouts,errors,process_count,memory_total,memory_processes,memory_binary,memory_ets,rss_kib,run_queue,reductions,gc_count,execution_map_arms,execution_maps_allocated,coverage_lifecycle_errors\n").
-define(KEYS, [elapsed_s,executions_total,exec_per_sec_window,exec_per_sec_total,
    corpus_size,global_coverage_count,new_coverage_events,crashes,timeouts,errors,
    process_count,memory_total,memory_processes,memory_binary,memory_ets,rss_kib,
    run_queue,reductions,gc_count,execution_map_arms,execution_maps_allocated,
    coverage_lifecycle_errors]).

main(Args) ->
    try run(parse(Args, #{backend => ets, duration => 900, seed => 424242,
                           corpus => "test/targets/cowboy/seeds", target => cowboy}))
    catch Class:Reason:Stack ->
        io:format(standard_error, "Cowboy bench failed: ~p:~p~n~p~n", [Class,Reason,Stack]),
        halt(1)
    end.

parse([], C) -> C;
parse(["--backend", "ets" | Rest], C) -> parse(Rest, C#{backend => ets});
parse(["--backend", "bitmap" | Rest], C) -> parse(Rest, C#{backend => bitmap});
parse(["--backend", "otp_native_public" | Rest], C) -> parse(Rest, C#{backend => otp_native_public});
parse(["--backend", "none" | Rest], C) -> parse(Rest, C#{backend => none});
parse(["--backend", "none_instrumented" | Rest], C) -> parse(Rest, C#{backend => none_instrumented});
parse(["--backend", "otp_native_no_read" | Rest], C) -> parse(Rest, C#{backend => otp_native_no_read});
parse(["--target", "noop" | Rest], C) -> parse(Rest, C#{target => noop});
parse(["--profile" | Rest], C) -> parse(Rest, C#{profile => true});
parse(["--fixed-replay", V | Rest], C) -> parse(Rest,C#{fixed_replay=>positive(V)});
parse(["--sample-interval", V | Rest], C) -> parse(Rest,C#{sample_interval=>positive(V)});
parse(["--duration", V | Rest], C) -> parse(Rest, C#{duration => positive(V)});
parse(["--seed", V | Rest], C) -> parse(Rest, C#{seed => nonnegative(V)});
parse(["--corpus", V | Rest], C) -> parse(Rest, C#{corpus => V});
parse(["--out", V | Rest], C) -> parse(Rest, C#{out => V});
parse(["--help"], _) ->
    io:format("Usage: run_cowboy_long_bench.sh --backend none|none_instrumented|otp_native_no_read|ets|bitmap|otp_native_public --target cowboy|noop --duration 900 --seed 424242 [--profile] [--sample-interval S] [--fixed-replay N] [--corpus DIR] [--out NEW_DIR]~n"),
    halt(0);
parse(Other, _) -> error({invalid_arguments, Other}).
positive(S) -> N = nonnegative(S), true = N > 0, N.
nonnegative(S) -> {N, []} = string:to_integer(S), true = N >= 0, N.

run(C0) ->
    true = maps:get(target,C0)=:=cowboy orelse maps:get(backend,C0)=:=none,
    paths(),
    C = C0#{out => filename:absname(maps:get(out, C0, default_out(C0)))},
    Out = maps:get(out, C),
    ok = filelib:ensure_dir(filename:join(filename:dirname(Out), "placeholder")),
    ok = file:make_dir(Out),
    ok = file:make_dir(filename:join(Out, "crashes")),
    try
        ok = file:make_dir(filename:join(Out,"target-beams")),
        Backend=maps:get(backend,C),
        TargetKind=maps:get(target,C),
        Artifacts = case TargetKind of cowboy -> instrument(Out,Backend); noop -> [] end,
        {ok, Manifests} = case Backend of
            _ when TargetKind=:=noop -> {ok,[]};
            otp_native_public -> efz_cov_native_public:preflight(Artifacts);
            none_instrumented -> efz_cov_native_public:preflight(Artifacts);
            otp_native_no_read -> efz_cov_native_public:preflight(Artifacts);
            none -> {ok,[]};
            _ -> efz_instrument:preflight(Artifacts)
        end,
        Target=case TargetKind of
            cowboy -> load_harness(), efz_cowboy_long_target;
            noop -> load_noop(), efz_noop_target
        end,
        TargetModules=case TargetKind of cowboy -> ?MODULES; noop -> [] end,
        Probes = lists:sum([case Backend of
            otp_native_public -> length(maps:get(lines,M));
            none_instrumented -> length(maps:get(lines,M));
            otp_native_no_read -> length(maps:get(lines,M));
            _ -> length(maps:get(probes,M))
        end || M <- Manifests]),
        true = Probes =< 65536,
        NativeSchema = case Backend of
            otp_native_public -> maps:get(fingerprint,efz_cov_native_public:prepare(Manifests));
            none_instrumented -> maps:get(fingerprint,efz_cov_native_public:prepare(Manifests));
            otp_native_no_read -> maps:get(fingerprint,efz_cov_native_public:prepare(Manifests));
            _ -> undefined
        end,
        case TargetKind of cowboy -> ok=efz_cowboy_long_target:setup(); noop -> ok end,
        Seeds = seeds(maps:get(corpus, C)),
        true = Seeds =/= [],
        Seed = maps:get(seed, C),
        Tuple = {Seed + 1, Seed + 3, Seed + 7},
        Replay=case maps:find(fixed_replay,C) of
            {ok,N} when N=<10000 -> fixed_inputs(Seeds,Tuple,N);
            {ok,N} -> error({fixed_replay_too_large,N});
            error -> undefined
        end,
        ReplayHash=case Replay of undefined -> undefined;
            _ -> crypto:hash(sha256,term_to_binary(Replay,[deterministic])) end,
        Config0 = #{target => Target,
            artifacts => case Backend of none_instrumented -> [];
                otp_native_no_read -> []; _ -> Artifacts end,
            seeds => Seeds, corpus_dir => filename:join(Out, "corpus"),
            crash_dir => filename:join(Out, "crashes"),
            max_iterations => infinity, mutation_mode => random,
            random_seed => Tuple, selection_seed => Tuple,
            max_input_bytes => 4096, timeout => 100,
            coverage_backend => case Backend of none_instrumented -> none;
                otp_native_no_read -> none; _ -> Backend end,
            coverage_feedback => presence, coverage_validation => prepared,
            performance_profile => maps:get(profile,C,false),
            runtime_oracles => #{enabled => false}},
        Config=case Replay of undefined -> Config0;
            _ -> Config0#{benchmark_replay_inputs=>Replay} end,
        PublicConfig=maps:remove(benchmark_replay_inputs,Config),
        ok = write_term(filename:join(Out, "config.term"),
            #{runner => C, efz_config => PublicConfig, replay_sha256=>ReplayHash,
              replay_count=>case Replay of undefined -> 0; _ -> length(Replay) end,
              instrumented_modules => TargetModules,
              total_probes => Probes, cowboy_version => cowboy_version(),
              native_schema => NativeSchema}),
        ok = environment(Out, C, Probes, PublicConfig, NativeSchema),
        case Replay of undefined -> ok;
            _ -> ok=write_term(filename:join(Out,"replay-inputs.term"),Replay)
        end,
        io:format("Target ~p, Cowboy ~s, ~p probes in ~p modules; ~p seeds; backend ~p~nOutput: ~s~n",
            [TargetKind,cowboy_version(), Probes, length(TargetModules), length(Seeds), maps:get(backend,C), Out]),
        CampaignStart=erlang:monotonic_time(microsecond),
        {ok, _} = efz:start(Config),
        try
            ok = case Replay of
                undefined -> sample_run(Out,maps:get(duration,C),maps:get(backend,C),C);
                _ -> fixed_run(Out,C,ReplayHash,CampaignStart)
            end,
            ok = write_term(filename:join(Out,"coverage.term"),
                            lists:sort(efz_fuzzer:benchmark_coverage()))
        after
            efz:stop(),
            case TargetKind of cowboy -> efz_cowboy_long_target:teardown(); noop -> ok end,
            ok = write_term(filename:join(Out,"cleanup.term"),
                #{efz_fuzzer => whereis(efz_fuzzer), efz_corpus => whereis(efz_corpus),
                  efz_stats => whereis(efz_stats),
                  process_count => erlang:system_info(process_count),
                  memory_total => erlang:memory(total)})
        end
    catch Class:Reason:Stack ->
        _ = file:write_file(filename:join(Out, "error.term"),
            io_lib:format("~tp.~n", [{Class,Reason,Stack}])),
        erlang:raise(Class,Reason,Stack)
    end.

paths() ->
    lists:foreach(fun(P) -> true = code:add_patha(filename:absname(P)) end,
        ["_build/default/lib/efz/ebin" | filelib:wildcard("_build/default/lib/*/ebin")]),
    {module, cowboy} = code:ensure_loaded(cowboy), ok.

default_out(C) ->
    {{Y,Mo,D},{H,Mi,S}} = calendar:universal_time(),
    Stamp = lists:flatten(io_lib:format("~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ",
        [Y,Mo,D,H,Mi,S])),
    filename:join(["artifacts","cowboy-long-bench",
        Stamp ++ case maps:get(target,C) of noop -> "-noop-"; cowboy -> "-" end ++
            atom_to_list(maps:get(backend,C))]).

load_harness() ->
    lists:foreach(fun(M) ->
        Src = filename:join("examples/cowboy/targets", atom_to_list(M) ++ ".erl"),
        {ok, M, Beam} = compile:noenv_file(Src, [binary, debug_info, warnings_as_errors]),
        {module, M} = code:load_binary(M, Src, Beam)
    end, [efz_cowboy_transport, efz_cowboy_stream, efz_cowboy_long_target]),
    ok.

load_noop() ->
    Src="examples/engine/efz_noop_target.erl",
    {ok,efz_noop_target,Beam}=compile:noenv_file(Src,[binary,debug_info,warnings_as_errors]),
    {module,efz_noop_target}=code:load_binary(efz_noop_target,Src,Beam),ok.

instrument(Out,Backend) ->
    Root = filename:absname("_build/default/lib/cowboy"),
    Artifacts=[begin
        Src = filename:join([Root,"src",atom_to_list(M) ++ ".erl"]),
        {ok, Artifact} = case Backend of
            otp_native_public -> efz_cov_native_public:compile(Src,filename:join(Out,"target-beams"));
            none_instrumented -> efz_cov_native_public:compile(Src,filename:join(Out,"target-beams"));
            otp_native_no_read -> efz_cov_native_public:compile(Src,filename:join(Out,"target-beams"));
            none -> raw_compile(Src,filename:join(Out,"target-beams"));
            _ -> efz_instrument:compile(Src,
                #{modules => [M], source_root => Root, strict => false,
                  outdir => filename:join(Out,"target-beams")})
        end,
        Artifact
    end || M <- ?MODULES],
    case Backend of none -> []; _ -> Artifacts end.

raw_compile(Src,Out) ->
    {ok,M,Beam} = compile:noenv_file(Src,[binary,debug_info,warnings_as_errors]),
    Path=filename:join(Out,atom_to_list(M)++".beam"),
    ok=file:write_file(Path,Beam),
    {module,M}=code:load_binary(M,Path,Beam),
    {ok,#{module=>M,beam=>Path}}.

seeds(Dir) ->
    {ok, Names} = file:list_dir(Dir),
    [begin {ok, B} = file:read_file(filename:join(Dir,N)), B end
     || N <- lists:sort(Names), filelib:is_regular(filename:join(Dir,N))].

fixed_inputs(Seeds,Seed,N) ->
    _=rand:seed(exsplus,Seed),
    [begin
        B=lists:nth(1+(I-1) rem length(Seeds),Seeds),
        case I rem 4 of
            0 -> B;
            _ -> efz_mutator_random:mutate(B,#{iteration=>I,max_input_bytes=>4096})
        end
    end || I<-lists:seq(1,N)].

cowboy_version() ->
    {ok, [{application,cowboy,Props}]} = file:consult("_build/default/lib/cowboy/ebin/cowboy.app"),
    proplists:get_value(vsn, Props).

sample_run(Out, Duration, Backend, C) ->
    Path = filename:join(Out,"samples.csv"),
    {ok, File} = file:open(Path, [write]),
    try
        ok = io:put_chars(File, ?HEADER),
        Begin = erlang:monotonic_time(millisecond),
        First = sample(0, 0, 0, 0),
        ok = write_sample(File, First),
        Rows = sampling_loop(File, Begin, Duration, First,
                             maps:get(sample_interval,C,10),
                             maps:get(executions_total, First), [First]),
        case maps:get(profile,C,false) of
            true -> ok=write_stage_samples(filename:join(Out,"stage-samples.csv"),Rows),
                    ok=write_term(filename:join(Out,"input-size-buckets.term"),
                        maps:get(input_size_buckets,lists:last(Rows),#{}));
            false -> ok
        end,
        FinalStatus=efz_fuzzer:benchmark_snapshot(),
        ok=write_term(filename:join(Out,"profile.term"),
                      maps:get(performance_profile,FinalStatus,disabled)),
        ok=write_term(filename:join(Out,"campaign-status.term"),
                      maps:with([completed,status,failure_context],FinalStatus)),
        Summary = summarize(Rows, Duration, Backend),
        ok = write_term(filename:join(Out,"summary.term"), Summary),
        ok = summary_csv(filename:join(Out,"summary.csv"), Summary),
        io:format("Summary: ~tp~n", [maps:with([total_executions,mean_exec_per_sec,
            median_window_exec_per_sec,global_coverage_final,corpus_final_size,
            crashes,timeouts,memory_delta,process_delta], Summary)]),
        ok
    after file:close(File) end.

sampling_loop(File, Begin, Duration, Prev, Interval, StartExec, Acc) ->
    Elapsed = (erlang:monotonic_time(millisecond) - Begin) / 1000,
    case Elapsed >= Duration of
        true -> lists:reverse(Acc);
        false ->
            Next = min(Duration, (length(Acc)) * Interval),
            timer:sleep(max(0, round(Next * 1000) - (erlang:monotonic_time(millisecond)-Begin))),
            Now = (erlang:monotonic_time(millisecond)-Begin) / 1000,
            Row = sample(Now, maps:get(elapsed_s,Prev),
                         maps:get(executions_total,Prev), StartExec),
            ok = write_sample(File, Row),
            sampling_loop(File, Begin, Duration, Row, Interval, StartExec, [Row|Acc])
    end.

fixed_run(Out,C,Hash,Started) ->
    Report=efz:await(max(60000,maps:get(fixed_replay,C)*200)),
    WallUs=erlang:monotonic_time(microsecond)-Started,
    N=maps:get(fixed_replay,C),
    Stats=maps:get(stats,Report),
    true=maps:get(executions,Stats)=:=N,
    completed=maps:get(status,Report),
    Profile=maps:get(performance_profile,Report,disabled),
    ok=write_term(filename:join(Out,"profile.term"),Profile),
    ok=write_term(filename:join(Out,"fixed-replay.term"),
        #{backend=>maps:get(backend,C),inputs=>N,input_sha256=>Hash,
          wall_us=>WallUs,us_per_input=>WallUs/N,exec_per_sec=>1000000*N/WallUs,
          coverage_count=>length(maps:get(coverage,Report)),
          corpus_size=>length(maps:get(corpus,Report)),
          input_size_buckets=>maps:get(input_size_buckets,Report,#{}),
          crashes=>maps:get(crashes,Stats),timeouts=>maps:get(timeouts,Stats)}),
    io:format("Fixed replay: ~B inputs, ~.2f exec/s, ~.1f us/input, sha256 ~s~n",
        [N,1000000*N/WallUs,WallUs/N,binary:encode_hex(Hash)]),ok.

sample(Elapsed, PrevTime, PrevExec, StartExec) ->
    Snap = efz_fuzzer:benchmark_snapshot(),
    Stats = maps:get(stats, Snap),
    Executions = maps:get(executions,Stats) + maps:get(calibrations,Stats),
    Mem = maps:from_list(erlang:memory()),
    {Gc, _, _} = erlang:statistics(garbage_collection),
    {Reductions, _} = erlang:statistics(reductions),
    Delta = Elapsed - PrevTime,
    #{elapsed_s => Elapsed,
      executions_total => Executions,
      exec_per_sec_window => case Delta > 0 of true -> (Executions-PrevExec)/Delta; false -> 0.0 end,
      exec_per_sec_total => case Elapsed > 0 of true -> (Executions-StartExec)/Elapsed; false -> 0.0 end,
      corpus_size => maps:get(corpus_size,Snap),
      global_coverage_count => maps:get(coverage_count,Snap),
      new_coverage_events => maps:get(discoveries,Stats),
      crashes => maps:get(crashes,Stats), timeouts => maps:get(timeouts,Stats),
      errors => maps:get(infrastructure_failures,Stats),
      process_count => erlang:system_info(process_count),
      memory_total => maps:get(total,Mem),
      memory_processes => maps:get(processes,Mem),
      memory_binary => maps:get(binary,Mem), memory_ets => maps:get(ets,Mem),
      rss_kib => rss(), run_queue => erlang:statistics(run_queue),
      reductions => Reductions, gc_count => Gc,
      execution_map_arms => maps:get(execution_map_arms,Snap,0),
      execution_maps_allocated => maps:get(execution_maps_allocated,Snap,0),
      coverage_lifecycle_errors => maps:get(coverage_broken_observations,Stats,0),
      profile_stages=>maps:get(performance_profile,Snap,disabled),
      input_size_buckets=>maps:get(input_size_buckets,Snap,#{}),
      input_bytes_total=>maps:get(input_bytes_total,Snap,0),
      input_count=>maps:get(input_count,Snap,0)}.

write_stage_samples(Path,Rows) ->
    Stages=[iteration_total,corpus_select,mutation,input_preparation,executor,
        executor_outer_us,guardian_prepare_us,trace_setup_us,coverage_open_us,
        target_us,cleanup_wait_us,guardian_finish_us,trace_destroy_us,
        shared_check_us,get_coverage_us,conversion_us,novelty_us,merge_us,
        feedback,corpus_decision,corpus_store,worker_unaccounted],
    Header=["elapsed_s,exec_per_sec_window,avg_input_bytes,gc_delta,run_queue,corpus_size,coverage_count,discoveries", 
            [[",",atom_to_list(K),"_us_per_execution"] || K<-Stages],"\n"],
    Previous=lists:sublist(Rows,length(Rows)-1),
    Body=[stage_row(A,B,Stages) || {A,B}<-lists:zip(Previous,tl(Rows))],
    file:write_file(Path,[Header,Body]).

stage_row(A,B,Stages) ->
    Count=max(1,maps:get(executions_total,B)-maps:get(executions_total,A)),
    InputCount=max(1,maps:get(input_count,B)-maps:get(input_count,A)),
    AvgBytes=(maps:get(input_bytes_total,B)-maps:get(input_bytes_total,A))/InputCount,
    Prefix=[maps:get(elapsed_s,B),maps:get(exec_per_sec_window,B),AvgBytes,
        maps:get(gc_count,B)-maps:get(gc_count,A),maps:get(run_queue,B),
        maps:get(corpus_size,B),maps:get(global_coverage_count,B),
        maps:get(new_coverage_events,B)-maps:get(new_coverage_events,A)],
    Values=Prefix++[stage_delta(A,B,K)/Count || K<-Stages],
    [string:join([case V of F when is_float(F)->value(F); I->integer_to_list(I) end
                  || V<-Values],","),"\n"].

stage_delta(A,B,K) ->
    P1=maps:get(profile_stages,A,disabled),P2=maps:get(profile_stages,B,disabled),
    T1=case P1 of disabled->0;_->maps:get(total_us,maps:get(K,P1,#{}),0) end,
    T2=case P2 of disabled->0;_->maps:get(total_us,maps:get(K,P2,#{}),0) end,
    T2-T1.

rss() ->
    case file:read_file("/proc/self/status") of
        {ok, Data} ->
            case re:run(Data, <<"VmRSS:\\s*([0-9]+) kB">>, [{capture,[1],binary}]) of
                {match,[N]} -> binary_to_integer(N);
                _ -> -1
            end;
        _ -> -1
    end.

write_sample(File, Row) ->
    io:put_chars(File, [string:join([value(maps:get(K,Row)) || K <- ?KEYS], ","), "\n"]).
value(V) when is_float(V) -> lists:flatten(io_lib:format("~.3f",[V]));
value(V) -> integer_to_list(V).

summarize(Rows, Duration, Backend) ->
    First = hd(Rows), Last = lists:last(Rows),
    Rates = lists:sort([maps:get(exec_per_sec_window,R) || R <- tl(Rows)]),
    E = maps:get(executions_total,Last), T = maps:get(elapsed_s,Last),
    #{backend => Backend, requested_duration_s => Duration, actual_duration_s => T,
      total_executions => E, timed_executions => E - maps:get(executions_total,First),
      mean_exec_per_sec => case T > 0 of
          true -> (E-maps:get(executions_total,First))/T; false -> 0.0 end,
      median_window_exec_per_sec => percentile(Rates,0.5),
      p10_window_exec_per_sec => percentile(Rates,0.1),
      p90_window_exec_per_sec => percentile(Rates,0.9),
      first_60s_exec_per_sec => interval_rate(Rows,0,min(60,T)),
      last_60s_exec_per_sec => interval_rate(Rows,max(0,T-60),T),
      global_coverage_final => maps:get(global_coverage_count,Last),
      coverage_discoveries => maps:get(new_coverage_events,Last),
      corpus_final_size => maps:get(corpus_size,Last),
      crashes => maps:get(crashes,Last), timeouts => maps:get(timeouts,Last),
      errors => maps:get(errors,Last),
      memory_start => maps:get(memory_total,First), memory_end => maps:get(memory_total,Last),
      memory_delta => maps:get(memory_total,Last)-maps:get(memory_total,First),
      rss_start_kib => maps:get(rss_kib,First), rss_end_kib => maps:get(rss_kib,Last),
      process_start => maps:get(process_count,First), process_end => maps:get(process_count,Last),
      process_delta => maps:get(process_count,Last)-maps:get(process_count,First),
      execution_map_arms => maps:get(execution_map_arms,Last),
      execution_maps_allocated => maps:get(execution_maps_allocated,Last),
      coverage_lifecycle_errors => maps:get(coverage_lifecycle_errors,Last)}.

percentile([], _) -> 0.0;
percentile(List, P) -> lists:nth(max(1,ceil(length(List)*P)),List).
interval_rate(Rows, From, To) ->
    Before = lists:last([hd(Rows) | [R || R <- Rows, maps:get(elapsed_s,R) =< From]]),
    After = lists:last([R || R <- Rows, maps:get(elapsed_s,R) =< To]),
    D = maps:get(elapsed_s,After)-maps:get(elapsed_s,Before),
    case D > 0 of true -> (maps:get(executions_total,After)-maps:get(executions_total,Before))/D;
        false -> 0.0 end.

summary_csv(Path, Summary) ->
    Keys = maps:keys(Summary),
    Values = [case maps:get(K,Summary) of
        V when is_atom(V) -> atom_to_list(V);
        V when is_float(V) -> value(V);
        V -> integer_to_list(V)
    end || K <- Keys],
    file:write_file(Path,[string:join([atom_to_list(K)||K<-Keys],","),"\n",
                          string:join(Values,","),"\n"]).

%% Write mode avoids emitting arbitrary binary bytes as invalid UTF-8 text.
write_term(Path, Term) -> file:write_file(Path, io_lib:format("~w.~n",[Term])).

environment(Out, C, Probes, Config, NativeSchema) ->
    Lines = [
        {git_commit, os:cmd("git rev-parse HEAD")},
        {git_status, os:cmd("git status --short")},
        {otp, erlang:system_info(otp_release)},
        {erts, erlang:system_info(version)},
        {cowboy, cowboy_version()},
        {os, os:cmd("uname -srm")},
        {cpu, os:cmd("grep -m1 'model name' /proc/cpuinfo")},
        {architecture, erlang:system_info(system_architecture)},
        {schedulers, erlang:system_info(schedulers)},
        {schedulers_online, erlang:system_info(schedulers_online)},
        {backend, maps:get(backend,C)},
        {bitmap_bits,65536},
        {instrumented_modules,case maps:get(target,C) of cowboy -> ?MODULES; noop -> [] end},
        {total_probes,Probes},
        {duration_s,case maps:is_key(fixed_replay,C) of
            true -> not_applicable; false -> maps:get(duration,C) end},
        {fixed_replay_inputs,maps:get(fixed_replay,C,undefined)},
        {native_schema,case NativeSchema of
            undefined -> undefined;
            Hash -> binary:encode_hex(Hash)
        end},
        {random_seed,maps:get(seed,C)},
        {initial_corpus,maps:get(corpus,C)}, {efz_config,Config}
    ],
    file:write_file(filename:join(Out,"environment.txt"),
        [io_lib:format("~p: ~tp~n",[K,V]) || {K,V} <- Lines]).
